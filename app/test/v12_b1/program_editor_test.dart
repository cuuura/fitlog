import 'package:fitlog/core/api/api_client.dart';
import 'package:fitlog/core/api/dto.dart';
import 'package:fitlog/core/api/program_dto.dart';
import 'package:fitlog/core/auth/auth_controller.dart';
import 'package:fitlog/core/clock.dart';
import 'package:fitlog/core/routes.dart';
import 'package:fitlog/core/settings/settings_controller.dart';
import 'package:fitlog/data/memory/memory_repositories.dart';
import 'package:fitlog/data/providers.dart';
import 'package:fitlog/features/program_editor/program_definition.dart';
import 'package:fitlog/features/program_editor/program_editor_page.dart';
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

Map<String, Object?> _def() => {
  'schemaVersion': 1,
  'name': '내 루틴',
  'family': 'fam',
  'variantLabel': '주 3일',
  'lifts': {
    'squat': {
      'exercise': {'id': 'ex-squat'},
      'derive': {'from': 'bench', 'ratio': 0.8},
    },
    'bench': {
      'exercise': {'id': 'ex-bench'},
    },
  },
  'progression': {
    'squat': {'type': 'LINEAR', 'incrementKg': 5},
  },
  'days': [
    {
      'key': 'A',
      'name': '하체',
      'exercises': [
        {
          'lift': 'squat',
          'sets': [
            {
              'count': 3,
              'reps': 5,
              'load': {'type': 'WORKING'},
              'weekly': [
                {'reps': 3},
              ],
            },
          ],
        },
      ],
    },
  ],
};

class _Repo extends MemoryProgramRepository {
  final created = <Map<String, Object?>>[];
  final updated = <Map<String, Object?>>[];
  final replaced = <String, List<Map<String, Object?>>>{};
  final replaceTm = <Map<String, double>>[];
  ApiException? validateError;
  List<ApiException> replaceErrors = [];

  @override
  Future<Program> validateProgram(Map<String, Object?> definition) async {
    if (validateError != null) throw validateError!;
    return super.validateProgram(definition);
  }

  @override
  Future<Program> createProgram(String id, Map<String, Object?> definition) async {
    created.add(definition);
    return super.createProgram(id, definition);
  }

  @override
  Future<Program> updateProgram(String id, {String? name, required Map<String, Object?> definition}) async {
    updated.add(definition);
    return super.updateProgram(id, name: name, definition: definition);
  }

  @override
  Future<Instance> replaceInstanceDefinition(
    String instanceId,
    Map<String, Object?> definition, {
    Map<String, double> tm = const {},
    Map<String, double> working = const {},
  }) async {
    if (replaceErrors.isNotEmpty) throw replaceErrors.removeAt(0);
    replaced.putIfAbsent(instanceId, () => []).add(definition);
    replaceTm.add(tm);
    return super.replaceInstanceDefinition(instanceId, definition, tm: tm, working: working);
  }
}

Instance _inst(String id) => Instance(
  id: id,
  programId: 'p-mine',
  name: '진행',
  status: InstanceStatus.ACTIVE,
  skipPolicy: SkipPolicy.SHIFT,
  startDate: DateTime(2026, 11, 26),
  state: const InstanceState(),
);

