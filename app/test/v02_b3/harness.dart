import 'package:fitlog/core/api/dto.dart';
import 'package:fitlog/core/api/program_dto.dart';
import 'package:fitlog/core/auth/auth_controller.dart';
import 'package:fitlog/core/clock.dart';
import 'package:fitlog/core/ids.dart';
import 'package:fitlog/core/routes.dart';
import 'package:fitlog/core/settings/settings_controller.dart';
import 'package:fitlog/data/memory/memory_repositories.dart';
import 'package:fitlog/data/providers.dart';
import 'package:fitlog/domain/repositories.dart';
import 'package:fitlog/features/history/history_page.dart';
import 'package:fitlog/features/history/session_edit_page.dart';
import 'package:fitlog/features/records/exercise_records_page.dart';
import 'package:fitlog/l10n/gen/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../support/fixed_providers.dart';

Exercise ex(String id, String ko, ExerciseType t, Muscle m) =>
    Exercise(id: id, nameKo: ko, type: t, primaryMuscle: m, builtIn: true, updatedAt: DateTime.utc(2026));

final squat = ex('ex-squat', '스쿼트', ExerciseType.BARBELL, Muscle.QUADS);
final bench = ex('ex-bench', '벤치 프레스', ExerciseType.BARBELL, Muscle.CHEST);
final pullUp = ex('ex-pullup', '풀업', ExerciseType.BODYWEIGHT, Muscle.LATS);

class B3Harness {
  B3Harness({this.settings = const Settings()}) {
    exercises = MemoryExerciseRepository(seed: [squat, bench, pullUp]);
    sessions = MemorySessionRepository(now: () => clock);
  }

  DateTime clock = DateTime.utc(2026, 11, 26, 12);
  final Settings settings;
  late final MemoryExerciseRepository exercises;
  late final MemorySessionRepository sessions;
  final records = MemoryRecordsRepository();

  /// 기록 저장소를 다른 구현으로 바꿔 끼울 때.
  RecordsRepository? recordsOverride;

  /// 선택 화면 대역이 돌려줄 종목.
  String? pickResult;

  /// 날짜 선택 대역이 돌려줄 값(로컬 시각).
  DateTime? pickedDateTime;

  /// 끝난 세션 하나를 만든다. 시작 [start], 종료는 한 시간 뒤.
  Future<Session> finished(DateTime start, {PlannedWorkout? plan, List<(String, List<(double, int)>)> lifts = const []}) async {
    clock = start;
    final s = await sessions.startSession(tz: 'Asia/Seoul', plan: plan);
    for (final (exId, sets) in lifts) {
      final se = await sessions.addExercise(s.id, exId);
      for (final (w, r) in sets) {
        await sessions.addSet(se.id, WorkoutSet(id: newId(), position: 0, weightKg: w, reps: r, completedAt: start));
      }
    }
    clock = start.add(const Duration(hours: 1));
    await sessions.endSession(s.id);
    return (await sessions.watchSession(s.id).first)!;
  }

  List<Override> get overrides => [
    exerciseRepositoryProvider.overrideWithValue(exercises),
    sessionRepositoryProvider.overrideWithValue(sessions),
    scheduledWorkoutRepositoryProvider.overrideWithValue(MemoryScheduledWorkoutRepository()),
    recordsRepositoryProvider.overrideWithValue(recordsOverride ?? records),
    syncServiceProvider.overrideWithValue(NoopSyncService()),
    clockProvider.overrideWithValue(() => clock),
    settingsProvider.overrideWith(() => FixedSettings(settings)),
    authControllerProvider.overrideWith(() => FixedAuthStatus(AuthStatus.signedIn)),
  ];

  late GoRouter router;

  Future<void> pump(WidgetTester tester, String initial) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    router = GoRouter(
      initialLocation: initial,
      routes: [
        GoRoute(path: Routes.home, builder: (_, _) => const Scaffold(body: Text('home-page'))),
        GoRoute(path: Routes.history, builder: (_, _) => const HistoryPage()),
        GoRoute(path: '/sessions/:id', builder: (_, s) => Scaffold(body: Text('detail-${s.pathParameters['id']}'))),
        GoRoute(
          path: '/sessions/:id/edit',
          builder: (_, s) => SessionEditPage(
            sessionId: s.pathParameters['id']!,
            pickDateTime: (_, initial) async => pickedDateTime,
          ),
        ),
        GoRoute(
          path: Routes.pickExercise,
          builder: (c, _) => Scaffold(
            body: TextButton(onPressed: () => c.pop(pickResult), child: const Text('pick-stub')),
          ),
        ),
        GoRoute(path: '/exercises/:id/records', builder: (_, s) => ExerciseRecordsPage(exerciseId: s.pathParameters['id']!)),
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
  }
}

PlannedWorkout plan() => const PlannedWorkout(
  instanceId: 'inst-1',
  planSeq: 4,
  dayIndex: 0,
  dayKey: 'A',
  dayName: 'Day A',
  week: 1,
  cycle: 1,
  exercises: [
    PlannedExercise(
      key: 'squat',
      exerciseId: 'ex-squat',
      accessory: false,
      sets: [
        PlannedSet(plannedSetKey: 'A.0.0', targetReps: 5, targetWeightKg: 100, isAmrap: false, isWarmup: false),
        PlannedSet(plannedSetKey: 'A.0.1', targetReps: 5, targetWeightKg: 100, isAmrap: true, isWarmup: false),
      ],
    ),
  ],
);
