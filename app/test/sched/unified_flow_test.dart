// 추가·수정·삭제 흐름 통일: 하루 예약 목록(FAB·⋮)·수정 화면(하단 저장·나가기 확인)과 세션 상세 ⋮ 메뉴.
import 'package:fitlog/core/api/dto.dart';
import 'package:fitlog/core/routes.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/app_env.dart';

ScheduledWorkout sw1() => const ScheduledWorkout(
  id: 'sw1',
  plannedDate: '2026-12-02',
  title: '하체 데이',
  items: [
    ScheduledItem(exerciseId: 'ex-squat', sets: [ScheduledSet(targetWeightKg: 80, targetReps: 10)]),
  ],
);

void main() {
  testWidgets('목록: 오른쪽 아래 FAB(예정 운동 만들기)가 진행 중 미니바와 겹치지 않는다', (t) async {
    final e = AppEnv();
    await e.scheduled.upsert(sw1());
    final s = await e.sessions.startSession(tz: 'Asia/Seoul');
    await e.sessions.addExercise(s.id, squat.id);
    await e.pump(t, initial: Routes.scheduled);

    final fab = find.byKey(const Key('sched-list-add'));
    expect(fab, findsOneWidget);
    expect(find.descendant(of: fab, matching: find.text('예정 운동 만들기')), findsOneWidget);
    expect(find.descendant(of: find.byType(AppBar), matching: find.byKey(const Key('sched-list-add'))), findsNothing);

    final mini = find.byKey(const Key('active-mini-bar'));
    expect(mini, findsOneWidget);
    expect(t.getBottomRight(fab).dy, lessThanOrEqualTo(t.getTopLeft(mini).dy));
    expect(t.getBottomRight(fab).dx, greaterThan(400), reason: '오른쪽에 붙는다');

    await t.tap(fab);
    await settle(t);
    expect(find.byKey(const Key('sched-title')), findsOneWidget);
  });

  testWidgets('목록 ⋮ 메뉴: 수정·건너뛰기·삭제(빨강), 삭제는 확인창을 거친다', (t) async {
    final e = AppEnv();
    await e.scheduled.upsert(sw1());
    await e.pump(t, initial: Routes.scheduled);

    await t.tap(find.byKey(const Key('sched-menu-sw1')));
    await settle(t);
    expect(find.byKey(const Key('sched-menu-edit-sw1')), findsOneWidget);
    expect(find.byKey(const Key('sched-menu-skip-sw1')), findsOneWidget);
    final del = find.descendant(of: find.byKey(const Key('sched-menu-delete-sw1')), matching: find.text('삭제'));
    expect(t.widget<Text>(del).style?.color, isNotNull);
    await t.tap(find.byKey(const Key('sched-menu-delete-sw1')));
    await settle(t);
    expect(find.text("'하체 데이' 예정 삭제"), findsOneWidget);
    await t.tap(find.byKey(const Key('sched-delete-confirm')));
    await settle(t);
    expect(await e.scheduled.byId('sw1'), isNull);
  });

  group('예정 수정 화면', () {
    Future<void> openNew(AppEnv e, WidgetTester t) async {
      await e.pump(t);
      e.router.push(Routes.scheduledNew);
      await settle(t);
    }

    testWidgets('저장 버튼은 화면 아래에 고정되고, 오류 문구도 그 위에 보인다', (t) async {
      final e = AppEnv();
      await openNew(e, t);
      final save = find.byKey(const Key('sched-save'));
      expect(find.ancestor(of: save, matching: find.byType(ListView)), findsNothing, reason: '스크롤 안이 아니다');
      expect(t.getBottomLeft(save).dy, greaterThan(1100));
      await t.tap(save);
      await settle(t);
      expect(find.byKey(const Key('sched-error')), findsOneWidget);
      expect(find.text('제목을 입력해 주세요'), findsOneWidget);
    });

    testWidgets('키보드가 올라와도 저장 버튼이 키보드 바로 위에 보인다', (t) async {
      final e = AppEnv();
      await openNew(e, t);
      t.view.viewInsets = const FakeViewPadding(bottom: 400);
      addTearDown(t.view.resetViewInsets);
      await settle(t);
      final save = find.byKey(const Key('sched-save'));
      final bottom = t.getBottomLeft(save).dy;
      expect(bottom, lessThanOrEqualTo(1000));
      expect(bottom, greaterThan(850), reason: '키보드 위 여백이 두 번 잡히지 않는다');
    });

    testWidgets('아무것도 안 넣고 나가면 묻지 않고, 고친 채 나가면 확인한다', (t) async {
      final e = AppEnv();
      await openNew(e, t);
      await t.binding.handlePopRoute();
      await settle(t);
      expect(find.byKey(const Key('sched-title')), findsNothing);

      e.router.push(Routes.scheduledNew);
      await settle(t);
      await t.enterText(find.byKey(const Key('sched-title')), '하체');
      await t.pump();
      await t.binding.handlePopRoute();
      await settle(t);
      expect(find.text('저장하지 않고 나갈까요?'), findsOneWidget);
      await t.tap(find.text('취소'));
      await settle(t);
      expect(find.byKey(const Key('sched-title')), findsOneWidget);
      expect(t.widget<TextField>(find.byKey(const Key('sched-title'))).controller!.text, '하체');

      await t.binding.handlePopRoute();
      await settle(t);
      await t.tap(find.byKey(const Key('discard-confirm')));
      await settle(t);
      expect(find.byKey(const Key('sched-title')), findsNothing);
    });

    testWidgets('저장하고 나갈 때는 묻지 않는다', (t) async {
      final e = AppEnv();
      await e.scheduled.upsert(sw1());
      await e.pump(t);
      e.router.push(Routes.scheduledEdit('sw1'));
      await settle(t);
      await t.enterText(find.byKey(const Key('sched-title')), '바꾼 제목');
      await t.pump();
      await t.tap(find.byKey(const Key('sched-save')));
      await settle(t);
      expect(find.text('저장하지 않고 나갈까요?'), findsNothing);
      expect(find.byKey(const Key('sched-title')), findsNothing);
      expect((await e.scheduled.byId('sw1'))!.title, '바꾼 제목');
    });

    testWidgets('줄 삭제 아이콘은 종목·세트 모두 X이고 확인 없이 지워진다', (t) async {
      final e = AppEnv();
      await e.scheduled.upsert(sw1());
      await e.pump(t);
      e.router.push(Routes.scheduledEdit('sw1'));
      await settle(t);
      for (final k in ['sched-remove-0', 'sched-remove-set-0-0']) {
        final icon = find.descendant(of: find.byKey(Key(k)), matching: find.byType(Icon));
        expect(t.widget<Icon>(icon).icon, Icons.close);
      }
      await t.tap(find.byKey(const Key('sched-remove-0')));
      await settle(t);
      expect(find.byKey(const Key('sched-item-0')), findsNothing);
    });
  });

  testWidgets('세션 상세: 비교는 아이콘, 수정·삭제는 ⋮ 메뉴 (삭제는 날짜가 든 확인창)', (t) async {
    final e = AppEnv();
    final s = await finishedSession(e, DateTime.utc(2026, 11, 15, 12), lifts: [
      ('ex-squat', [(100.0, 5)]),
    ]);
    await e.pump(t);
    e.router.push(Routes.sessionDetail(s.id));
    await settle(t);
    expect(find.byKey(const Key('detail-compare')), findsOneWidget);
    expect(find.byKey(const Key('detail-edit')), findsNothing);

    await t.tap(find.byType(PopupMenuButton<String>));
    await settle(t);
    await t.tap(find.byKey(const Key('detail-edit')));
    await settle(t);
    expect(find.byKey(const Key('edit-start')), findsOneWidget);
    e.router.pop();
    await settle(t);

    await t.tap(find.byType(PopupMenuButton<String>));
    await settle(t);
    await t.tap(find.byKey(const Key('detail-delete')));
    await settle(t);
    expect(find.text('2026-11-15 세션 삭제'), findsOneWidget);
    await t.tap(find.text('취소'));
    await settle(t);
    expect(await e.sessions.watchSession(s.id).first, isNotNull);
    await t.tap(find.byType(PopupMenuButton<String>));
    await settle(t);
    await t.tap(find.byKey(const Key('detail-delete')));
    await settle(t);
    await t.tap(find.byKey(const Key('detail-delete-confirm')));
    await settle(t);
    expect(await e.sessions.watchSession(s.id).first, isNull);
  });
}
