// 예정 운동(LOG-13) 화면·세션: 홈 카드, 홈 로딩·오류, 수정 화면, 판정 없음, 휴식 타이머, 가져오기 묶음 분할.
import 'package:fitlog/core/api/dto.dart';
import 'package:fitlog/core/routes.dart';
import 'package:fitlog/features/home/home_page.dart';
import 'package:fitlog/features/importing/import_logic.dart';
import 'package:fitlog/features/rest_timer/rest_timer_controller.dart';
import 'package:fitlog/features/scheduled/scheduled_edit_page.dart';
import 'package:fitlog/features/scheduled/scheduled_list_page.dart';
import 'package:fitlog/features/session/session_controller.dart';
import 'package:fitlog/domain/repositories.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:fitlog/l10n/gen/app_localizations.dart';
import 'package:fitlog/features/scheduled/scheduled_providers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../b2/harness.dart';

Future<void> settle(WidgetTester t, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

ScheduledWorkout sw({
  String id = 'sw1',
  String date = '2026-11-26',
  String title = 'B-2 하체 2',
  int? restSec = 180,
}) => ScheduledWorkout(
  id: id,
  plannedDate: date,
  title: title,
  items: [
    ScheduledItem(
      exerciseId: squat.id,
      note: '벨트',
      restSec: restSec,
      sets: const [
        ScheduledSet(targetWeightKg: 80, targetReps: 12, targetRepsMax: 15, targetRir: 3),
        ScheduledSet(targetWeightKg: 80, targetReps: 12, targetRepsMax: 15, targetRir: 3),
      ],
    ),
    ScheduledItem(exerciseId: dbPress.id, sets: const [ScheduledSet(targetWeightKg: 20, targetReps: 10)]),
  ],
);

List<RouteBase> schedRoutes() => [
  GoRoute(path: Routes.scheduled, builder: (_, _) => const ScheduledListPage()),
  GoRoute(path: Routes.scheduledNew, builder: (_, s) => ScheduledEditPage(initialDate: s.uri.queryParameters['date'])),
  GoRoute(path: '/scheduled/:id/edit', builder: (_, s) => ScheduledEditPage(scheduledId: s.pathParameters['id']!)),
];

Future<Session> active(Harness h) => h.sessions.watchActiveSession().first.then((s) => s!);

void main() {
  group('홈 카드', () {
    testWidgets('오늘 예정 카드: 제목·종목/세트 수·이름·시작 -> 로컬 세션이 연결되어 시작', (t) async {
      final h = Harness();
      await h.scheduled.upsert(sw());
      await h.pump(t);
      await settle(t);

      expect(find.byKey(const Key('sched-today-title')), findsOneWidget);
      expect(find.text('오늘 예정'), findsOneWidget);
      expect(find.byKey(const Key('sched-title-sw1')), findsOneWidget);
      expect(find.text('B-2 하체 2'), findsOneWidget);
      expect(find.text('종목 2개 · 3세트'), findsOneWidget);
      expect(find.text('스쿼트'), findsOneWidget);
      expect(find.text('덤벨 프레스'), findsOneWidget);
      final start = find.byKey(const Key('sched-start-sw1'));
      expect(find.descendant(of: start, matching: find.text('시작')), findsOneWidget);

      await t.tap(start);
      await settle(t);
      final s = await active(h);
      expect(s.scheduledWorkoutId, 'sw1');
      expect(s.programInstanceId, isNull);
      expect(s.exercises.first.note, '벨트');
      expect(s.exercises.first.sets.first.targetRestSec, 180);
      // 세션 화면: 목표가 "80kg × 12~15 · RIR 3"로 보인다.
      expect(find.byKey(Key('target-${s.exercises.first.sets.first.id}')), findsOneWidget);
      expect(find.text('80kg × 12~15 · RIR 3'), findsOneWidget);
    });

    testWidgets('진행 중이면 "이어서", 끝나면 카드가 사라진다', (t) async {
      final h = Harness();
      await h.scheduled.upsert(sw());
      final s = await h.sessions.startSession(tz: 'Asia/Seoul', scheduled: sw());
      await h.pump(t);
      await settle(t);
      expect(find.descendant(of: find.byKey(const Key('sched-start-sw1')), matching: find.text('이어서')), findsOneWidget);
      expect(find.byKey(const Key('sched-chip-progress-sw1')), findsOneWidget);
      await h.sessions.endSession(s.id);
      await settle(t);
      expect(find.byKey(const Key('sched-card-sw1')), findsNothing);
    });

    testWidgets('지난 예정(7일 안 PLANNED)은 "지난 예정" 구역과 날짜 칩, 7일 넘으면 숨김, 미래도 숨김', (t) async {
      final h = Harness();
      await h.scheduled.upsert(sw(id: 'late', date: '2026-11-22', title: '밀린 운동'));
      await h.scheduled.upsert(sw(id: 'old', date: '2026-11-10', title: '아주 오래전'));
      await h.scheduled.upsert(sw(id: 'next', date: '2026-11-28', title: '모레'));
      await h.pump(t);
      await settle(t);
      expect(find.byKey(const Key('sched-late-title')), findsOneWidget);
      expect(find.byKey(const Key('sched-chip-late-late')), findsOneWidget);
      expect(find.text('11월 22일 예정'), findsOneWidget);
      expect(find.byKey(const Key('sched-card-old')), findsNothing);
      expect(find.byKey(const Key('sched-card-next')), findsNothing);
      expect(find.byKey(const Key('sched-today-title')), findsNothing);
    });

    testWidgets('메뉴: 건너뛰기하면 카드가 빠지고, 삭제는 앱 안 확인창을 거친다', (t) async {
      final h = Harness();
      await h.scheduled.upsert(sw());
      await h.scheduled.upsert(sw(id: 'sw2', title: '두 번째'));
      await h.pump(t);
      await settle(t);

      await t.tap(find.byKey(const Key('sched-menu-sw1')));
      await settle(t);
      expect(find.byKey(const Key('sched-menu-edit-sw1')), findsOneWidget);
      expect(find.text('건너뛰기 취소'), findsNothing);
      await t.tap(find.byKey(const Key('sched-menu-skip-sw1')));
      await settle(t);
      expect(find.byKey(const Key('sched-card-sw1')), findsNothing);
      expect((await h.scheduled.byId('sw1'))!.skippedAt, isNotNull);

      await t.tap(find.byKey(const Key('sched-menu-sw2')));
      await settle(t);
      await t.tap(find.byKey(const Key('sched-menu-delete-sw2')));
      await settle(t);
      expect(find.text("'두 번째' 예정 삭제"), findsOneWidget);
      expect(find.text('이미 한 운동 기록은 그대로 남아요.'), findsOneWidget);
      await t.tap(find.text('취소'));
      await settle(t);
      expect(await h.scheduled.byId('sw2'), isNotNull);
      await t.tap(find.byKey(const Key('sched-menu-sw2')));
      await settle(t);
      await t.tap(find.byKey(const Key('sched-menu-delete-sw2')));
      await settle(t);
      await t.tap(find.byKey(const Key('sched-delete-confirm')));
      await settle(t);
      expect(await h.scheduled.byId('sw2'), isNull);
      expect(find.byKey(const Key('sched-card-sw2')), findsNothing);
    });

    testWidgets('진행 중인 다른 세션이 있으면(비어 있지 않음) 안내만 하고 시작하지 않는다', (t) async {
      final h = Harness();
      final free = await h.sessions.startSession(tz: 'Asia/Seoul');
      final se = await h.sessions.addExercise(free.id, squat.id);
      await h.sessions.addSet(se.id, const WorkoutSet(id: 'w1', position: 0, weightKg: 50, reps: 5));
      await h.scheduled.upsert(sw());
      await h.pump(t);
      await settle(t);
      await t.tap(find.byKey(const Key('sched-start-sw1')));
      await settle(t);
      expect(find.text('진행 중인 세션을 끝내야 시작할 수 있어요'), findsOneWidget);
      expect((await active(h)).scheduledWorkoutId, isNull);
    });

    testWidgets('모두 보기·만들기 진입', (t) async {
      final h = Harness();
      await h.scheduled.upsert(sw(id: 'next', date: '2026-12-02', title: '다음 주'));
      await h.scheduled.upsert(sw(id: 'old', date: '2026-11-10', title: '지난 운동'));
      await h.pump(t, extraRoutes: schedRoutes());
      await settle(t);
      await t.tap(find.byKey(const Key('sched-view-all')));
      await settle(t);
      expect(find.text('다가오는 예정'), findsOneWidget);
      expect(find.text('다음 주'), findsOneWidget);
      expect(find.text('지난 운동'), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('sched-status-old')), matching: find.text('지난 예정')), findsOneWidget);
      await t.tap(find.byKey(const Key('sched-list-add')));
      await settle(t);
      expect(find.byKey(const Key('sched-title')), findsOneWidget);
    });
  });

  group('홈 로딩·오류', () {
    Future<void> pumpHome(WidgetTester t, Harness h, List<Override> extra) async {
      t.view.physicalSize = const Size(800, 1400);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      final router = GoRouter(routes: [GoRoute(path: '/', builder: (_, _) => const HomePage())]);
      await t.pumpWidget(
        ProviderScope(
          overrides: [...h.overrides, ...extra],
          child: MaterialApp.router(
            routerConfig: router,
            localizationsDelegates: [AppLocalizations.delegate, ...GlobalMaterialLocalizations.delegates],
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('ko'),
          ),
        ),
      );
      await settle(t);
    }

    testWidgets('계획 로딩 실패: 오류 문구와 다시 시도, 시도하면 복구된다', (t) async {
      final h = Harness();
      var fail = true;
      await pumpHome(t, h, [
        planItemsProvider.overrideWith((ref) => fail ? Stream<List<InstancePlan>>.error(Exception('x')) : Stream.value(const [])),
      ]);
      expect(find.byKey(const Key('home-load-error')), findsOneWidget);
      expect(find.text('계획을 불러오지 못했어요'), findsOneWidget);
      fail = false;
      await t.tap(find.byKey(const Key('home-load-retry')));
      await settle(t);
      expect(find.byKey(const Key('home-load-error')), findsNothing);
      expect(find.byKey(const Key('home-plan-loading')), findsNothing);
    });

    testWidgets('예정 운동 로딩 실패도 같은 오류와 다시 시도', (t) async {
      final h = Harness();
      var fail = true;
      await pumpHome(t, h, [
        scheduledLinksProvider.overrideWith(
          (ref) => fail ? Stream<List<ScheduledLink>>.error(Exception('x')) : Stream.value(const []),
        ),
      ]);
      expect(find.text('계획을 불러오지 못했어요'), findsOneWidget);
      fail = false;
      await t.tap(find.byKey(const Key('home-load-retry')));
      await settle(t);
      expect(find.byKey(const Key('home-load-error')), findsNothing);
    });

    testWidgets('로딩 중에는 진행 표시', (t) async {
      final h = Harness();
      await pumpHome(t, h, [planItemsProvider.overrideWith((ref) => const Stream<List<InstancePlan>>.empty())]);
      // 스트림이 값을 내지 않는 동안 로딩.
      expect(find.byKey(const Key('home-plan-loading')), findsOneWidget);
    });
  });

  group('수정 화면', () {
    testWidgets('만들기: 검증 -> 종목 추가 -> 세트 목표 입력 -> 저장', (t) async {
      final h = Harness();
      await h.pump(t, initial: '${Routes.scheduledNew}?date=2026-12-01', extraRoutes: schedRoutes());
      await settle(t);
      expect(find.textContaining('2026-12-01'), findsOneWidget);

      await t.tap(find.byKey(const Key('sched-save')));
      await settle(t);
      expect(find.text('제목을 입력해 주세요'), findsOneWidget);

      await t.enterText(find.byKey(const Key('sched-title')), '하체 데이');
      await t.tap(find.byKey(const Key('sched-save')));
      await settle(t);
      expect(find.text('종목을 하나 이상 추가해 주세요'), findsOneWidget);

      await t.ensureVisible(find.byKey(const Key('sched-add-exercise')));
      await t.tap(find.byKey(const Key('sched-add-exercise')));
      await settle(t);
      await t.tap(find.byKey(Key('exercise-${squat.id}')));
      await settle(t);
      expect(find.byKey(const Key('sched-item-0')), findsOneWidget);

      await t.enterText(find.byKey(const Key('sched-rest-0')), '150');
      await t.enterText(find.byKey(const Key('sched-w-0-0')), '80');
      await t.enterText(find.byKey(const Key('sched-r-0-0')), '12');
      await t.enterText(find.byKey(const Key('sched-rm-0-0')), '10'); // 최대 < 횟수
      await t.ensureVisible(find.byKey(const Key('sched-save')));
      await t.tap(find.byKey(const Key('sched-save')));
      await settle(t);
      expect(find.text('최대 횟수는 횟수 이상이어야 해요'), findsOneWidget);
      await t.enterText(find.byKey(const Key('sched-rm-0-0')), '15');
      await t.enterText(find.byKey(const Key('sched-rir-0-0')), '3');
      await t.ensureVisible(find.byKey(const Key('sched-add-set-0')));
      await t.tap(find.byKey(const Key('sched-add-set-0'))); // 마지막 세트 값 복사
      await settle(t);
      expect(t.widget<TextField>(find.byKey(const Key('sched-w-0-1'))).controller!.text, '80');
      await t.ensureVisible(find.byKey(const Key('sched-save')));
      await t.tap(find.byKey(const Key('sched-save')));
      await settle(t);

      final saved = h.scheduled.all.single;
      expect(saved.title, '하체 데이');
      expect(saved.plannedDate, '2026-12-01');
      final item = saved.items.single;
      expect((item.exerciseId, item.restSec), (squat.id, 150));
      expect(item.sets.length, 2);
      final s = item.sets.first;
      expect((s.targetWeightKg, s.targetReps, s.targetRepsMax, s.targetRir), (80, 12, 15, 3));
    });

    testWidgets('수정: 기존 값 표시, 순서 바꾸기·세트 삭제·종목 삭제 후 저장', (t) async {
      final h = Harness();
      await h.scheduled.upsert(sw());
      await h.pump(t, initial: Routes.scheduledEdit('sw1'), extraRoutes: schedRoutes());
      await settle(t);
      expect(t.widget<TextField>(find.byKey(const Key('sched-title'))).controller!.text, 'B-2 하체 2');
      expect(t.widget<TextField>(find.byKey(const Key('sched-rest-0'))).controller!.text, '180');
      expect(t.widget<TextField>(find.byKey(const Key('sched-rm-0-0'))).controller!.text, '15');

      await t.enterText(find.byKey(const Key('sched-title')), '바꾼 제목');
      await t.ensureVisible(find.byKey(const Key('sched-down-0')));
      await t.tap(find.byKey(const Key('sched-down-0')));
      await settle(t);
      await t.ensureVisible(find.byKey(const Key('sched-remove-set-1-1')));
      await t.tap(find.byKey(const Key('sched-remove-set-1-1')));
      await settle(t);
      await t.ensureVisible(find.byKey(const Key('sched-save')));
      await t.tap(find.byKey(const Key('sched-save')));
      await settle(t);

      final saved = (await h.scheduled.byId('sw1'))!;
      expect(saved.title, '바꾼 제목');
      expect([for (final i in saved.items) i.exerciseId], [dbPress.id, squat.id]);
      expect(saved.items[1].sets.length, 1);
      expect(saved.items[1].restSec, 180);
    });
  });

  group('세션: 판정 없음·휴식 타이머', () {
    testWidgets('목표 미달이어도 실패 표시(빨강)가 없다', (t) async {
      final h = Harness();
      await h.sessions.startSession(tz: 'Asia/Seoul', scheduled: sw());
      await h.pump(t, initial: Routes.session);
      await settle(t);
      final s = await active(h);
      final first = s.exercises.first.sets.first;
      await t.enterText(find.byKey(Key('reps-${first.id}')), '3');
      await settle(t);
      await t.tap(find.byKey(const Key('complete-current')));
      await settle(t);
      expect(find.byKey(Key('failed-${first.id}')), findsNothing);
      expect(find.text('목표 미달'), findsNothing);
      expect((await active(h)).exercises.first.sets.first.isCompleted, isTrue);
    });

    testWidgets('휴식 라벨과 타이머는 세트의 targetRestSec(없으면 기본 2:00)', (t) async {
      final h = Harness();
      await h.sessions.startSession(tz: 'Asia/Seoul', scheduled: sw());
      await h.pump(t, initial: Routes.session);
      await settle(t);
      expect(find.text('휴식 3:00'), findsOneWidget);
      await t.tap(find.byKey(const Key('complete-current')));
      await settle(t);
      expect(h.container.read(restTimerProvider).totalSec, 180);

      // 두 번째 종목(restSec 없음)은 설정 기본값 120초.
      final s = await active(h);
      final dbSet = s.exercises[1].sets.single;
      await h.sessions.updateSet(s.exercises[0].sets[1].copyWith(completedAt: () => h.now));
      await settle(t);
      expect(find.text('휴식 2:00'), findsOneWidget);
      await t.tap(find.byKey(const Key('complete-current')));
      await settle(t);
      expect(h.container.read(restTimerProvider).totalSec, 120);
      expect(dbSet.targetRestSec, isNull);
    });

    test('짧은 휴식(15초 이하)은 사전 경고를 건너뛴다(규칙 유지)', () {
      expect(kRestWarnLead, const Duration(seconds: 10));
      expect(kRestWarnMinTotal, const Duration(seconds: 15));
    });
  });

  group('가져오기 묶음 분할', () {
    Map<String, Object?> sched(int i) => {
      'plannedDate': '2026-12-01',
      'title': 'w$i',
      'items': [
        {
          'exercise': {'name': '스쿼트'},
          'sets': [
            {'targetReps': 5},
          ],
        },
      ],
    };

    test('예정 30건 이하는 그대로', () {
      final b = {
        'schemaVersion': 1,
        'scheduledWorkouts': [for (var i = 0; i < 30; i++) sched(i)],
      };
      expect(splitBundle(b), [b]);
    });

    test('31건이면 30건씩 나누고 예정 조각이 세션 조각보다 앞', () {
      final b = {
        'schemaVersion': 1,
        'note': 'n',
        'scheduledWorkouts': [for (var i = 0; i < 65; i++) sched(i)],
        'sessions': [for (var i = 0; i < 201; i++) {'startedAt': '2026-01-01T00:00:00+09:00'}],
      };
      final parts = splitBundle(b);
      expect(parts.length, 4); // 첫 조각 + 예정 2 + 세션 1
      expect((parts[0]['scheduledWorkouts'] as List).length, 30);
      expect(parts[0]['note'], 'n');
      expect((parts[0]['sessions'] as List).length, 200);
      expect((parts[1]['scheduledWorkouts'] as List).length, 30);
      expect((parts[2]['scheduledWorkouts'] as List).length, 5);
      expect(parts[3].keys, containsAll(['schemaVersion', 'sessions']));
      final total = parts.fold<int>(0, (a, p) => a + ((p['scheduledWorkouts'] as List?)?.length ?? 0));
      expect(total, 65);
    });
  });
}
