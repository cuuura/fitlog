// P2: 맞추기 화면(첫 운동·겹침·시작 무게·일정) 동작과 레이아웃.
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
import 'package:fitlog/features/programs/program_start_page.dart';
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

Map<String, Object?> _def({bool weekdays = true, num? rounding, List<String> days = const ['MON', 'THU']}) => {
  'schemaVersion': 1,
  'name': '테스트 5x5',
  'lifts': {
    'squat': {'exercise': {'id': 'ex-squat'}},
    'bench': {'exercise': {'id': 'ex-bench'}},
  },
  'roundingKg': ?rounding,
  'days': [
    for (var i = 0; i < days.length; i++)
      {
        'key': 'D$i',
        'name': 'Workout ${String.fromCharCode(65 + i)}',
        if (weekdays) 'weekday': days[i],
        'exercises': [
          {'lift': 'squat', 'sets': [{'count': 5, 'reps': 5, 'load': {'type': 'WORKING'}}]},
          if (i == 0) {'lift': 'bench', 'sets': [{'count': 3, 'reps': 5, 'load': {'type': 'WORKING'}}]},
        ],
      },
  ],
};

Program _prog(String id, String name, {bool weekdays = true, num? rounding, List<String>? days}) => Program(
  id: id,
  name: name,
  description: '$name 설명',
  builtIn: true,
  dayCount: (days ?? const ['MON', 'THU']).length,
  definition: _def(weekdays: weekdays, rounding: rounding, days: days ?? const ['MON', 'THU'])..['name'] = name,
);

Instance _inst(String id, String programId, {InstanceStatus status = InstanceStatus.ACTIVE}) => Instance(
  id: id,
  programId: programId,
  name: '진행 $id',
  status: status,
  skipPolicy: SkipPolicy.SHIFT,
  startDate: DateTime(2026, 11, 1),
  state: const InstanceState(week: 1, cycle: 1, seq: 1),
);

class _Repo extends MemoryProgramRepository {
  Object? startError;
  Object? patchError;
  Object? getError;
  @override
  Future<Program> getProgram(String id) async {
    if (getError != null) throw getError!;
    return super.getProgram(id);
  }

  @override
  Future<Instance> patchInstance(String id, InstancePatch patch) async {
    if (patchError != null) throw patchError!;
    return super.patchInstance(id, patch);
  }

  @override
  Future<Instance> startInstance(StartInstance start) async {
    if (startError != null) throw startError!;
    return super.startInstance(start);
  }
}

