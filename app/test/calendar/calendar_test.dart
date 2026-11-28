import 'package:fitlog/core/api/dto.dart';
import 'package:fitlog/core/routes.dart';
import 'package:fitlog/features/calendar/calendar_logic.dart';
import 'package:fitlog/features/calendar/week_strip.dart';
import 'package:fitlog/features/history/history_page.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../b2/harness.dart';

SessionSummary sum(String id, DateTime localStart, {DateTime? ended}) =>
    SessionSummary(
      id: id,
      startedAt: localStart.toUtc(),
      endedAt: ended ?? localStart.add(const Duration(hours: 1)).toUtc(),
      tz: 'Asia/Seoul',
      exerciseCount: 2,
      setCount: 6,
      totalVolumeKg: 1000,
    );

/// 로컬 시각 [at]에 끝난 세션을 하나 만든다.
Future<String> done(Harness h, DateTime at) async {
  h.now = at.toUtc();
  final s = await h.sessions.startSession(tz: 'Asia/Seoul');
  await h.sessions.endSession(s.id);
  return s.id;
}

void main() {
  group('logic', () {
    test('2026-11 grid starts Monday Oct 26, 6x7', () {
      final g = monthGrid(2026, 11);
      expect(g.length, 42);
      expect(g.first, DateTime(2026, 10, 26));
      expect(g.first.weekday, DateTime.monday);
      expect(g.last, DateTime(2026, 12, 6));
    });

    test('weekStart is Monday', () {
      expect(weekStart(DateTime(2026, 11, 29)), DateTime(2026, 11, 23)); // Sun
      expect(weekStart(DateTime(2026, 11, 23)), DateTime(2026, 11, 23));
      expect(weekDays(DateTime(2026, 11, 26)).last, DateTime(2026, 11, 29));
    });

    test('byLocalDay buckets by local date, skips active, sorts', () {
      final late = sum('b', DateTime(2026, 11, 26, 23, 30));
      final early = sum('a', DateTime(2026, 11, 26, 0, 10));
      final next = sum('c', DateTime(2026, 11, 27, 0, 5));
      final active = SessionSummary(
        id: 'x',
        startedAt: DateTime(2026, 11, 20, 10).toUtc(),
        tz: 'Asia/Seoul',
        exerciseCount: 0,
        setCount: 0,
        totalVolumeKg: 0,
      );
      final m = byLocalDay([late, early, next, active]);
      expect(m.keys.toSet(), {DateTime(2026, 11, 26), DateTime(2026, 11, 27)});
      expect(m[DateTime(2026, 11, 26)]!.map((e) => e.id), ['a', 'b']);
    });

    test('counts and streak', () {
      final m = byLocalDay([
        sum('1', DateTime(2026, 11, 24, 9)),
        sum('2', DateTime(2026, 11, 25, 9)),
        sum('3', DateTime(2026, 11, 26, 9)),
        sum('4', DateTime(2026, 11, 20, 9)),
      ]);
      expect(workedDayCount(m, weekDays(DateTime(2026, 11, 26))), 3);
      expect(workedDaysInMonth(m, 2026, 11), 4);
      expect(currentStreak(m, DateTime(2026, 11, 26)), 3);
      expect(currentStreak(m, DateTime(2026, 11, 27)), 3); // 오늘 전이면 어제부터
      expect(currentStreak(m, DateTime(2026, 11, 29)), 0);
    });
  });

  group('widgets', () {
    testWidgets('week strip dots and count', (tester) async {
      final h = Harness(start: DateTime(2026, 11, 26, 9).toUtc());
      await done(h, DateTime(2026, 11, 23, 10)); // Mon
      await done(h, DateTime(2026, 11, 25, 10)); // Wed
      await done(h, DateTime(2026, 11, 18, 10)); // prev week
      h.now = DateTime(2026, 11, 26, 9).toUtc();
      await h.pump(tester);
      expect(find.byKey(const Key('week-strip')), findsOneWidget);
      expect(find.byKey(const Key('week-dot-2026-11-23')), findsOneWidget);
      expect(find.byKey(const Key('week-dot-2026-11-25')), findsOneWidget);
      expect(find.byKey(const Key('week-dot-2026-11-24')), findsNothing);
      expect(find.byKey(const Key('week-dot-2026-11-18')), findsNothing);
      expect(find.text('이번 주 2회 운동'), findsOneWidget);
    });

    testWidgets('week strip tap opens history calendar', (tester) async {
      final h = Harness(start: DateTime(2026, 11, 26, 9).toUtc());
      await h.pump(
        tester,
        extraRoutes: [
          GoRoute(path: Routes.history, builder: (_, _) => const HistoryPage()),
        ],
      );
      await tester.tap(find.byType(WeekStrip));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('month-calendar')), findsOneWidget);
    });

    Future<Harness> openHistory(
      WidgetTester tester, {
      List<DateTime> at = const [],
    }) async {
      final h = Harness(start: DateTime(2026, 11, 26, 9).toUtc());
      for (final d in at) {
        await done(h, d);
      }
      h.now = DateTime(2026, 11, 26, 9).toUtc();
      await h.pump(
        tester,
        initial: Routes.history,
        extraRoutes: [
          GoRoute(path: Routes.history, builder: (_, _) => const HistoryPage()),
        ],
      );
      return h;
    }

    Future<void> settle(WidgetTester tester) async {
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump(const Duration(milliseconds: 250));
    }

    testWidgets('history starts collapsed as week view, no toggle', (
      tester,
    ) async {
      await openHistory(
        tester,
        at: [DateTime(2026, 11, 24, 10), DateTime(2026, 11, 18, 10)],
      );
      expect(find.byKey(const Key('week-calendar')), findsOneWidget);
      expect(find.byKey(const Key('month-calendar')), findsNothing);
      expect(find.byKey(const Key('history-view-calendar')), findsNothing);
      expect(find.text('11월 4주 · 1회 운동'), findsOneWidget);
      expect(find.byKey(const Key('week-dot-2026-11-24')), findsOneWidget);
      expect(find.byKey(const Key('week-dot-2026-11-18')), findsNothing);
      // 목록은 아래에 항상 보인다.
      expect(find.byKey(const Key('history-list')), findsOneWidget);
      expect(find.byKey(const Key('month-2026-11')), findsOneWidget);
    });

    testWidgets('expand by button, collapse back', (tester) async {
      await openHistory(
        tester,
        at: [DateTime(2026, 11, 24, 10), DateTime(2026, 10, 28, 10)],
      );
      await tester.tap(find.byKey(const Key('history-cal-expand')));
      await settle(tester);
      expect(find.byKey(const Key('month-calendar')), findsOneWidget);
      expect(find.byKey(const Key('week-calendar')), findsNothing);
      expect(find.text('2026년 11월 · 1일 운동'), findsOneWidget);
      expect(find.byKey(const Key('cal-dot-2026-11-24')), findsOneWidget);
      expect(find.byKey(const Key('cal-dot-2026-10-28')), findsOneWidget);
      expect(find.byTooltip('달력 접기'), findsOneWidget);
      await tester.tap(find.byKey(const Key('history-cal-expand')));
      await settle(tester);
      expect(find.byKey(const Key('week-calendar')), findsOneWidget);
      expect(find.byKey(const Key('month-calendar')), findsNothing);
    });

    testWidgets('expand by tapping the header title', (tester) async {
      await openHistory(tester);
      await tester.tap(find.byKey(const Key('cal-title')));
      await settle(tester);
      expect(find.byKey(const Key('month-calendar')), findsOneWidget);
    });

    testWidgets('week and month navigation', (tester) async {
      await openHistory(
        tester,
        at: [DateTime(2026, 11, 18, 10), DateTime(2026, 12, 3, 10)],
      );
      await tester.tap(find.byKey(const Key('cal-prev')));
      await settle(tester);
      expect(find.text('11월 3주 · 1회 운동'), findsOneWidget);
      expect(find.byKey(const Key('week-dot-2026-11-18')), findsOneWidget);
      await tester.tap(find.byKey(const Key('cal-next')));
      await tester.tap(find.byKey(const Key('cal-next')));
      await settle(tester);
      expect(find.text('12월 1주 · 1회 운동'), findsOneWidget);
      expect(find.byKey(const Key('week-dot-2026-12-03')), findsOneWidget);
      await tester.tap(find.byKey(const Key('history-cal-expand')));
      await settle(tester);
      expect(find.text('2026년 12월 · 1일 운동'), findsOneWidget);
      await tester.tap(find.byKey(const Key('cal-prev')));
      await settle(tester);
      expect(find.text('2026년 11월 · 1일 운동'), findsOneWidget);
      await tester.tap(find.byKey(const Key('cal-prev')));
      await settle(tester);
      expect(find.text('2026년 10월 · 0일 운동'), findsOneWidget);
    });

    for (final expand in [false, true]) {
      testWidgets('day tap filters list, chip clears (expanded=$expand)', (
        tester,
      ) async {
        final h = await openHistory(
          tester,
          at: [DateTime(2026, 11, 24, 10), DateTime(2026, 11, 25, 10)],
        );
        final all = await h.sessions.watchRecentSessions(limit: 10).first;
        expect(all.length, 2);
        if (expand) {
          await tester.tap(find.byKey(const Key('history-cal-expand')));
          await settle(tester);
        }
        for (final s in all) {
          expect(find.byKey(Key('history-${s.id}')), findsOneWidget);
        }
        await tester.tap(find.byKey(const Key('cal-day-2026-11-24')));
        await settle(tester);
        final shown = all
            .where(
              (s) => find.byKey(Key('history-${s.id}')).evaluate().isNotEmpty,
            )
            .toList();
        expect(shown.length, 1);
        await tester.tap(find.byKey(const Key('cal-day-2026-11-24')));
        await settle(tester);
        for (final s in all) {
          expect(find.byKey(Key('history-${s.id}')), findsOneWidget);
        }
      });
    }

    testWidgets('day without sessions shows empty message', (tester) async {
      await openHistory(tester, at: [DateTime(2026, 11, 24, 10)]);
      await tester.tap(find.byKey(const Key('cal-day-2026-11-25')));
      await settle(tester);
      expect(find.text('이 날은 운동 기록이 없어요'), findsOneWidget);
      expect(find.byKey(const Key('month-2026-11')), findsNothing);
    });

    for (final dark in [false, true]) {
      testWidgets('no overflow at 320px, 2x text, dark=$dark', (tester) async {
        final h = Harness(start: DateTime(2026, 11, 26, 9).toUtc());
        await done(h, DateTime(2026, 11, 24, 10));
        h.now = DateTime(2026, 11, 26, 9).toUtc();
        await h.pump(
          tester,
          initial: Routes.history,
          extraRoutes: [
            GoRoute(
              path: Routes.history,
              builder: (_, _) => const HistoryPage(),
            ),
          ],
        );
        tester.view.physicalSize = const Size(320, 640);
        tester.platformDispatcher.textScaleFactorTestValue = 2.0;
        if (dark) {
          tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
        }
        addTearDown(tester.platformDispatcher.clearAllTestValues);
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const Key('history-cal-expand')));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const Key('cal-day-2026-11-24')));
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);
      });
    }
  });
}
