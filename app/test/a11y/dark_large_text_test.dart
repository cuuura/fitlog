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
    await t.ensureVisible(done);
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
