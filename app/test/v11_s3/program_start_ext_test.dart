// v1.1 S3: 프로그램 시작 확장(미리 계산·자동 계산 묶음·요일 바꾸기·보조 종목·회당 시간) 앱 쪽.
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

Program _prog(String id, String name, {SessionMinutes? minutes}) => Program(
  id: id,
  name: name,
  builtIn: true,
  dayCount: 2,
  sessionMinutes: minutes,
  definition: {
    'schemaVersion': 1,
    'name': name,
    'lifts': {
      'squat': {'exercise': {'id': 'ex-squat'}},
      'front': {'exercise': {'id': 'ex-front'}},
      'bench': {'exercise': {'id': 'ex-bench'}},
    },
    'days': [
      for (final (i, wd) in ['MON', 'THU'].indexed)
        {
          'key': 'D$i',
          'name': 'Workout ${'AB'[i]}',
          'weekday': wd,
          'exercises': [
            {'lift': 'squat', 'sets': [{'count': 5, 'reps': 5, 'load': {'type': 'WORKING'}}]},
          ],
        },
    ],
  },
);

PlannedWorkout _plan({int? minutes = 55}) => PlannedWorkout(
  instanceId: '',
  planSeq: 1,
  dayIndex: 0,
  dayKey: 'D0',
  dayName: 'Workout A',
  week: 1,
  cycle: 1,
  confirmed: true,
  estimatedMinutes: minutes,
  exercises: [
    PlannedExercise(
      key: 'squat',
      exerciseId: 'ex-squat',
      accessory: false,
      sets: [
        for (var i = 0; i < 5; i++)
          PlannedSet(plannedSetKey: 'D0.0.$i', targetReps: 5, targetWeightKg: 100, isAmrap: false, isWarmup: false),
      ],
    ),
  ],
);

class _Repo extends MemoryProgramRepository {
  bool previewFails = false;
  Object? accessoriesError;
  final starts = <StartInstance>[];
  @override
  Future<StartPreview> previewStart(String programId, StartPreviewRequest request) async {
    if (previewFails) {
      previewRequests.add(request);
      throw const ApiException(code: 'NETWORK', message: 'x');
    }
    return super.previewStart(programId, request);
  }

  @override
  Future<Instance> startInstance(StartInstance start) {
    starts.add(start);
    return super.startInstance(start);
  }

  @override
  Future<List<Accessory>> putAccessories(String instanceId, List<Accessory> list) async {
    if (accessoriesError != null) throw accessoriesError!;
    return super.putAccessories(instanceId, list);
  }
}

class _Env {
  _Env() {
    programs.programs['p'] = _prog('p', '파생 프로그램', minutes: const SessionMinutes(min: 45, max: 70));
    programs.programs['q'] = _prog('q', '고정 시간', minutes: const SessionMinutes(min: 50, max: 50));
    programs.programs['r'] = _prog('r', '시간 없음');
    programs.suggestions['p'] = const [
      SuggestItem(key: 'squat', exerciseId: 'ex-squat', needs: SuggestNeeds.TM, suggestedKg: 100),
      SuggestItem(key: 'bench', exerciseId: 'ex-bench', needs: SuggestNeeds.WORKING),
      SuggestItem(
        key: 'front',
        exerciseId: 'ex-front',
        needs: SuggestNeeds.TM,
        optional: true,
        derivedFrom: 'squat',
        derivedRatio: 0.8,
      ),
    ];
    programs.suggestions['q'] = const [
      SuggestItem(key: 'squat', exerciseId: 'ex-squat', needs: SuggestNeeds.TM, suggestedKg: 100),
    ];
    programs.suggestions['r'] = const [];
    programs.previews['p'] = StartPreview(
      workouts: [_plan()],
      inputsTm: const {'squat': 100, 'front': 80},
      inputsWorking: const {'bench': 60},
      derived: const ['front'],
    );
    programs.previews['q'] = StartPreview(workouts: [_plan(minutes: null)], inputsTm: const {'squat': 100});
  }

  final programs = _Repo();
  final exercises = MemoryExerciseRepository(
    seed: [_ex('ex-squat', '스쿼트'), _ex('ex-front', '프론트 스쿼트'), _ex('ex-bench', '벤치프레스')],
  );

