import 'package:fitlog/core/api/dto.dart';
import 'package:fitlog/features/rest_timer/rest_timer_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'harness.dart';

Future<void> settle(WidgetTester t, [int n = 6]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<Session> active(Harness h) =>
    h.sessions.watchActiveSession().first.then((s) => s!);

Future<void> startAndAdd(WidgetTester t, Harness h, String exerciseId) async {
  await t.tap(find.byKey(const Key('add-exercise')));
  await settle(t);
  await t.tap(find.byKey(Key('exercise-$exerciseId')));
  await settle(t);
}

void main() {
  testWidgets('세션 시작 -> 종목 추가 -> 세트 입력 -> 완료 -> 타이머, 직전 세트 restSec', (t) async {
    final h = Harness();
    await h.pump(t);

    await t.tap(find.byKey(const Key('home-start')));
    await settle(t);
    expect(find.byKey(const Key('add-exercise')), findsOneWidget);

    await startAndAdd(t, h, squat.id);
    var s = await active(h);
    expect(s.exercises.single.exerciseId, squat.id);
    final seId = s.exercises.single.id;

    await t.tap(find.byKey(Key('add-set-$seId')));
    await settle(t);
    s = await active(h);
    final set1 = s.exercises.single.sets.single;
    await t.enterText(find.byKey(Key('weight-${set1.id}')), '100');
    await t.enterText(find.byKey(Key('reps-${set1.id}')), '5');
    await settle(t);
    s = await active(h);
    expect(s.exercises.single.sets.single.weightKg, 100);
    expect(s.exercises.single.sets.single.reps, 5);

    // 첫 세트 완료 -> 타이머 시작(기본 120초)
    await t.tap(find.byKey(Key('done-${set1.id}')));
    await settle(t);
    final timer = h.container.read(restTimerProvider);
    expect(timer.running, isTrue);
    expect(timer.totalSec, 120);
    expect(timer.label, contains('스쿼트'));
    s = await active(h);
    expect(s.exercises.single.sets.single.completedAt, h.now);

    // 두 번째 세트: 기본값은 직전 세트 값
    await t.tap(find.byKey(Key('add-set-$seId')));
    await settle(t);
    s = await active(h);
    final set2 = s.exercises.single.sets[1];
    expect(set2.weightKg, 100);
    expect(set2.reps, 5);

    h.now = h.now.add(const Duration(seconds: 90));
    await t.tap(find.byKey(Key('done-${set2.id}')));
    await settle(t);
    s = await active(h);
    expect(s.exercises.single.sets[0].restSec, 90);
    expect(s.exercises.single.sets[1].restSec, isNull);
    expect(s.exercises.single.sets[1].completedAt, h.now);

    // 완료 해제
    await t.tap(find.byKey(Key('done-${set2.id}')));
    await settle(t);
    s = await active(h);
    expect(s.exercises.single.sets[1].completedAt, isNull);

    // 세션 종료 -> 요약 -> 홈
    await t.tap(find.byKey(const Key('end-session')));
    await settle(t);
    await t.tap(find.byKey(const Key('end-confirm')));
    await settle(t, 10);
    expect(find.byKey(const Key('summary-done')), findsOneWidget);
    expect(h.container.read(restTimerProvider).running, isFalse);
    await t.tap(find.byKey(const Key('summary-done')));
    await settle(t);
    expect(find.byKey(const Key('home-start')), findsOneWidget);
  });

  testWidgets('덤벨은 한쪽 표시, 맨몸은 추가 중량(음수 가능)과 무게칸 없음', (t) async {
    final h = Harness();
    await h.pump(t);
    final s0 = await h.sessions.startSession(tz: 'Asia/Seoul');
    await h.sessions.addExercise(s0.id, dbPress.id);
    await h.sessions.addExercise(s0.id, pullUp.id);
    await settle(t);
    await t.tap(find.byKey(const Key('home-resume')));
    await settle(t);

    var s = await active(h);
    for (final se in s.exercises) {
      await t.tap(find.byKey(Key('add-set-${se.id}')));
      await settle(t);
    }
    s = await active(h);
    final db = s.exercises[0].sets.single;
    final bw = s.exercises[1].sets.single;

    expect(find.textContaining('한쪽'), findsWidgets);
    expect(find.byKey(Key('weight-${db.id}')), findsOneWidget);
    expect(find.byKey(Key('added-${db.id}')), findsNothing);
    expect(find.byKey(Key('weight-${bw.id}')), findsNothing);
    expect(find.byKey(Key('added-${bw.id}')), findsOneWidget);

    await t.enterText(find.byKey(Key('weight-${db.id}')), '22.5');
    await t.enterText(find.byKey(Key('added-${bw.id}')), '-20');
    await t.enterText(find.byKey(Key('reps-${bw.id}')), '8');
    await settle(t);
    s = await active(h);
    expect(s.exercises[0].sets.single.weightKg, 22.5);
    expect(s.exercises[1].sets.single.addedWeightKg, -20);
    expect(s.exercises[1].sets.single.weightKg, isNull);
    expect(s.exercises[1].sets.single.reps, 8);

    // 맨몸은 무게 없이 횟수만으로 완료된다
    await t.tap(find.byKey(Key('done-${bw.id}')));
    await settle(t);
    s = await active(h);
    expect(s.exercises[1].sets.single.isCompleted, isTrue);

    // 덤벨은 횟수 없이 완료 불가
    await t.tap(find.byKey(Key('done-${db.id}')));
    await settle(t);
    s = await active(h);
    expect(s.exercises[0].sets.single.isCompleted, isFalse);
    expect(find.text('횟수를 입력해 주세요'), findsOneWidget);
  });

  testWidgets('lb 설정: 225 입력 -> 102.06kg 저장, 표시는 lb', (t) async {
    final h = Harness(settings: const Settings(weightUnit: WeightUnit.LB));
    await h.pump(t);
    final s0 = await h.sessions.startSession(tz: 'Asia/Seoul');
    await h.sessions.addExercise(s0.id, squat.id);
    await settle(t);
    await t.tap(find.byKey(const Key('home-resume')));
    await settle(t);
    var s = await active(h);
    await t.tap(find.byKey(Key('add-set-${s.exercises.single.id}')));
    await settle(t);
    s = await active(h);
    final set = s.exercises.single.sets.single;

    await t.enterText(find.byKey(Key('weight-${set.id}')), '225');
    await settle(t);
    s = await active(h);
    expect(s.exercises.single.sets.single.weightKg, 102.06);
    expect(
      t.widget<TextField>(find.byKey(Key('weight-${set.id}'))).controller!.text,
      '225',
    );

    // + 버튼은 5lb 단위
    await t.tap(find.byKey(Key('weight-plus-${set.id}')));
    await settle(t);
    s = await active(h);
    expect(s.exercises.single.sets.single.weightKg, 104.33);
    expect(
      t.widget<TextField>(find.byKey(Key('weight-${set.id}'))).controller!.text,
      '230',
    );
  });

  testWidgets('kg + / - 버튼과 입력 검증', (t) async {
    final h = Harness();
    await h.pump(t);
    final s0 = await h.sessions.startSession(tz: 'Asia/Seoul');
    await h.sessions.addExercise(s0.id, legPress.id);
    await settle(t);
    await t.tap(find.byKey(const Key('home-resume')));
    await settle(t);
    var s = await active(h);
    await t.tap(find.byKey(Key('add-set-${s.exercises.single.id}')));
    await settle(t);
    s = await active(h);
    final id = s.exercises.single.sets.single.id;

    await t.tap(find.byKey(Key('weight-plus-$id')));
    await t.tap(find.byKey(Key('weight-plus-$id')));
    await t.tap(find.byKey(Key('reps-plus-$id')));
    await settle(t);
    s = await active(h);
    expect(s.exercises.single.sets.single.weightKg, 5);
    expect(s.exercises.single.sets.single.reps, 1);
    await t.tap(find.byKey(Key('reps-minus-$id')));
    await t.tap(find.byKey(Key('reps-minus-$id')));
    await settle(t);
    s = await active(h);
    expect(s.exercises.single.sets.single.reps, 0);

    // RPE 범위 밖이면 저장하지 않고 오류 표시
    await t.tap(find.byKey(Key('more-$id')));
    await settle(t);
    await t.enterText(find.byKey(Key('rpe-$id')), '11');
    await settle(t);
    expect(find.text('1~10, 0.5 단위'), findsOneWidget);
    s = await active(h);
    expect(s.exercises.single.sets.single.rpe, isNull);
    await t.enterText(find.byKey(Key('rpe-$id')), '8.5');
    await t.enterText(find.byKey(Key('rir-$id')), '2');
    await settle(t);
    s = await active(h);
    expect(s.exercises.single.sets.single.rpe, 8.5);
    expect(s.exercises.single.sets.single.rir, 2);

    // 워밍업 토글, 삭제
    await t.tap(find.byKey(Key('warmup-$id')));
    await settle(t);
    s = await active(h);
    expect(s.exercises.single.sets.single.isWarmup, isTrue);
    await t.ensureVisible(find.byKey(Key('delete-$id')));
    await t.tap(find.byKey(Key('delete-$id')));
    await settle(t);
    s = await active(h);
    expect(s.exercises.single.sets, isEmpty);
  });

  testWidgets('RPE/RIR 설정을 끄면 입력칸이 없다', (t) async {
    final h = Harness(settings: const Settings(rpeInputEnabled: false));
    await h.pump(t);
    final s0 = await h.sessions.startSession(tz: 'Asia/Seoul');
    await h.sessions.addExercise(s0.id, squat.id);
    await settle(t);
    await t.tap(find.byKey(const Key('home-resume')));
    await settle(t);
    var s = await active(h);
    await t.tap(find.byKey(Key('add-set-${s.exercises.single.id}')));
    await settle(t);
    s = await active(h);
    final id = s.exercises.single.sets.single.id;
    await t.tap(find.byKey(Key('more-$id')));
    await settle(t);
    expect(find.byKey(Key('rpe-$id')), findsNothing);
    expect(find.byKey(Key('rir-$id')), findsNothing);
    expect(find.byKey(Key('note-$id')), findsOneWidget);
  });

  testWidgets('지난 세션 기본값과 "지난번" 표시', (t) async {
    final h = Harness();
    // 지난 세션: 스쿼트 100x5, 110x3
    final old = await h.sessions.startSession(tz: 'Asia/Seoul');
    final se = await h.sessions.addExercise(old.id, squat.id);
    await h.sessions.addSet(
      se.id,
      const WorkoutSet(id: 'o1', position: 0, weightKg: 100, reps: 5),
    );
    await h.sessions.addSet(
      se.id,
      const WorkoutSet(id: 'o2', position: 1, weightKg: 110, reps: 3),
    );
    await h.sessions.endSession(old.id);
    h.now = h.now.add(const Duration(days: 2));

    await h.pump(t);
    await t.tap(find.byKey(const Key('home-start')));
    await settle(t);
    await startAndAdd(t, h, squat.id);
    var s = await active(h);
    final seId = s.exercises.single.id;
    await t.tap(find.byKey(Key('add-set-$seId')));
    await settle(t);
    await t.tap(find.byKey(Key('add-set-$seId')));
    await settle(t);
    s = await active(h);
    final sets = s.exercises.single.sets;
    expect(sets[0].weightKg, 100);
    expect(sets[0].reps, 5);
    // 두 번째 세트 기본값 = 이 세션의 마지막 세트
    expect(sets[1].weightKg, 100);
    expect(find.text('지난번: 100 kg×5'), findsOneWidget);
    expect(find.text('지난번: 110 kg×3'), findsOneWidget);
  });

  testWidgets('종목 삭제는 확인 후', (t) async {
    final h = Harness();
    await h.pump(t);
    final s0 = await h.sessions.startSession(tz: 'Asia/Seoul');
    final se = await h.sessions.addExercise(s0.id, squat.id);
    await settle(t);
    await t.tap(find.byKey(const Key('home-resume')));
    await settle(t);
    await t.tap(find.byKey(Key('remove-exercise-${se.id}')));
    await settle(t);
    await t.tap(find.byKey(const Key('remove-exercise-confirm')));
    await settle(t);
    expect((await active(h)).exercises, isEmpty);
  });

  testWidgets('세션 메모 저장(제출 시)', (t) async {
    final h = Harness();
    await h.pump(t);
    await h.sessions.startSession(tz: 'Asia/Seoul');
    await settle(t);
    await t.tap(find.byKey(const Key('home-resume')));
    await settle(t);
    await t.enterText(find.byKey(const Key('session-note')), '컨디션 좋음');
    await t.testTextInput.receiveAction(TextInputAction.done);
    await settle(t);
    expect((await active(h)).note, '컨디션 좋음');
  });
}
