import 'package:fitlog/core/api/ai_dto.dart';
import 'package:fitlog/core/routes.dart';
import 'package:fitlog/features/ai_history/ai_labels.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'harness.dart';

void main() {
  testWidgets('이력 목록: 채널·AI 이름·메모·요약·되돌림 표시, 탭하면 상세', (tester) async {
    final h = V03Harness();
    h.imports.batches.addAll([
      batch('b2', DateTime.utc(2026, 11, 25, 3), summary: {'sessions': 3, 'programs': 1, 'replaced': 1}, note: '지난달 기록'),
      batch('b1', DateTime.utc(2026, 11, 20, 3), channel: ImportChannel.MCP, summary: {'sessions': 2}, revertedAt: DateTime.utc(2026, 11, 21)),
    ]);
    await h.pump(tester, Routes.aiHistory);

    expect(find.text('${aiDateTime(DateTime.utc(2026, 11, 25, 3))} · 앱 JSON · Claude'), findsOneWidget);
    expect(find.textContaining('세션 3 · 프로그램 1 · 교체 1'), findsOneWidget);
    expect(find.textContaining('지난달 기록'), findsOneWidget);
    expect(find.text('${aiDateTime(DateTime.utc(2026, 11, 20, 3))} · MCP · Claude'), findsOneWidget);
    expect(find.byKey(const Key('ai-batch-reverted-b1')), findsOneWidget);
    expect(find.byKey(const Key('ai-batch-reverted-b2')), findsNothing);

    await tester.tap(find.byKey(const Key('ai-batch-b2')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ai-revert')), findsOneWidget);
  });

  testWidgets('비어 있으면 안내', (tester) async {
    final h = V03Harness();
    await h.pump(tester, Routes.aiHistory);
    expect(find.byKey(const Key('ai-history-empty')), findsOneWidget);
  });

  testWidgets('20개를 다 받으면 더 보기가 나오고, 누르면 before 커서로 이어 받는다', (tester) async {
    final h = V03Harness();
    final base = DateTime.utc(2026, 11, 25);
    for (var i = 0; i < 25; i++) {
      h.imports.batches.add(batch('n$i', base.subtract(Duration(days: i)), summary: {'sessions': 1}));
    }
    await h.pump(tester, Routes.aiHistory);
    expect(find.byKey(const Key('ai-batch-n0')), findsOneWidget);
    expect(find.byKey(const Key('ai-batch-n24')), findsNothing);
    await tester.scrollUntilVisible(find.byKey(const Key('ai-history-more')), 400);
    await tester.tap(find.byKey(const Key('ai-history-more')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(const Key('ai-batch-n24')), 400);
    expect(find.byKey(const Key('ai-batch-n24')), findsOneWidget);
    expect(find.byKey(const Key('ai-history-more')), findsNothing); // 5개만 와서 끝
  });

  testWidgets('상세: entity별 묶음·label·action, 되돌리기 확인 문구의 개수, 실행 후 되돌린 시각', (tester) async {
    final h = V03Harness();
    h.imports.batches.add(batch('b1', DateTime.utc(2026, 11, 25, 3), summary: {'sessions': 3, 'programs': 1}));
    h.imports.items['b1'] = [
      for (var i = 0; i < 3; i++)
        ImportItem(entity: 'workout_session', entityId: 's$i', action: ImportItemAction.CREATED, label: '세션 라벨 $i'),
      const ImportItem(entity: 'program', entityId: 'p0', action: ImportItemAction.CREATED, label: '내 프로그램'),
      const ImportItem(entity: 'workout_session', entityId: 'old', action: ImportItemAction.REPLACED_OLD, label: '옛 세션'),
    ];
    await h.pump(tester, Routes.aiHistoryDetail('b1'));

    expect(find.text('세션 라벨 0'), findsOneWidget);
    expect(find.text('내 프로그램'), findsOneWidget);
    expect(find.text('옛 세션'), findsOneWidget);
    expect(find.text('교체됨(이전 것)'), findsOneWidget);
    expect(find.text('생성'), findsNWidgets(4));

    await tester.tap(find.byKey(const Key('ai-revert')));
    await tester.pumpAndSettle();
    expect(find.textContaining('세션 3개, 프로그램 1개'), findsOneWidget);
    expect(find.textContaining('교체된 1개가 복원됩니다'), findsOneWidget);

    await tester.tap(find.byKey(const Key('ai-revert-confirm')));
    await tester.pumpAndSettle();
    expect(h.imports.batches.single.isReverted, isTrue);
    expect(find.byKey(const Key('ai-revert')), findsNothing);
    expect(find.byKey(const Key('ai-reverted-at')), findsOneWidget);
    expect(find.text('되돌렸어요'), findsOneWidget);
  });

  testWidgets('이미 되돌린 묶음은 버튼 없이 되돌린 시각', (tester) async {
    final h = V03Harness();
    h.imports.batches.add(batch('b1', DateTime.utc(2026, 11, 25), revertedAt: DateTime.utc(2026, 11, 26, 1)));
    await h.pump(tester, Routes.aiHistoryDetail('b1'));
    expect(find.byKey(const Key('ai-revert')), findsNothing);
    expect(find.text('${aiDateTime(DateTime.utc(2026, 11, 26, 1))}에 되돌림'), findsOneWidget);
  });
}
