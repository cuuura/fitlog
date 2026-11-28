import 'package:fitlog/core/api/api_client.dart';
import 'package:fitlog/core/api/dto.dart';
import 'package:fitlog/core/api/program_dto.dart';
import 'package:fitlog/core/auth/auth_controller.dart';
import 'package:fitlog/core/clock.dart';
import 'package:fitlog/core/routes.dart';
import 'package:fitlog/core/settings/settings_controller.dart';
import 'package:fitlog/core/ui/row_menu.dart';
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
  Object? putError;
  Object? patchError;
  Object? deleteError;
  @override
  Future<List<ProgramSummary>> listPrograms({ProgramListSource? source}) async {
    if (listError != null) throw listError!;
    return super.listPrograms(source: source);
  }

  @override
  Future<List<Accessory>> putAccessories(String instanceId, List<Accessory> list) async {
    if (putError != null) throw putError!;
    return super.putAccessories(instanceId, list);
  }

  @override
  Future<Instance> patchInstance(String id, InstancePatch patch) async {
    if (patchError != null) throw patchError!;
    return super.patchInstance(id, patch);
  }

  @override
  Future<void> deleteProgram(String id) async {
    if (deleteError != null) throw deleteError!;
    return super.deleteProgram(id);
  }

  @override
  Future<Instance> startInstance(StartInstance start) async {
    if (startError != null) throw startError!;
    return super.startInstance(start);
  }
}

