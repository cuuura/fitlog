import 'package:fitlog/core/api/program_dto.dart';
import 'package:fitlog/core/auth/auth_controller.dart';
import 'package:fitlog/core/clock.dart';
import 'package:fitlog/core/routes.dart';
import 'package:fitlog/core/api/dto.dart';
import 'package:fitlog/core/settings/settings_controller.dart';
import 'package:fitlog/data/memory/memory_repositories.dart';
import 'package:fitlog/data/providers.dart';
import 'package:fitlog/features/programs/program_recommend.dart';
import 'package:fitlog/features/programs/programs_page.dart';
import 'package:fitlog/features/session/session_controller.dart'
    show deviceTimezoneProvider;
import 'package:fitlog/l10n/gen/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../support/fixed_providers.dart';

const _rules = ProgramRules(
  progress: '성공하면 올려요',
  failure: '못 하면 유지해요',
  deload: '막히면 낮춰요',
);

Program _p(
  String id,
  String name, {
  int days = 4,
  String? level,
  String? family,
  String? label,
  List<String> aka = const [],
  ProgramRules? rules,
  String? category = 'POWERLIFTING',
  bool builtIn = true,
}) => Program(
  id: id,
  name: name,
  description: '$name 설명',
  builtIn: builtIn,
  dayCount: days,
  category: category,
  level: level,
  family: family,
  variantLabel: label,
  aka: aka,
  rules: rules,
  definition: {
    'schemaVersion': 1,
    'name': name,
    'lifts': <String, Object?>{},
    'days': <Object?>[],
  },
);

List<Program> _seed() => [
  _p(
    'w-3',
    '5/3/1 초보',
    days: 3,
    level: 'BEGINNER',
    family: 'w',
    label: '3일',
    aka: ['오리지널 531'],
    rules: _rules,
  ),
  _p(
    'w-bbb',
    '5/3/1 BBB',
    days: 4,
    level: 'INTERMEDIATE',
    family: 'w',
    label: 'BBB',
    rules: _rules,
  ),
  _p(
    'n-4',
    'nSuns 4일',
    days: 4,
    level: 'INTERMEDIATE',
    family: 'n',
    label: '주 4일',
    aka: ['nSuns LP'],
  ),
  _p(
    'n-5',
    'nSuns 5일',
    days: 5,
    level: 'INTERMEDIATE',
    family: 'n',
    label: '주 5일',
  ),
  _p('solo', '혼자 카드', days: 3, level: 'MYSTERY', category: 'BODYWEIGHT'),
  _p('mine', '내 거', days: 3, builtIn: false, category: null),
];

