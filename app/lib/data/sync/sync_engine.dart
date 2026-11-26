// B3 소유. outbox push → pull 동기화(contracts/v0.1/sync.md).
// - 부모 먼저(세션 → 종목 → 세트), 삭제는 자식 먼저. 한 번에 최대 200개.
// - applied: outbox 정리(보낸 뒤 또 바뀐 행은 남김). conflict: 서버 값으로 덮어씀. PARENT_MISSING: 남겨서 재시도.
// - pull은 outbox에 남은 행을 덮어쓰지 않는다(다음 push가 LWW로 결정).
// - 실패하면 지수 백오프 5s → 최대 5분. 401은 B1의 Dio 인터셉터가 갱신을 시도한 뒤에도 실패한 경우라 재시도하지 않는다.
import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';

import '../../core/api/api_client.dart';
import '../../core/api/dto.dart';
import '../../domain/repositories.dart';
import '../local/app_database.dart';
import '../local/local_mappers.dart';

class SyncEngine implements SyncService {
  final AppDatabase db;
  final ApiClient api;
  final DateTime Function() _clock;

  /// 한 번에 보내는 최대 변경 수(계약: 200).
  final int batchSize;

  /// 이 횟수 이상 거절된 항목은 더 보내지 않는다(남아 있으면서 lastError를 보여줌).
  final int maxAttempts;

  SyncEngine({
    required this.db,
    required this.api,
    DateTime Function()? clock,
    this.batchSize = 200,
    this.maxAttempts = 5,
  }) : _clock = clock ?? (() => DateTime.now().toUtc());

  /// 연속 실패 횟수 → 다음 시도까지 기다릴 시간. 5s, 10s, 20s ... 최대 5분.
  static Duration backoffFor(int failures) {
    if (failures <= 0) return Duration.zero;
    final secs = 5 * (1 << (failures - 1).clamp(0, 10));
    return Duration(seconds: secs > 300 ? 300 : secs);
  }

  /// push 순서: UPSERT는 부모 먼저, DELETE는 자식 먼저.
  static int entityRank(SyncEntity e) => switch (e) {
        SyncEntity.exercise => 0,
        SyncEntity.body_measurement => 0,
        SyncEntity.workout_session => 1,
        SyncEntity.session_exercise => 2,
        SyncEntity.workout_set => 3,
      };

  // ---------- 상태 ----------

  SyncPhase _phase = SyncPhase.idle;
  DateTime? _lastSyncedAt;
  String? _lastError;
  int _failures = 0;
  Future<void>? _running;
  bool _rerun = false;
  bool _disposed = false;
  Timer? _debounce;
  Timer? _retry;
  final _internal = StreamController<void>.broadcast();

  /// 지금 예약된 재시도까지 남은 대기(테스트·표시용).
  Duration get nextRetryDelay => backoffFor(_failures);
  int get failures => _failures;

  void _setState({SyncPhase? phase, DateTime? lastSyncedAt, String? lastError, bool clearError = false}) {
    if (phase != null) _phase = phase;
    if (lastSyncedAt != null) _lastSyncedAt = lastSyncedAt;
    if (clearError) _lastError = null;
    if (lastError != null) _lastError = lastError;
    if (!_internal.isClosed) _internal.add(null);
  }

  @override
  Stream<SyncStatus> watchStatus() {
    late StreamController<SyncStatus> c;
    StreamSubscription<int>? countSub;
    StreamSubscription<void>? stateSub;
    var pending = 0;
    void emit() {
      if (!c.isClosed) {
        c.add(SyncStatus(phase: _phase, pending: pending, lastSyncedAt: _lastSyncedAt, lastError: _lastError));
      }
    }

    c = StreamController<SyncStatus>(
      onListen: () {
        countSub = db.watchOutboxCount().listen((n) {
          pending = n;
          emit();
        });
        stateSub = _internal.stream.listen((_) => emit());
      },
      onCancel: () async {
        await countSub?.cancel();
        await stateSub?.cancel();
      },
    );
    return c.stream;
  }

