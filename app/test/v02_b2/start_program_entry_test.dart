import 'package:fitlog/core/api/dto.dart';
import 'package:fitlog/core/api/program_dto.dart';
import 'package:fitlog/core/routes.dart';
import 'package:fitlog/features/programs/instance_detail_page.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../b2/harness.dart';

PlannedWorkout _plan(int seq) => PlannedWorkout(
  instanceId: 'i1',
  planSeq: seq,
  dayIndex: 0,
  dayKey: 'A',
  dayName: '데이 A',
  week: seq,
  cycle: 1,
  confirmed: true,
  exercises: [
    PlannedExercise(
      key: 'squat',
      exerciseId: squat.id,
      accessory: false,
      sets: [
        for (var i = 0; i < 3; i++)
          PlannedSet(
            plannedSetKey: 'A.0.$i',
            targetReps: 5,
            targetWeightKg: 100,
            isAmrap: false,
            isWarmup: false,
          ),
      ],
    ),
  ],
);

Future<void> _setup(Harness h) async {
  h.programs.instances['i1'] = Instance(
    id: 'i1',
    programId: 'p1',
    name: 'GZCLP',
    status: InstanceStatus.ACTIVE,
    skipPolicy: SkipPolicy.SHIFT,
    startDate: DateTime(2026, 11, 1),
    state: const InstanceState(week: 1, cycle: 1, seq: 1),
  );
  h.programs.programs['p1'] = Program(
    id: 'p1',
    name: 'GZCLP',
    description: '',
    builtIn: true,
    dayCount: 1,
    definition: {
      'schemaVersion': 1,
      'name': 'GZCLP',
      'lifts': {
        'squat': {
          'exercise': {'id': squat.id},
        },
      },
      'days': [
        {
          'key': 'A',
          'name': '데이 A',
          'exercises': [
            {
              'lift': 'squat',
              'sets': [
                {
                  'count': 3,
                  'reps': 5,
                  'load': {'type': 'WORKING'},
                },
              ],
            },
          ],
        },
      ],
    },
  );
  h.programs.plans['i1'] = [_plan(2), _plan(3)];
  await h.planCache.refresh();
}

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('계획이 있으면 오늘 운동이 위, 자유 세션은 아래 보조 버튼', (t) async {
    final h = Harness();
    await _setup(h);
    await h.pump(t);
    final planY = t.getTopLeft(find.byKey(const Key('plan-card-i1'))).dy;
    final freeY = t.getTopLeft(find.byKey(const Key('home-start'))).dy;
    expect(planY, lessThan(freeY));
    expect(find.text('오늘 운동 시작'), findsOneWidget);
    expect(find.text('계획 없이 자유 세션 시작'), findsOneWidget);
  });

  testWidgets('계획이 없으면 자유 시작이 위, 프로그램 안내가 보인다', (t) async {
    final h = Harness();
    await h.pump(t);
    expect(find.text('자유 세션 시작'), findsOneWidget);
    expect(find.byKey(const Key('home-program-hint')), findsOneWidget);
  });

  testWidgets('비어 있는 자유 세션: 취소하면 유지, 버리고 시작하면 프로그램 세션', (t) async {
    final h = Harness();
    await _setup(h);
    final free = await h.sessions.startSession(tz: 'Asia/Seoul');
    await h.pump(t);

    await t.tap(find.byKey(const Key('plan-start-i1')));
    await _settle(t);
    expect(find.byKey(const Key('discard-free-dialog')), findsOneWidget);
    await t.tap(find.byKey(const Key('discard-free-cancel')));
    await _settle(t);
    expect((await h.sessions.watchActiveSession().first)!.id, free.id);

    await t.tap(find.byKey(const Key('plan-start-i1')));
    await _settle(t);
    await t.tap(find.byKey(const Key('discard-free-confirm')));
    await _settle(t);
    final s = (await h.sessions.watchActiveSession().first)!;
    expect(s.id, isNot(free.id));
    expect(s.programInstanceId, 'i1');
    expect(find.byKey(const Key('plan-header')), findsOneWidget);
  });

  testWidgets('기록이 있는 세션이 진행 중이면 안내만 하고 세션을 유지한다', (t) async {
    final h = Harness();
    await _setup(h);
    final free = await h.sessions.startSession(tz: 'Asia/Seoul');
    final se = await h.sessions.addExercise(free.id, squat.id);
    await h.sessions.addSet(
      se.id,
      const WorkoutSet(id: 'w0', position: 0, weightKg: 100, reps: 5),
    );
    await h.pump(t);

    await t.tap(find.byKey(const Key('plan-start-i1')));
    await _settle(t);
    expect(find.text('진행 중인 세션을 끝내야 시작할 수 있어요'), findsOneWidget);
    expect(find.byKey(const Key('discard-free-dialog')), findsNothing);
    expect(find.byKey(const Key('home-resume')), findsOneWidget);
    expect((await h.sessions.watchActiveSession().first)!.id, free.id);
  });

  testWidgets('프로그램 상세: 오늘 운동 시작 -> 계획 세션', (t) async {
    final h = Harness();
    await _setup(h);
    await h.pump(
      t,
      initial: Routes.instanceDetail('i1'),
      extraRoutes: [
        GoRoute(
          path: '/instances/:id',
          builder: (_, s) =>
              InstanceDetailPage(instanceId: s.pathParameters['id']!),
        ),
      ],
    );
    await _settle(t);
    expect(find.byKey(const Key('instance-start')), findsOneWidget);
    await t.tap(find.byKey(const Key('instance-start')));
    await _settle(t);
    final s = (await h.sessions.watchActiveSession().first)!;
    expect(s.programInstanceId, 'i1');
    expect(s.planSeq, 2);
    expect(find.byKey(const Key('plan-header')), findsOneWidget);
  });
}