  Future<void> pump(WidgetTester tester, String initial) async {
    tester.view.physicalSize = const Size(800, 2000);
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
          builder: (c, _) => Scaffold(body: TextButton(onPressed: () => c.pop('ex-bench'), child: const Text('pick-bench'))),
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authControllerProvider.overrideWith(() => FixedAuthStatus(AuthStatus.signedIn)),
          settingsProvider.overrideWith(() => FixedSettings(const Settings())),
          programRepositoryProvider.overrideWithValue(programs),
          planCacheProvider.overrideWithValue(MemoryPlanCache(programs)),
          exerciseRepositoryProvider.overrideWithValue(exercises),
          sessionRepositoryProvider.overrideWithValue(MemorySessionRepository()),
          scheduledWorkoutRepositoryProvider.overrideWithValue(MemoryScheduledWorkoutRepository()),
          syncServiceProvider.overrideWithValue(NoopSyncService()),
          clockProvider.overrideWithValue(() => DateTime.utc(2026, 11, 26, 3)),
          deviceTimezoneProvider.overrideWithValue(() async => 'Asia/Seoul'),
        ],
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

Finder _field(String id) => find.byKey(ValueKey('start-$id'));
String _text(WidgetTester t, String id) => t.widget<TextField>(_field(id)).controller!.text;

Future<void> _submit(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(const Key('start-submit')));
  await tester.tap(find.byKey(const Key('start-submit')));
  await tester.pumpAndSettle();
}

/// 디바운스(400ms)를 넘긴다.
Future<void> _debounce(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 450));
  await tester.pumpAndSettle();
}

Future<void> _open(WidgetTester tester, String title) async {
  final f = find.text(title).first;
  await tester.ensureVisible(f);
  await tester.tap(f);
  await tester.pumpAndSettle();
}