Future<_Repo> _pump(WidgetTester tester, String initial, {int instances = 0}) async {
  tester.view.physicalSize = const Size(800, 1800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final repo = _Repo();
  repo.programs['p-mine'] = Program(id: 'p-mine', name: '내 루틴', builtIn: false, dayCount: 1, definition: _def());
  repo.programs['p-tpl'] = Program(id: 'p-tpl', name: '템플릿', builtIn: true, dayCount: 1, definition: _def());
  for (var i = 0; i < instances; i++) {
    repo.instances['i$i'] = _inst('i$i');
  }
  final router = GoRouter(
    initialLocation: initial,
    routes: [
      GoRoute(path: Routes.programs, builder: (_, _) => const Scaffold(body: Text('programs-page'))),
      GoRoute(
        path: Routes.programEditor,
        builder: (_, s) => ProgramEditorPage(
          programId: s.uri.queryParameters['programId'],
          copyFromProgramId: s.uri.queryParameters['copyFrom'],
          instanceId: s.uri.queryParameters['instanceId'],
        ),
      ),
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
      overrides: [
        authControllerProvider.overrideWith(() => FixedAuthStatus(AuthStatus.signedIn)),
        settingsProvider.overrideWith(() => FixedSettings(const Settings())),
        programRepositoryProvider.overrideWithValue(repo),
        exerciseRepositoryProvider.overrideWithValue(
          MemoryExerciseRepository(seed: [_ex('ex-squat', '스쿼트'), _ex('ex-bench', '벤치프레스')]),
        ),
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
  return repo;
}

Future<void> _pickOption(WidgetTester tester, Finder dropdown, String text) async {
  await tester.ensureVisible(dropdown);
  await tester.tap(dropdown);
  await tester.pumpAndSettle();
  await tester.tap(find.text(text).last);
  await tester.pumpAndSettle();
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _save(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('editor-save')));
  // 저장 중 스피너가 계속 돌아 pumpAndSettle을 쓸 수 없다.
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  group('정의 모델', () {
    test('모르는 필드를 그대로 보존하고 사본을 만든다', () {
      final d = ProgramDef(_def().cast<String, dynamic>());
      d.day(0)['name'] = '바뀜';
      final out = d.toJson();
      expect(out['family'], 'fam');
      expect(out['variantLabel'], '주 3일');
      expect(((out['lifts'] as Map)['squat'] as Map)['derive'], {'from': 'bench', 'ratio': 0.8});
      expect(
        (((out['days'] as List)[0] as Map)['exercises'] as List).first['sets'][0]['weekly'],
        [
          {'reps': 3},
        ],
      );
      // derive가 가리키는 bench는 날에 없어도 남는다.
      expect((out['lifts'] as Map).containsKey('bench'), isTrue);
      // 원본은 그대로.
      expect((_def()['days'] as List)[0]['name'], '하체');
    });

    test('안 쓰게 된 종목 키와 규칙은 저장 때 정리하고 처음부터 안 쓰던 건 둔다', () {
      final src = _def().cast<String, dynamic>();
      (src['lifts'] as Map)['extra'] = {
        'exercise': {'name': 'x'},
      };
      final d = ProgramDef(src);
      final keep = d.unusedLiftKeys();
      expect(keep, {'extra'});
      d.addExercise(0, exerciseId: 'ex-dead', nameForKey: 'Dead Lift');
      expect(d.lifts.containsKey('dead_lift'), isTrue);
      d.exercises(0).removeLast();
      d.progression['dead_lift'] = {'type': 'NONE'};
      final out = d.toJson(keepUnused: keep);
      expect((out['lifts'] as Map).containsKey('dead_lift'), isFalse);
      expect((out['lifts'] as Map).containsKey('extra'), isTrue);
      expect((out['progression'] as Map).containsKey('dead_lift'), isFalse);
    });

    test('종목 키 자동 생성과 같은 종목 재사용', () {
      final d = ProgramDef.blank();
      final k1 = d.addExercise(0, exerciseId: 'a', nameForKey: 'Bench Press');
      final k2 = d.addExercise(0, exerciseId: 'a', nameForKey: 'Bench Press');
      final k3 = d.addExercise(0, exerciseId: 'b', nameForKey: 'Bench Press');
      expect(k1, 'bench_press');
      expect(k2, 'bench_press');
      expect(k3, 'bench_press_2');
      expect(ProgramDef.liftKeyBase('스쿼트'), 'lift');
      expect(isValidLiftKey(ProgramDef.liftKeyBase('1RM test')), isTrue);
    });
  });

  group('편집기 화면', () {
    testWidgets('새로 만들기: 날·종목·세트 추가, 규칙을 CUSTOM으로 바꾸고 저장하면 POST', (tester) async {
      final repo = await _pump(tester, Routes.programEditorFor());
      await tester.enterText(find.byKey(const Key('editor-name')), '나만의 루틴');
      await tester.tap(find.byKey(const Key('editor-add-day')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('day-card-1')), findsOneWidget);

      await tester.tap(find.byKey(const Key('day-card-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('day-add-exercise')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('pick-bench'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ex-card-0')), findsOneWidget);
      expect(find.text('벤치프레스'), findsOneWidget);
      expect(find.byKey(const Key('set-line-0-0')), findsOneWidget);

      // 세트 추가: 3×8, AMRAP
      await tester.tap(find.byKey(const Key('ex-add-set-0')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('set-reps')), '8');
      await tester.tap(find.byKey(const Key('set-amrap')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('sheet-submit')));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(find.byKey(const Key('set-line-0-1'))).data, contains('AMRAP'));
      expect(tester.widget<Text>(find.byKey(const Key('set-line-0-1'))).data, contains('3×8'));

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      // 규칙을 CUSTOM으로
      await tester.ensureVisible(find.byKey(const Key('rule-quads')));
      await tester.tap(find.byKey(const Key('rule-quads')));
      await tester.pumpAndSettle();
      await _pickOption(tester, find.byKey(const Key('rule-type-NONE')), '직접 정하기(CUSTOM)');
      expect(find.byKey(const Key('rule-success-when')), findsOneWidget);
      await tester.tap(find.byKey(const Key('sheet-submit')));
      await tester.pumpAndSettle();
      expect(find.textContaining('직접 정하기(CUSTOM)'), findsOneWidget);

      await _save(tester);
      expect(repo.created, hasLength(1));
      final def = repo.created.single;
      expect(def['name'], '나만의 루틴');
      expect((def['days'] as List), hasLength(2));
      expect((def['progression'] as Map)['quads'], containsPair('type', 'CUSTOM'));
      expect(((def['progression'] as Map)['quads'] as Map)['success'], containsPair('method', 'ADD_KG'));
      expect(find.text('programs-page'), findsOneWidget);
    });

    testWidgets('검증 에러는 경로에 맞는 칸 아래, 맞는 칸이 없으면 맨 위에 보인다', (tester) async {
      final repo = await _pump(tester, Routes.programEditorFor(programId: 'p-mine'));
      repo.validateError = const ApiException(
        statusCode: 400,
        code: 'VALIDATION_FAILED',
        message: '검증 실패',
        details: [
          (path: '/name', message: '이름이 너무 짧아요'),
          (path: '/days/0/exercises/0/sets/0/reps', message: '횟수가 틀렸어요'),
          (path: '/lifts/squat/derive', message: '자동 계산이 이상해요'),
        ],
      );
      await _save(tester);
      expect(find.text('이름이 너무 짧아요'), findsOneWidget);
      expect(find.text('횟수가 틀렸어요'), findsOneWidget);
      expect(find.text('자동 계산이 이상해요'), findsOneWidget);
      expect(find.byKey(const Key('editor-errors')), findsOneWidget);
      expect(repo.updated, isEmpty);
      await tester.tap(find.byKey(const Key('day-card-0')));
      await tester.pumpAndSettle();
      expect(find.text('횟수가 틀렸어요'), findsOneWidget);
    });

    testWidgets('고치기: PUT, 주차별 설정 세트는 표시하고 그대로 둔다', (tester) async {
      final repo = await _pump(tester, Routes.programEditorFor(programId: 'p-mine'));
      await tester.enterText(find.byKey(const Key('editor-name')), '이름 바꿈');
      await tester.tap(find.byKey(const Key('day-card-0')));
      await tester.pumpAndSettle();
      expect(find.text('주차별 설정 있음(그대로 유지)'), findsOneWidget);
      await tester.tap(find.byKey(const Key('set-line-0-0')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('set-weekly-note')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('set-reps')), '4');
      await tester.tap(find.byKey(const Key('sheet-submit')));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await _save(tester);
      expect(repo.created, isEmpty);
      final def = repo.updated.single;
      expect(def['name'], '이름 바꿈');
      expect(def['family'], 'fam');
      final set = (((def['days'] as List)[0] as Map)['exercises'] as List)[0]['sets'][0] as Map;
      expect(set['reps'], 4);
      expect(set['weekly'], [
        {'reps': 3},
      ]);
    });

    testWidgets('복사해서 고치기: family를 빼고 이름 뒤에 (내 버전), 새로 만든다', (tester) async {
      final repo = await _pump(tester, Routes.programEditorFor(copyFromProgramId: 'p-tpl'));
      expect(find.text('내 루틴 (내 버전)'), findsOneWidget);
      await _save(tester);
      final def = repo.created.single;
      expect(def['name'], '내 루틴 (내 버전)');
      expect(def.containsKey('family'), isFalse);
      expect(def.containsKey('variantLabel'), isFalse);
    });

    testWidgets('저장 뒤 진행 중 인스턴스에 적용: 확인 후 빠진 시작 무게를 받아 다시 보낸다', (tester) async {
      final repo = await _pump(tester, Routes.programEditorFor(programId: 'p-mine'), instances: 2);
      repo.replaceErrors = [
        const ApiException(
          statusCode: 400,
          code: 'VALIDATION_FAILED',
          message: '빠진 값',
          details: [(path: '/working/squat', message: '필요해요')],
        ),
      ];
      await tester.enterText(find.byKey(const Key('editor-name')), '바꿈');
      await _save(tester);
      expect(find.textContaining('진행 중인 2개에도 다음 회차부터 적용할까요?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('confirm-ok')));
      await _settle(tester);
      expect(find.byKey(const Key('missing-/working/squat')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('missing-/working/squat')), '100');
      await tester.tap(find.byKey(const Key('sheet-submit')));
      await _settle(tester);
      expect(repo.replaced.keys, containsAll(['i0', 'i1']));
      expect(repo.replaceTm, hasLength(2));
      expect(find.text('programs-page'), findsOneWidget);
    });

    testWidgets('적용 안 함을 고르면 인스턴스는 건드리지 않는다', (tester) async {
      final repo = await _pump(tester, Routes.programEditorFor(programId: 'p-mine'), instances: 1);
      await tester.enterText(find.byKey(const Key('editor-name')), '바꿈');
      await _save(tester);
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();
      expect(repo.updated, hasLength(1));
      expect(repo.replaced, isEmpty);
    });

    testWidgets('이 진행만 고치기: PUT definition, 409는 메시지를 보여 준다', (tester) async {
      final repo = await _pump(tester, Routes.programEditorFor(instanceId: 'i0'), instances: 1);
      expect(find.byKey(const Key('editor-instance-note')), findsOneWidget);
      repo.replaceErrors = [
        const ApiException(statusCode: 409, code: 'CONFLICT', message: '진행 중인 회차를 끝내거나 지운 뒤 바꾸세요'),
      ];
      await _save(tester);
      expect(find.text('진행 중인 회차를 끝내거나 지운 뒤 바꾸세요'), findsOneWidget);
      expect(repo.updated, isEmpty);
      expect(repo.created, isEmpty);
      await _save(tester);
      expect(repo.replaced['i0'], hasLength(1));
    });

    testWidgets('고친 채 나가려 하면 확인을 묻는다', (tester) async {
      await _pump(tester, Routes.programEditorFor(programId: 'p-mine'));
      await tester.enterText(find.byKey(const Key('editor-name')), '바꿈');
      await tester.pump();
      final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
      nav.maybePop();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('discard-confirm')), findsOneWidget);
    });
  });
}