  // ---------- 트리거 ----------

  @override
  void schedule({Duration delay = const Duration(seconds: 5)}) {
    if (_disposed) return;
    _debounce?.cancel();
    _debounce = Timer(delay, () => unawaited(syncNow()));
  }

  /// 예외를 밖으로 던지지 않는다. 결과는 [watchStatus]로 본다.
  @override
  Future<void> syncNow() {
    if (_disposed) return Future.value();
    _debounce?.cancel();
    _retry?.cancel();
    final running = _running;
    if (running != null) {
      _rerun = true; // 도는 중에 쓰기가 생겼을 수 있으니 한 번 더
      return running;
    }
    return _running = _loop().whenComplete(() => _running = null);
  }

  Future<void> _loop() async {
    do {
      _rerun = false;
      await _runOnce();
    } while (_rerun && _failures == 0 && !_disposed);
  }

  Future<void> _runOnce() async {
    _setState(phase: SyncPhase.syncing);
    try {
      await _push();
      await _pull();
      _failures = 0;
      final dead = await _deadLetter();
      _setState(
        phase: dead == null ? SyncPhase.idle : SyncPhase.error,
        lastSyncedAt: _clock(),
        lastError: dead,
        clearError: dead == null,
      );
    } on ApiException catch (e) {
      if (e.isUnauthenticated) {
        // 로그인 안 됨/만료. 로그인하면 SyncLifecycle이 다시 트리거한다.
        _setState(phase: SyncPhase.offline, lastError: e.code);
      } else if (e.isNetwork) {
        _failed(SyncPhase.offline, e.message);
      } else {
        _failed(SyncPhase.error, e.toString());
      }
    } catch (e) {
      _failed(SyncPhase.error, e.toString());
    }
  }

  void _failed(SyncPhase phase, String message) {
    _failures++;
    _setState(phase: phase, lastError: message);
    if (_disposed) return;
    _retry?.cancel();
    _retry = Timer(backoffFor(_failures), () => unawaited(syncNow()));
  }

  Future<String?> _deadLetter() async {
    final row = await (db.select(db.outbox)
          ..where((t) => t.attempts.isBiggerOrEqualValue(maxAttempts))
          ..limit(1))
        .getSingleOrNull();
    return row == null ? null : '${row.entity} ${row.entityId}: ${row.lastError ?? 'rejected'}';
  }

  // ---------- push ----------

  Future<List<OutboxRow>> _nextBatch(Set<int> seen) async {
    final rows = await (db.select(db.outbox)
          ..where((t) => t.attempts.isSmallerThanValue(maxAttempts) & t.id.isNotIn(seen))
          ..orderBy([(t) => OrderingTerm.asc(t.id)])
          ..limit(batchSize))
        .get();
    int rank(OutboxRow r) => entityRank(SyncEntity.values.byName(r.entity));
    rows.sort((a, b) {
      final au = a.op == ChangeOp.UPSERT.name, bu = b.op == ChangeOp.UPSERT.name;
      if (au != bu) return au ? -1 : 1; // UPSERT 먼저
      final c = au ? rank(a).compareTo(rank(b)) : rank(b).compareTo(rank(a));
      return c != 0 ? c : a.id.compareTo(b.id);
    });
    return rows;
  }

  Change _toChange(OutboxRow r) => Change(
        entity: SyncEntity.values.byName(r.entity),
        id: r.entityId,
        op: ChangeOp.values.byName(r.op),
        parentId: r.parentId,
        payload: r.payload == null ? null : (jsonDecode(r.payload!) as Map).cast<String, Object?>(),
        clientUpdatedAt: r.clientUpdatedAt.toUtc(),
      );

  Future<void> _push() async {
    final seen = <int>{};
    while (!_disposed) {
      final rows = await _nextBatch(seen);
      if (rows.isEmpty) return;
      seen.addAll(rows.map((r) => r.id));
      final results = await api.syncPush([for (final r in rows) _toChange(r)]);
      await _handleResults(rows, results);
    }
  }

