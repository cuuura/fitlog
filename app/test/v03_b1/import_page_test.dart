import 'dart:convert';

import 'package:fitlog/core/api/ai_dto.dart';
import 'package:fitlog/core/api/api_client.dart';
import 'package:fitlog/core/api/dto.dart';
import 'package:fitlog/core/auth/auth_controller.dart';
import 'package:fitlog/core/clock.dart';
import 'package:fitlog/core/routes.dart';
import 'package:fitlog/core/settings/settings_controller.dart';
import 'package:fitlog/data/memory/memory_repositories.dart';
import 'package:fitlog/data/providers.dart';
import 'package:fitlog/features/importing/import_page.dart';
import 'package:fitlog/features/session/session_controller.dart' show deviceTimezoneProvider;
import 'package:fitlog/l10n/gen/app_localizations.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../support/fixed_providers.dart';

class _Repo extends MemoryImportRepository {
  ApiException? previewError;
  final List<ImportRequest> previewed = [];
  @override
  Future<ImportPreview> preview(ImportRequest request) async {
    previewed.add(request);
    if (previewError != null) throw previewError!;
    return nextPreview;
  }
}

Conflict _conflict(String code, String path, List<ResolutionAction> allowed, {List<ExerciseCandidate> cands = const [], Map<String, Object?>? suggested, Map<String, Object?>? existing}) =>
    Conflict(
      conflictId: '$code:$path',
      code: ConflictCode.values.byName(code),
      path: path,
      message: '$code 메시지',
      allowed: allowed,
      candidates: cands,
      suggested: suggested,
      existing: existing,
    );

String _bundleJson({int sessions = 1}) => jsonEncode({
  'schemaVersion': 1,
  'sessions': [for (var i = 0; i < sessions; i++) {'startedAt': '2026-01-01T00:00:00+09:00', 'n': i}],
});

class _Env {
  final repo = _Repo();
  final Settings settings;
  Uint8List? pickedFile;
  String? clipboard;
  _Env({this.settings = const Settings()});

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard = (call.arguments as Map)['text'] as String?;
      } else if (call.method == 'Clipboard.getData') {
        return clipboard == null ? null : {'text': clipboard};
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final overrides = <Override>[
      authControllerProvider.overrideWith(() => FixedAuthStatus(AuthStatus.signedIn)),
      settingsProvider.overrideWith(() => FixedSettings(settings)),
      importRepositoryProvider.overrideWithValue(repo),
      exerciseRepositoryProvider.overrideWithValue(
        MemoryExerciseRepository(
          seed: [
            Exercise(
              id: 'ex-bench',
              nameKo: '벤치프레스',
              type: ExerciseType.BARBELL,
              primaryMuscle: Muscle.CHEST,
              builtIn: true,
              updatedAt: DateTime.utc(2026),
            ),
          ],
        ),
      ),
      sessionRepositoryProvider.overrideWithValue(MemorySessionRepository()),
      syncServiceProvider.overrideWithValue(NoopSyncService()),
      clockProvider.overrideWithValue(() => DateTime.utc(2026, 11, 26, 3)),
      deviceTimezoneProvider.overrideWithValue(() async => 'Asia/Seoul'),
      importFilePickerProvider.overrideWithValue(() async => pickedFile),
    ];
    final router = GoRouter(
      initialLocation: Routes.importJson,
      routes: [
        GoRoute(path: Routes.home, builder: (_, _) => const Scaffold(body: Text('home-page'))),
        GoRoute(path: Routes.importJson, builder: (_, _) => const ImportPage()),
        GoRoute(path: '/ai/history/:id', builder: (_, s) => Scaffold(body: Text('history-${s.pathParameters['id']}'))),
        GoRoute(
          path: Routes.pickExercise,
          builder: (c, _) => Scaffold(body: TextButton(onPressed: () => c.pop('ex-bench'), child: const Text('pick-bench'))),
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

  Future<void> enter(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(const ValueKey('import-text')), text);
    await tester.pump();
  }

  Future<void> preview(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('import-preview')));
    await tester.pumpAndSettle();
  }

  Future<void> save(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('import-save')));
    await tester.pumpAndSettle();
  }

  Future<void> choose(WidgetTester tester, Conflict c, ResolutionAction a) async {
    await tester.tap(find.byKey(ValueKey('action-${c.conflictId}-${a.name}')));
    await tester.pumpAndSettle();
  }

  bool saveEnabled(WidgetTester tester) => tester.widget<FilledButton>(find.byKey(const ValueKey('import-save'))).onPressed != null;
}

