import 'package:fitlog/core/api/dto.dart';
import 'package:fitlog/core/api/program_dto.dart';
import 'package:fitlog/features/session/plan_logic.dart';
import 'package:fitlog/features/session/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../b2/harness.dart';

PlannedSet ps(
  int i,
  double? kg, {
  int reps = 5,
  bool amrap = false,
  bool warmup = false,
}) => PlannedSet(
  plannedSetKey: 'A.0.$i',
  targetReps: reps,
  targetWeightKg: kg,
  isAmrap: amrap,
  isWarmup: warmup,
);

PlannedWorkout planOf(int seq, double kg, {bool confirmed = true}) =>
    PlannedWorkout(
      instanceId: 'i1',
      planSeq: seq,
      dayIndex: 0,
      dayKey: 'A',
      dayName: '데이 A',
      week: seq,
      cycle: 1,
      confirmed: confirmed,
      exercises: [
        PlannedExercise(
          key: 'squat',
          exerciseId: squat.id,
          accessory: false,
          sets: [ps(0, kg), ps(1, kg), ps(2, kg, amrap: true)],
        ),
      ],
    );

Future<void> settle(WidgetTester t, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<Session> active(Harness h) =>
    h.sessions.watchActiveSession().first.then((s) => s!);

Future<void> setup(Harness h, {List<PlannedWorkout>? plans}) async {
  h.programs.instances['i1'] = Instance(
    id: 'i1',
    programId: 'p1',
    name: 'GZCLP',
    status: InstanceStatus.ACTIVE,
    skipPolicy: SkipPolicy.SHIFT,
    startDate: DateTime(2026, 11, 1),
    state: const InstanceState(week: 1, cycle: 1, seq: 1),
  );
  h.programs.plans['i1'] = plans ?? [planOf(2, 100), planOf(3, 102.5)];
  await h.planCache.refresh();
}

void main() {
  testWidgets(
    '홈 카드 -> 계획 세션 -> 미리 채움·target 유지·실패·세트 추가/순서·보조운동 -> 요약의 다음 회차',
    (t) async {
      final h = Harness();
      await setup(h);
      // 지난 같은 세션(dayKey A): 100 kg x 5,5,4
      final prev = await h.sessions.startSession(
        tz: 'Asia/Seoul',
        plan: planOf(1, 100),
      );
      final prevSets = prev.exercises.single.sets;
      await h.sessions.updateSet(prevSets[2].copyWith(reps: () => 4));
      await h.sessions.endSession(prev.id);

      await h.pump(t);
      expect(find.byKey(const Key('plan-card-i1')), findsOneWidget);
      expect(find.text('GZCLP'), findsOneWidget);
      expect(find.textContaining('데이 A'), findsOneWidget);
      expect(find.text('스쿼트 100 kg'), findsOneWidget);
      expect(find.byKey(const Key('plan-estimated-i1')), findsNothing);
      expect(find.byKey(const Key('home-programs')), findsOneWidget);
      expect(find.byKey(const Key('home-history')), findsOneWidget);

      await t.tap(find.byKey(const Key('plan-start-i1')));
      await settle(t);

      var s = await active(h);
      expect(s.programInstanceId, 'i1');
      expect(s.planSeq, 2);
      final se = s.exercises.single;
      expect(se.sets.map((e) => e.weightKg), [100, 100, 100]);
      expect(se.sets.map((e) => e.reps), [5, 5, 5]);
      expect(find.byKey(const Key('plan-header')), findsOneWidget);
      expect(find.text('GZCLP · 데이 A · 2주차'), findsOneWidget);
      // 현재(첫) 세트만 펼쳐져 목표 문구가 보이고, 나머지는 계획 열로 보인다
      expect(find.text('목표 5회 × 100 kg'), findsOneWidget);
      expect(find.byKey(Key('target-${se.sets[0].id}')), findsOneWidget);
      expect(find.text('100×5'), findsOneWidget);
      expect(find.byKey(Key('plan-${se.sets[1].id}')), findsOneWidget);
      expect(find.text('100×5+'), findsOneWidget);
      expect(find.text('지난번: 100 kg×5,5,4'), findsWidgets);
      expect(find.byKey(Key('past-day-${se.id}')), findsOneWidget);
      expect(find.byKey(Key('differs-${se.sets[0].id}')), findsNothing);

      // 무게를 바꿔도 target은 그대로, "계획과 다름"
      final s0 = se.sets[0];
      await t.enterText(find.byKey(Key('weight-${s0.id}')), '95');
      await settle(t);
      s = await active(h);
      expect(s.exercises.single.sets[0].weightKg, 95);
      expect(s.exercises.single.sets[0].targetWeightKg, 100);
      expect(s.exercises.single.sets[0].plannedSetKey, 'A.0.0');
      expect(find.byKey(Key('differs-${s0.id}')), findsOneWidget);

      // 완료: 횟수 부족이면 실패, 목표 이상이면 아님(바꾼 무게와 무관)
      await t.tap(find.byKey(Key('done-${s0.id}')));
      await settle(t);
      expect(find.byKey(Key('failed-${s0.id}')), findsNothing);
      final s1 = se.sets[1];
      await t.enterText(find.byKey(Key('reps-${s1.id}')), '3');
      await settle(t);
      await t.tap(find.byKey(Key('done-${s1.id}')));
      await settle(t);
      expect(find.byKey(Key('failed-${s1.id}')), findsOneWidget);

      // 계획 외 세트 추가
      await t.tap(find.byKey(Key('add-set-${se.id}')));
      await settle(t);
      s = await active(h);
      expect(s.exercises.single.sets.length, 4);
      final extra = s.exercises.single.sets[3];
      expect(extra.plannedSetKey, isNull);
      expect(extra.targetReps, isNull);

      // 세트 순서 변경(드래그): 추가한 세트를 맨 위로
      await t.drag(find.byKey(Key('drag-${extra.id}')), const Offset(0, -520));
      await settle(t);
      s = await active(h);
      expect(s.exercises.single.sets.first.id, extra.id);
      expect(s.exercises.single.sets.map((e) => e.position), [0, 1, 2, 3]);

      // 보조운동 즉석 추가
      await t.scrollUntilVisible(
        find.byKey(const Key('add-exercise')),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await t.tap(find.byKey(const Key('add-exercise')));
      await settle(t);
      await t.tap(find.byKey(Key('exercise-${pullUp.id}')));
      await settle(t);
      s = await active(h);
      expect(s.exercises.length, 2);
      expect(s.exercises[1].accessory, isTrue);
      expect(s.exercises[1].exerciseId, pullUp.id);
      expect(find.byKey(Key('accessory-${s.exercises[1].id}')), findsOneWidget);

      // 서버가 replay로 다음 회차를 확정했다고 가정하고 종료
      h.programs.plans['i1'] = [planOf(3, 102.5)];
      await t.tap(find.byKey(const Key('end-session')));
      await settle(t);
      await t.tap(find.byKey(const Key('end-confirm')));
      await settle(t, 12);

      expect(find.byKey(const Key('summary-done')), findsOneWidget);
      expect(find.byKey(const Key('summary-sets')), findsOneWidget);
      // 완료한 세트 2개(워밍업 없음), 볼륨 95*5 + 100*3
      expect(t.widget<Text>(find.byKey(const Key('summary-sets'))).data, '2');
      expect(find.text('775 kg'), findsOneWidget);
      // 종목 판정: 스쿼트는 실패, 보조운동은 판정 없음
      expect(find.byKey(Key('result-${se.id}')), findsOneWidget);
      expect(find.text('실패'), findsOneWidget);
      expect(find.byKey(Key('result-${s.exercises[1].id}')), findsNothing);
      // 다음 회차
      expect(find.byKey(const Key('summary-next')), findsOneWidget);
      expect(find.text('데이 A · 3주차'), findsOneWidget);
      expect(find.text('스쿼트 102.5 kg'), findsOneWidget);

      await t.tap(find.byKey(const Key('summary-done')));
      await settle(t);
      expect(find.byKey(const Key('plan-card-i1')), findsOneWidget);
    },
  );

  testWidgets('예상(확정 아님) 계획이면 요약에 "연결되면 계산됩니다"', (t) async {
    final h = Harness();
    await setup(h, plans: [planOf(2, 100, confirmed: false)]);
    await h.pump(t);
    // 캐시 항목은 확정이 아니라 fromCache로 표시되지만 MemoryPlanCache는 plan 그대로 보여준다.
    await t.tap(find.byKey(const Key('plan-start-i1')));
    await settle(t);
    await t.tap(find.byKey(const Key('end-session')));
    await settle(t);
    await t.tap(find.byKey(const Key('end-confirm')));
    await settle(t, 12);
    expect(find.byKey(const Key('summary-next-pending')), findsOneWidget);
    expect(find.text('연결되면 계산됩니다'), findsOneWidget);
  });

  testWidgets('무게 없는 계획 세트는 지난 기록 무게로 채운다', (t) async {
    final h = Harness();
    final noWeight = PlannedWorkout(
      instanceId: 'i1',
      planSeq: 2,
      dayIndex: 0,
      dayKey: 'A',
      dayName: '데이 A',
      week: 1,
      cycle: 1,
      confirmed: true,
      exercises: [
        PlannedExercise(
          key: 'press',
          exerciseId: dbPress.id,
          accessory: false,
          sets: [ps(0, null, reps: 10), ps(1, null, reps: 10)],
        ),
      ],
    );
    await setup(h, plans: [noWeight]);
    final prev = await h.sessions.startSession(
      tz: 'Asia/Seoul',
      plan: noWeight.withPlanSeq(1),
    );
    for (final w in prev.exercises.single.sets) {
      await h.sessions.updateSet(
        w.copyWith(weightKg: () => 20, reps: () => 10),
      );
    }
    await h.sessions.endSession(prev.id);

    await h.pump(t);
    final s = await h.container
        .read(sessionControllerProvider)
        .startProgram('i1', programName: 'GZCLP');
    expect(s.planSeq, 2);
    final now = await active(h);
    expect(now.exercises.single.sets.map((e) => e.weightKg), [20, 20]);
    expect(now.exercises.single.sets.map((e) => e.targetWeightKg), [
      null,
      null,
    ]);
  });

  test('성공·실패 판정: 횟수만 보고 워밍업·보조·무게는 제외', () {
    SessionExercise ex({bool acc = false, required List<WorkoutSet> sets}) =>
        SessionExercise(
          id: 'e',
          exerciseId: 'x',
          position: 0,
          accessory: acc,
          sets: sets,
        );
    WorkoutSet w(
      int reps, {
      int target = 5,
      bool done = true,
      bool warm = false,
      double kg = 50,
    }) => WorkoutSet(
      id: '$reps$target$done$warm',
      position: 0,
      reps: reps,
      weightKg: kg,
      targetReps: target,
      targetWeightKg: 100,
      isWarmup: warm,
      plannedSetKey: 'A.0.0',
      completedAt: done ? DateTime.utc(2026) : null,
    );
    expect(
      exerciseVerdict(ex(sets: [w(5), w(6)])),
      ExerciseVerdict.success,
    ); // 무게를 낮춰도 횟수만
    expect(exerciseVerdict(ex(sets: [w(5), w(4)])), ExerciseVerdict.failure);
    expect(
      exerciseVerdict(ex(sets: [w(5), w(5, done: false)])),
      ExerciseVerdict.failure,
    );
    expect(
      exerciseVerdict(ex(sets: [w(5), w(1, warm: true)])),
      ExerciseVerdict.success,
    );
    expect(exerciseVerdict(ex(acc: true, sets: [w(1)])), isNull);
  });
}
