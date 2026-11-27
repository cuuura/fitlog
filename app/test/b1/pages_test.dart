import 'package:fitlog/core/api/dto.dart';
import 'package:fitlog/core/auth/auth_controller.dart';
import 'package:fitlog/core/auth/token_store.dart';
import 'package:fitlog/core/settings/settings_controller.dart';
import 'package:fitlog/data/memory/memory_repositories.dart';
import 'package:fitlog/data/providers.dart';
import 'package:fitlog/domain/repositories.dart';
import 'package:fitlog/features/auth/consent_page.dart';
import 'package:fitlog/features/auth/login_page.dart';
import 'package:fitlog/features/profile/body_weight_page.dart';
import 'package:fitlog/features/settings/settings_page.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers.dart';

class FixedSettings extends SettingsController {
  final Settings initial;
  FixedSettings(this.initial);
  @override
  Settings build() => initial;
  @override
  Future<void> update(Settings next) async => state = next;
}

class PendingSync implements SyncService {
  final int pending;
  PendingSync(this.pending);
  @override
  Stream<SyncStatus> watchStatus() => Stream.value(SyncStatus(pending: pending));
  @override
  Future<void> syncNow() async {}
  @override
  void schedule({Duration delay = const Duration(seconds: 5)}) {}
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('ConsentPage', () {
    testWidgets('세 항목을 모두 체크해야 진행 가능, 기록 후 signedIn', (tester) async {
      var consented = false;
      final a = FakeAdapter((o) {
        if (o.path == '/v1/me/consents') {
          consented = true;
          return json({'kind': 'TERMS', 'version': 'v', 'granted': true}, 201);
        }
        return json(meJson(required: consented ? [] : ['TERMS', 'PRIVACY', 'HEALTH_DATA']));
      });
      final container = authContainer(
        adapter: a,
        extra: [authControllerProvider.overrideWith(() => FixedAuth(AuthStatus.needsConsent))],
      );
      await tester.pumpWidget(containerApp(container, const ConsentPage()));

      FilledButton btn() => tester.widget<FilledButton>(find.byKey(const Key('consentContinue')));
      expect(btn().onPressed, isNull);

      await tester.tap(find.byKey(const Key('consent_TERMS')));
      await tester.tap(find.byKey(const Key('consent_PRIVACY')));
      await tester.pump();
      expect(btn().onPressed, isNull); // HEALTH_DATA 빠짐

      await tester.tap(find.byKey(const Key('consent_HEALTH_DATA')));
      await tester.pump();
      expect(btn().onPressed, isNotNull);

      await tester.tap(find.byKey(const Key('consentContinue')));
      await tester.pumpAndSettle();
      expect(a.count('POST', '/v1/me/consents'), 3);
      expect(container.read(authControllerProvider), AuthStatus.signedIn);
    });

    testWidgets('기록 후에도 서버가 동의를 요구하면 오류 표시', (tester) async {
      final a = FakeAdapter((o) {
        if (o.path == '/v1/me/consents') return json({'kind': 'TERMS', 'version': 'v', 'granted': true}, 201);
        return json(meJson(required: ['TERMS', 'PRIVACY', 'HEALTH_DATA']));
      });
      final container = authContainer(
        adapter: a,
        extra: [authControllerProvider.overrideWith(() => FixedAuth(AuthStatus.needsConsent))],
      );
      await tester.pumpWidget(containerApp(container, const ConsentPage()));
      await tester.tap(find.byKey(const Key('consentAll')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('consentContinue')));
      await tester.pumpAndSettle();
      expect(container.read(authControllerProvider), AuthStatus.needsConsent);
      expect(find.byKey(const Key('consentError')), findsOneWidget);
    });

    testWidgets('모두 동의 체크로 한번에 선택', (tester) async {
      final container = authContainer(
        adapter: FakeAdapter((o) => json(meJson())),
        extra: [authControllerProvider.overrideWith(() => FixedAuth(AuthStatus.needsConsent))],
      );
      await tester.pumpWidget(containerApp(container, const ConsentPage()));
      await tester.tap(find.byKey(const Key('consentAll')));
      await tester.pump();
      expect(tester.widget<FilledButton>(find.byKey(const Key('consentContinue'))).onPressed, isNotNull);
    });
  });

