import 'package:fitlog/core/api/dto.dart';
import 'package:fitlog/core/ids.dart';
import 'package:fitlog/core/routes.dart';
import 'package:fitlog/features/rest_timer/rest_timer_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/app_env.dart';

void main() {
  testWidgets('하단 내비 4탭 전환, 세션 화면에는 내비 없음', (t) async {
    final e = AppEnv();
    await e.pump(t);
    expect(find.byKey(const Key('app-nav')), findsOneWidget);
    for (final l in ['오늘', '기록', '프로그램', '나']) {
      expect(find.descendant(of: find.byKey(const Key('app-nav')), matching: find.text(l)), findsOneWidget);
    }
    await t.tap(find.byKey(const Key('nav-history')));
    await settle(t);
    expect(e.router.state.uri.path, Routes.history);
    await t.tap(find.byKey(const Key('nav-programs')));
    await settle(t);
    expect(e.router.state.uri.path, Routes.programs);
    await t.tap(find.byKey(const Key('nav-me')));
    await settle(t);
    expect(e.router.state.uri.path, Routes.me);
    await t.tap(find.byKey(const Key('nav-today')));
    await settle(t);
    expect(e.router.state.uri.path, Routes.home);

    // 세션 화면은 셸 밖
    await t.tap(find.byKey(const Key('home-start')));
    await settle(t);
    expect(e.router.state.uri.path, Routes.session);
    expect(find.byKey(const Key('app-nav')), findsNothing);
  });

  testWidgets('다른 탭에서 하위 화면을 열어도 내비가 보인다(교차 push 포함)', (t) async {
    final e = AppEnv();
    final s = await finishedSession(e, DateTime.utc(2026, 11, 20, 3), lifts: [
      (squat.id, [(100.0, 5)]),
    ]);
    await e.pump(t);
    e.router.push(Routes.sessionDetail(s.id));
    await settle(t);
    expect(find.byKey(const Key('detail-header')), findsOneWidget);
    expect(find.byKey(const Key('app-nav')), findsOneWidget);
    e.router.pop();
    await settle(t);
    expect(e.router.state.uri.path, Routes.home);
  });

  testWidgets('진행 중 세션이 있으면 미니바(운동·세트·휴식), 누르면 세션 화면', (t) async {
    final e = AppEnv();
    final s = await e.sessions.startSession(tz: 'Asia/Seoul');
    final se = await e.sessions.addExercise(s.id, bench.id);
    for (var i = 0; i < 4; i++) {
      await e.sessions.addSet(
          se.id,
          WorkoutSet(
              id: newId(), position: 0, weightKg: 60, reps: 8, completedAt: i < 3 ? DateTime.utc(2026, 11, 26, 9) : null));
    }
    await e.pump(t);
    await t.tap(find.byKey(const Key('nav-history')));
    await settle(t);
    expect(find.byKey(const Key('active-mini-bar')), findsOneWidget);
    expect(find.text('진행 중 · 벤치 프레스 3/4세트'), findsOneWidget);

    e.container.read(restTimerProvider.notifier).start(72);
    await settle(t);
    expect(find.textContaining('휴식 1:'), findsOneWidget);

    await t.tap(find.byKey(const Key('active-mini-bar')));
    await settle(t);
    expect(e.router.state.uri.path, Routes.session);
    expect(find.byKey(const Key('active-mini-bar')), findsNothing);
  });

  testWidgets('진행 중 세션이 없으면 미니바 없음', (t) async {
    final e = AppEnv();
    await e.pump(t);
    expect(find.byKey(const Key('active-mini-bar')), findsNothing);
  });
}
