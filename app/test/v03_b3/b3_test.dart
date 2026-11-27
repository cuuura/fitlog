import 'package:fitlog/core/api/ai_dto.dart';
import 'package:fitlog/core/auth/auth_controller.dart';
import 'package:fitlog/core/routes.dart';
import 'package:fitlog/core/settings/settings_controller.dart';
import 'package:fitlog/data/memory/memory_repositories.dart';
import 'package:fitlog/data/providers.dart';
import 'package:fitlog/domain/repositories.dart';
import 'package:fitlog/features/ai_connect/ai_connect_page.dart';
import 'package:fitlog/features/ai_connect/ai_hub_page.dart';
import 'package:fitlog/features/export/export_page.dart';
import 'package:fitlog/features/export/export_saver.dart';
import 'package:fitlog/l10n/gen/app_localizations.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../support/fixed_providers.dart';

class FakeSaver implements ExportSaver {
  final saved = <({String fileName, String content, String mimeType})>[];
  @override
  Future<void> save({required String fileName, required String content, required String mimeType}) async =>
      saved.add((fileName: fileName, content: content, mimeType: mimeType));
}

class _FailingExport extends MemoryExportRepository {
  @override
  Future<String> exportJson() async => throw Exception('offline');
}

class _FailingConns extends MemoryAiConnectionRepository {
  @override
  Future<McpInfo> mcpInfo() async => throw Exception('offline');
}

class _FailingDeletions extends MemoryDeletionRequestRepository {
  @override
  Future<int> pendingCount() async => throw Exception('offline');
}

class Env {
  final ai = MemoryAiConnectionRepository();
  ExportRepository export = MemoryExportRepository();
  final saver = FakeSaver();
  DeletionRequestRepository deletions = MemoryDeletionRequestRepository();
  AiConnectionRepository? aiOverride;

  List<Override> get overrides => [
    authControllerProvider.overrideWith(() => FixedAuthStatus(AuthStatus.signedIn)),
    settingsProvider.overrideWith(() => FixedSettings()),
    exerciseRepositoryProvider.overrideWithValue(MemoryExerciseRepository()),
    sessionRepositoryProvider.overrideWithValue(MemorySessionRepository()),
    scheduledWorkoutRepositoryProvider.overrideWithValue(MemoryScheduledWorkoutRepository()),
    bodyRepositoryProvider.overrideWithValue(MemoryBodyRepository()),
    syncServiceProvider.overrideWithValue(NoopSyncService()),
    planCacheProvider.overrideWithValue(MemoryPlanCache(_NoPrograms())),
    aiConnectionRepositoryProvider.overrideWithValue(aiOverride ?? ai),
    exportRepositoryProvider.overrideWithValue(export),
    deletionRequestRepositoryProvider.overrideWithValue(deletions),
    exportSaverProvider.overrideWithValue(saver),
  ];

