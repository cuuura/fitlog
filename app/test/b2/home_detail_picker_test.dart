import 'package:fitlog/core/api/dto.dart';
import 'package:fitlog/core/routes.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'harness.dart';

Future<void> settle(WidgetTester t, [int n = 6]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('강제 종료 후 홈에서 "이어서 기록"이 보이고 시작 버튼은 없다', (t) async {
    final h = Harness();
    final s = await h.sessions.startSession(tz: 'Asia/Seoul');
    await h.sessions.addExercise(s.id, squat.id);
    await h.pump(t);
    expect(find.byKey(const Key('home-resume-card')), findsOneWidget);
    expect(find.text('이어서 기록'), findsOneWidget);
    expect(find.byKey(const Key('home-start')), findsNothing);
    await settle(t);
    await t.tap(find.byKey(const Key('home-resume')));
    await settle(t);
    expect(find.byKey(const Key('add-exercise')), findsOneWidget);
  });

  testWidgets('최근 세션 목록 요약 -> 상세 -> 삭제', (t) async {
    final h = Harness(settings: const Settings(weightUnit: WeightUnit.KG));
    final s = await h.sessions.startSession(tz: 'Asia/Seoul');
    final se = await h.sessions.addExercise(s.id, squat.id);
    await h.sessions.addSet(se.id, const WorkoutSet(id: 'w0', position: 0, isWarmup: true, weightKg: 40, reps: 10));
    await h.sessions.addSet(se.id, const WorkoutSet(id: 'w1', position: 0, weightKg: 100, reps: 5));
    await h.sessions.addSet(se.id, const WorkoutSet(id: 'w2', position: 0, weightKg: 100, reps: 5));
    await h.sessions.endSession(s.id);
    await h.pump(t);

    expect(find.byKey(const Key('home-start')), findsOneWidget);
    expect(find.text('종목 1개 · 2세트 · 1,000 kg'), findsOneWidget);

    await t.tap(find.byKey(Key('home-session-${s.id}')));
    await settle(t);
    expect(find.text('스쿼트 · 바벨'), findsOneWidget);
    expect(find.textContaining('볼륨 1,000 kg'), findsOneWidget);
    expect(find.text('40 kg×10'), findsOneWidget);

    await t.tap(find.byKey(const Key('detail-delete')));
    await settle(t);
    await t.tap(find.byKey(const Key('detail-delete-confirm')));
    await settle(t);
    expect(find.byKey(Key('home-session-${s.id}')), findsNothing);
    expect(find.text('아직 기록이 없어요'), findsOneWidget);
  });

  testWidgets('홈 앱바에는 오늘 제목만 있고 이동 아이콘은 탭/나 화면으로 옮겨졌다', (t) async {
    final h = Harness();
    await h.pump(t);
    expect(find.text('오늘'), findsWidgets);
    for (final k in ['home-programs', 'home-history', 'home-body', 'home-profile', 'home-settings']) {
      expect(find.byKey(Key(k)), findsNothing);
    }
    expect(Routes.settings, '/settings');
  });

  testWidgets('종목 검색, 필터, 내 종목 추가 후 바로 선택', (t) async {
    final h = Harness();
    await h.pump(t);
    final s = await h.sessions.startSession(tz: 'Asia/Seoul');
    await settle(t);
    await t.tap(find.byKey(const Key('home-resume')));
    await settle(t);
    await t.tap(find.byKey(const Key('add-exercise')));
    await settle(t);

    expect(find.byKey(Key('exercise-${squat.id}')), findsOneWidget);
    expect(find.byKey(Key('exercise-${pullUp.id}')), findsOneWidget);

    await t.enterText(find.byKey(const Key('exercise-search')), '스쿼');
    await settle(t);
    expect(find.byKey(Key('exercise-${squat.id}')), findsOneWidget);
    expect(find.byKey(Key('exercise-${pullUp.id}')), findsNothing);

    await t.enterText(find.byKey(const Key('exercise-search')), 'pull');
    await settle(t);
    expect(find.byKey(Key('exercise-${pullUp.id}')), findsOneWidget);

    await t.enterText(find.byKey(const Key('exercise-search')), '없는종목');
    await settle(t);
    expect(find.text('맞는 종목이 없어요'), findsOneWidget);

    // 내 종목 추가: 이름이 비면 저장되지 않는다
    await t.tap(find.byKey(const Key('add-custom')));
    await settle(t);
    await t.tap(find.byKey(const Key('custom-save')));
    await settle(t);
    expect(find.text('1~60자로 입력해 주세요'), findsOneWidget);

    await t.enterText(find.byKey(const Key('custom-name-ko')), '케이블 크런치');
    await t.tap(find.byKey(const Key('custom-type-MACHINE')));
    await t.tap(find.byKey(const Key('custom-primary-ABS')));
    await t.ensureVisible(find.byKey(const Key('custom-secondary-OBLIQUES')));
    await t.tap(find.byKey(const Key('custom-secondary-OBLIQUES')));
    await t.ensureVisible(find.byKey(const Key('custom-save')));
    await t.tap(find.byKey(const Key('custom-save')));
    await settle(t, 10);

    // 선택되어 세션에 추가되고 기록 화면으로 돌아온다
    final created = (await h.exercises.search(query: '케이블')).single;
    expect(created.builtIn, isFalse);
    expect(created.type, ExerciseType.MACHINE);
    expect(created.primaryMuscle, Muscle.ABS);
    expect(created.secondaryMuscles, [Muscle.OBLIQUES]);
    final cur = await h.sessions.watchActiveSession().first;
    expect(cur!.id, s.id);
    expect(cur.exercises.single.exerciseId, created.id);
    // 플레이리스트 행과 종목 카드에 한 번씩 보인다.
    expect(find.text('케이블 크런치'), findsNWidgets(2));
  });

  testWidgets('내 종목 길게 눌러 삭제(기본 종목은 길게 누르기 없음)', (t) async {
    final custom = ex('ex-mine', '내 종목', ExerciseType.BARBELL, Muscle.BACK, builtIn: false);
    final h = Harness(seed: [squat, custom]);
    await h.pump(t);
    await h.sessions.startSession(tz: 'Asia/Seoul');
    await settle(t);
    await t.tap(find.byKey(const Key('home-resume')));
    await settle(t);
    await t.tap(find.byKey(const Key('add-exercise')));
    await settle(t);

    expect(t.widget<ListTile>(find.byKey(Key('exercise-${squat.id}'))).onLongPress, isNull);
    await t.longPress(find.byKey(Key('exercise-${custom.id}')));
    await settle(t);
    await t.tap(find.byKey(const Key('custom-delete')));
    await settle(t);
    await t.tap(find.byKey(const Key('custom-delete-confirm')));
    await settle(t);
    expect(find.byKey(Key('exercise-${custom.id}')), findsNothing);
    expect(await h.exercises.byId(custom.id), isNull);
  });
}
