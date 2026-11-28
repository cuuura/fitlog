import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/dto.dart';
import '../../core/auth/auth_controller.dart';
import '../../core/config.dart';
import '../../core/crash/crash_reporting.dart';
import '../../core/reminders/reminder_scheduler.dart';
import '../../core/reminders/reminder_settings.dart';
import '../../core/routes.dart';
import '../../core/ui/confirm.dart';
import '../../core/settings/settings_controller.dart';
import '../../data/providers.dart';
import '../../l10n/gen/app_localizations.dart';
import '../rest_timer/rest_timer_notifier.dart';
import '../sync_status/sync_status_indicator.dart';
import 'privacy_link.dart';

/// ACC-3 설정 + 계정(ACC-5, ACC-6 철회).
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  static const restOptions = [30, 45, 60, 90, 120, 150, 180, 240, 300];

  static String _e1rmName(AppLocalizations l, E1rmFormula f) => switch (f) {
    E1rmFormula.EPLEY => l.settingsE1rmEpley,
    E1rmFormula.BRZYCKI => l.settingsE1rmBrzycki,
    E1rmFormula.LOMBARDI => l.settingsE1rmLombardi,
  };

  static String _e1rmDesc(AppLocalizations l, E1rmFormula f) => switch (f) {
    E1rmFormula.EPLEY => l.settingsE1rmEpleyDesc,
    E1rmFormula.BRZYCKI => l.settingsE1rmBrzyckiDesc,
    E1rmFormula.LOMBARDI => l.settingsE1rmLombardiDesc,
  };

  Future<void> _update(BuildContext context, WidgetRef ref, Settings next) async {
    final l = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(settingsProvider.notifier).update(next);
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(l.settingsSaveFailed)));
    }
  }

  Future<void> _guard(BuildContext context, Future<void> Function() f) async {
    final messenger = ScaffoldMessenger.of(context);
    final msg = AppLocalizations.of(context).settingsActionFailed;
    try {
      await f();
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  Future<void> _guardWith(BuildContext context, String failMsg, Future<void> Function() f) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await f();
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(failMsg)));
    }
  }

  Future<void> _signOut(BuildContext context, WidgetRef ref) async {
    final l = AppLocalizations.of(context);
    var pending = 0;
    try {
      final st = await ref.read(syncServiceProvider).watchStatus().first.timeout(const Duration(seconds: 2));
      pending = st.pending;
    } catch (_) {}
    if (!context.mounted) return;
    final ok = pending > 0
        ? await confirmAction(
            context,
            title: l.settingsSignOutPendingTitle,
            body: l.settingsSignOutPendingBody(pending),
            action: l.settingsSignOutAnyway,
            confirmKey: const Key('dialogConfirm'),
            destructive: true,
          )
        : await confirmAction(
            context,
            title: l.settingsSignOutConfirmTitle,
            body: l.settingsSignOutConfirmBody,
            action: l.settingsSignOut,
            confirmKey: const Key('dialogConfirm'),
          );
    if (!ok || !context.mounted) return;
    await _guard(context, () => ref.read(authControllerProvider.notifier).signOut());
  }

  Future<void> _deleteAccount(BuildContext context, WidgetRef ref) async {
    final l = AppLocalizations.of(context);
    final ok = await confirmAction(
      context,
      title: l.settingsDeleteConfirmTitle,
      body: l.settingsDeleteConfirmBody,
      action: l.settingsDeleteConfirmAction,
      confirmKey: const Key('dialogConfirm'),
      destructive: true,
    );
    if (!ok || !context.mounted) return;
    await _guard(context, () => ref.read(authControllerProvider.notifier).deleteAccount());
  }

  Future<void> _withdrawHealth(BuildContext context, WidgetRef ref) async {
    final l = AppLocalizations.of(context);
    final ok = await confirmAction(
      context,
      title: l.settingsWithdrawHealth,
      body: l.settingsWithdrawHealthBody,
      action: l.settingsWithdrawAction,
      confirmKey: const Key('dialogConfirm'),
      destructive: true,
    );
    if (!ok || !context.mounted) return;
    await _guard(context, () async {
      final auth = ref.read(authControllerProvider.notifier);
      await auth.recordConsent(ConsentKind.HEALTH_DATA, version: AppConfig.consentVersion, granted: false);
      await auth.refreshMe(); // 필수 동의가 비면 라우터가 동의 화면으로 보낸다.
    });
  }

  /// v1.2 운동 알림(LOG-12). 설정은 기기에만 저장한다.
  List<Widget> _reminderSection(BuildContext context, WidgetRef ref, AppLocalizations l, Widget Function(String) header) {
    final r = ref.watch(reminderSettingsProvider);
    Future<void> set(ReminderSettings next) => _guardWith(
      context,
      l.settingsSaveFailed,
      () => ref.read(reminderSettingsProvider.notifier).update(next),
    );
    return [
      header(l.settingsSectionReminder),
      SwitchListTile(
        key: const Key('reminderEnabled'),
        title: Text(l.reminderEnable),
        subtitle: Text(l.reminderEnableDesc),
        value: r.enabled,
        onChanged: (v) async {
          if (v) await ref.read(reminderSchedulerProvider).requestPermission();
          if (!context.mounted) return;
          await set(r.copyWith(enabled: v));
        },
      ),
      if (r.enabled) ...[
        ListTile(
          key: const Key('reminderTime'),
          title: Text(l.reminderTime),
          subtitle: Text(MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay(hour: r.hour, minute: r.minute), alwaysUse24HourFormat: true)),
          enabled: r.when == ReminderWhen.sameDay,
          onTap: () async {
            final t = await showTimePicker(context: context, initialTime: TimeOfDay(hour: r.hour, minute: r.minute));
            if (t == null || !context.mounted) return;
            await set(r.copyWith(hour: t.hour, minute: t.minute));
          },
        ),
        ListTile(
          title: Text(l.reminderWhen),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: SegmentedButton<ReminderWhen>(
              key: const Key('reminderWhen'),
              showSelectedIcon: false,
              segments: [
                ButtonSegment(value: ReminderWhen.sameDay, label: Text(l.reminderWhenSameDay)),
                ButtonSegment(value: ReminderWhen.eveBefore, label: Text(l.reminderWhenEve)),
              ],
              selected: {r.when},
              onSelectionChanged: (v) => set(r.copyWith(when: v.first)),
            ),
          ),
        ),
      ],
    ];
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final s = ref.watch(settingsProvider);
    ref.watch(authControllerProvider);
    final me = ref.read(authControllerProvider.notifier).me;
    final options = {...restOptions, s.defaultRestSec}.toList()..sort();
    final theme = Theme.of(context);

    Widget header(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Text(text, style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary)),
    );

    return Scaffold(
      appBar: AppBar(title: Text(l.settingsTitle)),
      body: ListView(
        children: [
          header(l.settingsSectionTraining),
          ListTile(
            title: Text(l.settingsWeightUnit),
            // 큰 글씨·영어에서 trailing이 타일 폭을 다 먹지 않게 컨트롤은 제목 아래에 둔다.
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SegmentedButton<WeightUnit>(
                key: const Key('unitToggle'),
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(value: WeightUnit.KG, label: Text(l.settingsUnitKg)),
                  ButtonSegment(value: WeightUnit.LB, label: Text(l.settingsUnitLb)),
                ],
                selected: {s.weightUnit},
                onSelectionChanged: (v) => _update(context, ref, s.copyWith(weightUnit: v.first)),
              ),
            ),
          ),
          ListTile(
            title: Text(l.settingsRestTime),
            subtitle: DropdownButton<int>(
              key: const Key('restDropdown'),
              isExpanded: true,
              value: s.defaultRestSec,
              items: [for (final o in options) DropdownMenuItem(value: o, child: Text(l.settingsRestSeconds(o)))],
              onChanged: (v) => v == null ? null : _update(context, ref, s.copyWith(defaultRestSec: v)),
            ),
          ),
          SwitchListTile(
            key: const Key('keepScreenOn'),
            title: Text(l.settingsKeepScreenOn),
            subtitle: Text(l.settingsKeepScreenOnDesc),
            value: s.keepScreenOn,
            onChanged: (v) => _update(context, ref, s.copyWith(keepScreenOn: v)),
          ),
          SwitchListTile(
            key: const Key('rpeInput'),
            title: Text(l.settingsRpe),
            subtitle: Text(l.settingsRpeDesc),
            value: s.rpeInputEnabled,
            onChanged: (v) => _update(context, ref, s.copyWith(rpeInputEnabled: v)),
          ),
          ListTile(
            title: Text(l.settingsE1rm),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DropdownButton<E1rmFormula>(
                  key: const Key('e1rmDropdown'),
                  isExpanded: true,
                  value: s.e1rmFormula,
                  items: [for (final f in E1rmFormula.values) DropdownMenuItem(value: f, child: Text(_e1rmName(l, f)))],
                  onChanged: (v) => v == null ? null : _update(context, ref, s.copyWith(e1rmFormula: v)),
                ),
                Text('${_e1rmDesc(l, s.e1rmFormula)}\n${l.settingsE1rmNote}', key: const Key('e1rmDesc')),
              ],
            ),
          ),
          if (ref.watch(restTimerNotifierProvider).supportsExactAlarm)
            ListTile(
              key: const Key('exactAlarm'),
              title: Text(l.settingsExactAlarm),
              subtitle: Text(l.settingsExactAlarmDesc),
              onTap: () => _guard(context, () async {
                await ref.read(restTimerNotifierProvider).requestExactAlarmPermission();
              }),
            ),
          ..._reminderSection(context, ref, l, header),
          header(l.settingsSectionData),
          ListTile(
            key: const Key('csvImportTile'),
            title: Text(l.settingsCsvImport),
            subtitle: Text(l.settingsCsvImportDesc),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push(Routes.csvImport),
          ),
          header(l.settingsSectionAccount),
          if (me != null)
            ListTile(
              key: const Key('accountTile'),
              title: Text(me.username ?? me.email),
              subtitle: me.isPasswordAccount
                  ? Text(
                      me.displayName == null
                          ? l.authPasswordAccountLabel
                          : '${l.authPasswordAccountLabel} · ${me.displayName}',
                    )
                  : (me.displayName == null ? null : Text(me.displayName!)),
            ),
          ListTile(
            key: const Key('syncTile'),
            title: Text(l.syncSheetTitle),
            onTap: () => showSyncStatusSheet(context),
          ),
          if (ref.watch(crashReportingAvailableProvider))
            SwitchListTile(
              key: const Key('crashReport'),
              title: Text(l.qaCrashReportTitle),
              subtitle: Text(l.qaCrashReportDesc),
              value: ref.watch(crashReportingEnabledProvider),
              onChanged: (v) => _guardWith(
                context,
                l.qaCrashReportSaveFailed,
                () => ref.read(crashReportingEnabledProvider.notifier).set(v),
              ),
            ),
          const PrivacyPolicyTile(),
          ListTile(
            key: const Key('withdrawHealth'),
            title: Text(l.settingsWithdrawHealth),
            onTap: () => _withdrawHealth(context, ref),
          ),
          ListTile(key: const Key('signOut'), title: Text(l.settingsSignOut), onTap: () => _signOut(context, ref)),
          ListTile(
            key: const Key('deleteAccount'),
            title: Text(l.settingsDeleteAccount, style: TextStyle(color: theme.colorScheme.error)),
            onTap: () => _deleteAccount(context, ref),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
