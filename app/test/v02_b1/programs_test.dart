import 'package:fitlog/core/api/api_client.dart';
import 'package:fitlog/core/api/dto.dart';
import 'package:fitlog/core/api/program_dto.dart';
import 'package:fitlog/core/auth/auth_controller.dart';
import 'package:fitlog/core/clock.dart';
import 'package:fitlog/core/routes.dart';
import 'package:fitlog/core/settings/settings_controller.dart';
import 'package:fitlog/data/memory/memory_repositories.dart';
import 'package:fitlog/data/providers.dart';
import 'package:fitlog/features/programs/instance_detail_page.dart';
import 'package:fitlog/features/programs/program_detail_page.dart';
import 'package:fitlog/features/programs/program_start_page.dart';
import 'package:fitlog/features/programs/programs_page.dart';
import 'package:fitlog/features/session/session_controller.dart' show deviceTimezoneProvider;
import 'package:fitlog/l10n/gen/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../support/fixed_providers.dart';

Exercise _ex(String id, String ko) => Exercise(
  id: id,
  nameKo: ko,
  type: ExerciseType.BARBELL,
  primaryMuscle: Muscle.QUADS,
  builtIn: true,
  updatedAt: DateTime.utc(2026),
);

Map<String, Object?> _def({bool weekdays = true}) => {
  'schemaVersion': 1,
  'name': '테스트 5x5',
  'lifts': {
    'squat': {'exercise': {'id': 'ex-squat'}},
    'bench': {'exercise': {'id': 'ex-bench'}},
  },
  'days': [
    {
      'key': 'A',
      'name': 'Workout A',
      if (weekdays) 'weekday': 'MON',
      'exercises': [
        {'lift': 'squat', 'sets': [{'count': 5, 'reps': 5, 'load': {'type': 'WORKING'}}]},
        {
          'lift': 'bench',
          'sets': [
            {'reps': 8, 'load': {'type': 'PERCENT_TM', 'value': 0.65}},
            {'reps': 6, 'load': {'type': 'PERCENT_TM', 'value': 0.75}},
            {'count': 3, 'reps': 4, 'load': {'type': 'PERCENT_TM', 'value': 0.85}},
            {'reps': 8, 'amrap': true, 'load': {'type': 'PERCENT_TM', 'value': 0.85}},
          ],
        },
      ],
    },
    {
      'key': 'B',
      'name': 'Workout B',
      if (weekdays) 'weekday': 'THU',
      'exercises': [
        {'lift': 'squat', 'sets': [{'count': 3, 'reps': 5, 'load': {'type': 'WORKING'}}]},
      ],
    },
  ],
};

Program _prog(String id, String name, {bool builtIn = true, bool weekdays = true}) => Program(
  id: id,
  name: name,
  description: '$name 설명',
  builtIn: builtIn,
  dayCount: 2,
  definition: _def(weekdays: weekdays)..['name'] = name,
);

PlannedWorkout _pw(String inst, int seq, String day) => PlannedWorkout(
  instanceId: inst,
  planSeq: seq,
  dayIndex: seq - 1,
  dayKey: day,
  dayName: 'Workout $day',
  week: 1,
  cycle: 1,
  exercises: [
    PlannedExercise(
      key: 'squat',
      exerciseId: 'ex-squat',
      accessory: false,
      sets: [
        for (var i = 0; i < 5; i++)
          const PlannedSet(plannedSetKey: 'k', targetReps: 5, targetWeightKg: 100, isAmrap: false, isWarmup: false),
      ],
    ),
  ],
);

Instance _inst(String id, {InstanceStatus status = InstanceStatus.ACTIVE, int seq = 0}) => Instance(
  id: id,
  programId: 'p-tpl',
  name: '내 5x5',
  status: status,
  skipPolicy: SkipPolicy.SHIFT,
  startDate: DateTime(2026, 11, 26),
  state: InstanceState(tm: const {'squat': 100}, working: const {'squat': 90}, week: 2, cycle: 1, seq: seq),
);

class _FailingRepo extends MemoryProgramRepository {
  Object? listError;
  Object? startError;
  @override
  Future<List<ProgramSummary>> listPrograms({ProgramListSource? source}) async {
    if (listError != null) throw listError!;
    return super.listPrograms(source: source);
  }

