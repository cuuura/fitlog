import 'package:fitlog/core/api/dto.dart';
import 'package:fitlog/core/routes.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../b2/harness.dart';

Future<void> settle(WidgetTester t, [int n = 6]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<Session> active(Harness h) =>
    h.sessions.watchActiveSession().first.then((s) => s!);

/// [from]을 길게 눌렀다가 [dy]만큼 끌어 놓는다.
Future<void> longPressDrag(WidgetTester t, Finder from, double dy) async {
  final g = await t.startGesture(t.getCenter(from));
  await t.pump(const Duration(milliseconds: 700));
  await g.moveBy(Offset(0, dy < 0 ? -20 : 20));
  await t.pump();
  await g.moveBy(Offset(0, dy < 0 ? dy + 20 : dy - 20));
  await t.pump();
  await g.up();
  await settle(t);
}

Future<Session> seed(
  Harness h, {
  int sets = 4,
  int done = 0,
  List<Exercise>? more,
}) async {
  final s0 = await h.sessions.startSession(tz: 'Asia/Seoul');
  final se = await h.sessions.addExercise(s0.id, squat.id);
  for (var i = 0; i < sets; i++) {
    await h.sessions.addSet(
      se.id,
      WorkoutSet(
        id: 'set-$i',
        position: i,
        weightKg: 100.0 + i,
        reps: 5,
        completedAt: i < done ? h.now : null,
      ),
    );
  }
  for (final e in more ?? const <Exercise>[]) {
    final x = await h.sessions.addExercise(s0.id, e.id);
    await h.sessions.addSet(
      x.id,
      WorkoutSet(id: 'x-${e.id}', position: 0, weightKg: 50, reps: 8),
    );
  }
  return active(h);
}

List<String> setIds(Session s, [int ex = 0]) => [
  for (final w in s.exercises[ex].sets) w.id,
];

void main() {
  testWidgets('long press a collapsed set row and drag to reorder (stored)', (
    t,
  ) async {
    final h = Harness();
    await seed(h);
    await h.pump(t, initial: Routes.session);
    await settle(t);
    // set-0 is current (expanded); drag the collapsed last set above it.
    await longPressDrag(t, find.byKey(const Key('row-set-3')), -700);
    final s = await active(h);
    expect(setIds(s).first, 'set-3');
    expect(s.exercises.single.sets.map((e) => e.position), [0, 1, 2, 3]);
  });

  testWidgets('number cell no longer drags immediately', (t) async {
    final h = Harness();
    await seed(h);
    await h.pump(t, initial: Routes.session);
    await settle(t);
    await t.drag(find.byKey(const Key('drag-set-3')), const Offset(0, -250));
    await settle(t);
    expect(setIds(await active(h)), ['set-0', 'set-1', 'set-2', 'set-3']);
  });

  testWidgets('completed sets can move and current set is recomputed', (
    t,
  ) async {
    final h = Harness();
    await seed(h, done: 2); // set-0, set-1 done; current = set-2
    await h.pump(t, initial: Routes.session);
    await settle(t);
    expect(find.byKey(const Key('current-set-2')), findsOneWidget);
    // move done set-1 below the others (collapsed rows, drag down past set-3)
    await longPressDrag(t, find.byKey(const Key('row-set-1')), 700);
    var s = await active(h);
    expect(setIds(s).last, 'set-1');
    expect(s.exercises.single.sets.last.completedAt, isNotNull);
    // first incomplete in the new order is still set-2
    expect(find.byKey(const Key('current-set-2')), findsOneWidget);
    // move done set-0 to the end of the list; current stays the first incomplete
    await longPressDrag(t, find.byKey(const Key('row-set-0')), 700);
    s = await active(h);
    expect(setIds(s).last, 'set-0');
    expect(find.byKey(const Key('current-set-2')), findsOneWidget);
  });

  testWidgets('previous value follows the matched set after reorder', (
    t,
  ) async {
    final h = Harness();
    // past session: k0 80kg, k1 90kg, k2 100kg
    final p = await h.sessions.startSession(tz: 'Asia/Seoul');
    final pse = await h.sessions.addExercise(p.id, squat.id);
    for (var i = 0; i < 3; i++) {
      await h.sessions.addSet(
        pse.id,
        WorkoutSet(
          id: 'p$i',
          position: i,
          plannedSetKey: 'k$i',
          weightKg: 80.0 + 10 * i,
          reps: 5,
          completedAt: h.now,
        ),
      );
    }
    await h.sessions.endSession(p.id);
    final s0 = await h.sessions.startSession(tz: 'Asia/Seoul');
    final se = await h.sessions.addExercise(s0.id, squat.id);
    for (var i = 0; i < 3; i++) {
      await h.sessions.addSet(
        se.id,
        WorkoutSet(id: 'set-$i', position: i, plannedSetKey: 'k$i', reps: 5),
      );
    }
    await h.pump(t, initial: Routes.session);
    await settle(t);
    expect(
      find.textContaining('지난번: 80 kg×5'),
      findsOneWidget,
    ); // current set-0
    await longPressDrag(t, find.byKey(const Key('row-set-2')), -700);
    final s = await active(h);
    expect(setIds(s), ['set-2', 'set-0', 'set-1']);
    // set-2 is now the current (first incomplete) set and keeps its own past value.
    expect(find.byKey(const Key('current-set-2')), findsOneWidget);
    expect(find.textContaining('지난번: 100 kg×5'), findsOneWidget);
  });

  testWidgets('adding a set after reorder uses the matched previous default', (
    t,
  ) async {
    final h = Harness();
    final p = await h.sessions.startSession(tz: 'Asia/Seoul');
    final pse = await h.sessions.addExercise(p.id, squat.id);
    for (var i = 0; i < 3; i++) {
      await h.sessions.addSet(
        pse.id,
        WorkoutSet(
          id: 'p$i',
          position: i,
          weightKg: 80.0 + 10 * i,
          reps: 5,
          completedAt: h.now,
        ),
      );
    }
    await h.sessions.endSession(p.id);
    final s0 = await h.sessions.startSession(tz: 'Asia/Seoul');
    final se = await h.sessions.addExercise(s0.id, squat.id);
    await h.pump(t, initial: Routes.session);
    await settle(t);
    await t.tap(find.byKey(Key('add-set-${se.id}')));
    await settle(t);
    final s = await active(h);
    expect(s.exercises.single.sets.single.weightKg, 80); // first work set
  });

  testWidgets('long press exercise header and drag to move the exercise', (
    t,
  ) async {
    final h = Harness();
    final s0 = await seed(h, sets: 1, more: [dbPress]);
    final ids = [for (final e in s0.exercises) e.id];
    await h.pump(t, initial: Routes.session);
    await settle(t);
    await longPressDrag(t, find.text('스쿼트').last, 1100);
    final s = await active(h);
    expect([for (final e in s.exercises) e.id], [ids[1], ids[0]]);
  });

  testWidgets('tall card: inline drag cannot reach the end, sheet can', (
    t,
  ) async {
    final h = Harness();
    final s0 = await seed(h, sets: 24);
    final seId = s0.exercises.single.id;
    await h.pump(t, initial: Routes.session);
    t.view.physicalSize = const Size(800, 900);
    await settle(t);
    // The outer list does not follow an inline drag, so the last set cannot reach the top.
    await t.scrollUntilVisible(
      find.byKey(const Key('row-set-23')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await longPressDrag(t, find.byKey(const Key('row-set-23')), -800);
    expect(setIds(await active(h)).first, isNot('set-23'));

    // The "reorder sets" sheet has its own scrolling list and saves on every drag.
    await t.ensureVisible(find.byKey(Key('reorder-sets-$seId')));
    await settle(t);
    await t.tap(find.byKey(Key('reorder-sets-$seId')));
    await settle(t);
    expect(find.byKey(Key('set-order-list-$seId')), findsOneWidget);
    await t.drag(
      find.byKey(const Key('set-order-drag-set-1')),
      const Offset(0, 120),
    );
    await settle(t);
    final ids = setIds(await active(h));
    expect(ids.length, 24);
    expect(ids.indexOf('set-1'), greaterThan(1));
  });
}
