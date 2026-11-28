import 'dart:convert';

import 'package:fitlog/core/api/dto.dart';
import 'package:fitlog/core/auth/auth_controller.dart';
import 'package:fitlog/core/auth/token_store.dart';
import 'package:fitlog/core/settings/settings_controller.dart';
import 'package:fitlog/features/profile/profile_page.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
      await c
          .read(settingsProvider.notifier)
          .update(c.read(settingsProvider).copyWith(e1rmFormula: E1rmFormula.BRZYCKI));
      expect(putBody(a)['e1rmFormula'], 'BRZYCKI');
      expect(c.read(settingsProvider).e1rmFormula, E1rmFormula.BRZYCKI);
    });
  });

  group('ProfilePage', () {
    Future<(FakeAdapter, ProviderContainer)> pumpProfile(WidgetTester tester, {bool failPut = false}) async {
      final a = FakeAdapter((o) => o.method == 'PUT' && !failPut ? json(o.data) : errorBody(500, 'X'));
      final c = authContainer(
        adapter: a,
        extra: [authControllerProvider.overrideWith(() => FixedAuth(AuthStatus.signedOut))],
      );
      c.read(settingsProvider);
      await tester.pumpWidget(containerApp(c, const ProfilePage()));
      await flush(tester);
      return (a, c);
    }

    testWidgets('값이 보이는 행 목록이고 입력란은 없다', (tester) async {
      await pumpProfile(tester);
      expect(find.byType(TextField), findsNothing);
      expect(
        find.descendant(of: find.byKey(const Key('profile-height')), matching: find.text('175 cm')),
        findsOneWidget,
      );
      expect(find.descendant(of: find.byKey(const Key('profile-sex')), matching: find.text('남성')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('profile-birth')), matching: find.text('1990')), findsOneWidget);
    });

    testWidgets('키 행 -> 시트에서 비워 저장하면 PUT에 null, 다른 값은 유지', (tester) async {
      final (a, c) = await pumpProfile(tester);
      await tester.tap(find.byKey(const Key('profile-height')));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, '175'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('profileHeight')), '');
      await tester.tap(find.byKey(const Key('profileSave')));
      await flush(tester);
      await tester.pumpAndSettle();

      final body = putBody(a);
      expect(jsonEncode(body), contains('"heightCm":null'));
      expect(body['sex'], 'MALE');
      expect(body['birthYear'], 1990);
      expect(c.read(settingsProvider).heightCm, isNull);
      expect(find.byKey(const Key('profileHeight')), findsNothing, reason: '저장하면 시트가 닫힌다');
      expect(
        find.descendant(of: find.byKey(const Key('profile-height')), matching: find.text('입력 안 함')),
        findsOneWidget,
      );
    });

    testWidgets('성별 행 -> 선택 안 함 저장 -> PUT에 null', (tester) async {
      final (a, c) = await pumpProfile(tester);
      await tester.tap(find.byKey(const Key('profile-sex')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('profileSex-none')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('profileSave')));
      await flush(tester);
      await tester.pumpAndSettle();
      expect(putBody(a)['sex'], isNull);
      expect(c.read(settingsProvider).sex, isNull);
      expect(c.read(settingsProvider).heightCm, 175);
    });

    testWidgets('출생 연도 행 -> 범위 밖이면 시트가 남고, 비우면 null', (tester) async {
      final (a, c) = await pumpProfile(tester);
      await tester.tap(find.byKey(const Key('profile-birth')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('profileBirth')), '1800');
      await tester.tap(find.byKey(const Key('profileSave')));
      await tester.pump();
      expect(find.textContaining('1900'), findsOneWidget);
      expect(a.log.where((o) => o.method == 'PUT'), isEmpty);

      await tester.enterText(find.byKey(const Key('profileBirth')), '');
      await tester.tap(find.byKey(const Key('profileSave')));
      await flush(tester);
      await tester.pumpAndSettle();
      expect(putBody(a)['birthYear'], isNull);
      expect(c.read(settingsProvider).birthYear, isNull);
    });

    testWidgets('저장 실패하면 시트 안에 오류를 보이고 입력을 유지한다', (tester) async {
      final (_, c) = await pumpProfile(tester, failPut: true);
      await tester.tap(find.byKey(const Key('profile-height')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('profileHeight')), '180');
      await tester.tap(find.byKey(const Key('profileSave')));
      await flush(tester);
      await tester.pump();
      expect(find.byKey(const Key('sheet-error')), findsOneWidget);
      expect(find.widgetWithText(TextField, '180'), findsOneWidget);
      expect(c.read(settingsProvider).heightCm, 175, reason: '실패하면 이전 값으로 되돌린다');
    });
  });

  group('SettingsPage 추정식', () {
    testWidgets('기본은 Epley이고 선택하면 저장된다', (tester) async {
      await tester.pumpWidget(
        app(
          const SettingsPage(),
          overrides: [
            authControllerProvider.overrideWith(() => FixedAuthStatus(AuthStatus.signedOut)),
            settingsProvider.overrideWith(() => FixedSettings()),
            tokenStoreProvider.overrideWithValue(MemoryTokenStore()),
          ],
        ),
      );
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
