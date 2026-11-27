import 'package:fitlog/core/api/dto.dart';
import 'package:fitlog/core/routes.dart';
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

/// 스쿼트(세트 2), 덤벨 프레스(세트 2), 풀업(세트 1)을 가진 세션.
Future<Session> seed(Harness h, {int squatDone = 0}) async {
  final s0 = await h.sessions.startSession(tz: 'Asia/Seoul');
  final plan = {squat.id: 2, dbPress.id: 2, pullUp.id: 1};
  for (final e in plan.entries) {
    final se = await h.sessions.addExercise(s0.id, e.key);
    for (var i = 0; i < e.value; i++) {
      await h.sessions.addSet(
        se.id,
        WorkoutSet(
          id: 'set-${e.key}-$i',
          position: i,
          weightKg: 100,
          reps: 5,
          completedAt: e.key == squat.id && i < squatDone ? h.now : null,
        ),
      );
    }
  }
  return active(h);
}

void main() {
  testWidgets('플레이리스트: 종목 순서·진행·다음 목표·현재 강조', (t) async {
    final h = Harness();
    final s = await seed(h, squatDone: 2);
    await h.pump(t, initial: Routes.session);
    await settle(t);
    final ids = [for (final e in s.exercises) e.id];

    expect(find.byKey(const Key('playlist')), findsOneWidget);
    expect(find.text('오늘 운동 · 1/3 종목'), findsOneWidget);
    for (final id in ids) {
      expect(find.byKey(Key('playlist-row-$id')), findsOneWidget);
      expect(find.byKey(Key('playlist-drag-$id')), findsOneWidget);
    }
    expect(
      find.byKey(Key('playlist-status-${ids[0]}-done')),
      findsOneWidget,
    );
    expect(find.byKey(Key('playlist-status-${ids[1]}-now')), findsOneWidget);
    expect(find.byKey(Key('playlist-status-${ids[2]}-todo')), findsOneWidget);
    expect(
      t.widget<Text>(find.byKey(Key('playlist-progress-${ids[0]}'))).data,
      '2/2',
    );
    expect(
      t.widget<Text>(find.byKey(Key('playlist-progress-${ids[1]}'))).data,
      '0/2',
    );
    expect(
      t.widget<Text>(find.byKey(Key('playlist-next-${ids[1]}'))).data,
      '100 kg×5',
    );

    // 접기/펼치기
    await t.tap(find.byKey(const Key('playlist-header')));
    await settle(t);
    expect(find.byKey(Key('playlist-row-${ids[0]}')), findsNothing);
    await t.tap(find.byKey(const Key('playlist-header')));
    await settle(t);
    expect(find.byKey(Key('playlist-row-${ids[0]}')), findsOneWidget);
  });

  testWidgets('플레이리스트: 끌어서 순서 변경', (t) async {
    final h = Harness();
    final s = await seed(h);
    await h.pump(t, initial: Routes.session);
    await settle(t);
    final ids = [for (final e in s.exercises) e.id];

    final g = await t.startGesture(
      t.getCenter(find.byKey(Key('playlist-drag-${ids[2]}'))),
    );
    await t.pump(const Duration(milliseconds: 100));
    for (var i = 0; i < 12; i++) {
      await g.moveBy(const Offset(0, -15));
      await t.pump(const Duration(milliseconds: 50));
    }
    await g.up();
    await settle(t);
    final after = await active(h);
    expect(after.exercises.first.id, ids[2]);
    expect(after.exercises.map((e) => e.id).toSet(), ids.toSet());
  });

  testWidgets('플레이리스트: 행을 누르면 그 종목 카드로 스크롤', (t) async {
    final h = Harness();
    final s = await seed(h);
    await h.pump(t, initial: Routes.session);
    t.view.physicalSize = const Size(400, 450);
    await settle(t);
    final last = s.exercises.last.id;
    final scroll = find.byType(Scrollable).first;
    final before = t.state<ScrollableState>(scroll).position.pixels;

    await t.tap(find.byKey(Key('playlist-row-$last')));
    await settle(t, 10);
    final afterPx = t.state<ScrollableState>(scroll).position.pixels;
    expect(afterPx, greaterThan(before));
    final top = t.getTopLeft(find.byKey(Key('exercise-$last'))).dy;
    expect(top, lessThan(450));
  });

  testWidgets('독: 휴식 중이 아니면 경과 시간 줄, 휴식 중이면 숨김', (t) async {
    final h = Harness();
    await seed(h, squatDone: 1);
    await h.pump(t, initial: Routes.session);
    h.now = h.now.add(const Duration(minutes: 38, seconds: 12));
    await t.pump(const Duration(seconds: 1));
    await settle(t);
    expect(find.byKey(const Key('dock-elapsed')), findsOneWidget);
    expect(
      t.widget<Text>(find.byKey(const Key('dock-elapsed'))).data,
      '운동 중 · 38:12 경과 · 전체 1/5세트',
    );

    h.container.read(restTimerProvider.notifier).start(60);
    await settle(t);
    expect(find.byKey(const Key('dock-elapsed')), findsNothing);
    expect(find.byKey(const Key('restTimerRemaining')), findsOneWidget);
    h.container.read(restTimerProvider.notifier).stop();
    await settle(t);
    expect(find.byKey(const Key('dock-elapsed')), findsOneWidget);
  });

  testWidgets('320px 폭 + 글자 2.0 + 다크: 오버플로 없음(휴식 중 포함)', (t) async {
    t.platformDispatcher.textScaleFactorTestValue = 2.0;
    t.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(t.platformDispatcher.clearAllTestValues);
    final h = Harness();
    await seed(h, squatDone: 1);
    await h.pump(t, initial: Routes.session);
    t.view.physicalSize = const Size(320, 640);
    await settle(t);
    expect(t.takeException(), isNull);
    h.container.read(restTimerProvider.notifier).start(60);
    await settle(t);
    expect(t.takeException(), isNull);
    h.now = h.now.add(const Duration(seconds: 55));
    await t.pump(const Duration(milliseconds: 300));
    expect(t.takeException(), isNull);
    h.container.read(restTimerProvider.notifier).stop();
    await settle(t);
  });
}