  Future<void> pump(WidgetTester tester, String initial) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    Widget stub(String t) => Scaffold(appBar: AppBar(title: Text(t)));
    final router = GoRouter(
      initialLocation: initial,
      routes: [
        GoRoute(path: Routes.ai, builder: (_, _) => const AiHubPage()),
        GoRoute(path: Routes.aiConnect, builder: (_, _) => const AiConnectPage()),
        GoRoute(path: Routes.export, builder: (_, _) => const ExportPage()),
        GoRoute(path: Routes.importJson, builder: (_, _) => stub('stub-import')),
        GoRoute(path: Routes.aiHistory, builder: (_, _) => stub('stub-history')),
        GoRoute(path: Routes.deletionRequests, builder: (_, _) => stub('stub-deletions')),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides,
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: [AppLocalizations.delegate, ...GlobalMaterialLocalizations.delegates],
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('ko'),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }
}

class _NoPrograms extends MemoryProgramRepository {}

DeletionRequest _pending(String id) => DeletionRequest(
  id: id,
  entity: 'workout_session',
  entityId: 'e$id',
  status: DeletionStatus.PENDING,
  createdAt: DateTime.utc(2026, 11, 1),
  expiresAt: DateTime.utc(2026, 12, 1),
);

AiConnection _conn(String id, String name, {bool write = true, DateTime? last}) => AiConnection(
  id: id,
  clientName: name,
  scopes: write ? ['fitlog.read', 'fitlog.write'] : ['fitlog.read'],
  createdAt: DateTime.utc(2026, 11, 2),
  lastUsedAt: last,
);

void main() {
  group('허브', () {
    testWidgets('항목·연결 수·삭제 요청 배지', (tester) async {
      final env = Env()..ai.list.add(_conn('c1', 'Claude'));
      (env.deletions as MemoryDeletionRequestRepository).requests.addAll([_pending('a'), _pending('b')]);
      await env.pump(tester, Routes.ai);
      expect(find.text('AI 연결(MCP)'), findsOneWidget);
      expect(find.textContaining('연결된 AI 1개'), findsOneWidget);
      expect(find.text('JSON 붙여넣기로 가져오기'), findsOneWidget);
      expect(find.text('가져오기 이력'), findsOneWidget);
      expect(find.text('삭제 요청'), findsOneWidget);
      expect(find.text('대기 2건'), findsOneWidget);
      expect(find.text('내보내기'), findsOneWidget);

      await tester.tap(find.text('가져오기 이력'));
      await tester.pumpAndSettle();
      expect(find.text('stub-history'), findsOneWidget);
    });

    testWidgets('배지는 대기 0건이거나 오류면 숨긴다', (tester) async {
      final env = Env()..deletions = _FailingDeletions();
      await env.pump(tester, Routes.ai);
      expect(find.textContaining('대기'), findsNothing);
      expect(find.text('삭제 요청'), findsOneWidget);
    });
  });

  group('연결 안내', () {
    testWidgets('주소 복사', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      final env = Env();
      await env.pump(tester, Routes.aiConnect);
      expect(find.text('https://api.test/mcp'), findsOneWidget);
      expect(find.textContaining('삭제는 앱에서 승인'), findsOneWidget);
      await tester.tap(find.text('주소 복사'));
      await tester.pump();
      expect(copied, 'https://api.test/mcp');
    });

    testWidgets('clients가 비면 기본 안내, 있으면 서버 안내', (tester) async {
      final env = Env();
      await env.pump(tester, Routes.aiConnect);
      await tester.tap(find.text('내 AI 앱'));
      await tester.pumpAndSettle();
      expect(find.textContaining('1. AI 앱의 설정 → 커넥터'), findsOneWidget);
      expect(find.textContaining('4. fitlog 계정으로 로그인'), findsOneWidget);
    });

    testWidgets('서버가 준 안내 카드와 안내 주소 복사', (tester) async {
      final env = Env();
      env.ai.info = const McpInfo(
        mcpUrl: 'https://api.test/mcp',
        clients: [
          McpClientGuide(key: 'claude', name: 'Claude', steps: ['커넥터 열기', '주소 붙여넣기'], docUrl: 'https://docs.test/claude'),
        ],
      );
      await env.pump(tester, Routes.aiConnect);
      expect(find.text('내 AI 앱'), findsNothing);
      await tester.tap(find.text('Claude'));
      await tester.pumpAndSettle();
      expect(find.text('1. 커넥터 열기'), findsOneWidget);
      expect(find.text('2. 주소 붙여넣기'), findsOneWidget);
      expect(find.textContaining('https://docs.test/claude'), findsOneWidget);
    });

    testWidgets('오류면 재시도 버튼', (tester) async {
      final env = Env()..aiOverride = _FailingConns();
      await env.pump(tester, Routes.aiConnect);
      expect(find.textContaining('불러오지 못했어요'), findsOneWidget);
      expect(find.text('다시 시도'), findsOneWidget);
    });

    testWidgets('연결 목록·끊기(확인 후 갱신)', (tester) async {
      final env = Env()
        ..ai.list.addAll([_conn('c1', 'Claude', last: DateTime.utc(2026, 11, 20)), _conn('c2', 'ChatGPT', write: false)]);
      await env.pump(tester, Routes.aiConnect);
      await tester.scrollUntilVisible(find.text('ChatGPT'), 200, scrollable: find.byType(Scrollable).first);
      expect(find.textContaining('읽기·쓰기\n'), findsOneWidget);
      expect(find.textContaining('마지막 사용 '), findsOneWidget);
      expect(find.textContaining('아직 사용 안 함'), findsOneWidget);

      await tester.tap(find.text('연결 끊기').first);
      await tester.pumpAndSettle();
      expect(find.text('Claude 연결을 끊을까요?'), findsOneWidget);
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();
      expect(env.ai.list.length, 2);

      await tester.tap(find.text('연결 끊기').first);
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('연결 끊기')));
      await tester.pumpAndSettle();
      expect(env.ai.list.map((c) => c.id), ['c2']);
      expect(find.text('Claude'), findsNothing);
    });
  });

  group('내보내기', () {
    String ymd() {
      final n = DateTime.now();
      return '${n.year}${n.month.toString().padLeft(2, '0')}${n.day.toString().padLeft(2, '0')}';
    }

    testWidgets('세 가지가 올바른 이름·내용으로 저장된다', (tester) async {
      final env = Env();
      (env.export as MemoryExportRepository)
        ..json = '{"a":1}'
        ..setsCsv = 'S'
        ..bodyCsv = 'B';
      await env.pump(tester, Routes.export);
      expect(find.textContaining('JSON 가져오기로 복원'), findsOneWidget);
      for (final t in ['전체 백업(JSON)', '세트 기록 CSV(엑셀)', '체중 CSV']) {
        await tester.tap(find.text(t));
        await tester.pumpAndSettle();
      }
      final d = ymd();
      expect(env.saver.saved.map((s) => (s.fileName, s.content, s.mimeType)).toList(), [
        ('fitlog-$d.json', '{"a":1}', 'application/json'),
        ('fitlog-sets-$d.csv', 'S', 'text/csv'),
        ('fitlog-body-$d.csv', 'B', 'text/csv'),
      ]);
      expect(find.textContaining('파일을 만들었어요'), findsOneWidget);
    });

    testWidgets('오류를 보여주고 저장하지 않는다', (tester) async {
      final env = Env()..export = _FailingExport();
      await env.pump(tester, Routes.export);
      await tester.tap(find.text('전체 백업(JSON)'));
      await tester.pumpAndSettle();
      expect(find.textContaining('내보내지 못했어요'), findsOneWidget);
      expect(env.saver.saved, isEmpty);
    });
  });
}

