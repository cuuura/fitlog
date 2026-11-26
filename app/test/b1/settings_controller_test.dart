import 'dart:async';
import 'dart:convert';

import 'package:fitlog/core/api/api_client.dart';
import 'package:fitlog/core/api/dto.dart';
import 'package:fitlog/core/auth/auth_controller.dart';
import 'package:fitlog/core/settings/settings_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers.dart';

Future<void> pump() => Future<void>.delayed(const Duration(milliseconds: 200));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('캐시에서 즉시 로드한다', () async {
    SharedPreferences.setMockInitialValues({
      settingsCacheKey: jsonEncode(const Settings(weightUnit: WeightUnit.LB, defaultRestSec: 90).toJson()),
    });
    final c = authContainer(
      adapter: FakeAdapter((o) => errorBody(500, 'X')),
      extra: [authControllerProvider.overrideWith(() => FixedAuth(AuthStatus.signedOut))],
    );
    expect(c.read(settingsProvider).weightUnit, WeightUnit.KG); // 기본값으로 시작
    await pump();
    expect(c.read(settingsProvider).weightUnit, WeightUnit.LB);
    expect(c.read(settingsProvider).defaultRestSec, 90);
  });

  test('signedIn이 되면 서버 값으로 갱신하고 캐시에 저장', () async {
    final a = FakeAdapter((o) => json({'weightUnit': 'LB', 'defaultRestSec': 60, 'keepScreenOn': false, 'rpeInputEnabled': true}));
    final c = authContainer(
      adapter: a,
      extra: [authControllerProvider.overrideWith(() => FixedAuth(AuthStatus.signedIn))],
    );
    c.read(settingsProvider);
    await pump();
    expect(c.read(settingsProvider).defaultRestSec, 60);
    expect(c.read(settingsProvider).keepScreenOn, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(jsonDecode(prefs.getString(settingsCacheKey)!)['defaultRestSec'], 60);
  });

  group('update', () {
    late FakeAdapter a;
    late Completer<void> gate;

    setUp(() {
      gate = Completer<void>();
      a = FakeAdapter((o) async {
        if (o.method == 'PUT') {
          await gate.future;
          return json(o.data);
        }
        return json(const Settings().toJson());
      });
    });

    test('낙관적으로 반영하고 서버에 PUT, 캐시 저장', () async {
      final c = authContainer(
        adapter: a,
        extra: [authControllerProvider.overrideWith(() => FixedAuth(AuthStatus.signedOut))],
      );
      final n = c.read(settingsProvider.notifier);
      final f = n.update(const Settings(defaultRestSec: 45));
      expect(c.read(settingsProvider).defaultRestSec, 45); // 서버 응답 전에 이미 반영
      gate.complete();
      await f;
      expect(a.log.single.data, containsPair('defaultRestSec', 45));
      final prefs = await SharedPreferences.getInstance();
      expect(jsonDecode(prefs.getString(settingsCacheKey)!)['defaultRestSec'], 45);
    });

    test('서버가 거부하면 롤백하고 예외를 던진다', () async {
      a.handler = (o) => errorBody(400, 'VALIDATION_FAILED');
      final c = authContainer(
        adapter: a,
        extra: [authControllerProvider.overrideWith(() => FixedAuth(AuthStatus.signedOut))],
      );
      final n = c.read(settingsProvider.notifier);
      await pump();
      await expectLater(n.update(const Settings(defaultRestSec: 45)), throwsA(isA<ApiException>()));
      expect(c.read(settingsProvider).defaultRestSec, 120);
      final prefs = await SharedPreferences.getInstance();
      expect(jsonDecode(prefs.getString(settingsCacheKey)!)['defaultRestSec'], 120);
    });
  });
}