Future<void> _mineSeg(WidgetTester tester) async {
  await tester.tap(find.descendant(of: find.byKey(const Key('programs-segments')), matching: find.textContaining('내 프로그램')));
  await tester.pumpAndSettle();
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

  Future<void> pump(WidgetTester tester, String initial, {List<RouteBase> extraRoutes = const []}) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final router = GoRouter(
      initialLocation: initial,
      routes: [
        ...extraRoutes,
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
    testWidgets('두 구분: 진행 중 인스턴스와 내 프로그램, 템플릿 구분은 없다', (tester) async {
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
      expect(find.text('템플릿'), findsNothing);
      expect(find.byKey(const Key('programs-import-ai')), findsNothing, reason: 'AI 가져오기는 시트 안으로');
      expect(find.byKey(const Key('programs-add')), findsOneWidget);
      await _mineSeg(tester);
      expect(find.text('내 루틴'), findsOneWidget);
      expect(find.text('템플릿 5x5'), findsNothing);
      // 내 프로그램에만 ⋮ 메뉴가 있고 늘 보이는 휴지통은 없다
      expect(find.byType(RowMenu<String>), findsOneWidget);
      expect(find.byIcon(Icons.delete_outline), findsNothing);

      // 자세히 → 상세 화면
      await tester.tap(find.byKey(const Key('program-detail-p-mine')));
      await tester.pumpAndSettle();
      expect(find.text('내 루틴 설명'), findsOneWidget);
      expect(find.text('월'), findsOneWidget);
    });

    testWidgets('진행 중이 비면 첫 프로그램 고르기 버튼이 시트를 연다', (tester) async {
      final env = _Env();
      await env.pump(tester, Routes.programs);
      expect(find.byKey(const Key('programs-first-pick')), findsOneWidget);
      await tester.tap(find.byKey(const Key('programs-first-pick')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('program-p-tpl')), findsOneWidget);
    });

    testWidgets('FAB로 시트를 열어 카드를 펼치고 이걸로 정하면 맞추기 화면', (tester) async {
      final env = _Env();
      env.programs.instances['i1'] = _inst('i1');
      await env.pump(tester, Routes.programs);
      await tester.tap(find.byKey(const Key('programs-add')));
      await tester.pumpAndSettle();
      // 템플릿 구분이 기본, 내 프로그램은 다른 구분
      expect(find.byKey(const Key('program-p-tpl')), findsOneWidget);
      expect(find.byKey(const Key('program-p-mine')), findsNothing);
      // 이미 진행 중인 프로그램에만 칩
      expect(find.byKey(const Key('program-running-p-tpl')), findsOneWidget);
      expect(find.byKey(const Key('program-running-p-opt')), findsNothing);
      // 펼치기 전에는 구조가 없다
      expect(find.byKey(const Key('program-pick-p-tpl')), findsNothing);
      await tester.tap(find.text('템플릿 5x5'));
      await tester.pumpAndSettle();
      expect(find.text('월'), findsOneWidget);
      expect(find.textContaining('스쿼트  5×5'), findsOneWidget);
      expect(find.text('이걸로 정하고 무게 맞추기'), findsOneWidget);
      // 한 번에 하나만 펼친다
      await tester.tap(find.text('더블'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('program-pick-p-tpl')), findsNothing);
      expect(find.byKey(const Key('program-pick-p-opt')), findsOneWidget);
      await tester.tap(find.text('템플릿 5x5'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('program-pick-p-tpl')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('program-add-segments')), findsNothing, reason: '시트는 닫힌다');
      expect(find.text('프로그램 시작'), findsOneWidget);
    });

    testWidgets('시트 맨 아래 다른 방법: AI로 가져오기와 하루만 예약', (tester) async {
      final env = _Env();
      await env.pump(tester, Routes.programs, extraRoutes: [
        GoRoute(path: Routes.importJson, builder: (_, _) => const Scaffold(body: Text('import-page'))),
        GoRoute(path: Routes.scheduledNew, builder: (_, _) => const Scaffold(body: Text('scheduled-new-page'))),
      ]);
      await tester.tap(find.byKey(const Key('programs-add')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.byKey(const Key('programs-import-ai')), 200, scrollable: find.descendant(of: find.byKey(const Key('program-add-list')), matching: find.byType(Scrollable)));
      expect(find.text('다른 방법으로 추가'), findsOneWidget);
      expect(find.byKey(const Key('programs-scheduled-new')), findsOneWidget);
      await tester.tap(find.byKey(const Key('programs-import-ai')));
      await tester.pumpAndSettle();
      expect(find.text('import-page'), findsOneWidget);
    });

    testWidgets('오프라인이면 시트에 안내와 다시 시도', (tester) async {
      final env = _Env();
      env.programs.listError = const ApiException(code: 'NETWORK', message: 'x');
      await env.pump(tester, Routes.programs);
      await tester.tap(find.byKey(const Key('programs-add')));
      await tester.pumpAndSettle();
      expect(find.textContaining('서버에 연결할 수 없어요'), findsOneWidget);
      env.programs.listError = null;
      await tester.tap(find.text('다시 시도'));
      await tester.pumpAndSettle();
      expect(find.text('템플릿 5x5'), findsOneWidget);
    });

    testWidgets('오프라인이면 내 프로그램에도 안내와 다시 시도', (tester) async {
      final env = _Env();
      env.programs.listError = const ApiException(code: 'NETWORK', message: 'x');
      await env.pump(tester, Routes.programs);
      await tester.tap(find.byKey(const Key('programs-add')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('program-add-close')));
      await tester.pumpAndSettle();
      await _mineSeg(tester);
      expect(find.textContaining('서버에 연결할 수 없어요'), findsOneWidget);
      env.programs.listError = null;
      await tester.tap(find.text('다시 시도'));
      await tester.pumpAndSettle();
      expect(find.text('내 루틴'), findsOneWidget);
    });

    testWidgets('삭제 실패 스낵바는 FAB를 가리지 않는다(이 탭 전용 메신저)', (tester) async {
      final env = _Env();
      env.programs.deleteError = const ApiException(code: 'X', message: '삭제 실패요');
      await env.pump(tester, Routes.programs);
      await _mineSeg(tester);
      await tester.tap(find.byType(RowMenu<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('program-delete-p-mine')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-ok')));
      await tester.pumpAndSettle();
      expect(find.text('삭제 실패요'), findsOneWidget);
      final fab = tester.getRect(find.byKey(const Key('programs-add')));
      final snack = tester.getRect(find.byType(SnackBar));
      expect(fab.overlaps(snack), isFalse);
    });

    testWidgets('내 프로그램 삭제는 확인 후', (tester) async {
      final env = _Env();
      await env.pump(tester, Routes.programs);
      await _mineSeg(tester);
      await tester.tap(find.byType(RowMenu<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('program-delete-p-mine')));
      await tester.pumpAndSettle();
      expect(find.text("'내 루틴' 프로그램을 삭제할까요?"), findsOneWidget);
      expect(env.programs.programs.containsKey('p-mine'), isTrue, reason: '확인 전에는 지우지 않는다');
      // 파괴적 확인은 OutlinedButton
      expect(find.descendant(of: find.byType(AlertDialog), matching: find.byType(OutlinedButton)), findsOneWidget);
      await tester.tap(find.byKey(const Key('confirm-ok')));
      await tester.pumpAndSettle();
      expect(env.programs.programs.containsKey('p-mine'), isFalse);
      expect(find.text('내 루틴'), findsNothing);
    });

    testWidgets('내 프로그램 삭제 확인에서 취소하면 그대로', (tester) async {
      final env = _Env();
      await env.pump(tester, Routes.programs);
      await _mineSeg(tester);
      await tester.tap(find.byType(RowMenu<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('program-delete-p-mine')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();
      expect(env.programs.programs.containsKey('p-mine'), isTrue);
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

    testWidgets('상태 버튼 줄과 맨 아래 삭제 버튼 없이 ⋮ 메뉴로 모았다', (tester) async {
      final env = withInstance();
      await env.pump(tester, Routes.instanceDetail('i1'));
      expect(find.widgetWithText(OutlinedButton, '일시정지'), findsNothing);
      expect(find.widgetWithText(OutlinedButton, '종료'), findsNothing);
      expect(find.text('프로그램 연결 삭제'), findsNothing);
      await tester.tap(find.byKey(const Key('instance-menu')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('instance-pause')), findsOneWidget);
      expect(find.byKey(const Key('instance-resume')), findsNothing);
      expect(find.byKey(const Key('instance-finish')), findsOneWidget);
      expect(find.byKey(const Key('instance-delete')), findsOneWidget);
    });

    testWidgets('일시정지 후 재개', (tester) async {
      final env = withInstance();
      await env.pump(tester, Routes.instanceDetail('i1'));
      await tester.tap(find.byKey(const Key('instance-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('instance-pause')));
      await tester.pumpAndSettle();
      expect(env.programs.instances['i1']!.status, InstanceStatus.PAUSED);
      // 일시정지 상태의 주 행동: 본문 "재개" 버튼
      expect(find.byKey(const Key('instance-resume-button')), findsOneWidget);
      await tester.tap(find.byKey(const Key('instance-resume-button')));
      await tester.pumpAndSettle();
      expect(env.programs.instances['i1']!.status, InstanceStatus.ACTIVE);
      // 메뉴에서도 재개할 수 있다
      await tester.tap(find.byKey(const Key('instance-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('instance-pause')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('instance-menu')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('instance-resume')), findsOneWidget);
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
      await tester.tap(find.byKey(const Key('instance-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('instance-finish')));
      await tester.pumpAndSettle();
      expect(find.text('프로그램을 종료할까요?'), findsOneWidget);
      // 끝내기는 파괴적이 아니므로 채움 버튼
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
      await tester.tap(find.byKey(const Key('sheet-submit')));
      await tester.pumpAndSettle();
      final saved = env.programs.accessoryLists['i1']!.single;
      expect(saved.dayKey, 'A');
      expect(saved.exerciseId, 'ex-bench');
      expect((saved.sets, saved.reps), (4, 12));
      expect(saved.weightKg, closeTo(20.41, 0.001));
      expect(find.text('벤치프레스'), findsOneWidget);
      expect(find.textContaining('4×12 · 45 lb'), findsOneWidget);

      // 지울 때는 확인 없이 지우고 되돌리기를 보여 준다
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(env.programs.accessoryLists['i1'], isEmpty);
      expect(find.byType(AlertDialog), findsNothing);
      await tester.tap(find.text('되돌리기'));
      await tester.pumpAndSettle();
      final back = env.programs.accessoryLists['i1']!.single;
      expect((back.exerciseId, back.sets, back.reps, back.position), ('ex-bench', 4, 12, 0));
      expect(find.text('벤치프레스'), findsOneWidget);
    });

    testWidgets('보조운동 저장이 실패하면 시트와 입력이 남고 오류가 보인다', (tester) async {
      final env = _Env();
      env.programs.instances['i1'] = _inst('i1');
      env.programs.putError = const ApiException(code: 'NETWORK', message: 'x');
      await env.pump(tester, Routes.instanceDetail('i1'));
      final add = find.byKey(const ValueKey('add-accessory-A'));
      await tester.ensureVisible(add);
      await tester.tap(add);
      await tester.pumpAndSettle();
      await tester.tap(find.text('pick-bench'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('acc-sets')), '5');
      await tester.tap(find.byKey(const Key('sheet-submit')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sheet-error')), findsOneWidget);
      expect(find.widgetWithText(TextField, '5'), findsOneWidget);
      env.programs.putError = null;
      await tester.tap(find.byKey(const Key('sheet-submit')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sheet-error')), findsNothing);
      expect(env.programs.accessoryLists['i1']!.single.sets, 5);
    });

    testWidgets('기준 무게 조정은 시트에서 저장하고, 실패하면 입력이 남는다', (tester) async {
      final env = withInstance();
      env.programs.patchError = const ApiException(code: 'NETWORK', message: 'x');
      await env.pump(tester, Routes.instanceDetail('i1'));
      final adjust = find.text('TM·작업 무게 조정');
      await tester.ensureVisible(adjust);
      await tester.tap(adjust);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      await tester.enterText(find.byKey(const ValueKey('adjust-tm-squat')), '105');
      await tester.tap(find.byKey(const Key('sheet-submit')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sheet-error')), findsOneWidget);
      expect(find.widgetWithText(TextField, '105'), findsOneWidget);
      env.programs.patchError = null;
      await tester.tap(find.byKey(const Key('sheet-submit')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sheet-submit')), findsNothing);
      expect(env.programs.instances['i1']!.state.tm['squat'], 105);
    });

    testWidgets('삭제는 확인 후 연결을 끊고 돌아간다', (tester) async {
      final env = withInstance();
      await env.pump(tester, Routes.programs);
      await tester.tap(find.text('내 5x5'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('instance-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('instance-delete')));
      await tester.pumpAndSettle();
      expect(find.text("'내 5x5' 진행을 삭제할까요?"), findsOneWidget);
      expect(find.text('기록은 그대로 남고, 프로그램 연결만 끊어요.'), findsOneWidget);
      expect(env.programs.instances, isNotEmpty, reason: '확인 전에는 지우지 않는다');
      await tester.tap(find.widgetWithText(OutlinedButton, '삭제'));
      await tester.pumpAndSettle();
      expect(env.programs.instances, isEmpty);
      expect(find.text('내 5x5'), findsNothing);
    });
  });
}