  group('LoginPage', () {
    testWidgets('로그인 실패 시 오류 문구 표시', (tester) async {
      final container = authContainer(
        adapter: FakeAdapter((o) => errorBody(401, 'UNAUTHENTICATED')),
        google: FakeGoogle('bad'),
        extra: [authControllerProvider.overrideWith(() => FixedAuth(AuthStatus.signedOut))],
      );
      await tester.pumpWidget(containerApp(container, const LoginPage()));
      expect(find.byKey(const Key('loginError')), findsNothing);
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('loginError')), findsOneWidget);
    });
  });

  group('BodyWeightPage', () {
    Future<MemoryBodyRepository> pumpBody(WidgetTester tester, {WeightUnit unit = WeightUnit.KG}) async {
      final repo = MemoryBodyRepository();
      await tester.pumpWidget(app(const BodyWeightPage(), overrides: [
        bodyRepositoryProvider.overrideWithValue(repo),
        settingsProvider.overrideWith(() => FixedSettings(Settings(weightUnit: unit))),
      ]));
      await tester.pump();
      return repo;
    }

    testWidgets('추가하면 최신순으로 보이고 kg로 저장', (tester) async {
      final repo = await pumpBody(tester);
      expect(find.text('아직 기록이 없어요. 아래에서 체중을 추가해 보세요.'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('bodyInput')), '70.5');
      await tester.tap(find.byKey(const Key('bodyAdd')));
      await tester.pump();
      await tester.pump();
      expect(find.text('70.5 kg'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('bodyInput')), '71');
      await tester.tap(find.byKey(const Key('bodyAdd')));
      await tester.pump();
      await tester.pump();
      final list = await repo.watchMeasurements().first;
      expect(list.map((m) => m.weightKg), [71, 70.5]);
      expect(list.first.measuredAt.isUtc, isTrue);
      expect(list.first.source, MeasurementSource.MANUAL);
    });

    testWidgets('범위 밖 값은 거부', (tester) async {
      final repo = await pumpBody(tester);
      await tester.enterText(find.byKey(const Key('bodyInput')), '19');
      await tester.tap(find.byKey(const Key('bodyAdd')));
      await tester.pump();
      expect(find.textContaining('20~400 kg'), findsOneWidget);
      expect(await repo.watchMeasurements().first, isEmpty);
    });

    testWidgets('lb 설정이면 lb로 입력받아 kg로 저장하고 lb로 표시', (tester) async {
      final repo = await pumpBody(tester, unit: WeightUnit.LB);
      await tester.enterText(find.byKey(const Key('bodyInput')), '154');
      await tester.tap(find.byKey(const Key('bodyAdd')));
      await tester.pump();
      await tester.pump();
      expect(find.text('154 lb'), findsOneWidget);
      expect((await repo.watchMeasurements().first).single.weightKg, closeTo(69.85, 0.01));
    });

    testWidgets('삭제', (tester) async {
      final repo = await pumpBody(tester);
      await repo.add(BodyMeasurement(id: 'm1', measuredAt: DateTime.utc(2026, 1, 1), weightKg: 80));
      await tester.pump();
      await tester.pump();
      expect(find.text('80 kg'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('dialogConfirm')));
      await tester.pumpAndSettle();
      expect(find.text('80 kg'), findsNothing);
    });
  });

  group('SettingsPage', () {
    testWidgets('스위치 변경이 설정에 반영된다', (tester) async {
      await tester.pumpWidget(app(const SettingsPage(), overrides: [
        authControllerProvider.overrideWith(() => FixedAuth(AuthStatus.signedOut)),
        settingsProvider.overrideWith(() => FixedSettings(const Settings())),
        tokenStoreProvider.overrideWithValue(MemoryTokenStore()),
      ]));
      await tester.pump();
      final sw = find.descendant(of: find.byKey(const Key('keepScreenOn')), matching: find.byType(Switch));
      expect(tester.widget<Switch>(sw).value, isTrue);
      await tester.tap(find.byKey(const Key('keepScreenOn')));
      await tester.pump();
      expect(tester.widget<Switch>(sw).value, isFalse);
    });

    testWidgets('미동기화 변경이 있으면 로그아웃 전에 경고하고, 취소하면 유지', (tester) async {
      final a = FakeAdapter((o) => noContent());
      final container = authContainer(adapter: a, extra: [
        authControllerProvider.overrideWith(() => FixedAuth(AuthStatus.signedIn)),
        settingsProvider.overrideWith(() => FixedSettings(const Settings())),
        syncServiceProvider.overrideWithValue(PendingSync(3)),
      ]);
      await tester.pumpWidget(containerApp(container, const SettingsPage()));
      await tester.scrollUntilVisible(find.byKey(const Key('signOut')), 200, scrollable: find.byType(Scrollable).first);
      await tester.tap(find.byKey(const Key('signOut')));
      await tester.pumpAndSettle();
      expect(find.text('아직 동기화되지 않은 변경이 있어요'), findsOneWidget);
      expect(find.textContaining('3건'), findsOneWidget);
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();
      expect(container.read(authControllerProvider), AuthStatus.signedIn);
      expect(a.log, isEmpty);
    });
  });
}
