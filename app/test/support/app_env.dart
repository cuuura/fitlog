// B3: 실제 라우터(routerProvider) + 메모리 저장소로 앱 전체를 띄우는 테스트 환경. E2E·접근성 테스트가 같이 쓴다.
import 'package:fitlog/core/api/dto.dart';
import 'package:fitlog/core/api/program_dto.dart';
import 'package:fitlog/core/auth/auth_controller.dart';
import 'package:fitlog/core/clock.dart';
import 'package:fitlog/core/ids.dart';
import 'package:fitlog/core/router.dart';
import 'package:fitlog/core/settings/settings_controller.dart';
import 'package:fitlog/core/theme.dart';
import 'package:fitlog/data/memory/memory_repositories.dart';
import 'package:fitlog/data/providers.dart';
import 'package:fitlog/features/session/session_controller.dart' show deviceTimezoneProvider;
import 'package:fitlog/l10n/gen/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixed_providers.dart';

Exercise exercise(String id, String ko, ExerciseType t, Muscle m, {String? en}) =>
    Exercise(id: id, nameKo: ko, nameEn: en, type: t, primaryMuscle: m, builtIn: true, updatedAt: DateTime.utc(2026));

final squat = exercise('ex-squat', '스쿼트', ExerciseType.BARBELL, Muscle.QUADS, en: 'Squat');
final bench = exercise('ex-bench', '벤치 프레스', ExerciseType.BARBELL, Muscle.CHEST, en: 'Bench Press');
final pullUp = exercise('ex-pullup', '풀업', ExerciseType.BODYWEIGHT, Muscle.LATS, en: 'Pull-up');
final dbPress = exercise('ex-dbpress', '덤벨 프레스', ExerciseType.DUMBBELL, Muscle.CHEST, en: 'Dumbbell Press');

class AppEnv {
  AppEnv({this.settings = const Settings(), List<Exercise>? seed, DateTime? start})
    : now = start ?? DateTime.utc(2026, 11, 26, 9) {
    exercises = MemoryExerciseRepository(seed: seed ?? [squat, bench, pullUp, dbPress]);
    sessions = MemorySessionRepository(now: () => now);
    programs = MemoryProgramRepository();
    planCache = MemoryPlanCache(programs);
    imports = MemoryImportRepository(now: () => now);
  }

  DateTime now;
  final Settings settings;
  late final MemoryExerciseRepository exercises;
  late final MemorySessionRepository sessions;
  late final MemoryProgramRepository programs;
  late final MemoryPlanCache planCache;
  late final MemoryImportRepository imports;
  final body = MemoryBodyRepository();
  final records = MemoryRecordsRepository();
  final stats = MemoryStatsRepository();
  final deletions = MemoryDeletionRequestRepository();
  late ProviderContainer container;
  late GoRouter router;

  List<Override> get overrides => [
    exerciseRepositoryProvider.overrideWithValue(exercises),
    sessionRepositoryProvider.overrideWithValue(sessions),
    bodyRepositoryProvider.overrideWithValue(body),
    programRepositoryProvider.overrideWithValue(programs),
    recordsRepositoryProvider.overrideWithValue(records),
    statsRepositoryProvider.overrideWithValue(stats),
    planCacheProvider.overrideWithValue(planCache),
    importRepositoryProvider.overrideWithValue(imports),
    deletionRequestRepositoryProvider.overrideWithValue(deletions),
    aiConnectionRepositoryProvider.overrideWithValue(MemoryAiConnectionRepository()),
    exportRepositoryProvider.overrideWithValue(MemoryExportRepository()),
    syncServiceProvider.overrideWithValue(NoopSyncService()),
    clockProvider.overrideWithValue(() => now),
    deviceTimezoneProvider.overrideWithValue(() async => 'Asia/Seoul'),
    settingsProvider.overrideWith(() => FixedSettings(settings)),
    authControllerProvider.overrideWith(() => FixedAuthStatus(AuthStatus.signedIn)),
  ];

  /// [size]는 논리 픽셀(devicePixelRatio 1). [initial]이 홈이 아니면 router.go로 옮긴다.
  Future<void> pump(
    WidgetTester tester, {
    String initial = '/',
    Size size = const Size(800, 1400),
    ThemeMode themeMode = ThemeMode.light,
    double textScale = 1.0,
    Locale locale = const Locale('ko'),
    List<Override> extraOverrides = const [],
  }) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [...overrides, ...extraOverrides],
        child: Consumer(
          builder: (context, ref, _) {
            container = ProviderScope.containerOf(context);
            router = ref.watch(routerProvider);
            return MaterialApp.router(
              routerConfig: router,
              theme: AppTheme.light(),
              darkTheme: AppTheme.dark(),
              themeMode: themeMode,
              locale: locale,
              localizationsDelegates: [AppLocalizations.delegate, ...GlobalMaterialLocalizations.delegates],
              supportedLocales: AppLocalizations.supportedLocales,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
                child: child!,
              ),
            );
          },
        ),
      ),
    );
    await settle(tester);
    if (initial != '/') {
      router.go(initial);
      await settle(tester);
    }
  }
}

Future<void> settle(WidgetTester t, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

/// 끝난 세션을 만든다. [lifts]: (종목 id, [(무게, 횟수)]).
Future<Session> finishedSession(
  AppEnv env,
  DateTime start, {
  List<(String, List<(double, int)>)> lifts = const [],
  PlannedWorkout? plan,
}) async {
  env.now = start;
  final s = await env.sessions.startSession(tz: 'Asia/Seoul', plan: plan);
  for (final (exId, sets) in lifts) {
    final se = await env.sessions.addExercise(s.id, exId);
    for (final (w, r) in sets) {
      await env.sessions.addSet(se.id, WorkoutSet(id: newId(), position: 0, weightKg: w, reps: r, completedAt: start));
    }
  }
  env.now = start.add(const Duration(hours: 1));
  await env.sessions.endSession(s.id);
  return (await env.sessions.watchSession(s.id).first)!;
}
