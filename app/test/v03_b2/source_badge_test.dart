import 'package:fitlog/core/api/dto.dart';
import 'package:fitlog/core/api/program_dto.dart';
import 'package:fitlog/core/ids.dart';
import 'package:fitlog/core/routes.dart';
import 'package:fitlog/features/source_badge/source_badge.dart';
import 'package:fitlog/l10n/gen/app_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import 'harness.dart';

Future<GoRouter> _pumpBadge(WidgetTester tester, Enum? source, String? batchId) async {
  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (_, _) => Scaffold(body: SourceBadge(source: source, importBatchId: batchId))),
      GoRoute(path: '/ai/history/:id', builder: (_, s) => Scaffold(body: Text('detail-${s.pathParameters['id']}'))),
    ],
  );
  await tester.pumpWidget(
    MaterialApp.router(
      routerConfig: router,
      localizationsDelegates: [AppLocalizations.delegate, ...GlobalMaterialLocalizations.delegates],
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('ko'),
    ),
  );
  await tester.pump();
  return router;
}

void main() {
  testWidgets('source별 문구, APP·MANUAL·USER·null은 아무것도 그리지 않는다', (tester) async {
    for (final (src, text) in <(Enum, String)>[
      (SessionSource.AI_JSON, 'AI·JSON'),
      (SessionSource.AI_MCP, 'AI·MCP'),
      (SessionSource.IMPORT, '가져옴'),
      (ProgramSource.AI_MCP, 'AI·MCP'),
      (MeasurementSource.IMPORT, '가져옴'),
    ]) {
      await _pumpBadge(tester, src, null);
      expect(find.text(text), findsOneWidget, reason: '$src');
    }
    for (final src in <Enum?>[SessionSource.APP, MeasurementSource.MANUAL, ProgramSource.USER, ProgramSource.TEMPLATE, null]) {
      await _pumpBadge(tester, src, 'b1');
      expect(find.byType(Chip), findsNothing, reason: '$src');
      expect(find.byType(ActionChip), findsNothing, reason: '$src');
    }
  });

  testWidgets('importBatchId가 있으면 탭해서 묶음 상세로, 없으면 탭할 수 없다', (tester) async {
    await _pumpBadge(tester, SessionSource.AI_JSON, null);
    expect(find.byType(ActionChip), findsNothing);
    await _pumpBadge(tester, SessionSource.AI_JSON, 'b9');
    await tester.tap(find.byType(ActionChip));
    await tester.pumpAndSettle();
    expect(find.text('detail-b9'), findsOneWidget);
  });

  testWidgets('세션 상세·목록: AI 세션에만 배지', (tester) async {
    final h = V03Harness();
    final ai = await h.sessions.startSession(tz: 'Asia/Seoul');
    await h.sessions.endSession(ai.id);
    h.now = DateTime.utc(2026, 11, 26, 12);
    final own = await h.sessions.startSession(tz: 'Asia/Seoul');
    await h.sessions.endSession(own.id);
    h.sessions.sources[ai.id] = (SessionSource.AI_MCP, 'b1');

    await h.pump(tester, Routes.history);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(Key('source-${ai.id}')), findsOneWidget);
    expect(find.byKey(Key('source-${own.id}')), findsNothing);

    await tester.tap(find.descendant(of: find.byKey(Key('source-${ai.id}')), matching: find.text('AI·MCP')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ai-revert')), findsNothing); // 상세 화면(이력 없음 -> 오류)으로 이동
    h.router.pop();
    await tester.pumpAndSettle();

    h.router.push(Routes.sessionDetail(ai.id));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('detail-source-badge')), findsOneWidget);
    h.router.pop();
    h.router.push(Routes.sessionDetail(own.id));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('detail-source-badge')), findsNothing);
  });

  testWidgets('프로그램 목록·상세: AI 프로그램에만 배지', (tester) async {
    final h = V03Harness();
    h.programs.programs['p-ai'] = const Program(
      id: 'p-ai',
      name: 'AI 프로그램',
      builtIn: false,
      dayCount: 1,
      source: ProgramSource.AI_JSON,
      importBatchId: 'b1',
      definition: {'name': 'AI 프로그램', 'days': []},
    );
    h.programs.programs['p-mine'] = const Program(
      id: 'p-mine',
      name: '내 프로그램',
      builtIn: false,
      dayCount: 1,
      source: ProgramSource.USER,
      definition: {'name': '내 프로그램', 'days': []},
    );
    await h.pump(tester, Routes.programs);
    await tester.tap(find.descendant(of: find.byKey(const Key('programs-segments')), matching: find.textContaining('내 프로그램')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('source-p-ai')), findsOneWidget);
    expect(find.byKey(const Key('source-p-mine')), findsNothing);
    // 추가 시트의 내 프로그램 구분에도 같은 배지
    await tester.tap(find.byKey(const Key('programs-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byKey(const Key('program-add-segments')), matching: find.text('내 프로그램')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('source-p-ai')), findsNWidgets(2));
    await tester.tap(find.byKey(const Key('program-add-close')));
    await tester.pumpAndSettle();

    h.router.push(Routes.programDetail('p-ai'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('program-source-badge')), findsOneWidget);
    h.router.pop();
    h.router.push(Routes.programDetail('p-mine'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('program-source-badge')), findsNothing);
  });

  testWidgets('체중 목록: AI·가져온 기록에만 배지', (tester) async {
    final h = V03Harness();
    await h.body.add(BodyMeasurement(id: newId(), measuredAt: DateTime.utc(2026, 11, 20), weightKg: 70, source: MeasurementSource.AI_JSON, importBatchId: 'b1'));
    await h.body.add(BodyMeasurement(id: 'manual', measuredAt: DateTime.utc(2026, 11, 21), weightKg: 71));
    await h.pump(tester, Routes.body);
    expect(find.text('AI·JSON'), findsOneWidget);
    expect(find.byType(ActionChip), findsOneWidget);
  });
}