void main() {
  testWidgets('코드 블록 표시를 벗기고 미리보기 → 충돌 없이 저장 → 결과', (tester) async {
    final env = _Env();
    env.repo.nextPreview = const ImportPreview(
      valid: true,
      counts: {
        'sessions': {'NEW': 3, 'UNCHANGED': 1},
      },
    );
    await env.pump(tester);
    await env.enter(tester, '```json\n${_bundleJson()}\n```');
    await tester.tap(find.byKey(const ValueKey('import-client-ChatGPT')));
    await tester.pump();
    await env.preview(tester);

    expect(find.textContaining('새로 3 · 변경 없음 1'), findsOneWidget);
    expect(find.byKey(const ValueKey('import-no-conflicts')), findsOneWidget);
    expect(env.saveEnabled(tester), isTrue);
    final req = env.repo.previewed.single;
    expect(req.clientName, 'ChatGPT');
    expect(req.tz, 'Asia/Seoul');
    expect(req.bundle['schemaVersion'], 1);

    await env.save(tester);
    expect(env.repo.submitted.single.resolutions, isEmpty);
    expect(find.text('가져오기 완료'), findsOneWidget);
    expect(find.text('세션 1'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('import-history-0')));
    await tester.pumpAndSettle();
    expect(find.text('history-${env.repo.batches.single.id}'), findsOneWidget);
  });

  testWidgets('JSON 문법 오류는 줄·열과 함께 보여주고 서버에 보내지 않는다', (tester) async {
    final env = _Env();
    await env.pump(tester);
    await env.enter(tester, '{\n  "a": 1,\n  "b": }');
    await env.preview(tester);
    expect(find.textContaining('3줄'), findsOneWidget);
    expect(env.repo.previewed, isEmpty);

    await env.enter(tester, '[1]');
    await env.preview(tester);
    expect(find.textContaining('객체'), findsOneWidget);
  });

  testWidgets('프롬프트 복사: 자리표시자를 채워 클립보드에 넣고 스낵바', (tester) async {
    final env = _Env(settings: const Settings(weightUnit: WeightUnit.LB));
    await env.pump(tester);
    await tester.tap(find.byKey(const ValueKey('import-copy-prompt')));
    await tester.pumpAndSettle();
    final p = env.clipboard!;
    expect(p, contains('https://api.test/v1/public/schema/import.json'));
    expect(p, contains('https://api.test/v1/public/schema/program.json'));
    expect(p, contains('Asia/Seoul'));
    expect(p, contains('lb이지만'));
    expect(RegExp(r'오늘은 2026-11-2[67]\.').hasMatch(p), isTrue);
    expect(p, isNot(contains('{SCHEMA_URL}')));
    expect(find.textContaining('프롬프트를 복사했어요'), findsOneWidget);
  });

  testWidgets('클립보드에서 붙여넣기', (tester) async {
    final env = _Env();
    env.clipboard = _bundleJson();
    await env.pump(tester);
    await tester.tap(find.byKey(const ValueKey('import-paste')));
    await tester.pumpAndSettle();
    expect(find.textContaining('schemaVersion'), findsOneWidget);
  });

  testWidgets('SESSION_OVERLAP: 모두 고르기 전엔 저장 불가, REPLACE는 경고, 요청에 해결이 담긴다', (tester) async {
    final env = _Env();
    final c = _conflict(
      'SESSION_OVERLAP',
      '/sessions/0',
      [ResolutionAction.SKIP, ResolutionAction.KEEP_BOTH, ResolutionAction.REPLACE],
      existing: {'date': '2026-01-01', 'exercises': 3},
    );
    env.repo.nextPreview = ImportPreview(valid: true, conflicts: [c], unresolved: [c.conflictId]);
    await env.pump(tester);
    await env.enter(tester, _bundleJson());
    await env.preview(tester);
    expect(find.text('세션이 겹쳐요'), findsOneWidget);
    expect(find.textContaining('date: 2026-01-01'), findsOneWidget);
    expect(env.saveEnabled(tester), isFalse);

    await env.choose(tester, c, ResolutionAction.REPLACE);
    expect(find.textContaining('되돌리기로 복원'), findsOneWidget);
    expect(env.saveEnabled(tester), isTrue);
    await env.save(tester);
    final r = env.repo.submitted.single.resolutions;
    expect(r.keys, [c.conflictId]);
    expect(r[c.conflictId]!.action, ResolutionAction.REPLACE);
  });

  testWidgets('UNKNOWN_EXERCISE: 후보로 MAP_TO, 다른 종목 선택, CREATE', (tester) async {
    final env = _Env();
    final c1 = _conflict(
      'UNKNOWN_EXERCISE',
      '/sessions/0/exercises/0',
      [ResolutionAction.MAP_TO, ResolutionAction.CREATE, ResolutionAction.SKIP],
      cands: const [ExerciseCandidate(exerciseId: 'ex-cand', nameKo: '인클라인 벤치', nameEn: 'Incline Bench')],
    );
    final c2 = _conflict('UNKNOWN_EXERCISE', '/sessions/0/exercises/1', [ResolutionAction.MAP_TO, ResolutionAction.CREATE, ResolutionAction.SKIP]);
    final c3 = _conflict('UNKNOWN_EXERCISE', '/sessions/0/exercises/2', [ResolutionAction.MAP_TO, ResolutionAction.CREATE, ResolutionAction.SKIP]);
    env.repo.nextPreview = ImportPreview(valid: true, conflicts: [c1, c2, c3]);
    await env.pump(tester);
    await env.enter(tester, _bundleJson());
    await env.preview(tester);

    // c1: 후보 선택
    await env.choose(tester, c1, ResolutionAction.MAP_TO);
    expect(find.text('인클라인 벤치'), findsOneWidget);
    expect(env.saveEnabled(tester), isFalse); // 아직 종목을 안 골랐다
    await tester.tap(find.byKey(const ValueKey('candidate-ex-cand')));
    await tester.pumpAndSettle();

    // c2: 다른 종목 선택(피커 → ex-bench)
    await env.choose(tester, c2, ResolutionAction.MAP_TO);
    await tester.tap(find.byKey(ValueKey('pick-other-${c2.conflictId}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('pick-bench'));
    await tester.pumpAndSettle();
    expect(find.text('벤치프레스'), findsOneWidget);

    // c3: 새 종목
    await env.choose(tester, c3, ResolutionAction.CREATE);
    expect(find.byKey(const ValueKey('create-confirm')), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('create-confirm'))).onPressed, isNull);
    await tester.tap(find.byKey(const ValueKey('create-type-DUMBBELL')));
    await tester.tap(find.byKey(const ValueKey('create-muscle-CHEST')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('create-confirm')));
    await tester.pumpAndSettle();

    expect(env.saveEnabled(tester), isTrue);
    await env.save(tester);
    final r = env.repo.submitted.single.resolutions;
    expect(r[c1.conflictId]!.action, ResolutionAction.MAP_TO);
    expect(r[c1.conflictId]!.exerciseId, 'ex-cand');
    expect(r[c2.conflictId]!.exerciseId, 'ex-bench');
    expect(r[c3.conflictId]!.action, ResolutionAction.CREATE);
    expect(r[c3.conflictId]!.exercise, {'type': 'DUMBBELL', 'primaryMuscle': 'CHEST'});
  });

  testWidgets('INSTANCE_NEEDS_VALUE: 제안값이 채워진 입력 → SET (kg)', (tester) async {
    final env = _Env();
    final c = _conflict(
      'INSTANCE_NEEDS_VALUE',
      '/startPrograms/0',
      [ResolutionAction.SET, ResolutionAction.SKIP],
      suggested: {
        'tm': {'squat': 100},
        'working': {'squat': 90},
      },
    );
    env.repo.nextPreview = ImportPreview(valid: true, conflicts: [c]);
    await env.pump(tester);
    await env.enter(tester, _bundleJson());
    await env.preview(tester);
    await env.choose(tester, c, ResolutionAction.SET);
    expect(find.widgetWithText(TextField, '100'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('set-tm-squat')), '110');
    await tester.tap(find.byKey(const ValueKey('set-confirm')));
    await tester.pumpAndSettle();
    await env.save(tester);
    final v = env.repo.submitted.single.resolutions[c.conflictId]!.value!;
    expect(v['tm'], {'squat': 110.0});
    expect(v['working'], {'squat': 90.0});
  });

  testWidgets('SET: lb 설정이면 입력을 kg로 바꿔 보낸다', (tester) async {
    final env = _Env(settings: const Settings(weightUnit: WeightUnit.LB));
    final c = _conflict(
      'INSTANCE_NEEDS_VALUE',
      '/startPrograms/0',
      [ResolutionAction.SET, ResolutionAction.SKIP],
      suggested: {
        'tm': {'squat': 100},
      },
    );
    env.repo.nextPreview = ImportPreview(valid: true, conflicts: [c]);
    await env.pump(tester);
    await env.enter(tester, _bundleJson());
    await env.preview(tester);
    await env.choose(tester, c, ResolutionAction.SET);
    await tester.enterText(find.byKey(const ValueKey('set-tm-squat')), '220');
    await tester.tap(find.byKey(const ValueKey('set-confirm')));
    await tester.pumpAndSettle();
    await env.save(tester);
    final v = env.repo.submitted.single.resolutions[c.conflictId]!.value!;
    expect((v['tm'] as Map)['squat'], closeTo(99.79, 0.01));
  });

  testWidgets('모두 건너뛰기는 모든 충돌을 SKIP으로(REPLACE 없음)', (tester) async {
    final env = _Env();
    final a = _conflict('SESSION_OVERLAP', '/sessions/0', [ResolutionAction.SKIP, ResolutionAction.REPLACE]);
    final b = _conflict('BODY_SAME_DAY', '/bodyMeasurements/0', [ResolutionAction.SKIP, ResolutionAction.KEEP_BOTH, ResolutionAction.REPLACE]);
    env.repo.nextPreview = ImportPreview(valid: true, conflicts: [a, b]);
    await env.pump(tester);
    await env.enter(tester, _bundleJson());
    await env.preview(tester);
    await tester.tap(find.byKey(const ValueKey('import-skip-all')));
    await tester.pumpAndSettle();
    expect(env.saveEnabled(tester), isTrue);
    await env.save(tester);
    final r = env.repo.submitted.single.resolutions;
    expect(r.values.map((e) => e.action).toSet(), {ResolutionAction.SKIP});
    expect(r.keys.toSet(), {a.conflictId, b.conflictId});
  });

  testWidgets('저장 중 새 충돌(needsResolution): 이미 고른 해결은 유지', (tester) async {
    final env = _Env();
    final a = _conflict('SESSION_OVERLAP', '/sessions/0', [ResolutionAction.SKIP, ResolutionAction.REPLACE]);
    final b = _conflict('PLAN_MISMATCH', '/sessions/1', [ResolutionAction.UNLINK, ResolutionAction.SKIP]);
    env.repo.nextPreview = ImportPreview(valid: true, conflicts: [a]);
    env.repo.nextOutcome = ImportOutcome.needsResolution(ImportPreview(valid: true, conflicts: [a, b], unresolved: [b.conflictId]));
    await env.pump(tester);
    await env.enter(tester, _bundleJson());
    await env.preview(tester);
    await env.choose(tester, a, ResolutionAction.REPLACE);
    await env.save(tester);

    // 새 충돌 b가 나타나고 a의 선택은 남아 있다
    expect(find.text('프로그램 회차가 맞지 않아요'), findsOneWidget);
    expect(env.saveEnabled(tester), isFalse);
    expect(env.repo.submitted, hasLength(1));
    await env.choose(tester, b, ResolutionAction.UNLINK);
    expect(env.saveEnabled(tester), isTrue);

    env.repo.nextOutcome = null;
    await env.save(tester);
    expect(env.repo.submitted, hasLength(2));
    final r = env.repo.submitted.last.resolutions;
    expect(r[a.conflictId]!.action, ResolutionAction.REPLACE);
    expect(r[b.conflictId]!.action, ResolutionAction.UNLINK);
    expect(find.text('가져오기 완료'), findsOneWidget);
  });

  testWidgets('400 VALIDATION_FAILED: details를 보여주고 저장 단계로 가지 않는다', (tester) async {
    final env = _Env();
    env.repo.previewError = const ApiException(
      statusCode: 400,
      code: 'VALIDATION_FAILED',
      message: 'bad',
      details: [(path: '/sessions/0/exercises/0/sets/1/reps', message: 'must be >= 0')],
    );
    await env.pump(tester);
    await env.enter(tester, _bundleJson());
    await env.preview(tester);
    expect(find.byKey(const ValueKey('import-validation')), findsOneWidget);
    expect(find.textContaining('/sessions/0/exercises/0/sets/1/reps: must be >= 0'), findsOneWidget);
    expect(find.byKey(const ValueKey('import-save')), findsNothing);
    // 입력은 그대로 남아 있다
    expect(find.byKey(const ValueKey('import-text')), findsOneWidget);
  });

  testWidgets('파일 선택: 450세션 묶음은 3조각으로 나눠 차례로 미리보기·저장', (tester) async {
    final env = _Env();
    env.pickedFile = Uint8List.fromList(utf8.encode(_bundleJson(sessions: 450)));
    env.repo.nextPreview = const ImportPreview(valid: true);
    await env.pump(tester);
    await tester.tap(find.byKey(const ValueKey('import-pick-file')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('import-clear-file')), findsOneWidget);
    await env.preview(tester);

    expect(find.text('1/3 묶음'), findsOneWidget);
    await env.save(tester);
    expect(find.text('2/3 묶음'), findsOneWidget);
    await env.save(tester);
    expect(find.text('3/3 묶음'), findsOneWidget);
    await env.save(tester);

    expect([for (final r in env.repo.submitted) (r.bundle['sessions'] as List).length], [200, 200, 50]);
    expect(find.text('가져오기 완료'), findsOneWidget);
    expect(find.text('세션 450'), findsOneWidget);
    expect(find.byKey(const ValueKey('import-history-2')), findsOneWidget);
  });
}
