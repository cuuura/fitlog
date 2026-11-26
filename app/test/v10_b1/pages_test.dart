import 'package:fitlog/core/api/api_client.dart' show ApiException;
import 'package:fitlog/core/api/dto.dart';
import 'package:fitlog/core/api/program_dto.dart' show RecordPoint;
import 'package:fitlog/core/api/stats_dto.dart';
import 'package:fitlog/core/auth/auth_controller.dart';
import 'package:fitlog/core/clock.dart';
import 'package:fitlog/core/ids.dart';
import 'package:fitlog/core/settings/settings_controller.dart';
import 'package:fitlog/data/memory/memory_repositories.dart';
import 'package:fitlog/data/providers.dart';
import 'package:fitlog/features/progress/exercise_progress_page.dart';
import 'package:fitlog/features/progress/session_comparison_page.dart';
import 'package:fitlog/features/records/exercise_records_page.dart';
import 'package:fitlog/features/session/session_detail_page.dart';
import 'package:fitlog/features/session/session_summary_page.dart';
import 'package:fitlog/l10n/gen/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../support/fixed_providers.dart';

final squat = Exercise(
  id: 'ex-squat',
  nameKo: '스쿼트',
  type: ExerciseType.BARBELL,
  primaryMuscle: Muscle.QUADS,
  builtIn: true,
  updatedAt: DateTime.utc(2026),
);

RecordPoint rp(double w, {double? e1rm}) =>
    RecordPoint(weightKg: w, reps: 5, e1rmKg: e1rm, sessionId: 'x', setId: 'y', achievedAt: DateTime.utc(2026, 10, 1));

ProgressPoint pp(int day, double w, {double? e1rm, double vol = 100, bool wPr = false, bool ePr = false}) =>
    ProgressPoint(
      sessionId: 's$day',
      startedAt: DateTime.utc(2026, 11, day, 12),
      topWeightKg: w,
      topReps: 5,
      bestE1rmKg: e1rm,
      volumeKg: vol,
      workSetCount: 3,
      isWeightPr: wPr,
      isE1rmPr: ePr,
    );

Snap snap(double top, double e1rm, double vol, List<SnapSet> sets) => Snap(
  sessionId: 's',
  startedAt: DateTime.utc(2026, 11, 1),
  sets: sets,
  setCount: sets.length,
  topWeightKg: top,
  bestE1rmKg: e1rm,
  volumeKg: vol,
);

class Harness {
  Harness({this.settings = const Settings()}) {
    exercises = MemoryExerciseRepository(seed: [squat]);
    sessions = MemorySessionRepository(now: () => clock);
  }

  DateTime clock = DateTime.utc(2026, 11, 26, 12);
  final Settings settings;
  late final MemoryExerciseRepository exercises;
  late final MemorySessionRepository sessions;
  final stats = MemoryStatsRepository();
  final records = MemoryRecordsRepository();
  late GoRouter router;

  Future<Session> finished() async {
    final s = await sessions.startSession(tz: 'Asia/Seoul');
    final se = await sessions.addExercise(s.id, 'ex-squat');
    await sessions.addSet(se.id, WorkoutSet(id: newId(), position: 0, weightKg: 100, reps: 5, completedAt: clock));
    await sessions.endSession(s.id);
    return (await sessions.watchSession(s.id).first)!;
  }

