import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:fitlog/core/api/dto.dart';
import 'package:fitlog/core/auth/auth_controller.dart';
import 'package:fitlog/core/clock.dart';
import 'package:fitlog/core/routes.dart';
import 'package:fitlog/core/settings/settings_controller.dart';
import 'package:fitlog/data/memory/memory_repositories.dart';
import 'package:fitlog/data/providers.dart';
import 'package:fitlog/domain/repositories.dart';
import 'package:fitlog/features/exercise_picker/exercise_picker_page.dart';
import 'package:fitlog/features/home/home_page.dart';
import 'package:fitlog/features/session/active_session_page.dart';
import 'package:fitlog/features/session/session_controller.dart';
import 'package:fitlog/features/session/session_detail_page.dart';
import 'package:fitlog/features/session/session_summary_page.dart';
import 'package:fitlog/l10n/gen/app_localizations.dart';
import 'package:go_router/go_router.dart';

import '../support/fixed_providers.dart';

import 'package:material_ui/material_ui.dart';

Exercise ex(
  String id,
  String ko,
  ExerciseType t,
  Muscle m, {
  String? en,
  bool builtIn = true,
}) => Exercise(
  id: id,
  nameKo: ko,
  nameEn: en,
  type: t,
  primaryMuscle: m,
  builtIn: builtIn,
  updatedAt: DateTime.utc(2026),
);

final squat = ex(
  'ex-squat',
  '스쿼트',
  ExerciseType.BARBELL,
  Muscle.QUADS,
  en: 'Squat',
);
final dbPress = ex(
  'ex-dbpress',
  '덤벨 프레스',
  ExerciseType.DUMBBELL,
  Muscle.CHEST,
  en: 'Dumbbell Press',
);
final pullUp = ex(
  'ex-pullup',
  '풀업',
  ExerciseType.BODYWEIGHT,
  Muscle.LATS,
  en: 'Pull-up',
);
final legPress = ex(
  'ex-legpress',
  '레그 프레스',
  ExerciseType.MACHINE,
  Muscle.QUADS,
);

class Harness {
  Harness({
    this.settings = const Settings(),
    List<Exercise>? seed,
    DateTime? start,
  }) : now = start ?? DateTime.utc(2026, 11, 26, 9, 0, 0) {
    exercises = MemoryExerciseRepository(
      seed: seed ?? [squat, dbPress, pullUp, legPress],
    );
    sessions = MemorySessionRepository(now: () => now);
    programs = MemoryProgramRepository();
    planCache = MemoryPlanCache(programs);
  }

  DateTime now;
  final Settings settings;
  late final MemoryExerciseRepository exercises;
  late final MemorySessionRepository sessions;
  late final MemoryProgramRepository programs;
  late final PlanCache planCache;
  late final ProviderContainer container;

  List<Override> get overrides => [
    exerciseRepositoryProvider.overrideWithValue(exercises),
    sessionRepositoryProvider.overrideWithValue(sessions),
    programRepositoryProvider.overrideWithValue(programs),
    planCacheProvider.overrideWithValue(planCache),
    syncServiceProvider.overrideWithValue(NoopSyncService()),
    clockProvider.overrideWithValue(() => now),
    deviceTimezoneProvider.overrideWithValue(() async => 'Asia/Seoul'),
    settingsProvider.overrideWith(() => FixedSettings(settings)),
    authControllerProvider.overrideWith(
      () => FixedAuthStatus(AuthStatus.signedIn),
    ),
  ];

  Future<void> pump(WidgetTester tester, {String initial = Routes.home}) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final router = GoRouter(
      initialLocation: initial,
      routes: [
        GoRoute(path: Routes.home, builder: (_, _) => const HomePage()),
        GoRoute(
          path: Routes.session,
          builder: (_, _) => const ActiveSessionPage(),
        ),
        GoRoute(
          path: Routes.pickExercise,
          builder: (_, _) => const ExercisePickerPage(),
        ),
        GoRoute(
          path: '/sessions/:id/summary',
          builder: (_, s) =>
              SessionSummaryPage(sessionId: s.pathParameters['id']!),
        ),
        GoRoute(
          path: '/sessions/:id',
          builder: (_, s) =>
              SessionDetailPage(sessionId: s.pathParameters['id']!),
        ),
        GoRoute(
          path: Routes.settings,
          builder: (_, _) => const Scaffold(body: Text('settings-page')),
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides,
        child: Builder(
          builder: (context) {
            container = ProviderScope.containerOf(context);
            return MaterialApp.router(
              routerConfig: router,
              localizationsDelegates: [
                AppLocalizations.delegate,
                ...GlobalMaterialLocalizations.delegates,
              ],
              supportedLocales: AppLocalizations.supportedLocales,
              locale: const Locale('ko'),
            );
          },
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
}
