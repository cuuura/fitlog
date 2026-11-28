import 'dart:async';

import 'package:fitlog/core/ui/form_sheet.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'harness.dart';

void main() {
  late String? result;
  Future<void> openSheet(WidgetTester t, Future<String?> Function() submit, {String Function(Object)? fm}) async {
    result = 'unset';
    await t.pumpWidget(opener((c) async => result = await showFormSheet<String>(c, builder: (_) => FormSheet<String>(
      title: '새 항목',
      submitLabel: '추가',
      failureMessage: fm,
      onSubmit: submit,
      children: const [TextField(key: Key('name'))],
    ))));
    await open(t);
    await t.enterText(find.byKey(const Key('name')), '입력값');
  }

  testWidgets('null이면 시트 유지', (t) async {
    await openSheet(t, () async => null);
    await t.tap(find.byKey(const Key('sheet-submit')));
    await t.pumpAndSettle();
    expect(find.text('새 항목'), findsOneWidget);
    expect(result, 'unset');
    expect(find.byKey(const Key('sheet-error')), findsNothing);
  });

  testWidgets('성공하면 값으로 닫힘', (t) async {
    await openSheet(t, () async => 'ok');
    await t.tap(find.byKey(const Key('sheet-submit')));
    await t.pumpAndSettle();
    expect(find.text('새 항목'), findsNothing);
    expect(result, 'ok');
  });

  testWidgets('예외면 유지 + 오류 표시 + 입력 보존, 다시 제출 가능', (t) async {
    var n = 0;
    await openSheet(t, () async {
      if (n++ == 0) throw Exception('x');
      return 'ok';
    });
    await t.tap(find.byKey(const Key('sheet-submit')));
    await t.pumpAndSettle();
    expect(find.text('새 항목'), findsOneWidget);
    expect(t.widget<Text>(find.byKey(const Key('sheet-error'))).data, '문제가 생겼어요');
    expect(find.text('입력값'), findsOneWidget);
    await t.tap(find.byKey(const Key('sheet-submit')));
    await t.pumpAndSettle();
    expect(result, 'ok');
  });

  testWidgets('failureMessage 사용', (t) async {
    await openSheet(t, () async => throw StateError('boom'), fm: (e) => '실패: ${e.runtimeType}');
    await t.tap(find.byKey(const Key('sheet-submit')));
    await t.pumpAndSettle();
    expect(find.text('실패: StateError'), findsOneWidget);
  });

  testWidgets('제출 중 중복 제출 방지 + 진행 표시', (t) async {
    final c = Completer<String?>();
    var calls = 0;
    await openSheet(t, () {
      calls++;
      return c.future;
    });
    await t.tap(find.byKey(const Key('sheet-submit')));
    await t.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(t.widget<FilledButton>(find.byKey(const Key('sheet-submit'))).onPressed, isNull);
    await t.tap(find.byKey(const Key('sheet-submit')), warnIfMissed: false);
    await t.pump();
    expect(calls, 1);
    c.complete('done');
    await t.pumpAndSettle();
    expect(result, 'done');
    expect(calls, 1);
  });

  testWidgets('enabled=false면 버튼 비활성', (t) async {
    await t.pumpWidget(host(const Scaffold(body: FormSheet<String>(title: 't', submitLabel: 's', enabled: false, onSubmit: _noop, children: []))));
    expect(t.widget<FilledButton>(find.byKey(const Key('sheet-submit'))).onPressed, isNull);
  });
}

Future<String?> _noop() async => null;
