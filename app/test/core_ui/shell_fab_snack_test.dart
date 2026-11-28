// 셸(하단 탭) 안의 화면이 되돌리기 스낵바를 띄워도 자기 FAB를 가리지 않는다.
import 'package:fitlog/core/api/program_dto.dart';
import 'package:fitlog/core/routes.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/app_env.dart';

void expectFabAboveSnack(WidgetTester t, String fabKey) {
  final fab = t.getRect(find.byKey(Key(fabKey)));
  final snack = t.getRect(find.byType(SnackBar));
  expect(fab.bottom, lessThan(snack.top), reason: 'FAB가 스낵바 위에 있어야 함');
}

void main() {
  testWidgets('예정 목록: 스낵바가 떠도 FAB가 그 위에 있다', (t) async {
    final e = AppEnv();
    await e.pump(t, initial: Routes.scheduled, size: const Size(360, 780));
    expect(find.byKey(const Key('app-nav')), findsOneWidget, reason: '셸 안에서 확인');
    ScaffoldMessenger.of(t.element(find.byKey(const Key('sched-list-add'))))
        .showSnackBar(const SnackBar(content: Text('알림 문구')));
    await t.pumpAndSettle();
    expect(find.text('알림 문구'), findsOneWidget);
    expectFabAboveSnack(t, 'sched-list-add');
  });

  testWidgets('종목 기록: 1RM 삭제 되돌리기 스낵바가 떠도 FAB가 그 위에 있다', (t) async {
    final e = AppEnv();
    final m = await e.records.addOneRm(
      squat.id,
      OneRmMeasurement(id: 'o1', weightKg: 120, measuredAt: DateTime.utc(2026, 11, 20)),
    );
    await e.pump(t, initial: Routes.exerciseRecords(squat.id), size: const Size(360, 780));
    expect(find.byKey(const Key('app-nav')), findsOneWidget, reason: '셸 안에서 확인');
    await t.tap(find.byKey(Key('onerm-menu-${m.id}')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(Key('onerm-delete-${m.id}')));
    await t.pumpAndSettle();
    expect(find.byType(SnackBar), findsOneWidget);
    expectFabAboveSnack(t, 'records-add-onerm');
  });
}
