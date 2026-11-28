import 'package:fitlog/core/ui/undo.dart';
import 'package:fitlog/l10n/gen/app_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'harness.dart';

void main() {
  Future<void> show(WidgetTester t, Future<void> Function() undo, {String msg = '지웠어요'}) async {
    await t.pumpWidget(opener((c) => showUndoSnack(ScaffoldMessenger.of(c), AppLocalizations.of(c), message: msg, onUndo: undo)));
    await t.tap(find.byKey(const Key('open')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
  }

  testWidgets('되돌리기 누르면 onUndo 호출', (t) async {
    var n = 0;
    await show(t, () async => n++);
    expect(find.text('지웠어요'), findsOneWidget);
    await t.tap(find.text('되돌리기'));
    await t.pump();
    expect(n, 1);
  });

  testWidgets('onUndo 예외면 오류 스낵바', (t) async {
    await show(t, () async => throw Exception('x'));
    await t.tap(find.text('되돌리기'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 800));
    expect(find.text('문제가 생겼어요'), findsOneWidget);
  });

  testWidgets('새 스낵바가 이전 것을 대체하고 5초 안에 사라짐', (t) async {
    var n = 0;
    await t.pumpWidget(opener((c) => showUndoSnack(ScaffoldMessenger.of(c), AppLocalizations.of(c), message: '메시지${++n}', onUndo: () async {})));
    await t.tap(find.byKey(const Key('open')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    await t.tap(find.byKey(const Key('open')), warnIfMissed: false);
    await t.pump();
    await t.pump(const Duration(milliseconds: 800));
    expect(find.text('메시지1'), findsNothing);
    expect(find.text('메시지2'), findsOneWidget);
    for (var i = 0; i < 3; i++) {
      await t.pump(const Duration(seconds: 1));
    }
    expect(find.text('메시지2'), findsOneWidget);
    for (var i = 0; i < 8; i++) {
      await t.pump(const Duration(seconds: 1));
    }
    expect(find.text('메시지2'), findsNothing);
  });
}
