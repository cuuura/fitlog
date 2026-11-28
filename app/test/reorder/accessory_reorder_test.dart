import 'package:drift/native.dart';
import 'package:fitlog/core/api/dto.dart';
import 'package:fitlog/core/api/program_dto.dart';
import 'package:fitlog/core/auth/auth_controller.dart';
import 'package:fitlog/core/clock.dart';
import 'package:fitlog/core/routes.dart';
import 'package:fitlog/core/settings/settings_controller.dart';
import 'package:fitlog/data/local/app_database.dart';
import 'package:fitlog/data/local/drift_repositories.dart';
import 'package:fitlog/data/memory/memory_repositories.dart';
import 'package:fitlog/data/providers.dart';
import 'package:fitlog/features/programs/instance_detail_page.dart';
import 'package:fitlog/features/session/session_controller.dart'
    show deviceTimezoneProvider;
import 'package:fitlog/l10n/gen/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../b3/fake_server.dart';
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
  'name': 'T',
  'lifts': {
    'squat': {
      'exercise': {'id': 'ex-a'},
    },
  },
  'days': [
    for (final k in ['A', 'B'])
      {
        'key': k,
        'name': 'Day $k',
        'exercises': [
          {
            'lift': 'squat',
            'sets': [
              {
                'count': 5,
                'reps': 5,
                'load': {'type': 'WORKING'},
              },
            ],
          },
        ],
      },
  ],
};

Accessory _acc(String id, String day, String ex, int pos) => Accessory(
  id: id,
  dayKey: day,
  exerciseId: ex,
  position: pos,
  sets: 3,
  reps: 10,
);

class _FailingPut extends MemoryProgramRepository {
  bool fail = false;
  @override
  Future<List<Accessory>> putAccessories(
    String instanceId,
    List<Accessory> list,
  ) async {
    if (fail) throw StateError('boom');
    return super.putAccessories(instanceId, list);
  }
}

Future<_FailingPut> _pump(WidgetTester tester, List<Accessory> initial) async {
  tester.view.physicalSize = const Size(800, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final programs = _FailingPut();
  programs.programs['p'] = Program(
    id: 'p',
    name: 'T',
    description: '',
    builtIn: false,
    dayCount: 2,
    definition: _def(),
  );
  programs.instances['i1'] = Instance(
    id: 'i1',
    programId: 'p',
    name: 'Inst',
    status: InstanceStatus.ACTIVE,
    skipPolicy: SkipPolicy.SHIFT,
    startDate: DateTime(2026, 11, 26),
    state: const InstanceState(
      tm: {'squat': 100},
      working: {'squat': 90},
      week: 1,
      cycle: 1,
      seq: 0,
    ),
  );
  programs.accessoryLists['i1'] = initial;
  final router = GoRouter(
    initialLocation: Routes.instanceDetail('i1'),
    routes: [
      GoRoute(
        path: '/instances/:id',
        builder: (_, s) =>
            InstanceDetailPage(instanceId: s.pathParameters['id']!),
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
        programRepositoryProvider.overrideWithValue(programs),
        planCacheProvider.overrideWithValue(MemoryPlanCache(programs)),
        exerciseRepositoryProvider.overrideWithValue(
          MemoryExerciseRepository(
            seed: [
              _ex('ex-a', 'AAA'),
              _ex('ex-b', 'BBB'),
              _ex('ex-c', 'CCC'),
              _ex('ex-d', 'DDD'),
            ],
          ),
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
        locale: const Locale('ko'),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return programs;
}

double _y(WidgetTester t, String id) =>
    t.getTopLeft(find.byKey(ValueKey('accessory-$id'))).dy;

Future<void> _drag(WidgetTester tester, String fromId, String toId) async {
  final handle = find.byKey(ValueKey('accessory-handle-$fromId'));
  await tester.ensureVisible(handle);
  await tester.pumpAndSettle();
  final from = tester.getCenter(handle);
  final to = tester.getCenter(find.byKey(ValueKey('accessory-$toId')));
  final g = await tester.startGesture(from);
  await tester.pump(const Duration(milliseconds: 100));
  final end = Offset(from.dx, to.dy + (to.dy > from.dy ? 40 : -40));
  for (var i = 1; i <= 10; i++) {
    await g.moveTo(Offset.lerp(from, end, i / 10)!);
    await tester.pump(const Duration(milliseconds: 50));
  }
  await g.up();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'dragging an accessory reorders only its own day and renumbers from 0',
    (tester) async {
      final programs = await _pump(tester, [
        _acc('a1', 'A', 'ex-a', 0),
        _acc('a2', 'A', 'ex-b', 1),
        _acc('a3', 'A', 'ex-c', 2),
        _acc('b1', 'B', 'ex-d', 0),
      ]);
      await _drag(tester, 'a1', 'a3');
      final saved = programs.accessoryLists['i1']!;
      final dayA = [
        for (final a in saved)
          if (a.dayKey == 'A') a,
      ]..sort((x, y) => x.position.compareTo(y.position));
      expect([for (final a in dayA) a.id], ['a2', 'a3', 'a1']);
      expect([for (final a in dayA) a.position], [0, 1, 2]);
      final b = saved.singleWhere((a) => a.dayKey == 'B');
      expect((b.id, b.position), ('b1', 0));
      // 화면 순서도 바뀐다.
      expect(_y(tester, 'a2'), lessThan(_y(tester, 'a3')));
      expect(_y(tester, 'a3'), lessThan(_y(tester, 'a1')));
    },
  );

  testWidgets('failed reorder keeps the old order and shows an error', (
    tester,
  ) async {
    final programs = await _pump(tester, [
      _acc('a1', 'A', 'ex-a', 0),
      _acc('a2', 'A', 'ex-b', 1),
    ]);
    programs.fail = true;
    await _drag(tester, 'a1', 'a2');
    expect(
      [for (final a in programs.accessoryLists['i1']!) a.id],
      ['a1', 'a2'],
    );
    expect(find.byType(SnackBar), findsOneWidget);
    expect(_y(tester, 'a1'), lessThan(_y(tester, 'a2')));
  });

  test('drift orders rows with equal position by id', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = DriftSessionRepository(
      db,
      SpySync(),
      clock: () => DateTime.utc(2026, 11, 26),
    );
    final at = DateTime.utc(2026, 11, 26);
    await db
        .into(db.sessions)
        .insert(
          SessionsCompanion.insert(
            id: 's1',
            startedAt: at,
            tz: 'Asia/Seoul',
            updatedAt: at,
          ),
        );
    // 일부러 id 와 삽입 순서를 엇갈리게 넣는다. position 은 모두 같다.
    for (final id in ['se-b', 'se-c', 'se-a']) {
      await db
          .into(db.sessionExercises)
          .insert(
            SessionExercisesCompanion.insert(
              id: id,
              sessionId: 's1',
              exerciseId: 'ex',
              position: 0,
              updatedAt: at,
            ),
          );
      for (final w in ['$id-w3', '$id-w1', '$id-w2']) {
        await db
            .into(db.workoutSets)
            .insert(
              WorkoutSetsCompanion.insert(
                id: w,
                sessionExerciseId: id,
                position: 0,
                updatedAt: at,
              ),
            );
      }
    }
    final s = (await repo.watchSession('s1').first)!;
    expect([for (final e in s.exercises) e.id], ['se-a', 'se-b', 'se-c']);
    expect(
      [for (final w in s.exercises.first.sets) w.id],
      ['se-a-w1', 'se-a-w2', 'se-a-w3'],
    );
  });
}
