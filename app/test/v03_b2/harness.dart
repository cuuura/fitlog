import 'package:fitlog/core/api/ai_dto.dart';
import 'package:fitlog/core/api/api_client.dart';
import 'package:fitlog/core/api/dto.dart';
import 'package:fitlog/core/auth/auth_controller.dart';
import 'package:fitlog/core/clock.dart';
import 'package:fitlog/core/routes.dart';
import 'package:fitlog/core/settings/settings_controller.dart';
import 'package:fitlog/data/memory/memory_repositories.dart';
import 'package:fitlog/data/providers.dart';
import 'package:fitlog/features/ai_history/ai_history_detail_page.dart';
import 'package:fitlog/features/ai_history/ai_history_page.dart';
import 'package:fitlog/features/deletion_requests/deletion_requests_page.dart';
import 'package:fitlog/features/history/history_page.dart';
import 'package:fitlog/features/home/home_page.dart';
import 'package:fitlog/features/profile/body_weight_page.dart';
import 'package:fitlog/features/programs/program_detail_page.dart';
import 'package:fitlog/features/programs/programs_page.dart';
import 'package:fitlog/features/session/session_controller.dart' show deviceTimezoneProvider;
import 'package:fitlog/features/session/session_detail_page.dart';
import 'package:fitlog/l10n/gen/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../support/fixed_providers.dart';

/// 승인·거절이 ApiException(409/410 등)을 던지게 하는 가짜.
class FailingDeletionRepository extends MemoryDeletionRequestRepository {
  FailingDeletionRepository({super.now});
  ApiException? failWith;
  bool countFails = false;

  @override
  Future<int> pendingCount() async => countFails ? throw const ApiException(code: 'NETWORK', message: 'x') : super.pendingCount();

  @override
  Future<DeletionRequest> approve(String id) async {
    final e = failWith;
    if (e != null) throw e;
    return super.approve(id);
  }

  @override
  Future<DeletionRequest> reject(String id) async {
    final e = failWith;
    if (e != null) throw e;
    return super.reject(id);
  }
}

/// 세션 id별로 출처를 덧씌워 돌려주는 세션 저장소.
class SourcedSessionRepository extends MemorySessionRepository {
  SourcedSessionRepository({super.now});
  final Map<String, (SessionSource, String?)> sources = {};

  Session _wrap(Session s) {
    final src = sources[s.id];
    if (src == null) return s;
    return Session(
      id: s.id,
      startedAt: s.startedAt,
      endedAt: s.endedAt,
      tz: s.tz,
      note: s.note,
      source: src.$1,
      importBatchId: src.$2,
      exercises: s.exercises,
      updatedAt: s.updatedAt,
    );
  }

  @override
  Stream<Session?> watchSession(String id) => super.watchSession(id).map((s) => s == null ? null : _wrap(s));
}

class V03Harness {
  V03Harness({DateTime? start}) : now = start ?? DateTime.utc(2026, 11, 26, 9) {
    sessions = SourcedSessionRepository(now: () => now);
    programs = MemoryProgramRepository();
    planCache = MemoryPlanCache(programs);
    imports = MemoryImportRepository(now: () => now);
    deletions = FailingDeletionRepository(now: () => now);
  }

  DateTime now;
  final exercises = MemoryExerciseRepository(seed: const []);
  late final SourcedSessionRepository sessions;
  final body = MemoryBodyRepository();
  late final MemoryProgramRepository programs;
  late final MemoryPlanCache planCache;
  late final MemoryImportRepository imports;
  late final FailingDeletionRepository deletions;
  late GoRouter router;

  List<Override> get overrides => [
    exerciseRepositoryProvider.overrideWithValue(exercises),
    sessionRepositoryProvider.overrideWithValue(sessions),
    scheduledWorkoutRepositoryProvider.overrideWithValue(MemoryScheduledWorkoutRepository()),
    bodyRepositoryProvider.overrideWithValue(body),
    programRepositoryProvider.overrideWithValue(programs),
    planCacheProvider.overrideWithValue(planCache),
    syncServiceProvider.overrideWithValue(NoopSyncService()),
    importRepositoryProvider.overrideWithValue(imports),
    deletionRequestRepositoryProvider.overrideWithValue(deletions),
    clockProvider.overrideWithValue(() => now),
    deviceTimezoneProvider.overrideWithValue(() async => 'Asia/Seoul'),
    settingsProvider.overrideWith(() => FixedSettings()),
    authControllerProvider.overrideWith(() => FixedAuthStatus(AuthStatus.signedIn)),
  ];

  Future<void> pump(WidgetTester tester, String initial) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    router = GoRouter(
      initialLocation: initial,
      routes: [
        GoRoute(path: Routes.home, builder: (_, _) => const HomePage()),
        GoRoute(path: Routes.history, builder: (_, _) => const HistoryPage()),
        GoRoute(path: '/sessions/:id', builder: (_, s) => SessionDetailPage(sessionId: s.pathParameters['id']!)),
        GoRoute(path: Routes.programs, builder: (_, _) => const ProgramsPage()),
        GoRoute(path: '/programs/:id', builder: (_, s) => ProgramDetailPage(programId: s.pathParameters['id']!)),
        GoRoute(path: Routes.body, builder: (_, _) => const BodyWeightPage()),
        GoRoute(path: Routes.aiHistory, builder: (_, _) => const AiHistoryPage()),
        GoRoute(path: '/ai/history/:id', builder: (_, s) => AiHistoryDetailPage(batchId: s.pathParameters['id']!)),
        GoRoute(path: Routes.deletionRequests, builder: (_, _) => const DeletionRequestsPage()),
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
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

ImportBatch batch(String id, DateTime at, {Map<String, int> summary = const {}, DateTime? revertedAt, String? note, ImportChannel channel = ImportChannel.APP_JSON, String? client = 'Claude'}) =>
    ImportBatch(id: id, createdAt: at, channel: channel, clientName: client, note: note, summary: summary, revertedAt: revertedAt);

DeletionRequest delReq(String id, DateTime now, {DeletionStatus status = DeletionStatus.PENDING, String entity = 'workout_session', String? label, Duration expiresIn = const Duration(hours: 5, minutes: 30)}) =>
    DeletionRequest(
      id: id,
      entity: entity,
      entityId: 'e-$id',
      label: label ?? '2026-11-20 세션',
      reason: '중복된 기록',
      clientName: 'Claude',
      status: status,
      createdAt: now.subtract(const Duration(hours: 1)),
      expiresAt: now.add(expiresIn),
    );
