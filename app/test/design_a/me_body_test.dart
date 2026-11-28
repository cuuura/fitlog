import 'package:fitlog/core/api/dto.dart';
import 'package:fitlog/core/routes.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/app_env.dart';

void main() {
  testWidgets('나 탭: 항목들과 최근 체중, 각 화면으로 이동', (t) async {
    final e = AppEnv(settings: const Settings(heightCm: 178, birthYear: 1990));
    await e.body.add(BodyMeasurement(id: 'b1', measuredAt: DateTime.utc(2026, 11, 25), weightKg: 78.4));
    await e.pump(t, initial: Routes.me);
    await settle(t);
    for (final k in ['me-body', 'me-profile', 'me-ai', 'me-export', 'me-settings']) {
      expect(find.byKey(Key(k)), findsOneWidget);
    }
    expect(find.text('최근 체중 78.4 kg'), findsOneWidget);
    expect(find.textContaining('키 178cm'), findsOneWidget);
    expect(find.byKey(const Key('app-nav')), findsOneWidget);

    await t.tap(find.byKey(const Key('me-body')));
    await settle(t);
    expect(e.router.state.uri.path, Routes.body);
    expect(find.byKey(const Key('app-nav')), findsOneWidget);
    e.router.pop();
    await settle(t);
    await t.tap(find.byKey(const Key('me-export')));
    await settle(t);
    expect(e.router.state.uri.path, Routes.export);
  });

  testWidgets('나 탭: 삭제 요청 대기 배지', (t) async {
    final e = AppEnv();
    await e.pump(t, initial: Routes.me);
    expect(find.byKey(const Key('me-ai-badge')), findsNothing);
  });

  testWidgets('신체 수치: 큰 체중, 지난주 대비, 12주 그래프, 키·BMI 출처', (t) async {
    final e = AppEnv(settings: const Settings(heightCm: 178));
    final base = DateTime.utc(2026, 11, 25);
    final data = [(0, 78.4), (7, 79.0), (30, 80.0), (60, 81.2)];
    for (final (i, d) in data.indexed) {
      await e.body.add(BodyMeasurement(id: 'b$i', measuredAt: base.subtract(Duration(days: d.$1)), weightKg: d.$2));
    }
    await e.pump(t, initial: Routes.body);
    await settle(t);
    expect(find.byKey(const Key('body-hero')), findsOneWidget);
    expect(tester(t, 'body-hero'), '78.4');
    expect(find.text('지난주 대비 −0.6kg'), findsOneWidget);
    expect(find.byKey(const Key('body-chart')), findsOneWidget);
    expect(find.byKey(const Key('body-metric-height')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('body-metric-bmi')), matching: find.text('24.7')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('body-metric-bmi')), matching: find.text('계산')), findsOneWidget);
    expect(find.text('오늘 체중'), findsOneWidget);
    expect(find.text('체중 기록'), findsOneWidget);
  });

  testWidgets('신체 수치: 키가 없으면 키 줄은 "입력"으로 보이고 BMI 줄은 없음', (t) async {
    final e = AppEnv();
    await e.body.add(BodyMeasurement(id: 'b0', measuredAt: DateTime.utc(2026, 11, 25), weightKg: 70));
    await e.pump(t, initial: Routes.body);
    await settle(t);
    expect(find.byKey(const Key('body-metric-height')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('body-metric-height')), matching: find.text('입력')), findsOneWidget);
    expect(find.byKey(const Key('body-metric-bmi')), findsNothing);
    expect(find.byKey(const Key('body-chart')), findsNothing);
  });
}

String tester(WidgetTester t, String key) => (t.widget(find.byKey(Key(key))) as Text).data!;
