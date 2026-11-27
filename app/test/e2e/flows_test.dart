// 앱 전체 라우터 + 메모리 저장소로 주요 흐름을 끝까지 돈다(헤드리스).
import 'package:fitlog/core/api/ai_dto.dart';
import 'package:fitlog/core/api/dto.dart';
import 'package:fitlog/core/api/program_dto.dart';
import 'package:fitlog/core/routes.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/app_env.dart';

PlannedWorkout planOf(int seq, double kg) => PlannedWorkout(
  instanceId: 'i1',
  planSeq: seq,
  dayIndex: 0,
  dayKey: 'A',
  dayName: '데이 A',
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
          PlannedSet(plannedSetKey: 'A.0.$i', targetReps: 5, targetWeightKg: kg, isAmrap: false, isWarmup: false),
      ],
    ),
  ],
);

Future<Session> active(AppEnv e) => e.sessions.watchActiveSession().first.then((s) => s!);

void main() {
  testWidgets('(a) 홈 -> 자유 세션 -> 종목 추가 -> 세트 기록 -> 종료 -> 요약 -> 홈', (t) async {
    final e = AppEnv();
    await e.pump(t);
    expect(find.byKey(const Key('home-start')), findsOneWidget);

    await t.tap(find.byKey(const Key('home-start')));
    await settle(t);
    await t.tap(find.byKey(const Key('add-exercise')));
    await settle(t);
    await t.tap(find.byKey(Key('exercise-${squat.id}')));
    await settle(t);

    var s = await active(e);
    final se = s.exercises.single;
    expect(se.exerciseId, squat.id);
    // 자유 세션은 종목을 추가하면 첫 세트가 바로 생긴다
    final set1 = (await active(e)).exercises.single.sets.single;
    await t.enterText(find.byKey(Key('weight-${set1.id}')), '100');
    await t.enterText(find.byKey(Key('reps-${set1.id}')), '5');
    await settle(t);
    await t.tap(find.byKey(Key('done-${set1.id}')));
    await settle(t);
    s = await active(e);
    expect(s.exercises.single.sets.single.isCompleted, isTrue);

    await t.tap(find.byKey(const Key('end-session')));
    await settle(t);
    await t.tap(find.byKey(const Key('end-confirm')));
    await settle(t, 12);
    expect(find.byKey(const Key('summary-done')), findsOneWidget);
    expect(t.widget<Text>(find.byKey(const Key('summary-volume'))).data, '500');

    await t.tap(find.byKey(const Key('summary-done')));
    await settle(t);
    expect(find.byKey(const Key('home-start')), findsOneWidget);
    expect(await e.sessions.watchActiveSession().first, isNull);
    expect(find.byKey(const Key('home-resume-card')), findsNothing);
  });

  testWidgets('(b) 프로그램 계획: 홈 오늘 할 운동 -> 계획 세트 채움 -> 종료', (t) async {
    final e = AppEnv();
    e.programs.instances['i1'] = Instance(
      id: 'i1',
      programId: 'p1',
      name: 'GZCLP',
      status: InstanceStatus.ACTIVE,
      skipPolicy: SkipPolicy.SHIFT,
      startDate: DateTime(2026, 11, 1),
      state: const InstanceState(week: 1, cycle: 1, seq: 1),
    );
    e.programs.plans['i1'] = [planOf(2, 100)];
    await e.planCache.refresh();
    await e.pump(t);

    expect(find.byKey(const Key('plan-card-i1')), findsOneWidget);
    expect(find.text('스쿼트'), findsOneWidget);
    expect(find.byKey(const Key('plan-main-weight-i1')), findsOneWidget);
    await t.tap(find.byKey(const Key('plan-start-i1')));
    await settle(t);

    final s = await active(e);
    expect(s.programInstanceId, 'i1');
    final sets = s.exercises.single.sets;
    expect(sets.map((x) => x.weightKg), [100, 100, 100]);
    expect(sets.map((x) => x.reps), [5, 5, 5]);
    expect(find.byKey(const Key('plan-header')), findsOneWidget);

    await t.tap(find.byKey(Key('done-${sets[0].id}')));
    await settle(t);
    e.programs.plans['i1'] = [planOf(3, 102.5)];
    await t.tap(find.byKey(const Key('end-session')));
    await settle(t);
    await t.tap(find.byKey(const Key('end-confirm')));
    await settle(t, 12);

    expect(find.byKey(const Key('summary-next')), findsOneWidget);
    expect(find.text('스쿼트 102.5 kg'), findsOneWidget);
    await t.tap(find.byKey(const Key('summary-done')));
    await settle(t);
    expect(find.byKey(const Key('plan-card-i1')), findsOneWidget);
  });

  testWidgets('(c) JSON 가져오기: 붙여넣기 -> 미리보기 -> 저장', (t) async {
    final e = AppEnv();
    e.imports.nextPreview = const ImportPreview(
      valid: true,
      counts: {
        'sessions': {'NEW': 1},
      },
    );
    await e.pump(t, initial: Routes.importJson);

    await t.enterText(
      find.byKey(const ValueKey('import-text')),
      '{"schemaVersion":1,"sessions":[{"startedAt":"2026-01-01T00:00:00+09:00"}]}',
    );
    await t.pump();
    await t.tap(find.byKey(const ValueKey('import-preview')));
    await settle(t);
    expect(find.byKey(const ValueKey('import-no-conflicts')), findsOneWidget);

    await t.tap(find.byKey(const ValueKey('import-save')));
    await settle(t);
    expect(e.imports.submitted.length, 1);
    expect(find.text('가져오기 완료'), findsOneWidget);
  });

  testWidgets('(d) 히스토리 -> 세션 상세', (t) async {
    final e = AppEnv();
    final s = await finishedSession(
      e,
      DateTime.utc(2026, 11, 20, 3),
      lifts: [
        (squat.id, [(100.0, 5), (100.0, 5)]),
      ],
    );
    await e.pump(t);

    await t.tap(find.byKey(const Key('nav-history')));
    await settle(t);
    expect(find.byKey(const Key('history-list')), findsOneWidget);
    await t.tap(find.byKey(Key('history-${s.id}')));
    await settle(t);
    expect(find.byKey(const Key('detail-header')), findsOneWidget);
    expect(find.byKey(const Key('detail-edit')), findsOneWidget);

    // 뒤로 -> 히스토리 -> 홈
    e.router.pop();
    await settle(t);
    expect(find.byKey(const Key('history-list')), findsOneWidget);
  });

  testWidgets('설정 화면 열기 -> 다시 홈 (DSN 없는 빌드는 오류 보고 토글이 보이지 않는다)', (t) async {
    final e = AppEnv();
    await e.pump(t);
    await t.tap(find.byKey(const Key('nav-me')));
    await settle(t);
    await t.tap(find.byKey(const Key('me-settings')));
    await settle(t);
    expect(find.byKey(const Key('unitToggle')), findsOneWidget);
    expect(find.byKey(const Key('crashReport')), findsNothing);
  });
}
