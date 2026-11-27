import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fitlog/core/api/dto.dart';
import 'package:fitlog/core/routes.dart';
import 'package:fitlog/features/history/history_page.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'harness.dart';

SessionSummary sum(String id, DateTime start, {DateTime? end}) => SessionSummary(
  id: id,
  startedAt: start,
  endedAt: end,
  tz: 'Asia/Seoul',
  exerciseCount: 1,
  setCount: 1,
  totalVolumeKg: 100,
);

void main() {
  test('groupByMonth: 진행 중 제외, 월 머리글은 월이 바뀔 때만', () {
    final end = DateTime.utc(2026, 11, 15, 13);
    final items = groupByMonth([
      sum('a', DateTime.utc(2026, 11, 20, 12)), // 진행 중
      sum('b', DateTime.utc(2026, 11, 15, 12), end: end),
      sum('c', DateTime.utc(2026, 11, 10, 12), end: end),
      sum('d', DateTime.utc(2026, 10, 10, 12), end: end),
    ]);
    expect(items.map((i) => i is HistoryMonthHeader ? 'H${i.month}' : (i as HistorySessionItem).summary.id), [
      'H11',
      'b',
      'c',
      'H10',
      'd',
    ]);
  });

  testWidgets('월별 그룹·요약·프로그램 배지, 진행 중 세션은 안 보인다', (tester) async {
    final h = B3Harness();
    final free = await h.finished(DateTime.utc(2026, 11, 15, 12), lifts: [
      ('ex-squat', [(100.0, 5)]),
    ]);
    final prog = await h.finished(DateTime.utc(2026, 11, 17, 12), plan: plan());
    final old = await h.finished(DateTime.utc(2026, 10, 3, 12), lifts: [
      ('ex-bench', [(60.0, 8)]),
    ]);
    h.clock = DateTime.utc(2026, 11, 25, 12);
    final active = await h.sessions.startSession(tz: 'Asia/Seoul');

    await h.pump(tester, Routes.history);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const Key('month-2026-11')), findsOneWidget);
    expect(find.byKey(const Key('month-2026-10')), findsOneWidget);
    expect(find.text('2026년 11월'), findsOneWidget);
    expect(find.byKey(Key('history-${free.id}')), findsOneWidget);
    expect(find.byKey(Key('history-${old.id}')), findsOneWidget);
    expect(find.byKey(Key('history-${active.id}')), findsNothing);
    // 월 머리말(불러온 범위 기준): 세션 수·볼륨 합. 행: 종목 요약과 큰 볼륨 숫자.
    expect(find.byKey(const Key('month-stats-2026-11')), findsOneWidget);
    expect(find.text('세션 2회 · 1,500kg'), findsOneWidget); // 11월: 자유(500) + 프로그램 계획 세트(1,000) // 11월: 자유(500) + 프로그램(0)
    expect(find.text('500'), findsOneWidget);
    expect(find.text('스쿼트'), findsWidgets);
    expect(find.text('자유 운동'), findsWidgets);

    expect(find.byKey(Key('badge-${prog.id}')), findsOneWidget);
    expect(find.text('프로그램 A · 4회차'), findsOneWidget);
    expect(find.byKey(Key('badge-${free.id}')), findsNothing);
  });

  testWidgets('탭하면 상세, 메뉴·길게 누르기는 수정으로 간다', (tester) async {
    final h = B3Harness();
    final s = await h.finished(DateTime.utc(2026, 11, 15, 12));
    await h.pump(tester, Routes.history);

    await tester.tap(find.byKey(Key('history-${s.id}')));
    await tester.pumpAndSettle();
    expect(find.text('detail-${s.id}'), findsOneWidget);
    h.router.pop();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(Key('menu-${s.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('menu-edit-${s.id}')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('edit-start')), findsOneWidget);
    h.router.pop();
    await tester.pumpAndSettle();

    await tester.longPress(find.byKey(Key('history-${s.id}')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('edit-start')), findsOneWidget);
  });

  testWidgets('빈 목록', (tester) async {
    final h = B3Harness();
    await h.pump(tester, Routes.history);
    expect(find.byKey(const Key('history-empty')), findsOneWidget);
  });

  testWidgets('끝까지 스크롤하면 더 불러온다(20개씩)', (tester) async {
    final h = B3Harness();
    final ids = <String>[];
    for (var i = 0; i < 45; i++) {
      final s = await h.finished(DateTime.utc(2026, 1, 1, 12).add(Duration(days: i)));
      ids.add(s.id);
    }
    await h.pump(tester, Routes.history);
    final container = ProviderScope.containerOf(tester.element(find.byType(HistoryPage)));
    expect(container.read(historyLimitProvider), 20);

    final oldest = find.byKey(Key('history-${ids.first}'));
    expect(oldest, findsNothing);
    await tester.scrollUntilVisible(oldest, 600, scrollable: find.descendant(of: find.byKey(const Key('history-list')), matching: find.byType(Scrollable)), maxScrolls: 200);
    expect(oldest, findsOneWidget);
    expect(container.read(historyLimitProvider), greaterThan(40));
  });

  testWidgets('종목별 기록: 종목 선택 후 기록 화면으로', (tester) async {
    final h = B3Harness()..pickResult = 'ex-squat';
    await h.pump(tester, Routes.history);
    await tester.tap(find.byKey(const Key('history-records')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('pick-stub'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('records-best-weight')), findsOneWidget);
    expect(find.text('스쿼트'), findsOneWidget);
  });
}