  @override
  Future<Instance> startInstance(StartInstance start) async {
    if (startError != null) throw startError!;
    return super.startInstance(start);
  }
}

class _Env {
  _Env({this.settings = const Settings()}) {
    programs
      ..programs['p-tpl'] = _prog('p-tpl', '템플릿 5x5')
      ..programs['p-mine'] = _prog('p-mine', '내 루틴', builtIn: false)
      ..programs['p-opt'] = _prog('p-opt', '더블')
      ..programs['p-noday'] = _prog('p-noday', '요일 없음', weekdays: false)
      ..suggestions['p-tpl'] = const [
        SuggestItem(
          key: 'squat',
          exerciseId: 'ex-squat',
          needs: SuggestNeeds.TM,
          oneRmKg: 120,
          oneRmSource: OneRmSource.MEASURED,
          suggestedKg: 100,
        ),
        SuggestItem(key: 'bench', exerciseId: 'ex-bench', needs: SuggestNeeds.WORKING),
      ]
      ..suggestions['p-opt'] = const [
        SuggestItem(key: 'squat', exerciseId: 'ex-squat', needs: SuggestNeeds.WORKING, optional: true),
        SuggestItem(key: 'bench', exerciseId: 'ex-bench', needs: SuggestNeeds.TM, suggestedKg: 80),
      ]
      ..suggestions['p-noday'] = const [];
    cache = MemoryPlanCache(programs);
  }

  final Settings settings;
  final programs = _FailingRepo();
  late final MemoryPlanCache cache;
  final exercises = MemoryExerciseRepository(seed: [_ex('ex-squat', '스쿼트'), _ex('ex-bench', '벤치프레스')]);

  List<Override> get overrides => [
    authControllerProvider.overrideWith(() => FixedAuthStatus(AuthStatus.signedIn)),
    settingsProvider.overrideWith(() => FixedSettings(settings)),
    programRepositoryProvider.overrideWithValue(programs),
    planCacheProvider.overrideWithValue(cache),
    exerciseRepositoryProvider.overrideWithValue(exercises),
    sessionRepositoryProvider.overrideWithValue(MemorySessionRepository()),
    scheduledWorkoutRepositoryProvider.overrideWithValue(MemoryScheduledWorkoutRepository()),
    syncServiceProvider.overrideWithValue(NoopSyncService()),
    clockProvider.overrideWithValue(() => DateTime.utc(2026, 11, 26, 3)),
    deviceTimezoneProvider.overrideWithValue(() async => 'Asia/Seoul'),
  ];