class _Env {
  _Env({this.settings = const Settings(), num? rounding}) {
    programs
      ..programs['p-tpl'] = _prog('p-tpl', '템플릿 5x5', rounding: rounding)
      ..programs['p-other'] = _prog('p-other', '다른 프로그램', days: ['THU', 'SAT'])
      ..programs['p-free'] = _prog('p-free', '다른 요일', days: ['TUE', 'FRI'])
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
  final programs = _Repo();
  late final MemoryPlanCache cache;
  final exercises = MemoryExerciseRepository(seed: [_ex('ex-squat', '스쿼트'), _ex('ex-bench', '벤치프레스')]);

  Future<void> pump(
    WidgetTester tester,
    String initial, {
    Size size = const Size(800, 1600),
    double textScale = 1.0,
    ThemeMode mode = ThemeMode.light,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final router = GoRouter(
      initialLocation: initial,
      routes: [
        GoRoute(path: Routes.home, builder: (_, _) => const Scaffold(body: Text('home-page'))),
        GoRoute(path: '/programs/:id/start', builder: (_, s) => ProgramStartPage(programId: s.pathParameters['id']!)),
        GoRoute(path: '/instances/:id', builder: (_, s) => InstanceDetailPage(instanceId: s.pathParameters['id']!)),
      ],
    );
    final List<Override> overrides = [
      authControllerProvider.overrideWith(() => FixedAuthStatus(AuthStatus.signedIn)),
      settingsProvider.overrideWith(() => FixedSettings(settings)),
      programRepositoryProvider.overrideWithValue(programs),
      planCacheProvider.overrideWithValue(cache),
      exerciseRepositoryProvider.overrideWithValue(exercises),
      sessionRepositoryProvider.overrideWithValue(MemorySessionRepository()),
      scheduledWorkoutRepositoryProvider.overrideWithValue(MemoryScheduledWorkoutRepository()),
      syncServiceProvider.overrideWithValue(NoopSyncService()),
      clockProvider.overrideWithValue(() => DateTime.utc(2026, 11, 26, 3)), // 2026-11-26 목요일
      deviceTimezoneProvider.overrideWithValue(() async => 'Asia/Seoul'),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides,
        child: MaterialApp.router(
          routerConfig: router,
          theme: ThemeData(useMaterial3: true, brightness: Brightness.light),
          darkTheme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
          themeMode: mode,
          builder: (c, child) => MediaQuery(
            data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          localizationsDelegates: [AppLocalizations.delegate, ...GlobalMaterialLocalizations.delegates],
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('ko'),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }
}

Finder _field(String id) => find.byKey(ValueKey('start-$id'));
String _text(WidgetTester t, String id) => t.widget<TextField>(_field(id)).controller!.text;

Future<void> _submit(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(const Key('start-submit')));
  await tester.tap(find.byKey(const Key('start-submit')));
  await tester.pumpAndSettle();
}

Future<void> _openSchedule(WidgetTester tester) async {
  await tester.tap(find.text('일정'));
  await tester.pumpAndSettle();
}

void main() {
  group('첫 운동', () {
    testWidgets('날짜와 그날 종목만 보이고, 건너뛰기 방식에 따라 날짜가 바뀐다', (tester) async {
      final env = _Env();
      await env.pump(tester, Routes.programStart('p-tpl'));
      expect(find.text('첫 운동 · 11월 26일(목)'), findsOneWidget);
      expect(find.text('Workout A · 스쿼트 · 벤치프레스'), findsOneWidget);
      // 세트·무게 미리보기는 없다
      expect(find.textContaining('5×5'), findsNothing);
      await _openSchedule(tester);
      await tester.tap(find.text('날짜 고정'));
      await tester.pumpAndSettle();
      // 첫째 날이 월요일이라 다음 월요일(30일)부터
      expect(find.text('첫 운동 · 11월 30일(월)'), findsOneWidget);
    });
  });

  group('시작 무게', () {
    testWidgets('제안 미리 채움, 출처 칩·근거, 빈 필수칸이 있어도 버튼은 눌리고 그 칸을 보여 준다', (tester) async {
      final env = _Env();
      await env.pump(tester, Routes.programStart('p-tpl'));
      expect(_text(tester, 'TM:squat'), '100');
      expect(find.byKey(const Key('start-source-TM:squat')), findsOneWidget);
      expect(find.textContaining('최근 측정 1RM 120 kg'), findsOneWidget);
      expect(find.text('1개 입력 필요'), findsOneWidget);
      final btn = tester.widget<FilledButton>(find.byKey(const Key('start-submit')));
      expect(btn.onPressed, isNotNull);
      await _submit(tester);
      expect(env.programs.instances, isEmpty);
      expect(find.text('무게를 입력해 주세요'), findsOneWidget);
      expect(find.text('벤치프레스 무게를 넣어 주세요'), findsWidgets); // 카드 요약과 아래 막대
      // 빠진 칸으로 초점이 간다
      final focus = tester.widget<TextField>(_field('WORKING:bench')).focusNode!;
      expect(focus.hasFocus, isTrue);
      // 입력하면 요약·칩만 바뀐다
      await tester.enterText(_field('WORKING:bench'), '60');
      await tester.pump();
      expect(find.text('2개 준비됨'), findsOneWidget);
    });

    testWidgets('접힌 카드에 빠진 칸이 있으면 펼친다', (tester) async {
      final env = _Env();
      await env.pump(tester, Routes.programStart('p-tpl'));
      await tester.tap(find.text('시작 무게').first);
      await tester.pumpAndSettle();
      expect(_field('WORKING:bench'), findsNothing);
      await _submit(tester);
      expect(_field('WORKING:bench'), findsOneWidget);
      expect(find.text('무게를 입력해 주세요'), findsOneWidget);
    });

    testWidgets('±는 프로그램 roundingKg 단위(없으면 2.5), 제안대로·10% 가볍게', (tester) async {
      final env = _Env(rounding: 5);
      await env.pump(tester, Routes.programStart('p-tpl'));
      await tester.tap(find.byKey(const Key('start-up-TM:squat')));
      await tester.pump();
      expect(_text(tester, 'TM:squat'), '105');
      await tester.tap(find.text('제안대로'));
      await tester.pump();
      expect(_text(tester, 'TM:squat'), '100');
      await tester.tap(find.text('10% 가볍게'));
      await tester.pump();
      expect(_text(tester, 'TM:squat'), '90');
      await tester.tap(find.byKey(const Key('start-down-TM:squat')));
      await tester.pump();
      expect(_text(tester, 'TM:squat'), '85');

      final env2 = _Env();
      await env2.pump(tester, Routes.programStart('p-tpl'));
      await tester.tap(find.byKey(const Key('start-up-TM:squat')));
      await tester.pump();
      expect(_text(tester, 'TM:squat'), '102.5');
    });

    testWidgets('제안과 40% 넘게 다르면 확인 문구', (tester) async {
      final env = _Env();
      await env.pump(tester, Routes.programStart('p-tpl'));
      await tester.enterText(_field('TM:squat'), '140');
      await tester.pump();
      expect(find.byKey(const Key('start-far-TM:squat')), findsNothing);
      await tester.enterText(_field('TM:squat'), '141');
      await tester.pump();
      expect(find.text('제안(100 kg)과 많이 달라요. 맞는지 확인해 주세요'), findsOneWidget);
      await tester.enterText(_field('TM:squat'), '55');
      await tester.pump();
      expect(find.byKey(const Key('start-far-TM:squat')), findsOneWidget);
      await tester.enterText(_field('TM:squat'), '60');
      await tester.pump();
      expect(find.byKey(const Key('start-far-TM:squat')), findsNothing);
    });

    testWidgets('제안이 없으면 든 무게×횟수로 계산(Epley, 12회 이하)하고 빈 봉으로 채울 수 있다', (tester) async {
      final env = _Env();
      await env.pump(tester, Routes.programStart('p-tpl'));
      await tester.tap(find.byKey(const Key('start-calc-WORKING:bench')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('start-calc-w-WORKING:bench')), '60');
      await tester.enterText(find.byKey(const Key('start-calc-r-WORKING:bench')), '13');
      await tester.tap(find.byKey(const Key('start-calc-ok-WORKING:bench')));
      await tester.pumpAndSettle();
      expect(find.text('무게와 횟수(12회 이하)를 넣어 주세요'), findsOneWidget);
      expect(_text(tester, 'WORKING:bench'), '');
      await tester.enterText(find.byKey(const Key('start-calc-r-WORKING:bench')), '5');
      await tester.tap(find.byKey(const Key('start-calc-ok-WORKING:bench')));
      await tester.pumpAndSettle();
      // 60×(1+5/30)=70 → 작업 무게는 70%인 49 → 2.5 단위 50
      expect(_text(tester, 'WORKING:bench'), '50');

      await tester.enterText(_field('WORKING:bench'), '');
      await tester.pump();
      await tester.tap(find.byKey(const Key('start-fill-bar')));
      await tester.pump();
      expect(_text(tester, 'WORKING:bench'), '20');
    });

    testWidgets('optional 칸은 접힌 묶음에 있고 비워도 시작되며 요청에서 빠진다', (tester) async {
      final env = _Env();
      await env.pump(tester, Routes.programStart('p-opt'));
      // 주 종목(필수: bench)이 위, optional(squat)은 접힘
      expect(_field('TM:bench'), findsOneWidget);
      expect(_field('WORKING:squat'), findsNothing);
      await tester.tap(find.byKey(const Key('start-optional-toggle')));
      await tester.pumpAndSettle();
      expect(find.text('비워두면 첫 운동 기록으로 정합니다'), findsOneWidget);
      await _submit(tester);
      final i = env.programs.instances.values.single;
      expect(i.state.tm, {'bench': 80});
      expect(i.state.working, isEmpty);
    });

    testWidgets('kg로 저장하고 인스턴스 화면으로 이동', (tester) async {
      final env = _Env();
      await env.pump(tester, Routes.programStart('p-tpl'));
      await tester.enterText(_field('WORKING:bench'), '60');
      await tester.pump();
      await _submit(tester);
      final i = env.programs.instances.values.single;
      expect(i.state.tm, {'squat': 100});
      expect(i.state.working, {'bench': 60});
      expect(i.startDate, DateTime(2026, 11, 26));
      expect(i.skipPolicy, SkipPolicy.SHIFT);
      expect(find.byKey(const Key('instance-menu')), findsOneWidget);
    });

    testWidgets('lb 입력은 kg로 변환해 저장', (tester) async {
      final env = _Env(settings: const Settings(weightUnit: WeightUnit.LB));
      await env.pump(tester, Routes.programStart('p-tpl'));
      expect(_text(tester, 'TM:squat'), '220.5');
      await tester.enterText(_field('TM:squat'), '225');
      await tester.enterText(_field('WORKING:bench'), '135');
      await tester.pump();
      await _submit(tester);
      final i = env.programs.instances.values.single;
      expect(i.state.tm['squat'], closeTo(102.06, 0.001));
      expect(i.state.working['bench'], closeTo(61.23, 0.001));
    });

    testWidgets('출처를 모르는 값(null)이어도 칩·근거 없이 그려진다', (tester) async {
      final env = _Env();
      env.programs.suggestions['p-tpl'] = const [
        SuggestItem(key: 'squat', exerciseId: 'ex-squat', needs: SuggestNeeds.TM, oneRmKg: 120, suggestedKg: 100),
        SuggestItem(key: 'bench', exerciseId: 'ex-bench', needs: SuggestNeeds.WORKING, suggestedKg: 60),
      ];
      await env.pump(tester, Routes.programStart('p-tpl'));
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('start-source-TM:squat')), findsNothing);
      expect(find.textContaining('1RM'), findsNothing);
      await _submit(tester);
      expect(env.programs.instances.values.single.state.tm, {'squat': 100});
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
      await tester.enterText(_field('WORKING:bench'), '1');
      await tester.pump();
      await _submit(tester);
      expect(find.text('너무 가벼워요'), findsOneWidget);
      expect(find.text('입력값을 확인해 주세요'), findsOneWidget);
      expect(env.programs.instances, isEmpty);
    });
  });

  group('일정', () {
    testWidgets('요일이 없는 프로그램은 날짜 고정 비활성, 있으면 선택해서 저장', (tester) async {
      bool fixedEnabled() => tester
          .widget<SegmentedButton<SkipPolicy>>(find.byKey(const Key('start-skip-policy')))
          .segments
          .firstWhere((s) => s.value == SkipPolicy.FIXED_DATE)
          .enabled;
      final env = _Env();
      await env.pump(tester, Routes.programStart('p-noday'));
      await _openSchedule(tester);
      expect(fixedEnabled(), isFalse);
      expect(find.textContaining('요일이 정해져 있지 않아'), findsWidgets);
      expect(find.text('첫 운동 · 11월 26일(목)'), findsOneWidget);

      final env2 = _Env();
      await env2.pump(tester, Routes.programStart('p-tpl'));
      await _openSchedule(tester);
      expect(fixedEnabled(), isTrue);
      await tester.enterText(_field('WORKING:bench'), '60');
      await tester.tap(find.text('날짜 고정'));
      await tester.pump();
      await _submit(tester);
      expect(env2.programs.instances.values.single.skipPolicy, SkipPolicy.FIXED_DATE);
    });

    testWidgets('접힌 요약 한 줄: 시작일·요일·방식', (tester) async {
      final env = _Env();
      await env.pump(tester, Routes.programStart('p-tpl'));
      expect(find.text('오늘부터 · 월·목 · 다음 날로 밀기'), findsOneWidget);
    });

    testWidgets('요일 줄에 다른 진행 중 프로그램의 요일이 겹치면 칩과 표시', (tester) async {
      final env = _Env();
      env.programs.instances['i-o'] = _inst('i-o', 'p-other'); // 목·토
      await env.pump(tester, Routes.programStart('p-tpl')); // 월·목
      expect(find.text('1일 겹침'), findsOneWidget);
      await _openSchedule(tester);
      expect(find.byKey(const Key('start-weekdays')), findsOneWidget);
      expect(find.bySemanticsLabel('목요일, 두 프로그램이 겹침'), findsOneWidget);
      expect(find.bySemanticsLabel('월요일, 이 프로그램 운동일'), findsOneWidget);
      expect(find.bySemanticsLabel('토요일, 다른 진행 중 프로그램 있음'), findsOneWidget);
      // 기존 것 일시정지를 고르면 그 요일은 겹치지 않는다
      await tester.tap(find.text('기존 것 일시정지'));
      await tester.pumpAndSettle();
      expect(find.text('1일 겹침'), findsNothing);
    });
  });

  group('겹침 알림', () {
    testWidgets('겹치지 않으면 알림이 없다', (tester) async {
      final env = _Env();
      env.programs.instances['i-f'] = _inst('i-f', 'p-free'); // 화·금
      await env.pump(tester, Routes.programStart('p-tpl'));
      expect(find.byKey(const Key('start-overlap')), findsNothing);
    });

    testWidgets('요일이 겹치면 알리고, 기본은 같이 진행(일시정지 안 함)', (tester) async {
      final env = _Env();
      env.programs.instances['i-o'] = _inst('i-o', 'p-other');
      await env.pump(tester, Routes.programStart('p-tpl'));
      expect(find.text('진행 중인 "진행 i-o" 프로그램과 목요일이 겹쳐요'), findsOneWidget);
      expect(find.text('두 프로그램이 따로 진행돼요. 무게는 프로그램마다 따로 관리돼요.'), findsOneWidget);
      await tester.enterText(_field('WORKING:bench'), '60');
      await _submit(tester);
      expect(env.programs.instances['i-o']!.status, InstanceStatus.ACTIVE);
      expect(env.programs.instances.length, 2);
    });

    testWidgets('같은 프로그램 중복 시작도 알린다', (tester) async {
      final env = _Env();
      env.programs.instances['i-s'] = _inst('i-s', 'p-tpl');
      await env.pump(tester, Routes.programStart('p-tpl'));
      expect(find.text('"진행 i-s" 프로그램이 이미 진행 중이에요'), findsOneWidget);
    });

    testWidgets('기존 것 일시정지: 시작 성공 뒤에 겹치는 기존 인스턴스만 일시정지', (tester) async {
      final env = _Env();
      env.programs.instances['i-o'] = _inst('i-o', 'p-other');
      env.programs.instances['i-f'] = _inst('i-f', 'p-free');
      await env.pump(tester, Routes.programStart('p-tpl'));
      await tester.tap(find.text('기존 것 일시정지'));
      await tester.pumpAndSettle();
      expect(find.text('기존 프로그램은 일시정지하고 이 프로그램만 진행해요. 기록과 무게는 그대로 남아요.'), findsOneWidget);
      await tester.enterText(_field('WORKING:bench'), '60');
      await _submit(tester);
      expect(env.programs.instances['i-o']!.status, InstanceStatus.PAUSED);
      expect(env.programs.instances['i-f']!.status, InstanceStatus.ACTIVE);
      expect(env.programs.instances.length, 3);
    });

    testWidgets('시작이 실패하면 기존 것은 그대로', (tester) async {
      final env = _Env();
      env.programs.instances['i-o'] = _inst('i-o', 'p-other');
      env.programs.startError = const ApiException(statusCode: 500, code: 'X', message: '서버 오류');
      await env.pump(tester, Routes.programStart('p-tpl'));
      await tester.tap(find.text('기존 것 일시정지'));
      await tester.pumpAndSettle();
      await tester.enterText(_field('WORKING:bench'), '60');
      await _submit(tester);
      expect(env.programs.instances['i-o']!.status, InstanceStatus.ACTIVE);
      expect(env.programs.instances.length, 1);
      expect(find.text('서버 오류'), findsOneWidget);
    });

    testWidgets('일시정지가 실패해도 시작은 유지하고 알린다', (tester) async {
      final env = _Env();
      env.programs.instances['i-o'] = _inst('i-o', 'p-other');
      env.programs.patchError = const ApiException(statusCode: 500, code: 'X', message: 'no');
      await env.pump(tester, Routes.programStart('p-tpl'));
      await tester.tap(find.text('기존 것 일시정지'));
      await tester.pumpAndSettle();
      await tester.enterText(_field('WORKING:bench'), '60');
      await _submit(tester);
      expect(env.programs.instances.length, 2);
      expect(find.textContaining('일시정지하지 못했어요'), findsOneWidget);
    });

    testWidgets('이미 일시정지된 것은 선택 없이 안내만', (tester) async {
      final env = _Env();
      env.programs.instances['i-o'] = _inst('i-o', 'p-other', status: InstanceStatus.PAUSED);
      await env.pump(tester, Routes.programStart('p-tpl'));
      expect(find.byKey(const Key('start-keep')), findsNothing);
      expect(find.text('일시정지된 프로그램이에요. 그대로 두고 새로 시작해요.'), findsOneWidget);
      // 일시정지된 것은 요일 줄에도 표시하지 않는다
      expect(find.text('1일 겹침'), findsNothing);
    });
  });

  group('오프라인', () {
    testWidgets('연결이 없으면 안내와 다시 시도', (tester) async {
      final env = _Env();
      env.programs.getError = const ApiException(statusCode: 0, code: 'NETWORK', message: 'x');
      await env.pump(tester, Routes.programStart('p-tpl'));
      expect(find.byKey(const Key('start-offline')), findsOneWidget);
      expect(find.textContaining('서버에 연결해야'), findsOneWidget);
      env.programs.getError = null;
      await tester.tap(find.text('다시 시도'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('start-submit')), findsOneWidget);
    });
  });

  group('레이아웃', () {
    for (final (name, mode, scale) in [
      ('라이트 1.0', ThemeMode.light, 1.0),
      ('다크 1.3', ThemeMode.dark, 1.3),
      ('다크 2.0', ThemeMode.dark, 2.0),
    ]) {
      testWidgets('360×780 $name: 넘침 없음(겹침·일정·계산 펼침)', (tester) async {
        final env = _Env();
        env.programs.instances['i-o'] = _inst('i-o', 'p-other');
        await env.pump(tester, Routes.programStart('p-tpl'), size: const Size(360, 780), textScale: scale, mode: mode);
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.byKey(const Key('start-calc-WORKING:bench')));
        await tester.tap(find.byKey(const Key('start-calc-WORKING:bench')));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('일정'));
        await tester.tap(find.text('일정'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const Key('start-weekdays')));
        await tester.pumpAndSettle();
        await _submit(tester); // 빠진 칸 오류 표시까지
        expect(tester.takeException(), isNull);
        // 아이콘 버튼은 tooltip과 48 이상의 터치 영역
        for (final b in tester.widgetList<IconButton>(find.byType(IconButton))) {
          expect(b.tooltip, isNotNull);
        }
        for (final k in ['start-up-TM:squat', 'start-down-TM:squat']) {
          final f = find.byKey(Key(k));
          if (f.evaluate().isEmpty) continue;
          expect(tester.getSize(f).shortestSide, greaterThanOrEqualTo(48));
        }
      });
    }
  });
}
