// B2 소유. 계획 캐시(sync.md "계획 캐시"): 활성 인스턴스와 plan(count: 3)을 shared_preferences에 JSON으로 저장한다.
import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../core/api/api_client.dart';
import '../../core/api/program_dto.dart';
import '../../domain/repositories.dart';

class _Entry {
  final Instance instance;
  final List<PlannedWorkout> plans;
  const _Entry(this.instance, this.plans);

  Map<String, Object?> toJson() => {
    'instance': instance.toJson(),
    'plans': [for (final p in plans) p.toJson()],
  };
  factory _Entry.fromJson(Map<String, Object?> j) =>
      _Entry(Instance.fromJson((j['instance'] as Map).cast()), [
        for (final p in (j['plans'] as List))
          PlannedWorkout.fromJson((p as Map).cast()),
      ]);
}

class PrefsPlanCache implements PlanCache {
  PrefsPlanCache({
    required this.programs,
    required this.sessions,
    this.prefsKey = 'plan_cache_v1',
  });

  final ProgramRepository programs;
  final SessionRepository sessions;
  final String prefsKey;

  List<_Entry>? _entries;
  final _bus = StreamController<void>.broadcast();

  Future<List<_Entry>> _load() async {
    final cached = _entries;
    if (cached != null) return cached;
    var list = <_Entry>[];
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(prefsKey);
      if (raw != null) {
        list = [
          for (final e in (jsonDecode(raw) as List))
            _Entry.fromJson((e as Map).cast()),
        ];
      }
    } catch (_) {
      list = [];
    }
    return _entries ??= list;
  }

  Future<void> _save(List<_Entry> list) async {
    _entries = list;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(
        prefsKey,
        jsonEncode([for (final e in list) e.toJson()]),
      );
    } catch (_) {}
    if (!_bus.isClosed) _bus.add(null);
  }

  /// 로그아웃 등으로 캐시를 비운다.
  Future<void> clear() async {
    _entries = [];
    try {
      final p = await SharedPreferences.getInstance();
      await p.remove(prefsKey);
    } catch (_) {}
    if (!_bus.isClosed) _bus.add(null);
  }

  /// 오프라인 규칙: 아직 로컬 세션이 안 쓴 가장 앞 planSeq. 다 썼으면 마지막 계획을 planSeq만 이어 붙인다.
  Future<PlannedWorkout?> _pickCached(_Entry e) async {
    if (e.plans.isEmpty) return null;
    final used = await sessions.planSeqsUsed(e.instance.id);
    final sorted = [...e.plans]..sort((a, b) => a.planSeq.compareTo(b.planSeq));
    for (final p in sorted) {
      if (!used.contains(p.planSeq)) return p;
    }
    final maxSeq = [
      ...sorted.map((p) => p.planSeq),
      ...used,
    ].reduce((a, b) => a > b ? a : b);
    return sorted.last.withPlanSeq(maxSeq + 1);
  }

  Future<List<InstancePlan>> _snapshot() async {
    final list = await _load();
    final out = <InstancePlan>[];
    for (final e in list) {
      if (e.instance.status != InstanceStatus.ACTIVE) continue;
      final p = await _pickCached(e);
      out.add(
        InstancePlan(
          instance: e.instance,
          next: p,
          fromCache: p != null && !p.confirmed,
        ),
      );
    }
    return out;
  }

  @override
  Stream<List<InstancePlan>> watchActive() {
    late StreamController<List<InstancePlan>> c;
    final subs = <StreamSubscription<dynamic>>[];
    var busy = false;
    var again = false;
    Future<void> emit() async {
      if (busy) {
        again = true;
        return;
      }
      busy = true;
      try {
        do {
          again = false;
          final snap = await _snapshot();
          if (!c.isClosed) c.add(snap);
        } while (again);
      } finally {
        busy = false;
      }
    }

    c = StreamController<List<InstancePlan>>(
      onListen: () {
        subs.add(_bus.stream.listen((_) => emit()));
        // 로컬 세션이 바뀌면(planSeq 사용) 다음 계획이 달라질 수 있다.
        subs.add(
          sessions.watchRecentSessions().listen((_) => emit(), onError: (_) {}),
        );
        emit();
      },
      onCancel: () async {
        for (final s in subs) {
          await s.cancel();
        }
      },
    );
    return c.stream;
  }

  @override
  Future<void> refresh({String? instanceId}) async {
    try {
      final old = {for (final e in await _load()) e.instance.id: e};
      final instances = await programs.listInstances(
        status: InstanceStatus.ACTIVE,
      );
      final next = <_Entry>[];
      for (final i in instances) {
        if (instanceId != null && i.id != instanceId && old.containsKey(i.id)) {
          next.add(_Entry(i, old[i.id]!.plans));
          continue;
        }
        try {
          next.add(_Entry(i, await programs.plan(i.id, count: 3)));
        } on ApiException {
          next.add(_Entry(i, old[i.id]?.plans ?? const []));
        }
      }
      await _save(next);
    } on ApiException {
      // 오프라인·서버 오류: 캐시를 그대로 둔다.
    }
  }

  @override
  Future<PlannedWorkout?> nextPlan(String instanceId) async {
    try {
      final plans = await programs.plan(instanceId, count: 1);
      unawaited(refresh(instanceId: instanceId).catchError((_) {}));
      return plans.firstOrNull;
    } on ApiException catch (e) {
      if (!e.isNetwork) rethrow;
    }
    final e = (await _load())
        .where((x) => x.instance.id == instanceId)
        .firstOrNull;
    if (e == null) return null;
    return _pickCached(e);
  }

  void dispose() => _bus.close();
}
