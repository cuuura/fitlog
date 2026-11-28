import 'package:fitlog/core/theme.dart';
import 'package:fitlog/core/ui/confirm.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'harness.dart';

void main() {
  testWidgets('파괴적: OutlinedButton + fail 색, 확인하면 true', (t) async {
    bool? r;
    await t.pumpWidget(opener((c) async => r = await confirmAction(c, title: '삭제할까요?', body: '본문', action: '삭제', destructive: true)));
    await open(t);
    expect(find.text('삭제할까요?'), findsOneWidget);
    expect(find.text('본문'), findsOneWidget);
    final btn = find.byKey(const Key('confirm-ok'));
    expect(t.widget(btn), isA<OutlinedButton>());
    expect(find.byType(FilledButton), findsNothing);
    final fail = AppColors.light.fail;
    final style = t.widget<OutlinedButton>(btn).style!;
    expect(style.foregroundColor!.resolve({}), fail);
    expect(style.side!.resolve({})!.color, fail);
    await t.tap(btn);
    await t.pumpAndSettle();
    expect(r, true);
  });

  testWidgets('일반: FilledButton, 취소하면 false', (t) async {
    bool? r;
    await t.pumpWidget(opener((c) async => r = await confirmAction(c, title: 't', action: '확인')));
    await open(t);
    expect(t.widget(find.byKey(const Key('confirm-ok'))), isA<FilledButton>());
    await t.tap(find.text('취소'));
    await t.pumpAndSettle();
    expect(r, false);
  });

  testWidgets('바깥 탭이면 false, 사용자 key 적용', (t) async {
    bool? r;
    await t.pumpWidget(opener((c) async => r = await confirmAction(c, title: 't', action: 'a', confirmKey: const Key('x'), dialogKey: const Key('d'))));
    await open(t);
    expect(find.byKey(const Key('x')), findsOneWidget);
    expect(find.byKey(const Key('d')), findsOneWidget);
    await t.tapAt(const Offset(2, 2));
    await t.pumpAndSettle();
    expect(r, false);
  });
}
