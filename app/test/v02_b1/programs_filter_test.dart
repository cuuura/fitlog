import 'package:fitlog/core/api/dto.dart';
import 'package:fitlog/core/api/program_dto.dart';
import 'package:fitlog/core/auth/auth_controller.dart';
import 'package:fitlog/core/clock.dart';
import 'package:fitlog/core/routes.dart';
import 'package:fitlog/core/settings/settings_controller.dart';
import 'package:fitlog/data/memory/memory_repositories.dart';
import 'package:fitlog/data/providers.dart';
import 'package:fitlog/features/programs/program_detail_page.dart';
import 'package:fitlog/features/programs/programs_page.dart';
import 'package:fitlog/features/session/session_controller.dart'
    show deviceTimezoneProvider;
import 'package:fitlog/l10n/gen/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../support/fixed_providers.dart';

Program _p(
  String id,
  String name, {
  String? category,
  bool builtIn = true,
  String? description,
  String? templateKey,
}) => Program(
  id: id,
  name: name,
  description: description,
  templateKey: templateKey,
  category: category,
  builtIn: builtIn,
  dayCount: 4,
  definition: {
    'schemaVersion': 1,
    'name': name,
    'lifts': <String, Object?>{},
    'days': <Object?>[],
  },
);

Future<MemoryProgramRepository> _pump(
  WidgetTester tester,
  List<Program> programs, {
  Locale locale = const Locale('ko'),
  String initial = '/programs',
}) async {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final repo = MemoryProgramRepository();
  for (final p in programs) {
    repo.programs[p.id] = p;
  }
  final router = GoRouter(
    initialLocation: initial,
    routes: [
      GoRoute(
        path: Routes.home,
        builder: (_, _) => const Scaffold(body: Text('home-page')),
      ),
      GoRoute(path: Routes.programs, builder: (_, _) => const ProgramsPage()),
      GoRoute(
        path: '/programs/:id',
        builder: (_, s) =>
            ProgramDetailPage(programId: s.pathParameters['id']!),
      ),
    ],
  );
  await tester.pumpWidget(
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
      ],
      child: MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: [
          AppLocalizations.delegate,
          ...GlobalMaterialLocalizations.delegates,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        locale: locale,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return repo;
}

Future<void> _seg(WidgetTester tester, String label) async {
  await tester.tap(
    find.descendant(
      of: find.byKey(const Key('programs-segments')),
      matching: find.text(label),
    ),
  );
  await tester.pumpAndSettle();
}

final _templates = [
  _p(
    't-pb',
    'GZCLP 변형',
    category: 'POWERBUILDING',
    description: 'Cody Lefever GZCLP',
    templateKey: 'gzclp',
  ),
  _p(
    't-pl',
    '5x5 스트렝스',
    category: 'POWERLIFTING',
    description: 'StrongLifts 5x5',
    templateKey: 'sl5x5',
  ),
  _p(
    't-pl2',
    '텍사스 메소드',
    category: 'POWERLIFTING',
    description: 'Texas method',
    templateKey: 'texas',
  ),
  _p('t-x', '미분류', category: 'FUTURE_THING'),
];

bool _selected(WidgetTester tester, String key) =>
    tester.widget<FilterChip>(find.byKey(Key(key))).selected;

void main() {
  group('DTO category', () {
    Map<String, Object?> base() => {
      'id': 'a',
      'name': 'n',
      'builtIn': true,
      'dayCount': 3,
    };
    test(
      '없으면 null',
      () => expect(ProgramSummary.fromJson(base()).category, isNull),
    );
    test('모르는 값도 문자열로 유지', () {
      expect(
        ProgramSummary.fromJson({...base(), 'category': 'SOMETHING_NEW'})
            .category,
        'SOMETHING_NEW',
      );
      expect(
        ProgramSummary.fromJson({...base(), 'category': null}).category,
        isNull,
      );
    });
    test('상세에도 전달', () {
      final p = Program.fromJson({
        ...base(),
        'category': 'POWERLIFTING',
        'definition': <String, Object?>{},
      });
      expect(p.category, 'POWERLIFTING');
    });
  });

  group('프로그램 필터', () {
    testWidgets('템플릿: 고정 칩 3개만, 선택 칩은 있을 때만', (tester) async {
      await _pump(tester, _templates);
      await _seg(tester, '템플릿');
      expect(find.byKey(const Key('programs-search')), findsOneWidget);
      for (final k in [
        'all',
        'BODYBUILDING',
        'POWERBUILDING',
        'POWERLIFTING',
      ]) {
        expect(find.byKey(Key('programs-type-$k')), findsOneWidget, reason: k);
      }
      expect(
        find.byKey(const Key('programs-type-GENERAL_STRENGTH')),
        findsNothing,
      );
      expect(find.byKey(const Key('programs-type-BODYWEIGHT')), findsNothing);
    });

    testWidgets('선택 칩은 해당 카테고리가 있으면 나타난다', (tester) async {
      await _pump(tester, [
        ..._templates,
        _p('t-bw', '맨몸 루틴', category: 'BODYWEIGHT'),
      ]);
      await _seg(tester, '템플릿');
      expect(find.byKey(const Key('programs-type-BODYWEIGHT')), findsOneWidget);
      expect(
        find.byKey(const Key('programs-type-GENERAL_STRENGTH')),
        findsNothing,
      );
    });

    testWidgets('진행 중 탭에는 검색/칩이 없다', (tester) async {
      await _pump(tester, _templates);
      expect(find.byKey(const Key('programs-search')), findsNothing);
      expect(find.byKey(const Key('programs-type-filter')), findsNothing);
    });

    testWidgets('타입 선택으로 거르고 다시 누르면 전체', (tester) async {
      await _pump(tester, _templates);
      await _seg(tester, '템플릿');
      expect(find.byKey(const Key('program-t-pb')), findsOneWidget);
      expect(find.text('주 4일 · 파워빌딩'), findsOneWidget);
      // 알 수 없는 카테고리는 라벨 없음
      expect(
        find.descendant(
          of: find.byKey(const Key('program-t-x')),
          matching: find.text('주 4일'),
        ),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('programs-type-POWERLIFTING')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('program-t-pl')), findsOneWidget);
      expect(find.byKey(const Key('program-t-pl2')), findsOneWidget);
      expect(find.byKey(const Key('program-t-pb')), findsNothing);
      expect(_selected(tester, 'programs-type-POWERLIFTING'), isTrue);

      await tester.tap(find.byKey(const Key('programs-type-POWERLIFTING')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('program-t-pb')), findsOneWidget);
      expect(_selected(tester, 'programs-type-all'), isTrue);
    });

    testWidgets('이름/설명/templateKey 검색, 대소문자·공백 무시', (tester) async {
      await _pump(tester, _templates);
      await _seg(tester, '템플릿');
      await tester.enterText(
        find.byKey(const Key('programs-search')),
        '  텍사스 ',
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('program-t-pl2')), findsOneWidget);
      expect(find.byKey(const Key('program-t-pl')), findsNothing);

      await tester.enterText(
        find.byKey(const Key('programs-search')),
        'stronglifts',
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('program-t-pl')), findsOneWidget);
      expect(find.byKey(const Key('program-t-pl2')), findsNothing);

      await tester.enterText(find.byKey(const Key('programs-search')), 'GZCLP');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('program-t-pb')), findsOneWidget);

      await tester.enterText(find.byKey(const Key('programs-search')), 'sl5x5');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('program-t-pl')), findsOneWidget);
    });

    testWidgets('타입 + 검색 조합, 지우기 버튼', (tester) async {
      await _pump(tester, _templates);
      await _seg(tester, '템플릿');
      expect(find.byKey(const Key('programs-search-clear')), findsNothing);
      await tester.tap(find.byKey(const Key('programs-type-POWERLIFTING')));
      await tester.enterText(find.byKey(const Key('programs-search')), 'texas');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('program-t-pl2')), findsOneWidget);
      expect(find.byKey(const Key('program-t-pl')), findsNothing);

      await tester.tap(find.byKey(const Key('programs-search-clear')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('program-t-pl')), findsOneWidget);
      expect(find.byKey(const Key('program-t-pb')), findsNothing);
    });

    testWidgets('빈 결과 메시지', (tester) async {
      await _pump(tester, _templates);
      await _seg(tester, '템플릿');
      await tester.tap(find.byKey(const Key('programs-type-BODYBUILDING')));
      await tester.pumpAndSettle();
      expect(find.text('이 타입의 프로그램은 아직 없어요.'), findsOneWidget);

      await tester.tap(find.byKey(const Key('programs-type-all')));
      await tester.enterText(find.byKey(const Key('programs-search')), 'zzzz');
      await tester.pumpAndSettle();
      expect(find.text('찾는 프로그램이 없어요.'), findsOneWidget);
      // 비어 있어도 당겨서 새로고침 가능
      expect(find.byType(RefreshIndicator), findsOneWidget);
    });

    testWidgets('내 프로그램: 카테고리가 없으면 칩 행 숨김, 있으면 표시', (tester) async {
      await _pump(tester, [..._templates, _p('m1', '내 루틴', builtIn: false)]);
      await _seg(tester, '내 프로그램');
      expect(find.byKey(const Key('programs-search')), findsOneWidget);
      expect(find.byKey(const Key('programs-type-filter')), findsNothing);
      expect(find.byKey(const Key('program-m1')), findsOneWidget);
    });

    testWidgets('내 프로그램에 카테고리가 있으면 칩 표시 + 세그먼트 전환 시 검색어 유지/타입 리셋', (
      tester,
    ) async {
      await _pump(tester, [
        ..._templates,
        _p('m1', '내 루틴', builtIn: false, category: 'BODYWEIGHT'),
      ]);
      await _seg(tester, '템플릿');
      await tester.enterText(find.byKey(const Key('programs-search')), '루틴');
      await tester.pumpAndSettle();
      await _seg(tester, '내 프로그램');
      expect(find.byKey(const Key('programs-type-filter')), findsOneWidget);
      expect(find.byKey(const Key('programs-type-BODYWEIGHT')), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('programs-search')))
            .controller!
            .text,
        '루틴',
      );

      await tester.tap(find.byKey(const Key('programs-type-BODYWEIGHT')));
      await tester.pumpAndSettle();
      await _seg(tester, '템플릿'); // 템플릿에는 맨몸 칩이 없다
      await tester.enterText(find.byKey(const Key('programs-search')), '');
      await tester.pumpAndSettle();
      expect(_selected(tester, 'programs-type-all'), isTrue);
      expect(find.byKey(const Key('program-t-pb')), findsOneWidget);
    });

    testWidgets('영어 문구', (tester) async {
      await _pump(tester, _templates, locale: const Locale('en'));
      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('programs-segments')),
          matching: find.text('Templates'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Search by name'), findsOneWidget);
      expect(find.text('All'), findsOneWidget);
      expect(find.text('Powerlifting'), findsWidgets);
      await tester.tap(find.byKey(const Key('programs-type-BODYBUILDING')));
      await tester.pumpAndSettle();
      expect(find.text('No programs of this type yet.'), findsOneWidget);
    });

    testWidgets('상세 화면에 타입 라벨', (tester) async {
      await _pump(tester, _templates, initial: '/programs/t-pl');
      expect(find.byKey(const Key('program-category')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('program-category')),
          matching: find.text('파워리프팅'),
        ),
        findsOneWidget,
      );
    });
  });
}
