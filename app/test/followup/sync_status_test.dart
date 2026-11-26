import 'dart:async';

import 'package:fitlog/core/auth/auth_controller.dart';
import 'package:fitlog/core/settings/settings_controller.dart';
import 'package:fitlog/data/providers.dart';
import 'package:fitlog/domain/repositories.dart';
import 'package:fitlog/features/rest_timer/rest_timer_notifier.dart';
import 'package:fitlog/features/settings/settings_page.dart';
import 'package:fitlog/features/sync_status/sync_status_indicator.dart';
import 'package:fitlog/l10n/gen/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/fixed_providers.dart';

class FakeSync implements SyncService {
  final ctrl = StreamController<SyncStatus>.broadcast();
  int syncNowCalls = 0;
  @override
  Stream<SyncStatus> watchStatus() => ctrl.stream;
  @override
  Future<void> syncNow() async => syncNowCalls++;
  @override
  void schedule({Duration delay = const Duration(seconds: 5)}) {}
}

class ExactNotifier extends NoopRestTimerNotifier {
  final bool supported;
  int requested = 0;
  ExactNotifier(this.supported);
  @override
  bool get supportsExactAlarm => supported;
  @override
  Future<bool> requestExactAlarmPermission() async {
    requested++;
    return supported;
  }
}

Widget wrap(FakeSync sync, Widget home, {RestTimerNotifier? notifier}) => ProviderScope(
      overrides: [
        syncServiceProvider.overrideWithValue(sync),
        restTimerNotifierProvider.overrideWithValue(notifier ?? NoopRestTimerNotifier()),
        authControllerProvider.overrideWith(() => FixedAuthStatus(AuthStatus.signedIn)),
        settingsProvider.overrideWith(() => FixedSettings()),
      ],
      child: MaterialApp(
        locale: const Locale('ko'),
        localizationsDelegates: const [AppLocalizations.delegate, ...GlobalMaterialLocalizations.delegates],
        supportedLocales: AppLocalizations.supportedLocales,
        home: home,
      ),
    );

void main() {
  Future<FakeSync> pumpIndicator(WidgetTester t) async {
    final sync = FakeSync();
    addTearDown(sync.ctrl.close);
    await t.pumpWidget(wrap(sync, const Scaffold(body: Center(child: SyncStatusIndicator()))));
    return sync;
  }

  testWidgets('상태별 아이콘과 툴팁', (t) async {
    final sync = await pumpIndicator(t);
    Future<void> emit(SyncStatus s) async {
      sync.ctrl.add(s);
      await t.pump();
      await t.pump();
    }

    await emit(const SyncStatus());
    expect(find.byKey(const Key('sync-icon-done')), findsOneWidget);
    await emit(const SyncStatus(pending: 3));
    expect(find.byKey(const Key('sync-icon-pending')), findsOneWidget);
    expect(find.byTooltip('3개 대기 중'), findsOneWidget);
    await emit(const SyncStatus(phase: SyncPhase.offline));
    expect(find.byKey(const Key('sync-icon-offline')), findsOneWidget);
    await emit(const SyncStatus(phase: SyncPhase.error, lastError: 'boom'));
    expect(find.byKey(const Key('sync-icon-error')), findsOneWidget);
    await emit(const SyncStatus(phase: SyncPhase.syncing));
    expect(find.byKey(const Key('sync-icon-syncing')), findsOneWidget);
  });

  testWidgets('시트의 지금 동기화가 syncNow를 부른다', (t) async {
    final sync = await pumpIndicator(t);
    sync.ctrl.add(SyncStatus(phase: SyncPhase.error, pending: 2, lastError: 'boom', lastSyncedAt: DateTime.utc(2026, 1, 2, 3, 4)));
    await t.pump();
    await t.pump();
    await t.tap(find.byKey(const Key('sync-indicator')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('sync-sheet-pending')), findsOneWidget);
    expect(find.text('boom'), findsOneWidget);
    await t.tap(find.byKey(const Key('sync-now')));
    await t.pump();
    expect(sync.syncNowCalls, 1);
  });

  testWidgets('설정 화면: 동기화 항목과 정확한 알림 항목', (t) async {
    final sync = FakeSync();
    addTearDown(sync.ctrl.close);
    final n = ExactNotifier(true);
    await t.pumpWidget(wrap(sync, const SettingsPage(), notifier: n));
    await t.pump();
    final scroll = find.byType(Scrollable).first;
    await t.scrollUntilVisible(find.byKey(const Key('syncTile')), 200, scrollable: scroll);
    expect(find.byKey(const Key('syncTile')), findsOneWidget);
    await t.scrollUntilVisible(find.byKey(const Key('exactAlarm')), -200, scrollable: scroll);
    await t.tap(find.byKey(const Key('exactAlarm')));
    await t.pump();
    expect(n.requested, 1);
    await t.scrollUntilVisible(find.byKey(const Key('syncTile')), 200, scrollable: scroll);
    await t.tap(find.byKey(const Key('syncTile')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('sync-now')), findsOneWidget);
  });

  testWidgets('지원 안 하면 정확한 알림 항목을 숨긴다', (t) async {
    final sync = FakeSync();
    addTearDown(sync.ctrl.close);
    await t.pumpWidget(wrap(sync, const SettingsPage()));
    await t.pump();
    expect(find.byKey(const Key('exactAlarm')), findsNothing);
    await t.scrollUntilVisible(find.byKey(const Key('syncTile')), 200, scrollable: find.byType(Scrollable).first);
    expect(find.byKey(const Key('syncTile')), findsOneWidget);
  });
}
