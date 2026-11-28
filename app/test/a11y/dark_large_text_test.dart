// 다크 모드 + 글자 크기 2.0 + 작은 폰(360x640)에서 주요 화면이 오버플로 없이 그려지는지,
// 아이콘 버튼에 tooltip(의미 레이블)이 있는지 확인한다.
import 'package:fitlog/core/api/dto.dart';
import 'package:fitlog/core/api/program_dto.dart';
import 'package:fitlog/core/routes.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/app_env.dart';

const _small = Size(360, 640);

Future<AppEnv> seeded({bool withActive = false}) async {
  final e = AppEnv();
  for (var i = 0; i < 3; i++) {
    await finishedSession(
      e,
      DateTime.utc(2026, 11, 10 + i * 3, 3),
      lifts: [
        (squat.id, [(100.0 + i * 2.5, 5), (100.0, 5), (97.5, 8)]),
        (bench.id, [(80.0, 5), (80.0, 4)]),
        (pullUp.id, [(0.0, 10)]),
      ],
    );
  }
  e.now = DateTime.utc(2026, 11, 26, 9);
  if (withActive) {
    final s = await e.sessions.startSession(tz: 'Asia/Seoul');
    for (final ex in [squat, dbPress, pullUp]) {
      final se = await e.sessions.addExercise(s.id, ex.id);
      for (var i = 0; i < 3; i++) {
        await e.sessions.addSet(
          se.id,
          WorkoutSet(id: 'set-${ex.id}-$i', position: i, weightKg: 102.5, reps: 5, completedAt: i == 0 ? e.now : null),
        );
      }
    }
  }
  return e;
}

/// 오버플로 같은 렌더링 예외가 있으면 위치까지 보이게 실패시킨다.
void noError(WidgetTester t, String reason) {
  final ex = t.takeException();
  if (ex != null) fail('$reason\n${ex is FlutterError ? ex.toStringDeep() : ex}');
}