  Future<void> pump(WidgetTester tester, String initial) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final router = GoRouter(
      initialLocation: initial,
      routes: [
        GoRoute(path: Routes.home, builder: (_, _) => const Scaffold(body: Text('home-page'))),
        GoRoute(path: Routes.programs, builder: (_, _) => const ProgramsPage()),
        GoRoute(path: '/programs/:id', builder: (_, s) => ProgramDetailPage(programId: s.pathParameters['id']!)),
        GoRoute(path: '/programs/:id/start', builder: (_, s) => ProgramStartPage(programId: s.pathParameters['id']!)),
        GoRoute(path: '/instances/:id', builder: (_, s) => InstanceDetailPage(instanceId: s.pathParameters['id']!)),
        GoRoute(
          path: Routes.pickExercise,
          builder: (c, _) => Scaffold(
            body: TextButton(onPressed: () => c.pop('ex-bench'), child: const Text('pick-bench')),
          ),
        ),
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

void main() {
  group('목록', () {
    testWidgets('두 탭: 진행 중 인스턴스와 템플릿·내 프로그램', (tester) async {
      final env = _Env();
      env.programs.instances['i1'] = Instance(
        id: 'i1',
        programId: 'p-tpl',
        name: '내 5x5',
        status: InstanceStatus.PAUSED,
        skipPolicy: SkipPolicy.SHIFT,
        startDate: DateTime(2026, 11, 1),
        state: const InstanceState(week: 2, cycle: 1, seq: 3),
        next: _pw('i1', 4, 'B'),
      );
      env.programs.instances['i2'] = _inst('i2', status: InstanceStatus.FINISHED);
      await env.pump(tester, Routes.programs);
      expect(find.text('내 5x5'), findsOneWidget);
      expect(find.textContaining('일시정지'), findsOneWidget);
      expect(find.textContaining('2주차'), findsOneWidget);
      expect(find.textContaining('다음: Workout B'), findsOneWidget);

      expect(find.text('진행 중 1'), findsOneWidget);
      await tester.tap(find.text('템플릿'));
      await tester.pumpAndSettle();
      expect(find.text('내 프로그램'), findsOneWidget);
      expect(find.text('템플릿 5x5'), findsOneWidget);
      expect(find.text('내 루틴'), findsNothing);
      expect(find.byIcon(Icons.delete_outline), findsNothing);
      expect(find.byKey(const Key('programs-import-ai')), findsOneWidget);
      await tester.tap(find.text('내 프로그램'));
      await tester.pumpAndSettle();
      expect(find.text('내 루틴'), findsOneWidget);
      // 내 프로그램에만 삭제 버튼이 있다
      expect(find.byIcon(Icons.delete_outline), findsOneWidget);
      await tester.tap(find.text('템플릿'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('템플릿 5x5'));
      await tester.pumpAndSettle();
      expect(find.text('월'), findsOneWidget);
    });

    testWidgets('오프라인이면 안내와 다시 시도', (tester) async {
      final env = _Env();
      env.programs.listError = const ApiException(code: 'NETWORK', message: 'x');
      await env.pump(tester, Routes.programs);
      await tester.tap(find.text('템플릿'));
      await tester.pumpAndSettle();
      expect(find.textContaining('서버에 연결할 수 없어요'), findsOneWidget);
      env.programs.listError = null;
      await tester.tap(find.text('다시 시도'));
      await tester.pumpAndSettle();
      expect(find.text('템플릿 5x5'), findsOneWidget);
    });

    testWidgets('내 프로그램 삭제는 확인 후', (tester) async {
      final env = _Env();
      await env.pump(tester, Routes.programs);
      await tester.tap(find.text('내 프로그램'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();
      expect(find.text('프로그램을 삭제할까요?'), findsOneWidget);
      await tester.tap(find.text('삭제').last);
      await tester.pumpAndSettle();
      expect(env.programs.programs.containsKey('p-mine'), isFalse);
      expect(find.text('내 루틴'), findsNothing);
    });
  });

  testWidgets('상세: 날과 종목·세트 요약, 시작 버튼', (tester) async {
    final env = _Env();
    await env.pump(tester, Routes.programDetail('p-tpl'));
    expect(find.text('템플릿 5x5 설명'), findsOneWidget);
    expect(find.text('월'), findsOneWidget);
    expect(find.textContaining('스쿼트  5×5'), findsOneWidget);
    expect(find.textContaining('벤치프레스  8,6,4,4,4,8+'), findsOneWidget);
    expect(find.textContaining('스쿼트  3×5'), findsOneWidget);
    await tester.tap(find.byKey(const Key('program-start')));
    await tester.pumpAndSettle();
    expect(find.text('프로그램 시작'), findsOneWidget);
  });

  group('시작 화면', () {
    testWidgets('제안 미리 채움, 빈 필수칸이면 시작 불가', (tester) async {
      final env = _Env();
      await env.pump(tester, Routes.programStart('p-tpl'));
      expect(find.widgetWithText(TextField, '100'), findsOneWidget);
      expect(find.textContaining('최근 측정 1RM 120 kg'), findsOneWidget);
      expect(find.textContaining('직접 입력'), findsOneWidget);
      FilledButton btn() => tester.widget<FilledButton>(find.widgetWithText(FilledButton, '이 프로그램 시작'));
      expect(btn().onPressed, isNull);
      await tester.enterText(find.byKey(const ValueKey('start-WORKING:bench')), '60');
      await tester.pump();
      expect(btn().onPressed, isNotNull);
    });

    testWidgets('optional 칸은 비워도 시작되고 요청에서 빠진다', (tester) async {
      final env = _Env();
      await env.pump(tester, Routes.programStart('p-opt'));
      expect(find.text('비워두면 첫 운동 기록으로 정합니다'), findsOneWidget);
      FilledButton btn() => tester.widget<FilledButton>(find.widgetWithText(FilledButton, '이 프로그램 시작'));
      expect(btn().onPressed, isNotNull);
      await tester.tap(find.text('이 프로그램 시작'));
      await tester.pumpAndSettle();
      final i = env.programs.instances.values.single;
      expect(i.state.tm, {'bench': 80});
      expect(i.state.working, isEmpty);
    });

    testWidgets('kg로 저장하고 인스턴스 화면으로 이동', (tester) async {
      final env = _Env();
      await env.pump(tester, Routes.programStart('p-tpl'));
      await tester.enterText(find.byKey(const ValueKey('start-WORKING:bench')), '60');
      await tester.pump();
      await tester.tap(find.text('이 프로그램 시작'));
      await tester.pumpAndSettle();
      final i = env.programs.instances.values.single;
      expect(i.state.tm, {'squat': 100});
      expect(i.state.working, {'bench': 60});
      expect(i.startDate, DateTime(2026, 11, 26));
      expect(i.skipPolicy, SkipPolicy.SHIFT);
      expect(find.text('일시정지'), findsOneWidget); // 인스턴스 상세
    });

    testWidgets('lb 입력은 kg로 변환해 저장', (tester) async {
      final env = _Env(settings: const Settings(weightUnit: WeightUnit.LB));
      await env.pump(tester, Routes.programStart('p-tpl'));
      // 제안 100kg = 220.5 lb로 표시
      expect(find.widgetWithText(TextField, '220.5'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('start-TM:squat')), '225');
      await tester.enterText(find.byKey(const ValueKey('start-WORKING:bench')), '135');
      await tester.pump();
      await tester.tap(find.text('이 프로그램 시작'));
      await tester.pumpAndSettle();
      final i = env.programs.instances.values.single;
      expect(i.state.tm['squat'], closeTo(102.06, 0.001));
      expect(i.state.working['bench'], closeTo(61.23, 0.001));
    });

    testWidgets('요일이 없는 프로그램은 FIXED_DATE 비활성, 있으면 선택 가능', (tester) async {
      bool fixedEnabled() => tester
          .widget<SegmentedButton<SkipPolicy>>(find.byKey(const Key('start-skip-policy')))
          .segments
          .firstWhere((s) => s.value == SkipPolicy.FIXED_DATE)
          .enabled;
      final env = _Env();
      await env.pump(tester, Routes.programStart('p-noday'));
      expect(fixedEnabled(), isFalse);
      expect(find.textContaining('요일이 정해져 있지 않아'), findsOneWidget);

      final env2 = _Env();
      await env2.pump(tester, Routes.programStart('p-tpl'));
      expect(fixedEnabled(), isTrue);
      await tester.enterText(find.byKey(const ValueKey('start-WORKING:bench')), '60');
      await tester.tap(find.text('날짜 고정'));
      await tester.pump();
      await tester.tap(find.text('이 프로그램 시작'));
      await tester.pumpAndSettle();
      expect(env2.programs.instances.values.single.skipPolicy, SkipPolicy.FIXED_DATE);
    });

    testWidgets('400 VALIDATION_FAILED details를 칸 옆에 보여준다', (tester) async {
      final env = _Env();
      env.programs.startError = const ApiException(
        statusCode: 400,
        code: 'VALIDATION_FAILED',
        message: 'bad',
        details: [(path: '/working/bench', message: '너무 가벼워요')],
      );
      await env.pump(tester, Routes.programStart('p-tpl'));
      await tester.enterText(find.byKey(const ValueKey('start-WORKING:bench')), '1');
      await tester.pump();
      await tester.tap(find.text('이 프로그램 시작'));
      await tester.pumpAndSettle();
      expect(find.text('너무 가벼워요'), findsOneWidget);
      expect(env.programs.instances, isEmpty);
    });
  });

  group('인스턴스 상세', () {
    _Env withInstance() {
      final env = _Env();
      env.programs.instances['i1'] = _inst('i1');
      env.programs.plans['i1'] = [_pw('i1', 1, 'A'), _pw('i1', 2, 'B'), _pw('i1', 3, 'A')];
      return env;
    }

    testWidgets('상태·무게·다음 회차 미리보기', (tester) async {
      final env = withInstance();
      await env.pump(tester, Routes.instanceDetail('i1'));
      expect(find.text('2주차 · 1사이클'), findsOneWidget);
      expect(find.textContaining('TM 100 kg · 작업 90 kg'), findsOneWidget);
      expect(find.textContaining('Workout A'), findsWidgets);
      expect(find.textContaining('100 kg 5×5'), findsWidgets);
    });

    testWidgets('일시정지 후 재개', (tester) async {
      final env = withInstance();
      await env.pump(tester, Routes.instanceDetail('i1'));
      await tester.tap(find.text('일시정지'));
      await tester.pumpAndSettle();
      expect(env.programs.instances['i1']!.status, InstanceStatus.PAUSED);
      expect(find.text('재개'), findsOneWidget);
      await tester.tap(find.text('재개'));
      await tester.pumpAndSettle();
      expect(env.programs.instances['i1']!.status, InstanceStatus.ACTIVE);
    });

    testWidgets('다음 회차 건너뛰기는 확인 후 planSeq=seq+1로', (tester) async {
      final env = withInstance();
      await env.pump(tester, Routes.instanceDetail('i1'));
      await tester.ensureVisible(find.text('다음 회차 건너뛰기'));
      await tester.tap(find.text('다음 회차 건너뛰기'));
      await tester.pumpAndSettle();
      expect(find.text('다음 회차를 건너뛸까요?'), findsOneWidget);
      await tester.tap(find.text('다음 회차 건너뛰기').last);
      await tester.pumpAndSettle();
      expect(env.programs.plans['i1']!.first.planSeq, 2);
    });

    testWidgets('종료는 확인을 거친다', (tester) async {
      final env = withInstance();
      await env.pump(tester, Routes.instanceDetail('i1'));
      await tester.tap(find.widgetWithText(OutlinedButton, '종료'));
      await tester.pumpAndSettle();
      expect(find.text('프로그램을 종료할까요?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '종료'));
      await tester.pumpAndSettle();
      expect(env.programs.instances['i1']!.status, InstanceStatus.FINISHED);
    });

    testWidgets('보조운동 추가는 종목 선택 후 저장(kg)', (tester) async {
      final env = _Env(settings: const Settings(weightUnit: WeightUnit.LB));
      env.programs.instances['i1'] = _inst('i1');
      await env.pump(tester, Routes.instanceDetail('i1'));
      final add = find.byKey(const ValueKey('add-accessory-A'));
      await tester.ensureVisible(add);
      await tester.tap(add);
      await tester.pumpAndSettle();
      await tester.tap(find.text('pick-bench'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('acc-sets')), '4');
      await tester.enterText(find.byKey(const ValueKey('acc-reps')), '12');
      await tester.enterText(find.byKey(const ValueKey('acc-weight')), '45');
      await tester.pump();
      await tester.tap(find.text('저장'));
      await tester.pumpAndSettle();
      final saved = env.programs.accessoryLists['i1']!.single;
      expect(saved.dayKey, 'A');
      expect(saved.exerciseId, 'ex-bench');
      expect((saved.sets, saved.reps), (4, 12));
      expect(saved.weightKg, closeTo(20.41, 0.001));
      expect(find.text('벤치프레스'), findsOneWidget);
      expect(find.textContaining('4×12 · 45 lb'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(env.programs.accessoryLists['i1'], isEmpty);
    });

    testWidgets('삭제는 확인 후 연결을 끊고 돌아간다', (tester) async {
      final env = withInstance();
      await env.pump(tester, Routes.programs);
      await tester.tap(find.text('내 5x5'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('프로그램 연결 삭제'));
      await tester.tap(find.text('프로그램 연결 삭제'));
      await tester.pumpAndSettle();
      expect(find.text('기록은 남고 연결만 끊깁니다.'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '삭제'));
      await tester.pumpAndSettle();
      expect(env.programs.instances, isEmpty);
      expect(find.text('내 5x5'), findsNothing);
    });
  });
}