  Future<void> _handleResults(List<OutboxRow> rows, List<ChangeResult> results) {
    final byId = {for (final r in results) r.id: r};
    return db.transaction(() async {
      for (final row in rows) {
        final res = byId[row.entityId];
        if (res == null) continue; // 응답에 없으면 그대로 두고 다음에 다시
        switch (res.status) {
          case ChangeStatus.applied:
            await _deleteIfUnchanged(row);
          case ChangeStatus.conflict:
            await _onConflict(row, res);
          case ChangeStatus.rejected:
            await _onRejected(row, res);
        }
      }
    });
  }

  /// 보낸 뒤에 같은 행이 또 바뀌었으면(clientUpdatedAt이 달라졌으면) 남긴다.
  Future<void> _deleteIfUnchanged(OutboxRow sent) => (db.delete(db.outbox)
        ..where((t) => t.id.equals(sent.id) & t.clientUpdatedAt.equals(sent.clientUpdatedAt)))
      .go();

  Future<void> _onConflict(OutboxRow sent, ChangeResult res) async {
    final cur = await (db.select(db.outbox)..where((t) => t.id.equals(sent.id))).getSingleOrNull();
    if (cur != null && cur.clientUpdatedAt.isAfter(sent.clientUpdatedAt)) {
      return; // 보내는 사이 더 새로 고쳤다 → 그 변경이 다음 push에서 다시 겨룬다
    }
    if (res.server != null) await db.applyServerChange(res.server!);
    await (db.delete(db.outbox)..where((t) => t.id.equals(sent.id))).go();
  }

  Future<void> _onRejected(OutboxRow sent, ChangeResult res) async {
    final code = res.code ?? 'REJECTED';
    final q = db.update(db.outbox)..where((t) => t.id.equals(sent.id) & t.clientUpdatedAt.equals(sent.clientUpdatedAt));
    if (code == 'PARENT_MISSING') {
      if (sent.op == ChangeOp.DELETE.name) {
        // 지울 대상의 부모가 서버에 없다 = 이미 없는 것과 같다. 몇 번 시도해도 안 되면 포기.
        if (sent.attempts + 1 >= maxAttempts) {
          await (db.delete(db.outbox)..where((t) => t.id.equals(sent.id))).go();
          return;
        }
        await q.write(OutboxCompanion(attempts: Value(sent.attempts + 1), lastError: Value(code)));
      } else {
        await q.write(OutboxCompanion(lastError: Value(code)));
      }
      return;
    }
    await q.write(OutboxCompanion(attempts: Value(sent.attempts + 1), lastError: Value(code)));
  }

  // ---------- pull ----------

  Future<void> _pull() async {
    var since = await db.getLastServerSeq();
    while (!_disposed) {
      final r = await api.syncPull(since);
      await db.transaction(() async {
        // 아직 못 보낸 변경이 있는 행은 덮어쓰지 않는다.
        final pending = {for (final o in await db.select(db.outbox).get()) o.entityId};
        for (final c in r.changes) {
          if (pending.contains(c.id)) continue;
          await db.applyServerChange(c);
        }
        await db.setLastServerSeq(r.nextSince);
      });
      if (!r.hasMore || r.nextSince <= since) return;
      since = r.nextSince;
    }
  }

  // ---------- 수명 ----------

  /// 로그아웃·계정 삭제 때 메모리 상태를 비운다(DB는 [AppDatabase.wipe]).
  Future<void> reset() async {
    _debounce?.cancel();
    _retry?.cancel();
    _failures = 0;
    _lastSyncedAt = null;
    _lastError = null;
    _phase = SyncPhase.idle;
    if (!_internal.isClosed) _internal.add(null);
  }

  Future<void> dispose() async {
    _disposed = true;
    _debounce?.cancel();
    _retry?.cancel();
    await _internal.close();
  }
}
