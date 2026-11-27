// 세션 화면: 현재 세트 패널, 하단 "N세트 완료", 진행 표시, 목표 미달, 휴식 다음 세트 안내.
import 'package:fitlog/core/api/dto.dart';
import 'package:fitlog/core/api/program_dto.dart';
import 'package:fitlog/core/routes.dart';
import 'package:fitlog/features/rest_timer/rest_timer_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../b2/harness.dart';
import '../support/app_env.dart' as env;

Future<void> settle(WidgetTester t, [int n = 6]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

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
      sets: [
        for (var i = 0; i < 3; i++)
          PlannedSet(
            plannedSetKey: 'A.0.$i',
            targetReps: 5,
            targetWeightKg: 100,
            isAmrap: i == 2,
            isWarmup: false,
          ),
      ],
    ),
  ],
);

Future<Session> active(Harness h) =>
    h.sessions.watchActiveSession().first.then((s) => s!);

Future<Session> startPlan(WidgetTester t, Harness h) async {
  await h.sessions.startSession(tz: 'Asia/Seoul', plan: plan());
  await h.pump(t, initial: Routes.session);
  await settle(t);
  return active(h);
}

String textOf(WidgetTester t, Key k) => t.widget<Text>(find.byKey(k)).data!;

void main() {
  testWidgets('현재 세트가 펼쳐지고 목표·휴식 길이·진행이 보인다', (t) async {
    final h = Harness();
    final s = await startPlan(t, h);
    final se = s.exercises.single;
    final sets = se.sets;

    expect(textOf(t, Key('progress-${se.id}')), '0/3세트');
    expect(find.byKey(const Key('set-table-header')), findsOneWidget);
    expect(find.text('계획'), findsOneWidget);
    // 현재 세트(첫 세트)만 펼쳐진다
    expect(find.byKey(Key('current-${sets[0].id}')), findsOneWidget);
    expect(find.byKey(Key('weight-${sets[0].id}')), findsOneWidget);
    expect(find.byKey(Key('weight-${sets[1].id}')), findsNothing);
    expect(find.text('목표 5회 × 100 kg'), findsOneWidget);
    expect(find.text('휴식 2:00'), findsOneWidget);
    // 나머지는 계획 열: "100×5", AMRAP은 "100×5+"
    expect(find.text('100×5'), findsOneWidget);
    expect(find.text('100×5+'), findsOneWidget);
    expect(find.text('스쿼트 1세트 완료'), findsOneWidget);
  });

  testWidgets('"N세트 완료"가 현재 세트를 완료하고 다음 세트로 넘어가며 휴식 막대가 다음을 알려준다', (t) async {
    final h = Harness();
    final s = await startPlan(t, h);
    final se = s.exercises.single;
    final sets = se.sets;

    await t.tap(find.byKey(const Key('complete-current')));
    await settle(t);

    final after = await active(h);
    expect(after.exercises.single.sets[0].isCompleted, isTrue);
    expect(after.exercises.single.sets[1].isCompleted, isFalse);
    expect(textOf(t, Key('progress-${se.id}')), '1/3세트');
    expect(find.byKey(Key('current-${sets[1].id}')), findsOneWidget);
    expect(find.byKey(Key('current-${sets[0].id}')), findsNothing);
    expect(find.byKey(Key('weight-${sets[1].id}')), findsOneWidget);
    expect(find.text('스쿼트 2세트 완료'), findsOneWidget);
    expect(h.container.read(restTimerProvider).running, isTrue);
    expect(textOf(t, const Key('restTimerNext')), '다음 · 2세트 · 100 kg×5');

    // 끝까지 완료하면 버튼은 비활성
    await t.tap(find.byKey(const Key('complete-current')));
    await settle(t);
    await t.tap(find.byKey(const Key('complete-current')));
    await settle(t);
    expect(textOf(t, Key('progress-${se.id}')), '3/3세트');
    expect(find.text('모든 세트 완료'), findsOneWidget);
    final btn = t.widget<FilledButton>(
      find.byKey(const Key('complete-current')),
    );
    expect(btn.onPressed, isNull);
  });

  testWidgets('횟수가 비면 하단 버튼도 체크박스와 같은 검증으로 막는다', (t) async {
    final h = Harness();
    final s0 = await h.sessions.startSession(tz: 'Asia/Seoul');
    final se = await h.sessions.addExercise(s0.id, squat.id);
    await h.sessions.addSet(
      se.id,
      const WorkoutSet(id: 'w1', position: 0, weightKg: 100),
    );
    await h.pump(t, initial: Routes.session);
    await settle(t);
    await t.tap(find.byKey(const Key('complete-current')));
    await settle(t);
    expect(find.text('횟수를 입력해 주세요'), findsOneWidget);
    expect((await active(h)).exercises.single.sets.single.isCompleted, isFalse);
  });

  testWidgets('다른 줄을 누르면 그 줄이 펼쳐지고, 현재 세트가 바뀌면 다시 현재를 따라간다', (t) async {
    final h = Harness();
    final s = await startPlan(t, h);
    final sets = s.exercises.single.sets;

    await t.tap(find.byKey(Key('row-${sets[2].id}')));
    await settle(t);
    expect(find.byKey(Key('weight-${sets[2].id}')), findsOneWidget);
    expect(find.byKey(Key('weight-${sets[0].id}')), findsNothing);
    // 하단 버튼은 그래도 현재(첫 미완료) 세트를 완료한다
    expect(find.text('스쿼트 1세트 완료'), findsOneWidget);
    await t.tap(find.byKey(const Key('complete-current')));
    await settle(t);
    expect(find.byKey(Key('weight-${sets[1].id}')), findsOneWidget);
    expect(find.byKey(Key('weight-${sets[2].id}')), findsNothing);
  });

  testWidgets('횟수 미달 세트는 아이콘과 "목표 미달"·"3/5"로 표시한다', (t) async {
    final h = Harness();
    final s = await startPlan(t, h);
    final sets = s.exercises.single.sets;

    await t.enterText(find.byKey(Key('reps-${sets[0].id}')), '3');
    await settle(t);
    await t.tap(find.byKey(const Key('complete-current')));
    await settle(t);

    expect(find.byKey(Key('failed-${sets[0].id}')), findsOneWidget);
    expect(find.text('목표 미달'), findsOneWidget);
    expect(find.text('3/5'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsWidgets);
  });

  testWidgets('워밍업은 W1로 세고 진행 수에서 뺀다', (t) async {
    final h = Harness();
    final s0 = await h.sessions.startSession(tz: 'Asia/Seoul');
    final se = await h.sessions.addExercise(s0.id, squat.id);
    await h.sessions.addSet(
      se.id,
      const WorkoutSet(
        id: 'w0',
        position: 0,
        isWarmup: true,
        weightKg: 40,
        reps: 5,
      ),
    );
    await h.sessions.addSet(
      se.id,
      const WorkoutSet(id: 'w1', position: 1, weightKg: 100, reps: 5),
    );
    await h.pump(t, initial: Routes.session);
    await settle(t);
    expect(textOf(t, Key('progress-${se.id}')), '0/1세트');
    expect(find.text('W1'), findsOneWidget);
    expect(find.text('스쿼트 W1 완료'), findsOneWidget);
  });

  testWidgets('자유 세션: 세트 없는 종목은 안내와 세트 추가 버튼, 종목 추가 시 첫 세트 자동', (t) async {
    final h = Harness();
    final s0 = await h.sessions.startSession(tz: 'Asia/Seoul');
    final se = await h.sessions.addExercise(s0.id, squat.id);
    await h.pump(t, initial: Routes.session);
    await settle(t);
    expect(find.byKey(Key('empty-sets-${se.id}')), findsOneWidget);
    expect(find.byKey(const Key('complete-current')), findsNothing);
    await t.tap(find.byKey(Key('add-set-${se.id}')));
    await settle(t);
    expect(find.byKey(Key('empty-sets-${se.id}')), findsNothing);
    expect(find.text('스쿼트 1세트 완료'), findsOneWidget);
  });

  testWidgets('320px 폭·큰 글씨·다크에서 펼친 줄/접힌 줄/실패 줄이 넘치지 않는다', (t) async {
    final e = env.AppEnv();
    e.now = DateTime.utc(2026, 11, 26, 9);
    final s0 = await e.sessions.startSession(tz: 'Asia/Seoul', plan: plan());
    final sets = s0.exercises.single.sets;
    await e.sessions.updateSet(
      sets[0].copyWith(reps: () => 3, completedAt: () => e.now),
    );
    for (final scale in [1.0, 2.0]) {
      await e.pump(
        t,
        initial: Routes.session,
        size: const Size(320, 640),
        themeMode: ThemeMode.dark,
        textScale: scale,
      );
      await settle(t);
      expect(t.takeException(), isNull, reason: 'scale $scale');
    }
  });
}