void main() {
  Future<void> check(WidgetTester t, AppEnv e, String route, {ThemeMode mode = ThemeMode.dark}) async {
    await e.pump(t, initial: route, size: _small, themeMode: mode, textScale: 2.0);
    noError(t, '$route 오버플로/예외');
    for (final b in t.widgetList<IconButton>(find.byType(IconButton))) {
      final hasLabel = b.tooltip != null || (b.icon is Icon && (b.icon as Icon).semanticLabel != null);
      expect(hasLabel, isTrue, reason: '$route 아이콘 버튼에 tooltip 없음: ${b.icon}');
    }
  }

  testWidgets('홈(진행 중 세션 카드 포함)', (t) async {
    final e = await seeded(withActive: true);
    await check(t, e, Routes.home);
  });

  testWidgets('홈(빈 상태)', (t) async {
    await check(t, AppEnv(), Routes.home);
  });

  testWidgets('진행 중 세션(종목 3 x 세트 3)', (t) async {
    final e = await seeded(withActive: true);
    await check(t, e, Routes.session);
  });

  testWidgets('세션 상세', (t) async {
    final e = await seeded();
    final id = (await e.sessions.watchRecentSessions().first).first.id;
    await check(t, e, Routes.sessionDetail(id));
  });

  testWidgets('세션 요약', (t) async {
    final e = await seeded();
    final id = (await e.sessions.watchRecentSessions().first).first.id;
    await check(t, e, Routes.sessionSummary(id));
  });

  testWidgets('히스토리', (t) async {
    await check(t, await seeded(), Routes.history);
  });

  testWidgets('설정', (t) async {
    await check(t, await seeded(), Routes.settings);
  });

  testWidgets('프로필·체중', (t) async {
    await check(t, await seeded(), Routes.profile);
    await check(t, await seeded(), Routes.body);
  });

  testWidgets('프로그램 목록', (t) async {
    await check(t, await seeded(), Routes.programs);
  });

  testWidgets('프로그램 추가 시트(카드 펼침, 내 프로그램, 다른 방법)와 내 프로그램 탭', (t) async {
    for (final (scale, mode) in [(1.3, ThemeMode.light), (2.0, ThemeMode.dark), (2.0, ThemeMode.light)]) {
      final e = await seeded();
      for (var i = 0; i < 3; i++) {
        e.programs.programs['t$i'] = Program(
          id: 't$i',
          name: '아주 긴 이름의 프로그램 템플릿 번호 $i 입니다',
          description: '설명이 길어도 넘치지 않아야 하는 프로그램 설명 문장입니다. 두 줄을 넘깁니다.',
          builtIn: true,
          dayCount: 3 + i,
          category: 'POWERBUILDING',
          definition: {
            'schemaVersion': 1,
            'name': 'x',
            'lifts': {'squat': {'exercise': {'id': squat.id}}},
            'days': [
              {
                'key': 'A',
                'name': 'A',
                'weekday': 'MON',
                'exercises': [
                  {
                    'lift': 'squat',
                    'sets': [
                      {'count': 3, 'reps': 5, 'load': {'type': 'WORKING'}},
                    ],
                  },
                ],
              },
            ],
          },
        );
      }
      e.programs.programs['m1'] = Program(
        id: 'm1',
        name: '내가 만든 아주 긴 이름의 프로그램',
        description: '내 설명',
        builtIn: false,
        dayCount: 3,
        definition: {'schemaVersion': 1, 'name': 'x', 'lifts': <String, Object?>{}, 'days': <Object?>[]},
      );
      await e.pump(t, initial: Routes.programs, size: const Size(360, 780), themeMode: mode, textScale: scale);
      noError(t, '프로그램 탭 $scale');
      await t.tap(find.byKey(const Key('programs-add')));
      await t.pumpAndSettle();
      noError(t, '시트 $scale');
      await t.tap(find.byKey(const Key('program-toggle-t0')));
      await t.pumpAndSettle();
      noError(t, '카드 펼침 $scale');
      expect(find.byKey(const Key('program-pick-t0')), findsOneWidget);
      final h = t.getSize(find.byKey(const Key('program-pick-t0'))).height;
      expect(h, greaterThanOrEqualTo(48));
      await t.tap(find.descendant(of: find.byKey(const Key('program-add-segments')), matching: find.text('내 프로그램')));
      await t.pumpAndSettle();
      noError(t, '시트 내 프로그램 $scale');
      await t.drag(find.byKey(const Key('program-add-list')), const Offset(0, -600));
      await t.pumpAndSettle();
      noError(t, '시트 다른 방법 $scale');
      await t.tap(find.byKey(const Key('program-add-close')));
      await t.pumpAndSettle();
      await t.tap(find.descendant(of: find.byKey(const Key('programs-segments')), matching: find.textContaining('내 프로그램')));
      await t.pumpAndSettle();
      noError(t, '내 프로그램 탭 $scale');
    }
  });

  testWidgets('셸 안 프로그램 탭: 스낵바가 FAB를 가리지 않는다', (t) async {
    final e = await seeded();
    e.programs.programs['m1'] = Program(
      id: 'm1',
      name: '내 프로그램',
      builtIn: false,
      dayCount: 3,
      definition: {'schemaVersion': 1, 'name': 'x', 'lifts': <String, Object?>{}, 'days': <Object?>[]},
    );
    await e.pump(t, initial: Routes.programs, size: const Size(360, 780));
    expect(find.byKey(const Key('app-nav')), findsOneWidget, reason: '셸 안에서 확인');
    ScaffoldMessenger.of(t.element(find.byKey(const Key('programs-add')))).showSnackBar(const SnackBar(content: Text('알림 문구')));
    await t.pumpAndSettle();
    expect(find.text('알림 문구'), findsOneWidget);
    final fab = t.getRect(find.byKey(const Key('programs-add')));
    final snack = t.getRect(find.byType(SnackBar));
    expect(fab.overlaps(snack), isFalse);
  });

  testWidgets('종목별 기록', (t) async {
    await check(t, await seeded(), Routes.exerciseRecords(squat.id));
  });

  testWidgets('가져오기', (t) async {
    await check(t, await seeded(), Routes.importJson);
  });

  testWidgets('AI 연동·내보내기', (t) async {
    await check(t, await seeded(), Routes.ai);
    await check(t, await seeded(), Routes.export);
    await check(t, await seeded(), Routes.aiConnect);
  });

  testWidgets('라이트 모드에서도 같은 화면이 깨지지 않는다(홈·세션)', (t) async {
    final e = await seeded(withActive: true);
    await check(t, e, Routes.home, mode: ThemeMode.light);
    await check(t, e, Routes.session, mode: ThemeMode.light);
  });

  testWidgets('프로그램 계획 카드·계획 세션·휴식 타이머(영어, 긴 문구)', (t) async {
    final e = await seeded();
    PlannedWorkout plan(int seq) => PlannedWorkout(
      instanceId: 'i1',
      planSeq: seq,
      dayIndex: 0,
      dayKey: 'A',
      dayName: 'Heavy Lower Body Day With A Very Long Name',
      week: seq,
      cycle: 1,
      confirmed: true,
      exercises: [
        PlannedExercise(
          key: 'squat',
          exerciseId: squat.id,
          accessory: false,
          sets: [
            for (var i = 0; i < 3; i++)
              PlannedSet(
                plannedSetKey: 'A.0.$i',
                targetReps: 5,
                targetWeightKg: 102.5,
                isAmrap: i == 2,
                isWarmup: false,
              ),
          ],
        ),
      ],
    );
    e.programs.instances['i1'] = Instance(
      id: 'i1',
      programId: 'p1',
      name: 'Greyskull Linear Progression Extended',
      status: InstanceStatus.ACTIVE,
      skipPolicy: SkipPolicy.SHIFT,
      startDate: DateTime(2026, 11, 1),
      state: const InstanceState(week: 1, cycle: 1, seq: 1),
    );
    e.programs.plans['i1'] = [plan(2)];
    await e.planCache.refresh();
    await e.pump(t, size: _small, themeMode: ThemeMode.dark, textScale: 2.0, locale: const Locale('en'));
    noError(t, 'home plan card');

    await t.ensureVisible(find.byKey(const Key('plan-start-i1')));
    await t.pump();
    await t.tap(find.byKey(const Key('plan-start-i1')));
    await settle(t);
    noError(t, 'plan session');

    final s = await e.sessions.watchActiveSession().first;
    final done = find.byKey(Key('done-${s!.exercises.single.sets.first.id}'));
    await t.scrollUntilVisible(done, 200, scrollable: find.byType(Scrollable).first);
    await t.pump();
    await t.tap(done);
    await settle(t);
    noError(t, 'rest timer bar');
    expect(find.byKey(const Key('end-session')), findsOneWidget);
  });

  testWidgets('영어 로케일 + 큰 글씨: 홈·설정·히스토리', (t) async {
    final e = await seeded(withActive: true);
    for (final r in [Routes.home, Routes.settings, Routes.history, Routes.importJson]) {
      await e.pump(t, initial: r, size: _small, themeMode: ThemeMode.dark, textScale: 2.0, locale: const Locale('en'));
      noError(t, r);
    }
  });
}