void main() {
  group('DTO', () {
    test('새 필드 파싱과 모르는 값 방어', () {
      final p = ProgramSummary.fromJson({
        'id': 'a',
        'name': 'n',
        'builtIn': true,
        'dayCount': 3,
        'sessionMinutes': {'min': 45, 'max': 70},
      });
      expect(p.sessionMinutes!.min, 45);
      expect(p.sessionMinutes!.max, 70);
      expect(
        ProgramSummary.fromJson({'id': 'a', 'name': 'n', 'builtIn': true, 'dayCount': 3, 'sessionMinutes': 'x'})
            .sessionMinutes,
        isNull,
      );
      final s = SuggestItem.fromJson({
        'key': 'front',
        'exerciseId': 'e',
        'needs': 'TM',
        'optional': true,
        'derivedFrom': 'squat',
        'derivedRatio': 0.8,
      });
      expect(s.derivedFrom, 'squat');
      expect(s.derivedRatio, 0.8);
      expect(s.canSkip, isTrue);
      final w = PlannedWorkout.fromJson({
        'planSeq': 1,
        'dayIndex': 0,
        'dayKey': 'A',
        'dayName': 'A 날',
        'week': 1,
        'cycle': 1,
        'estimatedMinutes': 55,
        'exercises': [],
        'newField': 1,
      });
      expect(w.estimatedMinutes, 55);
      final r = StartPreview.fromJson({
        'workouts': [],
        'inputs': {'tm': {'squat': 100}, 'working': {'row': 40}},
        'derived': ['row'],
      });
      expect(r.inputsTm['squat'], 100);
      expect(r.derived, ['row']);
    });

    test('요청 본문: weekdays·count', () {
      final j = StartPreviewRequest(
        startDate: DateTime(2026, 12, 1),
        tz: 'Asia/Seoul',
        tm: const {'squat': 100},
        weekdays: const {'A': 'TUE'},
      ).toJson();
      expect(j['weekdays'], {'A': 'TUE'});
      expect(j['count'], 1);
      final s = StartInstance(id: 'i', programId: 'p', startDate: DateTime(2026, 12, 1), tz: 'UTC').toJson();
      expect(s.containsKey('weekdays'), isFalse);
    });
  });

  group('첫 운동 미리 계산', () {
    testWidgets('칸이 비면 안내, 채우면 400ms 뒤 세트×횟수@무게와 약 N분', (tester) async {
      final env = _Env();
      await env.pump(tester, Routes.programStart('p'));
      expect(find.text('무게를 채우면 세트가 보여요'), findsOneWidget);
      expect(find.byKey(const Key('start-preview-sets')), findsNothing);
      expect(env.programs.previewRequests, isEmpty);
      await tester.enterText(_field('WORKING:bench'), '60');
      await tester.pump(const Duration(milliseconds: 200));
      expect(env.programs.previewRequests, isEmpty); // 디바운스 중
      await _debounce(tester);
      expect(env.programs.previewRequests, hasLength(1));
      final req = env.programs.previewRequests.single;
      expect(req.count, 1);
      expect(req.tm, {'squat': 100});
      expect(req.working, {'bench': 60});
      expect(find.byKey(const Key('start-preview-sets')), findsOneWidget);
      expect(find.text('5×5 @ 100 kg'), findsOneWidget);
      expect(find.text('약 55분'), findsOneWidget);
      expect(find.text('무게를 채우면 세트가 보여요'), findsNothing);
      // 칸을 다시 비우면 안내로 돌아간다
      await tester.enterText(_field('WORKING:bench'), '');
      await tester.pump();
      expect(find.byKey(const Key('start-preview-sets')), findsNothing);
      expect(find.text('무게를 채우면 세트가 보여요'), findsOneWidget);
    });

    testWidgets('연속 입력은 마지막 한 번만 부른다', (tester) async {
      final env = _Env();
      await env.pump(tester, Routes.programStart('p'));
      for (final t in ['6', '60', '62']) {
        await tester.enterText(_field('WORKING:bench'), t);
        await tester.pump(const Duration(milliseconds: 100));
      }
      await _debounce(tester);
      expect(env.programs.previewRequests, hasLength(1));
      expect(env.programs.previewRequests.single.working, {'bench': 62});
    });

    testWidgets('실패·오프라인이면 안내로 돌아가고 시작은 막지 않는다', (tester) async {
      final env = _Env();
      env.programs.previewFails = true;
      await env.pump(tester, Routes.programStart('p'));
      await tester.enterText(_field('WORKING:bench'), '60');
      await _debounce(tester);
      expect(env.programs.previewRequests, hasLength(1));
      expect(find.byKey(const Key('start-preview-sets')), findsNothing);
      expect(find.text('무게를 채우면 세트가 보여요'), findsOneWidget);
      expect(find.text('Workout A · 스쿼트'), findsOneWidget);
      await _submit(tester);
      expect(env.programs.starts, hasLength(1));
    });

    testWidgets('estimatedMinutes가 없으면 시간을 숨긴다', (tester) async {
      final env = _Env();
      await env.pump(tester, Routes.programStart('q'));
      await _debounce(tester);
      expect(find.byKey(const Key('start-preview-sets')), findsOneWidget);
      expect(find.byKey(const Key('start-preview-minutes')), findsNothing);
    });
  });

  group('자동 계산 묶음', () {
    testWidgets('접힌 묶음, preview 값으로 채우고 근거를 보이며, 안 고치면 보내지 않는다', (tester) async {
      final env = _Env();
      await env.pump(tester, Routes.programStart('p'));
      expect(find.byKey(const Key('start-derived-group')), findsOneWidget);
      expect(find.text('자동 계산 1개'), findsOneWidget);
      expect(_field('TM:front'), findsNothing); // 접힘
      await tester.enterText(_field('WORKING:bench'), '60');
      await _debounce(tester);
      await tester.tap(find.byKey(const Key('start-derived-toggle')));
      await tester.pumpAndSettle();
      expect(_text(tester, 'TM:front'), '80');
      expect(find.text('스쿼트 × 80%'), findsOneWidget);
      await _submit(tester);
      final st = env.programs.starts.single;
      expect(st.tm, {'squat': 100});
      expect(st.working, {'bench': 60});
    });

    testWidgets('직접 고치면 그 값을 보낸다. 첫 운동에서 정하기 안내', (tester) async {
      final env = _Env();
      await env.pump(tester, Routes.programStart('p'));
      await tester.enterText(_field('WORKING:bench'), '60');
      await _debounce(tester);
      await tester.tap(find.byKey(const Key('start-derived-toggle')));
      await tester.pumpAndSettle();
      await tester.enterText(_field('TM:front'), '70');
      await tester.pump();
      await _debounce(tester);
      expect(_text(tester, 'TM:front'), '70'); // preview가 덮어쓰지 않는다
      expect(env.programs.previewRequests.last.tm, {'squat': 100, 'front': 70});
      await _submit(tester);
      expect(env.programs.starts.single.tm, {'squat': 100, 'front': 70});
    });
  });

  group('요일 바꾸기', () {
    testWidgets('같은 요일 두 날은 막고, 바꾼 요일이 미리 계산·시작 요청에 실린다', (tester) async {
      final env = _Env();
      await env.pump(tester, Routes.programStart('q'));
      await _open(tester, '일정');
      expect(find.byKey(const Key('start-weekday-D1')), findsOneWidget);
      // D1(목)이 월요일 칩은 D0가 쓰고 있어 못 누른다
      final taken = tester.widget<ChoiceChip>(find.byKey(const Key('start-weekday-D1-MON')));
      expect(taken.onSelected, isNull);
      await tester.ensureVisible(find.byKey(const Key('start-weekday-D1-WED')));
      await tester.tap(find.byKey(const Key('start-weekday-D1-WED')));
      await tester.pump();
      await _debounce(tester);
      expect(env.programs.previewRequests.last.weekdays, {'D1': 'WED'});
      expect(find.textContaining('월·수'), findsWidgets); // 일정 요약
      await _submit(tester);
      expect(env.programs.starts.single.weekdays, {'D1': 'WED'});
    });

    testWidgets('안 바꾸면 weekdays를 보내지 않는다', (tester) async {
      final env = _Env();
      await env.pump(tester, Routes.programStart('q'));
      await _submit(tester);
      expect(env.programs.starts.single.weekdays, isEmpty);
      expect(env.programs.starts.single.toJson().containsKey('weekdays'), isFalse);
    });
  });

  group('보조 종목', () {
    Future<void> addOne(WidgetTester tester) async {
      await _open(tester, '보조 종목');
      await tester.tap(find.byKey(const Key('start-acc-add-D0')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('pick-bench'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('acc-weight')), '20');
      await tester.tap(find.byKey(const Key('sheet-submit')));
      await tester.pumpAndSettle();
    }

    testWidgets('날마다 추가·삭제(되돌리기), 시작 뒤 PUT으로 저장', (tester) async {
      final env = _Env();
      await env.pump(tester, Routes.programStart('q'));
      expect(find.text('추가하지 않아도 돼요'), findsOneWidget);
      await addOne(tester);
      expect(find.text('1개 추가'), findsOneWidget);
      expect(find.textContaining('벤치프레스'), findsWidgets);
      // 삭제: 즉시 지우고 되돌리기
      final menu = find.descendant(of: find.byKey(const Key('start-accessories')), matching: find.byType(PopupMenuButton<String>));
      await tester.tap(menu);
      await tester.pumpAndSettle();
      await tester.tap(find.text('삭제'));
      await tester.pumpAndSettle();
      expect(find.text('추가하지 않아도 돼요'), findsOneWidget);
      await tester.tap(find.text('되돌리기'));
      await tester.pumpAndSettle();
      expect(find.text('1개 추가'), findsOneWidget);
      await _submit(tester);
      final id = env.programs.starts.single.id;
      final saved = env.programs.accessoryLists[id]!;
      expect(saved, hasLength(1));
      expect(saved.single.dayKey, 'D0');
      expect(saved.single.exerciseId, 'ex-bench');
      expect(saved.single.sets, 3);
      expect(saved.single.weightKg, 20);
    });

    testWidgets('저장이 실패해도 시작은 성공이고 스낵바로 안내한다', (tester) async {
      final env = _Env();
      env.programs.accessoriesError = const ApiException(code: 'NETWORK', message: 'x');
      await env.pump(tester, Routes.programStart('q'));
      await addOne(tester);
      await _submit(tester);
      expect(env.programs.instances, hasLength(1));
      expect(find.textContaining('보조 종목은 저장하지 못했어요'), findsOneWidget);
    });

    testWidgets('고르지 않으면 PUT을 부르지 않는다', (tester) async {
      final env = _Env();
      await env.pump(tester, Routes.programStart('q'));
      await _submit(tester);
      expect(env.programs.accessoryLists, isEmpty);
    });
  });

  group('회당 시간', () {
    testWidgets('맞추기 화면 머리: 범위·같은 값·없음', (tester) async {
      var env = _Env();
      await env.pump(tester, Routes.programStart('p'));
      expect(find.text('회당 약 45~70분'), findsOneWidget);
      env = _Env();
      await env.pump(tester, Routes.programStart('q'));
      expect(find.text('회당 약 50분'), findsOneWidget);
      env = _Env();
      await env.pump(tester, Routes.programStart('r'));
      expect(find.byKey(const Key('program-session-minutes')), findsNothing);
    });

    testWidgets('상세 화면', (tester) async {
      final env = _Env();
      await env.pump(tester, '/programs/p');
      expect(find.byKey(const Key('program-session-minutes')), findsOneWidget);
      expect(find.text('회당 약 45~70분'), findsOneWidget);
    });

    testWidgets('추가 시트 카드', (tester) async {
      final env = _Env();
      await env.pump(tester, Routes.programs);
      await tester.tap(find.byKey(const Key('programs-add')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('program-session-minutes-p')), findsOneWidget);
      expect(find.text('회당 약 45~70분'), findsOneWidget);
      expect(find.byKey(const Key('program-session-minutes-r')), findsNothing);
    });
  });
}
