import 'package:fitlog/core/theme.dart';
import 'package:fitlog/core/ui/row_menu.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'harness.dart';

void main() {
  testWidgets('선택·key·destructive 색·기본 tooltip·터치 영역', (t) async {
    String? picked;
    await t.pumpWidget(host(Scaffold(
      body: RowMenu<String>(
        onSelected: (v) => picked = v,
        items: const [
          RowMenuItem(value: 'edit', label: '수정', key: Key('m-edit')),
          RowMenuItem(value: 'del', label: '삭제', key: Key('m-del'), destructive: true),
        ],
      ),
    )));
    expect(find.byTooltip('더보기'), findsOneWidget);
    final size = t.getSize(find.byType(PopupMenuButton<String>));
    expect(size.width, greaterThanOrEqualTo(48));
    expect(size.height, greaterThanOrEqualTo(48));
    await t.tap(find.byType(PopupMenuButton<String>));
    await t.pumpAndSettle();
    expect(t.widget<Text>(find.text('삭제')).style!.color, AppColors.light.fail);
    expect(t.widget<Text>(find.text('수정')).style, isNull);
    await t.tap(find.byKey(const Key('m-del')));
    await t.pumpAndSettle();
    expect(picked, 'del');
  });

  testWidgets('enabled=false 항목은 선택되지 않음', (t) async {
    String? picked;
    await t.pumpWidget(host(Scaffold(
      body: RowMenu<String>(
        tooltip: '메뉴',
        onSelected: (v) => picked = v,
        items: const [RowMenuItem(value: 'a', label: 'A', key: Key('m-a'), enabled: false)],
      ),
    )));
    await t.tap(find.byTooltip('메뉴'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('m-a')), warnIfMissed: false);
    await t.pumpAndSettle();
    expect(picked, isNull);
  });
}
