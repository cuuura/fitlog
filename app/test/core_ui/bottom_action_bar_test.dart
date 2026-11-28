import 'package:fitlog/core/theme.dart';
import 'package:fitlog/core/ui/bottom_action_bar.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'harness.dart';

void main() {
  testWidgets('버튼이 가로로 꽉 차고 오류 문구는 fail 색', (t) async {
    await t.pumpWidget(host(Scaffold(
      body: const SizedBox(),
      bottomNavigationBar: BottomActionBar(error: '저장 실패', child: FilledButton(onPressed: () {}, child: const Text('저장'))),
    )));
    expect(t.widget<Text>(find.text('저장 실패')).style!.color, AppColors.light.fail);
    final w = t.getSize(find.byType(FilledButton)).width;
    expect(w, t.view.physicalSize.width / t.view.devicePixelRatio - 32);
  });

  testWidgets('오류 없으면 문구 없음', (t) async {
    await t.pumpWidget(host(Scaffold(
      bottomNavigationBar: BottomActionBar(child: FilledButton(onPressed: () {}, child: const Text('저장'))),
    )));
    expect(find.text('저장'), findsOneWidget);
    expect(find.byType(Text), findsOneWidget);
  });

  testWidgets('키보드가 올라오면 그 위로 올라옴', (t) async {
    await t.pumpWidget(host(MediaQuery(
      data: const MediaQueryData(size: Size(800, 600), viewInsets: EdgeInsets.only(bottom: 300)),
      child: Scaffold(bottomNavigationBar: BottomActionBar(child: FilledButton(onPressed: () {}, child: const Text('저장')))),
    )));
    expect(t.getBottomLeft(find.byType(FilledButton)).dy, lessThanOrEqualTo(300));
  });
}