  Future<void> pump(WidgetTester tester, String initial) async {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    router = GoRouter(
      initialLocation: initial,
      routes: [
        GoRoute(
          path: '/home',
          builder: (_, _) => const Scaffold(body: Text('home-page')),
        ),
        GoRoute(
          path: '/exercises/:id/records',
          builder: (_, s) => ExerciseRecordsPage(exerciseId: s.pathParameters['id']!),
        ),
        GoRoute(
          path: '/exercises/:id/progress',
          builder: (_, s) => ExerciseProgressPage(exerciseId: s.pathParameters['id']!),
        ),
        GoRoute(
          path: '/sessions/:id/comparison',
          builder: (_, s) => SessionComparisonPage(sessionId: s.pathParameters['id']!),
        ),
        GoRoute(
          path: '/sessions/:id/summary',
          builder: (_, s) => SessionSummaryPage(sessionId: s.pathParameters['id']!),
        ),
        GoRoute(
          path: '/sessions/:id',
          builder: (_, s) => SessionDetailPage(sessionId: s.pathParameters['id']!),
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          exerciseRepositoryProvider.overrideWithValue(exercises),
          sessionRepositoryProvider.overrideWithValue(sessions),
          recordsRepositoryProvider.overrideWithValue(records),
          statsRepositoryProvider.overrideWithValue(stats),
          syncServiceProvider.overrideWithValue(NoopSyncService()),
          clockProvider.overrideWithValue(() => clock),
          settingsProvider.overrideWith(() => FixedSettings(settings)),
          authControllerProvider.overrideWith(() => FixedAuthStatus(AuthStatus.signedIn)),
        ],
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

void main() {
  const progressRoute = '/exercises/ex-squat/progress';

  ExerciseProgress sample() => ExerciseProgress(
    exerciseId: 'ex-squat',
    formula: 'EPLEY',
    points: [pp(1, 100, e1rm: 117), pp(10, 105, e1rm: 123, wPr: true, ePr: true), pp(20, 102, e1rm: 120)],
    bestWeight: rp(105),
    bestE1rm: rp(105, e1rm: 123),
  );

  testWidgets('추이: 차트·범례·선택 점 요약, 지표 토글', (tester) async {
    final h = Harness();
    h.stats.progressByExercise['ex-squat'] = sample();
    await h.pump(tester, progressRoute);

    expect(find.text('스쿼트'), findsOneWidget);
    expect(find.byKey(const Key('progress-chart')), findsOneWidget);
    expect(find.text('일반'), findsOneWidget);
    expect(find.text('PR'), findsOneWidget);
    expect(find.text('전체 최고'), findsOneWidget);
    // 마지막 점이 기본 선택
    expect(find.text('2026-11-20 · 102 kg × 5회'), findsOneWidget);

    await tester.tap(find.text('볼륨'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('PR'), findsNothing); // 볼륨은 PR 구분 없음
    expect(find.text('전체 최고'), findsNothing);
    expect(find.text('2026-11-20 · 100 kg'), findsOneWidget);

    await tester.tap(find.text('추정 1RM'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('PR'), findsOneWidget);
    expect(find.text('2026-11-20 · 120 kg'), findsOneWidget);
  });

  testWidgets('추이: lb 설정이면 lb로 표시', (tester) async {
    final h = Harness(settings: const Settings(weightUnit: WeightUnit.LB));
    h.stats.progressByExercise['ex-squat'] = sample();
    await h.pump(tester, progressRoute);
    expect(find.text('2026-11-20 · 224.9 lb × 5회'), findsOneWidget);
  });

  testWidgets('추이: 기간 칩은 기간 밖 점을 거른다', (tester) async {
    final h = Harness();
    h.stats.progressByExercise['ex-squat'] = ExerciseProgress(
      exerciseId: 'ex-squat',
      formula: 'EPLEY',
      points: [
        ProgressPoint(
          sessionId: 'old',
          startedAt: DateTime.utc(2025, 1, 5),
          topWeightKg: 80,
          topReps: 5,
          volumeKg: 1,
          workSetCount: 1,
        ),
      ],
    );
    await h.pump(tester, progressRoute);
    expect(find.byKey(const Key('progress-empty')), findsOneWidget);
    await tester.tap(find.text('전체'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const Key('progress-chart')), findsOneWidget);
  });

  testWidgets('추이: 빈 상태', (tester) async {
    final h = Harness();
    await h.pump(tester, progressRoute);
    expect(find.byKey(const Key('progress-empty')), findsOneWidget);
  });

  testWidgets('추이: 오프라인 → 안내와 다시 시도', (tester) async {
    final h = Harness();
    h.stats.failure = const ApiException(code: 'NETWORK', message: 'x');
    await h.pump(tester, progressRoute);
    expect(find.text('연결 후 볼 수 있어요'), findsOneWidget);
    h.stats.failure = null;
    h.stats.progressByExercise['ex-squat'] = sample();
    await tester.tap(find.byKey(const Key('progress-retry')));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const Key('progress-chart')), findsOneWidget);
  });

  testWidgets('추이: 기타 오류', (tester) async {
    final h = Harness();
    h.stats.failure = const ApiException(statusCode: 500, code: 'INTERNAL', message: 'x');
    await h.pump(tester, progressRoute);
    expect(find.byKey(const Key('progress-error')), findsOneWidget);
    expect(find.text('연결 후 볼 수 있어요'), findsNothing);
  });

  testWidgets('추이: 선택한 점에서 세션 상세로 이동', (tester) async {
    final h = Harness();
    h.stats.progressByExercise['ex-squat'] = sample();
    await h.pump(tester, progressRoute);
    await tester.tap(find.byKey(const Key('progress-open-session')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(h.router.state.uri.path, '/sessions/s20');
  });

  group('비교', () {
    ExerciseComparison cmp({bool first = false, double bestW = 100}) => ExerciseComparison(
      exerciseId: 'ex-squat',
      current: snap(105, 123, 1000, const [SnapSet(105, 5), SnapSet(100, 5)]),
      previous: first ? null : snap(100, 117, 900, const [SnapSet(100, 5)]),
      bestWeight: first ? null : rp(bestW),
      bestE1rm: first ? null : rp(100, e1rm: 120),
    );

    testWidgets('이전 기록 있음: PR 배지·세트별 표·범례', (tester) async {
      final h = Harness();
      h.stats.comparisonBySession['s1'] = SessionComparison(sessionId: 's1', formula: 'EPLEY', exercises: [cmp()]);
      await h.pump(tester, '/sessions/s1/comparison');

      expect(find.text('스쿼트'), findsOneWidget);
      expect(find.byKey(const Key('pr-weight-ex-squat')), findsOneWidget);
      expect(find.byKey(const Key('pr-e1rm-ex-squat')), findsOneWidget);
      expect(find.byKey(const Key('first-ex-squat')), findsNothing);
      expect(find.text('지난 같은 세션'), findsWidgets);
      expect(find.text('이전 PR'), findsOneWidget);
      expect(find.text('세트 1'), findsOneWidget);
      expect(find.text('100×5'), findsWidgets);
      expect(find.text('105×5'), findsOneWidget);
      expect(find.text('세트 2'), findsOneWidget);
      expect(find.text('-'), findsOneWidget); // 지난 세션엔 2세트가 없음
    });

    testWidgets('볼륨 지표에서는 이전 PR 막대가 없다', (tester) async {
      final h = Harness();
      h.stats.comparisonBySession['s1'] = SessionComparison(sessionId: 's1', formula: 'EPLEY', exercises: [cmp()]);
      await h.pump(tester, '/sessions/s1/comparison');
      await tester.tap(find.text('볼륨'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('이전 PR'), findsNothing);
    });

    testWidgets('이전 기록 없음: 첫 기록, PR 배지 없음', (tester) async {
      final h = Harness();
      h.stats.comparisonBySession['s1'] = SessionComparison(
        sessionId: 's1',
        formula: 'EPLEY',
        exercises: [cmp(first: true)],
      );
      await h.pump(tester, '/sessions/s1/comparison');
      expect(find.byKey(const Key('first-ex-squat')), findsOneWidget);
      expect(find.text('첫 기록'), findsOneWidget);
      expect(find.byKey(const Key('pr-weight-ex-squat')), findsNothing);
    });

    testWidgets('오늘이 PR이 아니면 배지 없음', (tester) async {
      final h = Harness();
      h.stats.comparisonBySession['s1'] = SessionComparison(
        sessionId: 's1',
        formula: 'EPLEY',
        exercises: [cmp(bestW: 110)],
      );
      await h.pump(tester, '/sessions/s1/comparison');
      expect(find.byKey(const Key('pr-weight-ex-squat')), findsNothing);
    });

    testWidgets('오프라인·빈 상태', (tester) async {
      final h = Harness();
      h.stats.failure = const ApiException(code: 'NETWORK', message: 'x');
      await h.pump(tester, '/sessions/s1/comparison');
      expect(find.text('연결 후 볼 수 있어요'), findsOneWidget);
      h.stats.failure = null;
      await tester.tap(find.byKey(const Key('compare-retry')));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const Key('compare-empty')), findsOneWidget);
    });
  });

  group('진입 버튼', () {
    testWidgets('기록 화면 → 추이 그래프', (tester) async {
      final h = Harness();
      await h.pump(tester, '/exercises/ex-squat/records');
      await tester.tap(find.byKey(const Key('records-progress')));
      await tester.pump(const Duration(milliseconds: 200));
      expect(h.router.state.uri.path, progressRoute);
    });

    testWidgets('세션 상세 → 비교', (tester) async {
      final h = Harness();
      final s = await h.finished();
      await h.pump(tester, '/sessions/${s.id}');
      await tester.tap(find.byKey(const Key('detail-compare')));
      await tester.pump(const Duration(milliseconds: 200));
      expect(h.router.state.uri.path, '/sessions/${s.id}/comparison');
    });

    testWidgets('세션 요약 → 비교', (tester) async {
      final h = Harness();
      final s = await h.finished();
      await h.pump(tester, '/sessions/${s.id}/summary');
      await tester.tap(find.byKey(const Key('summary-compare')));
      await tester.pump(const Duration(milliseconds: 200));
      expect(h.router.state.uri.path, '/sessions/${s.id}/comparison');
    });
  });
}