Future<MemoryProgramRepository> _pump(
  WidgetTester t, {
  List<Program>? programs,
  RecommendInputs? rec,
  bool recFails = false,
  double scale = 1.0,
  Size size = const Size(800, 1600),
  List<Instance> instances = const [],
  Locale locale = const Locale('ko'),
}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  final repo = MemoryProgramRepository();
  for (final p in programs ?? _seed()) {
    repo.programs[p.id] = p;
  }
  for (final i in instances) {
    repo.instances[i.id] = i;
  }
  final router = GoRouter(
    initialLocation: Routes.programs,
    routes: [
      GoRoute(
        path: Routes.home,
        builder: (_, _) => const Scaffold(body: Text('home')),
      ),
      GoRoute(path: Routes.programs, builder: (_, _) => const ProgramsPage()),
      GoRoute(
        path: '/programs/:id/start',
        builder: (_, s) =>
            Scaffold(body: Text('start-${s.pathParameters['id']}')),
      ),
    ],
  );
  await t.pumpWidget(
    ProviderScope(
      overrides: [
        authControllerProvider.overrideWith(
          () => FixedAuthStatus(AuthStatus.signedIn),
        ),
        settingsProvider.overrideWith(() => FixedSettings(const Settings())),
        programRepositoryProvider.overrideWithValue(repo),
        planCacheProvider.overrideWithValue(MemoryPlanCache(repo)),
        exerciseRepositoryProvider.overrideWithValue(
          MemoryExerciseRepository(seed: []),
        ),
        sessionRepositoryProvider.overrideWithValue(MemorySessionRepository()),
        scheduledWorkoutRepositoryProvider.overrideWithValue(
          MemoryScheduledWorkoutRepository(),
        ),
        syncServiceProvider.overrideWithValue(NoopSyncService()),
        clockProvider.overrideWithValue(() => DateTime.utc(2026, 11, 26, 3)),
        deviceTimezoneProvider.overrideWithValue(() async => 'Asia/Seoul'),
        recommendInputsProvider.overrideWith((ref) async {
          if (recFails || rec == null) throw StateError('no data');
          return rec;
        }),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: [
          AppLocalizations.delegate,
          ...GlobalMaterialLocalizations.delegates,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        locale: locale,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
  await t.tap(find.byKey(const Key('programs-add')));
  await t.pumpAndSettle();
  return repo;
}

Finder _k(String k) => find.byKey(Key(k));

void main() {
  testWidgets('같은 family 는 카드 하나로 합쳐지고 단독 템플릿은 일반 카드', (t) async {
    await _pump(t);
    expect(_k('program-family-w'), findsOneWidget);
    expect(_k('program-family-n'), findsOneWidget);
    expect(_k('program-w-3'), findsNothing);
    expect(_k('program-solo'), findsOneWidget);
    // 접힌 묶음은 일수·수준 범위
    expect(find.text('주 3~4일 · 입문~중급 · 파워리프팅'), findsOneWidget);
    // 모르는 수준은 숨김
    expect(find.text('주 3일 · 맨몸·홈트'), findsOneWidget);
  });

  testWidgets('구성 칩으로 변형을 바꾸면 일수·수준·CTA·규칙이 따라 바뀐다', (t) async {
    await _pump(t);
    await t.tap(_k('program-family-toggle-w'));
    await t.pumpAndSettle();
    expect(_k('program-variant-w-3'), findsOneWidget);
    expect(_k('program-variant-w-bbb'), findsOneWidget);
    expect(
      t.getSize(_k('program-variant-w-3')).height,
      greaterThanOrEqualTo(48),
    );
    expect(_k('program-pick-w-3'), findsOneWidget);
    expect(find.text('주 3일 · 입문 · 파워리프팅'), findsOneWidget);
    expect(find.text('흔히 부르는 이름: 오리지널 531'), findsOneWidget);

    await t.tap(_k('program-variant-w-bbb'));
    await t.pumpAndSettle();
    expect(_k('program-pick-w-3'), findsNothing);
    expect(_k('program-pick-w-bbb'), findsOneWidget);
    expect(find.text('주 4일 · 중급 · 파워리프팅'), findsOneWidget);
    expect(find.textContaining('오리지널'), findsNothing);

    await t.tap(_k('program-pick-w-bbb'));
    await t.pumpAndSettle();
    expect(find.text('start-w-bbb'), findsOneWidget);
  });

  testWidgets('필터 후 남은 변형만 칩으로 보이고, 하나만 남으면 일반 카드', (t) async {
    await _pump(t);
    await t.tap(_k('programs-days-3'));
    await t.pumpAndSettle();
    expect(_k('program-family-w'), findsNothing);
    expect(_k('program-w-3'), findsOneWidget);
    expect(_k('program-family-n'), findsNothing);
    await t.tap(_k('programs-days-all'));
    await t.pumpAndSettle();
    await t.tap(_k('programs-days-5'));
    await t.pumpAndSettle();
    expect(_k('program-n-5'), findsOneWidget);
    await t.tap(_k('programs-days-4'));
    await t.pumpAndSettle();
    expect(_k('program-family-w'), findsNothing);
    expect(_k('program-w-bbb'), findsOneWidget);
    expect(_k('program-n-4'), findsOneWidget);
  });

  testWidgets('수준 필터: 입문만, 중급만, 모르는 수준은 어느 칩에도 안 잡힌다', (t) async {
    await _pump(t);
    await t.tap(_k('programs-level-BEGINNER'));
    await t.pumpAndSettle();
    expect(_k('program-w-3'), findsOneWidget);
    expect(_k('program-family-n'), findsNothing);
    expect(_k('program-solo'), findsNothing);
    await t.tap(_k('programs-level-INTERMEDIATE'));
    await t.pumpAndSettle();
    expect(_k('program-w-bbb'), findsOneWidget);
    expect(_k('program-family-n'), findsOneWidget);
    await t.tap(_k('programs-level-ADVANCED'));
    await t.pumpAndSettle();
    expect(_k('programs-empty'), findsOneWidget);
    await t.tap(_k('programs-level-all'));
    await t.pumpAndSettle();
    expect(_k('program-solo'), findsOneWidget);
  });

  testWidgets('검색은 aka 도 찾는다', (t) async {
    await _pump(t);
    await t.enterText(_k('programs-search'), '오리지널');
    await t.pumpAndSettle();
    expect(_k('program-w-3'), findsOneWidget);
    expect(_k('program-n-4'), findsNothing);
    await t.enterText(_k('programs-search'), 'NSUNS lp');
    await t.pumpAndSettle();
    expect(_k('program-n-4'), findsOneWidget);
    expect(_k('program-n-5'), findsNothing);
  });

  testWidgets('펼친 카드에 쉬운 말 규칙 세 줄, rules 없으면 숨김', (t) async {
    await _pump(t);
    await t.tap(_k('program-family-toggle-w'));
    await t.pumpAndSettle();
    expect(_k('program-rules-w-3'), findsOneWidget);
    expect(find.textContaining('오르면'), findsOneWidget);
    expect(find.textContaining('성공하면 올려요'), findsOneWidget);
    expect(find.textContaining('실패하면'), findsOneWidget);
    expect(find.textContaining('낮출 때'), findsOneWidget);
    await t.tap(_k('program-family-toggle-n'));
    await t.pumpAndSettle();
    expect(_k('program-rules-n-4'), findsNothing);
    expect(find.textContaining('오르면'), findsNothing);
  });

  testWidgets('진행 중 칩은 해당 변형 칩에 붙는다', (t) async {
    await _pump(
      t,
      instances: [
        Instance(
          id: 'i1',
          programId: 'w-bbb',
          name: 'x',
          status: InstanceStatus.ACTIVE,
          skipPolicy: SkipPolicy.SHIFT,
          startDate: DateTime(2026, 11, 26),
          state: const InstanceState(),
        ),
      ],
    );
    // 접힌 묶음: 하나라도 진행 중이면 표시
    expect(
      find.descendant(of: _k('program-family-w'), matching: find.text('진행 중')),
      findsOneWidget,
    );
    await t.tap(_k('program-family-toggle-w'));
    await t.pumpAndSettle();
    expect(
      find.descendant(
        of: _k('program-variant-w-bbb'),
        matching: find.textContaining('진행 중'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: _k('program-variant-w-3'),
        matching: find.textContaining('진행 중'),
      ),
      findsNothing,
    );
  });

  group('추천', () {
    testWidgets('필터가 없으면 위에 2장과 이유, 전체에서는 빠진다', (t) async {
      await _pump(t, rec: const RecommendInputs(0, false));
      expect(_k('program-rec-title'), findsOneWidget);
      expect(find.textContaining('기록이 거의 없어서'), findsOneWidget);
      expect(_k('program-rec-w-3'), findsOneWidget);
      expect(_k('program-rec-solo'), findsNothing); // 수준 모름은 추천 안 함
      expect(_k('program-rec-n-4'), findsOneWidget); // 같은 묶음은 하나만, 다른 묶음이 두 번째
      expect(_k('program-family-w'), findsNothing);
      await t.tap(_k('program-rec-toggle-w-3'));
      await t.pumpAndSettle();
      expect(_k('program-pick-w-3'), findsOneWidget);
      await t.tap(_k('program-variant-w-bbb'));
      await t.pumpAndSettle();
      await t.tap(_k('program-pick-w-bbb'));
      await t.pumpAndSettle();
      expect(find.text('start-w-bbb'), findsOneWidget);
    });

    testWidgets('검색어나 필터가 걸리면 숨김, 내 프로그램에서도 숨김', (t) async {
      await _pump(t, rec: const RecommendInputs(0, false));
      await t.enterText(_k('programs-search'), '5/3/1');
      await t.pumpAndSettle();
      expect(_k('program-rec-title'), findsNothing);
      await t.enterText(_k('programs-search'), '');
      await t.pumpAndSettle();
      expect(_k('program-rec-title'), findsOneWidget);
      await t.tap(_k('programs-level-BEGINNER'));
      await t.pumpAndSettle();
      expect(_k('program-rec-title'), findsNothing);
      await t.tap(_k('programs-level-all'));
      await t.pumpAndSettle();
      await t.tap(
        find.descendant(
          of: _k('program-add-segments'),
          matching: find.text('내 프로그램'),
        ),
      );
      await t.pumpAndSettle();
      expect(_k('program-rec-title'), findsNothing);
    });

    testWidgets('진행 중인 템플릿은 추천에서 빠진다', (t) async {
      await _pump(
        t,
        rec: const RecommendInputs(0, false),
        instances: [
          Instance(
            id: 'i1',
            programId: 'w-3',
            name: 'x',
            status: InstanceStatus.ACTIVE,
            skipPolicy: SkipPolicy.SHIFT,
            startDate: DateTime(2026, 11, 26),
            state: const InstanceState(),
          ),
        ],
      );
      expect(_k('program-rec-w-3'), findsNothing);
    });

    testWidgets('읽기에 실패하면 추천만 숨기고 시트는 정상', (t) async {
      await _pump(t, recFails: true);
      expect(_k('program-rec-title'), findsNothing);
      expect(_k('program-family-w'), findsOneWidget);
    });
  });

  for (final scale in [1.3, 2.0]) {
    testWidgets('360x780 글씨 $scale배: 묶음·추천·규칙이 넘치지 않는다', (t) async {
      await _pump(
        t,
        rec: const RecommendInputs(4, true),
        scale: scale,
        size: const Size(360, 780),
      );
      expect(t.takeException(), isNull);
      await t.tap(
        find
            .byWidgetPredicate(
              (w) =>
                  w.key is ValueKey<String> &&
                  (w.key as ValueKey<String>).value.startsWith(
                    'program-rec-toggle-',
                  ),
            )
            .first,
      );
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      final pick = find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key as ValueKey<String>).value.startsWith('program-pick-'),
      );
      expect(t.getSize(pick.first).height, greaterThanOrEqualTo(48));
      await t.drag(_k('program-add-list'), const Offset(0, -900));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    });

    testWidgets('360x780 글씨 $scale배(영어): 변형 칩과 규칙', (t) async {
      await _pump(
        t,
        scale: scale,
        size: const Size(360, 780),
        locale: const Locale('en'),
      );
      await t.tap(_k('program-family-toggle-w'));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(_k('program-rules-w-3'), findsOneWidget);
    });
  }
}
