import 'package:drift/drift.dart' show OrderingTerm, Value;
import 'package:fitlog/core/api/dto.dart';
import 'package:fitlog/core/ids.dart';
import 'package:fitlog/data/local/app_database.dart';
import 'package:fitlog/data/local/drift_repositories.dart';
import 'package:fitlog/data/sync/sync_engine.dart';
import 'package:fitlog/domain/repositories.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_server.dart';

void main() {
  late Env env;
  late DriftSessionRepository sessions;

  setUp(() {
    env = makeEnv();
    sessions = DriftSessionRepository(env.db, env.engine, clock: () => env.now);
  });
  tearDown(() => env.close());

  AppDatabase db() => env.db;

  Future<List<OutboxRow>> outbox() => (db().select(db().outbox)..orderBy([(t) => OrderingTerm.asc(t.id)])).get();

  Future<({String s, String se, String set})> seedSession() async {
    final s = await sessions.startSession(tz: 'Asia/Seoul');
    final se = await sessions.addExercise(s.id, 'ex1');
    final w = await sessions.addSet(se.id, WorkoutSet(id: newId(), position: 0, weightKg: 100, reps: 5));
    return (s: s.id, se: se.id, set: w.id);
  }

  test('backoffFor: 5s -> 최대 5분', () {
    expect(SyncEngine.backoffFor(0), Duration.zero);
    expect([for (var i = 1; i <= 8; i++) SyncEngine.backoffFor(i).inSeconds], [5, 10, 20, 40, 80, 160, 300, 300]);
    expect(SyncEngine.backoffFor(100).inSeconds, 300);
  });

  test('push 순서: 부모 먼저, payload에 중첩 없음, parentId 채움', () async {
    final ids = await seedSession();
    final rows = await outbox();
    expect(rows.map((r) => r.entity), ['workout_session', 'session_exercise', 'workout_set']);

    await env.engine.syncNow();
    final sent = env.server.pushes.single;
    expect(sent.map((c) => c['entity']), ['workout_session', 'session_exercise', 'workout_set']);
    expect(sent[1]['parentId'], ids.s);
    expect(sent[2]['parentId'], ids.se);
    expect((sent[0]['payload'] as Map).containsKey('exercises'), isFalse);
    expect((sent[1]['payload'] as Map).containsKey('sets'), isFalse);
    expect(await outbox(), isEmpty);
    expect(env.server.rows.length, 3);
  });

  test('부모가 나중에 쌓인 경우에도 배치 안에서 부모가 앞', () async {
    final ids = await seedSession();
    // 세션을 나중에 수정 -> 같은 줄을 고치므로 id는 그대로. 직접 순서를 뒤집어 확인한다.
    await db().customStatement("UPDATE outbox SET id = id + 100 WHERE entity = 'workout_session'");
    await env.engine.syncNow();
    final sent = env.server.pushes.single;
    expect(sent.first['id'], ids.s);
    expect(await outbox(), isEmpty);
  });

  test('200개씩 분할', () async {
    final s = await sessions.startSession(tz: 'Asia/Seoul');
    final se = await sessions.addExercise(s.id, 'ex1');
    for (var i = 0; i < 450; i++) {
      await sessions.addSet(se.id, WorkoutSet(id: newId(), position: 0, weightKg: 10, reps: 1));
    }
    await env.engine.syncNow();
    expect(env.server.pushes.map((p) => p.length), [200, 200, 52]);
    expect(await outbox(), isEmpty);
    // 두 번째 배치는 첫 배치에 있는 부모를 이미 서버가 알고 있어 PARENT_MISSING 없음
    expect(env.server.rows.length, 452);
  });

  test('멱등: 같은 push를 두 번 받아도 같다', () async {
    await seedSession();
    final copy = await outbox();
    await env.engine.syncNow();
    final before = {for (final e in env.server.rows.entries) e.key: e.value.updatedAt};
    // outbox를 되살려 같은 변경을 다시 보낸다
    for (final r in copy) {
      await db().into(db().outbox).insert(OutboxCompanion.insert(
          entity: r.entity,
          entityId: r.entityId,
          op: r.op,
          parentId: Value(r.parentId),
          payload: Value(r.payload),
          clientUpdatedAt: r.clientUpdatedAt));
    }
    await env.engine.syncNow();
    expect(await outbox(), isEmpty);
    expect({for (final e in env.server.rows.entries) e.key: e.value.updatedAt}, before);
  });

  test('conflict: 서버 값으로 덮어쓰고 outbox 정리', () async {
    final ids = await seedSession();
    // 서버에 더 새로운 세션이 이미 있다(다른 기기)
    env.server.seed(
        'workout_session',
        ids.s,
        {'id': ids.s, 'startedAt': '2026-11-26T10:00:00.000Z', 'tz': 'Asia/Seoul', 'note': '서버 메모'},
        t(500));
    await env.engine.syncNow();
    final row = await (db().select(db().sessions)..where((x) => x.id.equals(ids.s))).getSingle();
    expect(row.note, '서버 메모');
    expect(row.updatedAt, t(500));
    expect((await outbox()), isEmpty);
  });

  test('PARENT_MISSING은 남기고 재시도, 부모가 오면 보낸다', () async {
    final ids = await seedSession();
    env.server.forceReject[ids.s] = 'VALIDATION_FAILED'; // 세션이 거절되면 자식은 PARENT_MISSING
    await env.engine.syncNow();
    var rows = await outbox();
    expect(rows.map((r) => r.entity).toSet(), {'workout_session', 'session_exercise', 'workout_set'});
    final sessionRow = rows.firstWhere((r) => r.entity == 'workout_session');
    expect(sessionRow.attempts, 1);
    expect(sessionRow.lastError, 'VALIDATION_FAILED');
    final childRow = rows.firstWhere((r) => r.entity == 'session_exercise');
    expect(childRow.attempts, 1, reason: 'PARENT_MISSING도 시도 횟수를 늘린다(무한 재시도 방지)');
    expect(childRow.lastError, 'PARENT_MISSING');

    env.server.forceReject.clear();
    await env.engine.syncNow();
    expect(await outbox(), isEmpty);
  });

  test('거절이 반복되면 상한에서 멈춘다', () async {
    final ids = await seedSession();
    env.server.forceReject[ids.set] = 'VALIDATION_FAILED';
    for (var i = 0; i < 8; i++) {
      await env.engine.syncNow();
    }
    final w = (await outbox()).single;
    expect(w.entityId, ids.set);
    expect(w.attempts, env.engine.maxAttempts);
    final pushesWithSet = env.server.pushes.where((p) => p.any((c) => c['id'] == ids.set)).length;
    expect(pushesWithSet, env.engine.maxAttempts);
    final st = await env.engine.watchStatus().firstWhere((s) => s.pending == 1);
    expect(st.phase, SyncPhase.error);
  });

  test('보낸 뒤 또 바뀐 행은 outbox에 남긴다', () async {
    final ids = await seedSession();
    final set = (await sessions.watchSession(ids.s).first)!.exercises.single.sets.single;
    // 서버가 응답하기 전에 같은 세트를 또 고친다
    env.server.beforeRespond = () async {
      env.server.beforeRespond = null;
      env.now = t(60);
      await sessions.updateSet(set.copyWith(reps: () => 8));
    };
    await env.engine.syncNow();
    final left = await outbox();
    expect(left.single.entityId, ids.set, reason: '보낸 뒤 바뀐 세트만 남는다');
    expect(env.server.rows[ids.set]!.payload!['reps'], 5);

    await env.engine.syncNow();
    expect(await outbox(), isEmpty);
    expect(env.server.rows[ids.set]!.payload!['reps'], 8);
  });

  test('pull: 페이지 반복, since 저장, 삭제 반영', () async {
    env.server.pageSize = 2;
    for (var i = 0; i < 5; i++) {
      env.server.seed('body_measurement', 'm$i',
          {'id': 'm$i', 'measuredAt': '2026-11-2${i}T00:00:00Z', 'weightKg': 70.0 + i, 'source': 'MANUAL'}, t(i));
    }
    await env.engine.syncNow();
    expect(env.server.pullSinces.take(3), [0, 2, 4]);
    expect(await db().getLastServerSeq(), 5);
    expect((await db().select(db().bodyMeasurements).get()).length, 5);

    // 서버에서 삭제됨
    env.server.pullSinces.clear();
    env.server.seed('body_measurement', 'm1', null, t(100), op: 'DELETE');
    await env.engine.syncNow();
    expect(env.server.pullSinces, [5]);
    final m1 = await (db().select(db().bodyMeasurements)..where((x) => x.id.equals('m1'))).getSingle();
    expect(m1.deletedAt, isNotNull);
  });

  test('pull: 세션 트리를 받아 조립된다(부모보다 자식이 먼저 와도)', () async {
    env.server.seed('workout_set', 'w1', {'id': 'w1', 'position': 0, 'weightKg': 60.0, 'reps': 5}, t(1), parentId: 'se1');
    env.server.seed('session_exercise', 'se1', {'id': 'se1', 'exerciseId': 'ex1', 'position': 0}, t(2), parentId: 's1');
    env.server.seed(
        'workout_session', 's1', {'id': 's1', 'startedAt': '2026-11-26T10:00:00Z', 'endedAt': '2026-11-26T11:00:00Z', 'tz': 'Asia/Seoul'}, t(3));
    await env.engine.syncNow();
    final s = await sessions.watchSession('s1').first;
    expect(s!.exercises.single.sets.single.weightKg, 60);
    expect(s.endedAt, DateTime.utc(2026, 11, 26, 11));
  });

  test('pull은 미전송 outbox가 있는 행을 덮어쓰지 않는다', () async {
    final ids = await seedSession();
    env.server.failNetwork = 1; // 첫 sync는 실패 -> outbox 그대로
    await env.engine.syncNow();
    expect(await outbox(), isNotEmpty);
    // 서버에는 다른 기기에서 더 오래된 값이 있다. 로컬이 더 새로우므로 로컬이 이겨야 한다
    await sessions.updateSessionNote(ids.s, '로컬 메모');
    env.server.seed('workout_session', ids.s,
        {'id': ids.s, 'startedAt': '2026-11-26T10:00:00Z', 'tz': 'Asia/Seoul', 'note': '서버 예전 메모'}, t(-100));
    await env.engine.syncNow();
    expect(env.server.rows[ids.s]!.payload!['note'], '로컬 메모');
    final row = await (db().select(db().sessions)..where((x) => x.id.equals(ids.s))).getSingle();
    expect(row.note, '로컬 메모');
  });

  test('pull 보호: push가 막힌 상태(오프라인 아님)에서도 outbox 행은 그대로', () async {
    final ids = await seedSession();
    env.server.forceReject[ids.s] = 'VALIDATION_FAILED';
    env.server.seed('workout_session', ids.s, {'id': ids.s, 'startedAt': '2026-11-26T10:00:00Z', 'tz': 'UTC', 'note': 'X'}, t(-5));
    await env.engine.syncNow();
    final row = await (db().select(db().sessions)..where((x) => x.id.equals(ids.s))).getSingle();
    expect(row.tz, 'Asia/Seoul');
  });

  test('네트워크 실패: offline 상태, 실패 횟수 증가, 복구되면 성공', () async {
    await seedSession();
    env.server.failNetwork = 1;
    await env.engine.syncNow();
    var st = await env.engine.watchStatus().first;
    expect(st.phase, SyncPhase.offline);
    expect(env.engine.failures, 1);
    expect(env.engine.nextRetryDelay, const Duration(seconds: 5));
    env.now = t(10);
    await env.engine.syncNow();
    st = await env.engine.watchStatus().firstWhere((s) => s.pending == 0);
    expect(st.phase, SyncPhase.idle);
    expect(st.lastSyncedAt, t(10));
    expect(env.engine.failures, 0);
  });

  test('401은 재시도 없이 offline, 500은 error', () async {
    await seedSession();
    env.server
      ..failStatus = 1
      ..statusToFail = 401;
    await env.engine.syncNow();
    expect((await env.engine.watchStatus().first).phase, SyncPhase.offline);
    expect(env.engine.failures, 0);
    env.server
      ..failStatus = 1
      ..statusToFail = 500;
    await env.engine.syncNow();
    expect((await env.engine.watchStatus().first).phase, SyncPhase.error);
    expect(env.engine.failures, 1);
  });

  test('동시 실행 방지: 도는 중 syncNow는 같은 결과를 기다린다', () async {
    await seedSession();
    final a = env.engine.syncNow();
    final b = env.engine.syncNow();
    await Future.wait([a, b]);
    expect(env.server.pushes.length, 1);
  });

  test('watchStatus: pending은 outbox 수', () async {
    await seedSession();
    final st = await env.engine.watchStatus().firstWhere((s) => s.pending == 3);
    expect(st.pending, 3);
  });

  test('SyncLifecycle 없이도 clearAll 뒤 상태 초기화', () async {
    await seedSession();
    await env.engine.syncNow();
    await DriftLocalDataStore(env.db, engine: env.engine).clearAll();
    expect(await env.db.getLastServerSeq(), 0);
    expect((await env.engine.watchStatus().first).lastSyncedAt, isNull);
  });
}
