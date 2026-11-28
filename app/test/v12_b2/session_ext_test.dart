// v1.2 B2 세션 확장: 슈퍼세트 번갈아 진행·휴식 규칙, 드롭 세트, 종목 바꾸기, 순서 기억, 표시.
import 'package:fitlog/core/api/dto.dart';
import 'package:fitlog/core/api/program_dto.dart';
import 'package:fitlog/core/routes.dart';
import 'package:fitlog/features/rest_timer/rest_timer_controller.dart';
import 'package:fitlog/features/session/current_set.dart';
import 'package:fitlog/features/session/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../b2/harness.dart';

Future<void> settle(WidgetTester t, [int n = 6]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

PlannedSet ps(String key, {bool drop = false}) => PlannedSet(
  plannedSetKey: key,
  targetReps: 5,
  targetWeightKg: 60,
  isAmrap: false,
  isWarmup: false,
  setType: drop ? 'DROP' : null,
);

PlannedWorkout plan() => PlannedWorkout(
  instanceId: 'i1',
  planSeq: 1,
  dayIndex: 0,
  dayKey: 'A',
  dayName: '데이 A',
  week: 1,
  cycle: 1,
  confirmed: true,
  exercises: [
    PlannedExercise(
      key: 'squat',
      exerciseId: squat.id,
      accessory: false,
      superset: 'A',
      sets: [ps('A.0.0'), ps('A.0.1')],
    ),
    PlannedExercise(
      key: 'press',
      exerciseId: dbPress.id,
      accessory: false,
      superset: 'A',
      sets: [ps('A.1.0'), ps('A.1.1')],
    ),
    PlannedExercise(
      key: 'pull',
      exerciseId: pullUp.id,
      accessory: false,
      sets: [ps('A.2.0'), ps('A.2.1', drop: true)],
    ),
  ],
);

Instance instance() => Instance(
  id: 'i1',
  programId: 'p1',
  name: '프로그램',
  status: InstanceStatus.ACTIVE,
  skipPolicy: SkipPolicy.SHIFT,
  startDate: DateTime(2026, 11, 1),
  state: const InstanceState(),
);

Program program() => const Program(
  id: 'p1',
  name: '프로그램',
  builtIn: false,
  dayCount: 1,
  definition: {
    'days': [
      {
        'key': 'A',
        'name': '데이 A',
        'exercises': [{}, {}, {}],
      },
    ],
  },
);

Future<Session> active(Harness h) => h.sessions.watchActiveSession().first.then((s) => s!);

Future<Session> startPlan(WidgetTester t, Harness h) async {
  h.programs.instances['i1'] = instance();
  h.programs.programs['p1'] = program();
  h.programs.plans['i1'] = [plan()];
  await h.pump(t);
  await settle(t);
  await h.container.read(sessionControllerProvider).startProgram('i1', programName: '프로그램');
  GoRouter.of(t.element(find.byType(Scaffold).first)).go(Routes.session);
  await settle(t);
  return active(h);
}

Future<void> complete(WidgetTester t, Harness h, SessionExercise se, int i) async {
  final s = await active(h);
  final e = s.exercises.firstWhere((x) => x.id == se.id);
  await h.container
      .read(sessionControllerProvider)
      .setCompleted(s, e.sets[i], true, timerLabel: 'x');
  await settle(t);
}

void main() {
  testWidgets('시작할 때 계획의 superset·setType이 복사된다', (t) async {
    final h = Harness();
    final s = await startPlan(t, h);
    expect(s.exercises.map((e) => e.supersetGroup), ['A', 'A', null]);
    expect(s.exercises[2].sets.map((w) => w.setType), [SetType.NORMAL, SetType.DROP]);
  });

  testWidgets('슈퍼세트: 현재 세트가 종목을 번갈아 가고 묶음의 마지막 종목 뒤에만 쉰다', (t) async {
    final h = Harness();
    final s = await startPlan(t, h);
    final squatSe = s.exercises[0], pressSe = s.exercises[1];
    expect(currentSetOf(s)!.se.id, squatSe.id);

    await complete(t, h, squatSe, 0);
    var cur = currentSetOf(await active(h))!;
    expect(cur.se.id, pressSe.id); // 번갈아
    expect(h.container.read(restTimerProvider).running, isFalse); // 한 바퀴 중간: 휴식 없음

    await complete(t, h, pressSe, 0);
    cur = currentSetOf(await active(h))!;
    expect(cur.se.id, squatSe.id);
    expect(h.container.read(restTimerProvider).running, isTrue); // 묶음 마지막 종목 뒤
  });

  testWidgets('다음 세트가 드롭이면 휴식 타이머를 띄우지 않는다', (t) async {
    final h = Harness();
    final s = await startPlan(t, h);
    final pull = s.exercises[2];
    await complete(t, h, pull, 0);
    expect(h.container.read(restTimerProvider).running, isFalse);
  });

  testWidgets('드롭 세트는 판정에서 제외된다', (t) async {
    final h = Harness();
    final s = await startPlan(t, h);
    final pull = s.exercises[2];
    // 드롭 세트는 판정 대상이 아니라 실패로 보이지 않는다.
    final drop = pull.sets[1].copyWith(reps: () => 1, completedAt: () => DateTime.utc(2026));
    await h.sessions.updateSet(drop);
    final s2 = await active(h);
    expect(
      s2.exercises[2].sets[1].setType == SetType.DROP && s2.exercises[2].sets[1].isCompleted,
      isTrue,
    );
  });

  testWidgets('묶기·풀기', (t) async {
    final h = Harness();
    final s = await startPlan(t, h);
    final c = h.container.read(sessionControllerProvider);
    await c.unbindSuperset(s, s.exercises[0]);
    var now = await active(h);
    expect(now.exercises.map((e) => e.supersetGroup), [null, null, null]); // 남은 한 종목도 풀림
    await c.bindSupersetWithNext(now, now.exercises[1]);
    now = await active(h);
    expect(now.exercises[1].supersetGroup, isNotNull);
    expect(now.exercises[1].supersetGroup, now.exercises[2].supersetGroup);
    expect(now.exercises[0].supersetGroup, isNull);
  });

  testWidgets('종목 바꾸기 이번만: liftKey·기록 유지, API 호출 없음', (t) async {
    final h = Harness();
    final s = await startPlan(t, h);
    final se = s.exercises[2];
    await h.container.read(sessionControllerProvider).swapThisTime(se.id, legPress.id);
    final now = (await active(h)).exercises[2];
    expect(now.exerciseId, legPress.id);
    expect(now.liftKey, 'pull');
    expect(now.sets.length, 2);
    expect(h.programs.swapCalls, isEmpty);
  });

  testWidgets('종목 바꾸기 앞으로 계속: swap API 호출, 실패하면 던지고 세션은 그대로', (t) async {
    final h = Harness();
    final s = await startPlan(t, h);
    final se = s.exercises[2];
    final c = h.container.read(sessionControllerProvider);
    expect(c.canSwapPersistently(s, se), isTrue);

    h.programs.swapError = Exception('offline');
    await expectLater(c.swapPersistent(s, se, legPress.id), throwsException);
    expect((await active(h)).exercises[2].exerciseId, pullUp.id);

    h.programs.swapError = null;
    await c.swapPersistent(s, se, legPress.id);
    expect(h.programs.swapCalls.single.liftKey, 'pull');
    expect(h.programs.swapCalls.single.exerciseId, legPress.id);
    expect((await active(h)).exercises[2].exerciseId, legPress.id);
  });

  testWidgets('끝낼 때 본운동 순서가 계획과 다르면 day-order를 저장하고 되돌리기는 이전 순서로 저장', (t) async {
    final h = Harness();
    final s = await startPlan(t, h);
    final c = h.container.read(sessionControllerProvider);
    // 같은 순서면 저장하지 않는다.
    expect(await c.saveDayOrderOnFinish(s), isNull);
    expect(h.programs.dayOrderCalls, isEmpty);

    await c.reorderExercises(s.id, [s.exercises[1].id, s.exercises[0].id, s.exercises[2].id]);
    final reordered = await active(h);
    final saved = await c.saveDayOrderOnFinish(reordered);
    expect(saved, isNotNull);
    expect(h.programs.dayOrderCalls.single.dayKey, 'A');
    expect(h.programs.dayOrderCalls.single.order, [1, 0, 2]);

    await c.undoDayOrder(saved!);
    expect(h.programs.dayOrderCalls.last.order, [0, 1, 2]);
  });

  testWidgets('순서 기억 저장이 실패하면 조용히 null', (t) async {
    final h = Harness();
    final s = await startPlan(t, h);
    final c = h.container.read(sessionControllerProvider);
    await c.reorderExercises(s.id, [s.exercises[1].id, s.exercises[0].id, s.exercises[2].id]);
    h.programs.dayOrderError = Exception('x');
    expect(await c.saveDayOrderOnFinish(await active(h)), isNull);
  });

  testWidgets('표시: 슈퍼세트 띠·글자, D/F 배지, 세트 메뉴로 종류 바꾸기', (t) async {
    final h = Harness();
    final s = await startPlan(t, h);
    expect(find.byKey(Key('superset-band-${s.exercises[0].id}')), findsOneWidget);
    expect(find.byKey(Key('superset-${s.exercises[1].id}')), findsOneWidget);
    expect(find.byKey(Key('superset-band-${s.exercises[2].id}')), findsNothing);
    // 계획의 드롭 세트는 D 배지
    final drop = s.exercises[2].sets[1];
    expect(find.descendant(of: find.byKey(Key('set-type-${drop.id}')), matching: find.text('D')), findsOneWidget);

    // 현재 세트(첫 스쿼트 세트)를 실패 세트로
    final cur = s.exercises[0].sets[0];
    await t.tap(find.byKey(Key('set-menu-${cur.id}')));
    await settle(t);
    await t.tap(find.byKey(Key('set-failure-${cur.id}')));
    await settle(t);
    expect(find.descendant(of: find.byKey(Key('set-type-${cur.id}')), matching: find.text('F')), findsOneWidget);
    expect((await active(h)).exercises[0].sets[0].setType, SetType.FAILURE);
  });

  testWidgets('종목 ⋮ 메뉴로 묶음 풀기', (t) async {
    final h = Harness();
    final s = await startPlan(t, h);
    await t.tap(find.byKey(Key('exercise-menu-${s.exercises[0].id}')));
    await settle(t);
    await t.tap(find.byKey(Key('superset-unbind-${s.exercises[0].id}')));
    await settle(t);
    expect((await active(h)).exercises.map((e) => e.supersetGroup), [null, null, null]);
  });
}
