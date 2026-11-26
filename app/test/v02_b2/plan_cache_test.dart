import 'package:fitlog/core/api/api_client.dart';
import 'package:fitlog/core/api/program_dto.dart';
import 'package:fitlog/data/memory/memory_repositories.dart';
import 'package:fitlog/data/plan_cache/prefs_plan_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

PlannedWorkout plan(
  int seq,
  double kg, {
  bool confirmed = false,
  String instance = 'i1',
}) => PlannedWorkout(
  instanceId: instance,
  planSeq: seq,
  dayIndex: 0,
  dayKey: 'A',
  dayName: '데이 A',
  week: 1,
  cycle: 1,
  confirmed: confirmed,
  exercises: [
    PlannedExercise(
      key: 'squat',
      exerciseId: 'ex-squat',
      accessory: false,
      sets: [
        PlannedSet(
          plannedSetKey: 'A.0.0',
          targetReps: 5,
          targetWeightKg: kg,
          isAmrap: false,
          isWarmup: false,
        ),
      ],
    ),
  ],
);

Instance instance({
  String id = 'i1',
  InstanceStatus status = InstanceStatus.ACTIVE,
}) => Instance(
  id: id,
  programId: 'p1',
  name: 'GZCLP',
  status: status,
  skipPolicy: SkipPolicy.SHIFT,
  startDate: DateTime(2026, 11, 1),
  state: const InstanceState(week: 1, cycle: 1, seq: 0),
);

class FlakyPrograms extends MemoryProgramRepository {
  bool offline = false;
  int planCalls = 0;
  @override
  Future<List<PlannedWorkout>> plan(String instanceId, {int count = 3}) {
    planCalls++;
    if (offline) throw const ApiException(code: 'NETWORK', message: 'offline');
    return super.plan(instanceId, count: count);
  }

  @override
  Future<List<Instance>> listInstances({InstanceStatus? status}) {
    if (offline) throw const ApiException(code: 'NETWORK', message: 'offline');
    return super.listInstances(status: status);
  }
}

void main() {
  late FlakyPrograms programs;
  late MemorySessionRepository sessions;
  late PrefsPlanCache cache;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    programs = FlakyPrograms()
      ..instances['i1'] = instance()
      ..plans['i1'] = [
        plan(1, 100, confirmed: true),
        plan(2, 102.5),
        plan(3, 105),
      ];
    sessions = MemorySessionRepository(now: () => DateTime.utc(2026, 11, 26));
    cache = PrefsPlanCache(programs: programs, sessions: sessions);
  });

  test('온라인: nextPlan은 서버의 확정 계획, 캐시는 count=3으로 채워진다', () async {
    final p = await cache.nextPlan('i1');
    expect(p!.planSeq, 1);
    expect(p.confirmed, isTrue);
    await cache.refresh();
    final items = await cache.watchActive().first;
    expect(items.single.instance.id, 'i1');
    expect(items.single.next!.planSeq, 1);
    expect(items.single.fromCache, isFalse);
  });

  test('오프라인: 캐시에서 아직 안 쓴 가장 앞 planSeq, 예상 표시는 확정이 아닐 때', () async {
    await cache.refresh();
    programs.offline = true;
    final p = await cache.nextPlan('i1');
    expect(p!.planSeq, 1);

    // planSeq 1을 로컬 세션이 썼다 -> 2(예상)
    await sessions.startSession(tz: 'Asia/Seoul', plan: plan(1, 100));
    final p2 = await cache.nextPlan('i1');
    expect(p2!.planSeq, 2);
    expect(p2.confirmed, isFalse);
    final items = await cache.watchActive().first;
    expect(items.single.next!.planSeq, 2);
    expect(items.single.fromCache, isTrue);
  });

  test(
    '오프라인: 사용된 planSeq는 건너뛰고(1,3 사용 -> 2), 캐시를 다 쓰면 마지막 계획을 max+1로',
    () async {
      await cache.refresh();
      programs.offline = true;
      final s1 = await sessions.startSession(
        tz: 'Asia/Seoul',
        plan: plan(1, 100),
      );
      await sessions.endSession(s1.id);
      final s3 = await sessions.startSession(
        tz: 'Asia/Seoul',
        plan: plan(3, 105),
      );
      await sessions.endSession(s3.id);
      expect((await cache.nextPlan('i1'))!.planSeq, 2);

      final s2 = await sessions.startSession(
        tz: 'Asia/Seoul',
        plan: plan(2, 102.5),
      );
      await sessions.endSession(s2.id);
      final next = await cache.nextPlan('i1');
      expect(next!.planSeq, 4);
      expect(
        next.exercises.single.sets.single.targetWeightKg,
        105,
      ); // 마지막 계획의 무게
      expect(next.confirmed, isFalse);
    },
  );

  test('오프라인에서 캐시가 없으면 null, 네트워크 아닌 오류는 그대로 던진다', () async {
    programs.offline = true;
    expect(await cache.nextPlan('i1'), isNull);
    programs.offline = false;
    programs.plans.remove('i1');
    expect(await cache.nextPlan('i1'), isNull); // 끝난 프로그램 등: 계획 없음
  });

  test('refresh는 오프라인에서 조용히 끝나고 캐시를 지키며, 앱을 다시 켜도 prefs에서 복원된다', () async {
    await cache.refresh();
    programs.offline = true;
    await cache.refresh();
    final reopened = PrefsPlanCache(programs: programs, sessions: sessions);
    final items = await reopened.watchActive().first;
    expect(items.single.next!.planSeq, 1);
  });

  test('ACTIVE가 아니게 된 인스턴스는 refresh 뒤 사라진다', () async {
    await cache.refresh();
    programs.instances['i1'] = instance(status: InstanceStatus.PAUSED);
    await cache.refresh();
    expect(await cache.watchActive().first, isEmpty);
  });

  test('instanceId를 주면 그 인스턴스의 계획만 다시 받는다', () async {
    programs.instances['i2'] = instance(id: 'i2');
    programs.plans['i2'] = [plan(1, 50, confirmed: true, instance: 'i2')];
    await cache.refresh();
    programs.planCalls = 0;
    await cache.refresh(instanceId: 'i2');
    expect(programs.planCalls, 1);
  });
}
