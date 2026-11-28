// 편집 화면 드래그 순서 변경: 지난 기록 편집(운동·세트), 예정 운동 편집(운동·세트).
import 'package:fitlog/core/api/dto.dart';
import 'package:fitlog/core/routes.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../b2/harness.dart' as b2;
import '../sched/ui_test.dart' show dragHandle, schedRoutes, settle;
import '../v02_b3/harness.dart';

Future<void> _drag(WidgetTester t, Finder handle, Offset by) async {
  final g = await t.startGesture(t.getCenter(handle));
  await t.pump(const Duration(milliseconds: 100));
  for (var i = 0; i < 10; i++) {
    await g.moveBy(by / 10);
    await t.pump(const Duration(milliseconds: 50));
  }
  await g.up();
  await t.pumpAndSettle();
}

void main() {
  final start = DateTime.utc(2026, 11, 15, 12);

  group('지난 기록 편집', () {
    testWidgets('운동 3개: 첫 운동을 맨 아래로 끌면 저장소 순서가 바뀐다', (t) async {
      final h = B3Harness();
      final s = await h.finished(
        start,
        lifts: [
          ('ex-squat', [(100.0, 5)]),
          ('ex-bench', [(60.0, 5)]),
          ('ex-pullup', [(0.0, 8)]),
        ],
      );
      final ids = [for (final e in s.exercises) e.id];
      await h.pump(t, Routes.sessionEdit(s.id));

      await _drag(
        t,
        find.byKey(Key('edit-ex-handle-${ids[0]}')),
        const Offset(0, 700),
      );
      var now = (await h.sessions.watchSession(s.id).first)!.exercises;
      expect(now.map((e) => e.id), [ids[1], ids[2], ids[0]]);
      expect(now.map((e) => e.position), [0, 1, 2]);

      // 가운데 운동을 맨 위로
      await _drag(
        t,
        find.byKey(Key('edit-ex-handle-${ids[2]}')),
        const Offset(0, -700),
      );
      now = (await h.sessions.watchSession(s.id).first)!.exercises;
      expect(now.map((e) => e.id), [ids[2], ids[1], ids[0]]);
    });

    testWidgets('세트 3개: 같은 운동 안에서 끌고, 다른 운동 세트는 그대로', (t) async {
      final h = B3Harness();
      final s = await h.finished(
        start,
        lifts: [
          ('ex-squat', [(100.0, 5), (90.0, 6), (80.0, 7)]),
          ('ex-bench', [(60.0, 5), (50.0, 6)]),
        ],
      );
      final a = s.exercises[0].sets, b = s.exercises[1].sets;
      await h.pump(t, Routes.sessionEdit(s.id));

      await _drag(
        t,
        find.byKey(Key('edit-set-handle-${a[0].id}')),
        const Offset(0, 600),
      );
      final now = (await h.sessions.watchSession(s.id).first)!.exercises;
      expect(
        now[0].sets.map((e) => e.id),
        isNot(orderedEquals([for (final w in a) w.id])),
      );
      expect(now[0].sets.last.id, a[0].id, reason: '맨 아래로 이동');
      expect(now[0].sets.map((e) => e.position), [0, 1, 2]);
      expect(now[1].sets.map((e) => e.id), [b[0].id, b[1].id]);
      expect(now.map((e) => e.id), [
        s.exercises[0].id,
        s.exercises[1].id,
      ], reason: '운동 순서는 그대로');
    });

    testWidgets('위/아래 버튼이 없다', (t) async {
      final h = B3Harness();
      final s = await h.finished(
        start,
        lifts: [
          ('ex-squat', [(100.0, 5), (90.0, 6)]),
        ],
      );
      await h.pump(t, Routes.sessionEdit(s.id));
      expect(find.byIcon(Icons.arrow_upward), findsNothing);
      expect(find.byIcon(Icons.arrow_downward), findsNothing);
      expect(
        find.byKey(Key('edit-ex-handle-${s.exercises.single.id}')),
        findsOneWidget,
      );
    });
  });

  group('예정 운동 편집', () {
    Future<b2.Harness> open(WidgetTester t, {int items = 3}) async {
      final h = b2.Harness();
      await h.scheduled.upsert(
        ScheduledWorkout(
          id: 'sw1',
          plannedDate: '2026-11-26',
          title: '3종목',
          items: [
            for (final (i, ex) in [b2.squat, b2.dbPress, b2.legPress].indexed)
              if (i < items)
                ScheduledItem(
                  exerciseId: ex.id,
                  sets: [
                    for (var k = 0; k < 3; k++)
                      ScheduledSet(
                        targetWeightKg: 10.0 * (i + 1),
                        targetReps: 5 + k,
                      ),
                  ],
                ),
          ],
        ),
      );
      await h.pump(
        t,
        initial: Routes.scheduledEdit('sw1'),
        extraRoutes: schedRoutes(),
      );
      await settle(t);
      return h;
    }

    Future<void> save(WidgetTester t) async {
      await t.scrollUntilVisible(
        find.byKey(const Key('sched-save')),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await t.tap(find.byKey(const Key('sched-save')));
      await settle(t);
    }

    testWidgets('운동 3개: 끌어 옮긴 순서대로 저장, 키는 같은 운동을 가리킨다', (t) async {
      final h = await open(t);
      await t.ensureVisible(find.byKey(const Key('sched-handle-0')));
      await dragHandle(
        t,
        find.byKey(const Key('sched-handle-0')),
        const Offset(0, 1400),
      );
      // 항목 0(스쿼트)은 여전히 sched-item-0 키, 세트 값도 그대로
      expect(
        t
            .widget<TextField>(find.byKey(const Key('sched-w-0-0')))
            .controller!
            .text,
        '10',
      );
      await save(t);
      final ids = [
        for (final i in (await h.scheduled.byId('sw1'))!.items) i.exerciseId,
      ];
      expect(ids.first, isNot(b2.squat.id));
      expect(ids.last, b2.squat.id);
      expect(ids.toSet(), {b2.squat.id, b2.dbPress.id, b2.legPress.id});
    });

    testWidgets('세트 3개: 세트를 끌면 그 운동 안에서만 바뀐다', (t) async {
      final h = await open(t);
      await t.ensureVisible(find.byKey(const Key('sched-set-handle-1-0')));
      await dragHandle(
        t,
        find.byKey(const Key('sched-set-handle-1-0')),
        const Offset(0, 400),
      );
      await save(t);
      final items = (await h.scheduled.byId('sw1'))!.items;
      expect([for (final s in items[1].sets) s.targetReps], [6, 7, 5]);
      expect([for (final s in items[0].sets) s.targetReps], [5, 6, 7]);
      expect([for (final s in items[2].sets) s.targetReps], [5, 6, 7]);
    });

    testWidgets('위/아래 버튼이 없다', (t) async {
      await open(t);
      expect(find.byIcon(Icons.arrow_upward), findsNothing);
      expect(find.byIcon(Icons.arrow_downward), findsNothing);
    });
  });
}
