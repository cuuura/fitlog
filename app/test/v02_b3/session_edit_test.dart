import 'package:fitlog/core/api/dto.dart';
import 'package:fitlog/core/routes.dart';
import 'package:fitlog/features/history/session_edit_page.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'harness.dart';

void main() {
  final start = DateTime.utc(2026, 11, 15, 12);

  Future<Session> reload(B3Harness h, String id) async => (await h.sessions.watchSession(id).first)!;

  test('validTimeRange', () {
    expect(validTimeRange(start, null), isTrue);
    expect(validTimeRange(start, start), isTrue);
    expect(validTimeRange(start, start.add(const Duration(minutes: 1))), isTrue);
    expect(validTimeRange(start, start.subtract(const Duration(minutes: 1))), isFalse);
  });

  testWidgets('종료를 시작보다 앞으로 바꾸면 거부하고, 뒤로 바꾸면 저장한다', (tester) async {
    final h = B3Harness();
    final s = await h.finished(start);
    await h.pump(tester, Routes.sessionEdit(s.id));

    h.pickedDateTime = start.subtract(const Duration(hours: 1)).toLocal();
    await tester.tap(find.byKey(const Key('edit-end')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('종료 시각은 시작 시각보다 늦어야 해요.'), findsOneWidget);
    expect((await reload(h, s.id)).endedAt, start.add(const Duration(hours: 1)));

    final later = start.add(const Duration(hours: 2));
    h.pickedDateTime = later.toLocal();
    await tester.tap(find.byKey(const Key('edit-end')));
    await tester.pump(const Duration(milliseconds: 100));
    expect((await reload(h, s.id)).endedAt, later);
  });

  testWidgets('시작을 종료보다 뒤로 바꾸면 거부하고, 앞으로 바꾸면 저장한다', (tester) async {
    final h = B3Harness();
    final s = await h.finished(start);
    await h.pump(tester, Routes.sessionEdit(s.id));

    h.pickedDateTime = start.add(const Duration(hours: 3)).toLocal();
    await tester.tap(find.byKey(const Key('edit-start')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('종료 시각은 시작 시각보다 늦어야 해요.'), findsOneWidget);
    expect((await reload(h, s.id)).startedAt, start);

    final earlier = start.subtract(const Duration(days: 1));
    h.pickedDateTime = earlier.toLocal();
    await tester.tap(find.byKey(const Key('edit-start')));
    await tester.pump(const Duration(milliseconds: 100));
    expect((await reload(h, s.id)).startedAt, earlier);
  });

  testWidgets('세트 값 수정, 잘못된 값은 저장하지 않는다', (tester) async {
    final h = B3Harness();
    final s = await h.finished(start, lifts: [
      ('ex-squat', [(100.0, 5)]),
    ]);
    final w = s.exercises.single.sets.single;
    await h.pump(tester, Routes.sessionEdit(s.id));

    await tester.enterText(find.byKey(Key('edit-weight-${w.id}')), '112.5');
    await tester.enterText(find.byKey(Key('edit-reps-${w.id}')), '3');
    await tester.pump(const Duration(milliseconds: 100));
    var saved = (await reload(h, s.id)).exercises.single.sets.single;
    expect(saved.weightKg, 112.5);
    expect(saved.reps, 3);
    expect(saved.completedAt, start, reason: '완료 시각은 그대로');

    await tester.enterText(find.byKey(Key('edit-weight-${w.id}')), '1.2.3');
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('올바른 값을 입력해 주세요'), findsOneWidget);
    saved = (await reload(h, s.id)).exercises.single.sets.single;
    expect(saved.weightKg, 112.5);

    // 워밍업 토글
    await tester.enterText(find.byKey(Key('edit-weight-${w.id}')), '100');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(Key('edit-warmup-${w.id}')));
    await tester.pump(const Duration(milliseconds: 100));
    saved = (await reload(h, s.id)).exercises.single.sets.single;
    expect(saved.isWarmup, isTrue);
    expect(saved.weightKg, 100);
  });

  testWidgets('lb 단위로 입력하면 kg로 저장', (tester) async {
    final h = B3Harness(settings: const Settings(weightUnit: WeightUnit.LB));
    final s = await h.finished(start, lifts: [
      ('ex-squat', [(100.0, 5)]),
    ]);
    final w = s.exercises.single.sets.single;
    await h.pump(tester, Routes.sessionEdit(s.id));
    await tester.enterText(find.byKey(Key('edit-weight-${w.id}')), '225');
    await tester.pump(const Duration(milliseconds: 100));
    final saved = (await reload(h, s.id)).exercises.single.sets.single;
    expect(saved.weightKg, closeTo(102.06, 0.01));
  });

  testWidgets('세트 추가·순서 변경·삭제', (tester) async {
    final h = B3Harness();
    final s = await h.finished(start, lifts: [
      ('ex-squat', [(100.0, 5), (90.0, 8)]),
    ]);
    final se = s.exercises.single;
    final first = se.sets[0], second = se.sets[1];
    await h.pump(tester, Routes.sessionEdit(s.id));

    await tester.tap(find.byKey(Key('edit-set-down-${first.id}')));
    await tester.pump(const Duration(milliseconds: 100));
    var sets = (await reload(h, s.id)).exercises.single.sets;
    expect(sets.map((e) => e.id), [second.id, first.id]);
    expect(sets.map((e) => e.position), [0, 1]);

    await tester.tap(find.byKey(Key('edit-set-add-${se.id}')));
    await tester.pump(const Duration(milliseconds: 100));
    sets = (await reload(h, s.id)).exercises.single.sets;
    expect(sets, hasLength(3));
    expect(sets.last.weightKg, 100, reason: '마지막 세트 값으로 채운다');
    expect(sets.last.completedAt, isNotNull);

    await tester.tap(find.byKey(Key('edit-set-delete-${second.id}')));
    await tester.pump(const Duration(milliseconds: 100));
    sets = (await reload(h, s.id)).exercises.single.sets;
    expect(sets.map((e) => e.id), isNot(contains(second.id)));
    expect(sets, hasLength(2));
    expect(find.text('세트를 지웠어요'), findsOneWidget, reason: '확인창 없이 지우고 되돌리기를 보인다');
  });

  testWidgets('세트를 지운 뒤 되돌리기: 같은 값·같은 자리로 다시 들어간다', (tester) async {
    final h = B3Harness();
    final s = await h.finished(start, lifts: [
      ('ex-squat', [(100.0, 5), (90.0, 8), (80.0, 10)]),
    ]);
    final mid = s.exercises.single.sets[1];
    await h.pump(tester, Routes.sessionEdit(s.id));

    await tester.ensureVisible(find.byKey(Key('edit-set-delete-${mid.id}')));
    await tester.tap(find.byKey(Key('edit-set-delete-${mid.id}')));
    await tester.pump(const Duration(milliseconds: 100));
    expect((await reload(h, s.id)).exercises.single.sets, hasLength(2));

    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('되돌리기'));
    await tester.pump(const Duration(milliseconds: 500));
    final sets = (await reload(h, s.id)).exercises.single.sets;
    expect(sets, hasLength(3));
    expect(sets.map((e) => e.weightKg), [100, 90, 80]);
    expect(sets.map((e) => e.reps), [5, 8, 10]);
    expect(sets.map((e) => e.position), [0, 1, 2]);
    expect(sets[1].completedAt, mid.completedAt);
    expect(sets[1].id, isNot(mid.id));
  });

  testWidgets('종목 추가·삭제(확인)와 메모', (tester) async {
    final h = B3Harness()..pickResult = 'ex-bench';
    final s = await h.finished(start, lifts: [
      ('ex-squat', [(100.0, 5)]),
    ]);
    final se = s.exercises.single;
    await h.pump(tester, Routes.sessionEdit(s.id));

    await tester.enterText(find.byKey(const Key('edit-note')), '컨디션 좋음');
    await tester.pump(const Duration(milliseconds: 100));
    expect((await reload(h, s.id)).note, '컨디션 좋음');

    await tester.ensureVisible(find.byKey(const Key('edit-add-exercise')));
    await tester.tap(find.byKey(const Key('edit-add-exercise')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('pick-stub'));
    await tester.pumpAndSettle();
    var exs = (await reload(h, s.id)).exercises;
    expect(exs.map((e) => e.exerciseId), ['ex-squat', 'ex-bench']);
    expect(find.text('벤치 프레스'), findsOneWidget);

    await tester.tap(find.byKey(Key('edit-ex-delete-${se.id}')));
    await tester.pumpAndSettle();
    expect((await reload(h, s.id)).exercises, hasLength(2), reason: '확인 전에는 지우지 않는다');
    expect(find.text('스쿼트 삭제'), findsOneWidget);
    expect(find.text('이 종목과 세트를 삭제할까요?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('edit-confirm')));
    await tester.pumpAndSettle();
    exs = (await reload(h, s.id)).exercises;
    expect(exs.map((e) => e.exerciseId), ['ex-bench']);
  });

  testWidgets('프로그램 세션: 안내와 계획 세트 목표 표시, 자유 세션에는 없다', (tester) async {
    final h = B3Harness();
    final prog = await h.finished(start, plan: plan());
    final free = await h.finished(start.add(const Duration(days: 1)));
    await h.pump(tester, Routes.sessionEdit(prog.id));
    expect(find.byKey(const Key('edit-program-notice')), findsOneWidget);
    expect(find.text('수정하면 이후 계획이 다시 계산됩니다.'), findsOneWidget);
    final sets = prog.exercises.single.sets;
    expect(find.byKey(Key('edit-target-${sets[0].id}')), findsOneWidget);
    expect(find.text('목표 100 kg×5'), findsOneWidget);
    expect(find.text('목표 100 kg×5+'), findsOneWidget);

    h.router.go(Routes.sessionEdit(free.id));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('edit-program-notice')), findsNothing);
  });

  testWidgets('맨몸 종목은 추가 무게를 수정한다', (tester) async {
    final h = B3Harness();
    clock0(h, start);
    final s = await h.sessions.startSession(tz: 'Asia/Seoul');
    final se = await h.sessions.addExercise(s.id, 'ex-pullup');
    final w = await h.sessions.addSet(se.id, WorkoutSet(id: 'set-pu', position: 0, reps: 8, completedAt: start));
    await h.sessions.endSession(s.id);
    await h.pump(tester, Routes.sessionEdit(s.id));
    await tester.enterText(find.byKey(Key('edit-weight-${w.id}')), '10');
    await tester.pump(const Duration(milliseconds: 100));
    final saved = (await reload(h, s.id)).exercises.single.sets.single;
    expect(saved.addedWeightKg, 10);
    expect(saved.weightKg, isNull);
  });
}

void clock0(B3Harness h, DateTime t) => h.clock = t;
