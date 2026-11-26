import 'dart:convert';

import 'package:fitlog/core/api/dto.dart';
import 'package:fitlog/core/auth/auth_controller.dart';
import 'package:fitlog/core/auth/token_store.dart';
import 'package:fitlog/core/settings/settings_controller.dart';
import 'package:fitlog/features/profile/profile_page.dart';
import 'package:fitlog/features/settings/settings_page.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../b1/helpers.dart';
import '../support/fixed_providers.dart';

/// 위젯 테스트에서 실제 비동기(SharedPreferences·Dio)와 fake 시계를 번갈아 돌린다.
Future<void> flush(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 200));

Map<String, Object?> putBody(FakeAdapter a) => (a.log.lastWhere((o) => o.method == 'PUT').data as Map).cast();

const profileFull = Settings(heightCm: 175, sex: Sex.MALE, birthYear: 1990);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({settingsCacheKey: jsonEncode(profileFull.toJson())}));

  group('SettingsController: null 필드', () {
    test('Settings.toJson은 비운 필드를 null로 명시한다', () {
      final j = profileFull.copyWith(heightCm: () => null, sex: () => null, birthYear: () => null).toJson();
      expect(j.containsKey('heightCm'), isTrue);
      expect(j['heightCm'], isNull);
      expect(j.containsKey('sex') && j['sex'] == null, isTrue);
      expect(j.containsKey('birthYear') && j['birthYear'] == null, isTrue);
    });

    test('PUT 본문에 "heightCm": null이 들어가고 캐시도 null로 저장된다', () async {
      final a = FakeAdapter((o) => o.method == 'PUT' ? json(o.data) : errorBody(500, 'X'));
      final c = authContainer(
        adapter: a,
        extra: [authControllerProvider.overrideWith(() => FixedAuth(AuthStatus.signedOut))],
      );
      c.read(settingsProvider);
      await settle();
      expect(c.read(settingsProvider).heightCm, 175);

      await c
          .read(settingsProvider.notifier)
          .update(c.read(settingsProvider).copyWith(heightCm: () => null, sex: () => null, birthYear: () => null));
      final body = putBody(a);
      expect(body.containsKey('heightCm'), isTrue);
      expect(body['heightCm'], isNull);
      expect(body['sex'], isNull);
      expect(body['birthYear'], isNull);
      expect(jsonEncode(body), contains('"heightCm":null'));
      expect(c.read(settingsProvider).heightCm, isNull);
      expect(c.read(settingsProvider).sex, isNull);

      final prefs = await SharedPreferences.getInstance();
      final cached = jsonDecode(prefs.getString(settingsCacheKey)!) as Map;
      expect(cached.containsKey('heightCm'), isTrue);
      expect(cached['heightCm'], isNull);
      expect(Settings.fromJson(cached.cast()).heightCm, isNull);
    });

    test('저장 실패하면 비우기 전 값으로 되돌린다(캐시 포함)', () async {
      final a = FakeAdapter((o) => o.method == 'PUT' ? errorBody(500, 'X') : errorBody(500, 'X'));
      final c = authContainer(
        adapter: a,
        extra: [authControllerProvider.overrideWith(() => FixedAuth(AuthStatus.signedOut))],
      );
      c.read(settingsProvider);
      await settle();
      await expectLater(
        c.read(settingsProvider.notifier).update(c.read(settingsProvider).copyWith(heightCm: () => null)),
        throwsA(anything),
      );
      expect(c.read(settingsProvider).heightCm, 175);
      final prefs = await SharedPreferences.getInstance();
      expect((jsonDecode(prefs.getString(settingsCacheKey)!) as Map)['heightCm'], 175);
    });

    test('추정식 변경이 PUT 본문에 실린다', () async {
      final a = FakeAdapter((o) => o.method == 'PUT' ? json(o.data) : errorBody(500, 'X'));
      final c = authContainer(
        adapter: a,
        extra: [authControllerProvider.overrideWith(() => FixedAuth(AuthStatus.signedOut))],
      );
      c.read(settingsProvider);
      await settle();
      await c.read(settingsProvider.notifier).update(c.read(settingsProvider).copyWith(e1rmFormula: E1rmFormula.BRZYCKI));
      expect(putBody(a)['e1rmFormula'], 'BRZYCKI');
      expect(c.read(settingsProvider).e1rmFormula, E1rmFormula.BRZYCKI);
    });
  });

  group('ProfilePage', () {
    testWidgets('키·출생 연도 지우기와 성별 선택 안 함 -> PUT에 null', (tester) async {
      final a = FakeAdapter((o) => o.method == 'PUT' ? json(o.data) : errorBody(500, 'X'));
      final c = authContainer(
        adapter: a,
        extra: [authControllerProvider.overrideWith(() => FixedAuth(AuthStatus.signedOut))],
      );
      c.read(settingsProvider);
      await tester.pumpWidget(containerApp(c, const ProfilePage()));
      await flush(tester);
      expect(find.widgetWithText(TextField, '175'), findsOneWidget);
      expect(find.widgetWithText(TextField, '1990'), findsOneWidget);

      await tester.tap(find.byKey(const Key('profileHeightClear')));
      await tester.tap(find.byKey(const Key('profileBirthClear')));
      await tester.tap(find.byKey(const Key('profileSex')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('선택 안 함').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('profileSave')));
      await flush(tester);

      final body = putBody(a);
      expect(jsonEncode(body), contains('"heightCm":null'));
      expect(body['sex'], isNull);
      expect(body['birthYear'], isNull);
      expect(c.read(settingsProvider).heightCm, isNull);
      expect(c.read(settingsProvider).sex, isNull);
      expect(c.read(settingsProvider).birthYear, isNull);
      expect(find.text('저장했어요.'), findsOneWidget);
    });

    testWidgets('텍스트를 직접 지워도 비워진다', (tester) async {
      final a = FakeAdapter((o) => o.method == 'PUT' ? json(o.data) : errorBody(500, 'X'));
      final c = authContainer(
        adapter: a,
        extra: [authControllerProvider.overrideWith(() => FixedAuth(AuthStatus.signedOut))],
      );
      c.read(settingsProvider);
      await tester.pumpWidget(containerApp(c, const ProfilePage()));
      await flush(tester);
      await tester.enterText(find.byKey(const Key('profileHeight')), '');
      await tester.tap(find.byKey(const Key('profileSave')));
      await flush(tester);
      final body = putBody(a);
      expect(body['heightCm'], isNull);
      expect(body['sex'], 'MALE', reason: '건드리지 않은 값은 유지');
      expect(body['birthYear'], 1990);
    });
  });

  group('SettingsPage 추정식', () {
    testWidgets('기본은 Epley이고 선택하면 저장된다', (tester) async {
      await tester.pumpWidget(app(const SettingsPage(), overrides: [
        authControllerProvider.overrideWith(() => FixedAuthStatus(AuthStatus.signedOut)),
        settingsProvider.overrideWith(() => FixedSettings()),
        tokenStoreProvider.overrideWithValue(MemoryTokenStore()),
      ]));
      await tester.pump();
      final dd = find.byKey(const Key('e1rmDropdown'));
      expect(tester.widget<DropdownButton<E1rmFormula>>(dd).value, E1rmFormula.EPLEY);
      expect(find.textContaining('1 + 횟수/30'), findsOneWidget);

      await tester.ensureVisible(dd);
      await tester.tap(dd);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Brzycki').last);
      await tester.pumpAndSettle();
      expect(tester.widget<DropdownButton<E1rmFormula>>(dd).value, E1rmFormula.BRZYCKI);
      expect(find.textContaining('36 / (37'), findsOneWidget);
    });
  });
}
