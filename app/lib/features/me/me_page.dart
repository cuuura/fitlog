import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/dto.dart';
import '../../core/auth/auth_controller.dart';
import '../../core/big3.dart';
import '../../core/routes.dart';
import '../../core/settings/settings_controller.dart';
import '../../core/theme.dart';
import '../../core/units.dart';
import '../../data/providers.dart';
import '../../l10n/gen/app_localizations.dart';
import '../deletion_requests/deletion_providers.dart';
import '../records/one_rm_sheet.dart';
import '../session/session_format.dart';
import '../sync_status/sync_status_indicator.dart';
import 'big3_logic.dart';
import 'big3_page.dart';

final _latestBodyProvider = StreamProvider.autoDispose<BodyMeasurement?>(
  (ref) => ref.watch(bodyRepositoryProvider).watchMeasurements().map((l) => l.isEmpty ? null : l.first),
);

/// 하단 내비 'MY' 탭: 프로필 요약과 신체·프로필·AI·내보내기·설정 진입.
String _trim(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

class MePage extends ConsumerWidget {
  const MePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final c = AppColors.of(context);
    final s = ref.watch(settingsProvider);
    ref.watch(authControllerProvider);
    final me = ref.read(authControllerProvider.notifier).me;
    final latest = ref.watch(_latestBodyProvider).value;
    final pending = ref.watch(pendingDeletionCountProvider).value ?? 0;

    final name = me == null ? l.meGuestName : (me.displayName ?? me.username ?? me.email);
    final sub = me == null ? null : (me.isPasswordAccount ? me.username : me.email);

    final profileParts = [
      if (s.heightCm != null) l.meHeight(_trim(s.heightCm!)),
      if (s.birthYear != null) l.meBirthYear(s.birthYear!),
    ];

    Widget tile({
      required Key key,
      required IconData icon,
      required String title,
      String? subtitle,
      Widget? badge,
      required String route,
    }) =>
        Card(
          margin: const EdgeInsets.symmetric(vertical: 4),
          child: InkWell(
            key: key,
            borderRadius: BorderRadius.circular(AppRadius.md),
            onTap: () => context.push(route),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 64),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(
                  children: [
                    Icon(icon, color: c.accentStrong),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                          if (subtitle != null)
                            Text(subtitle, style: TextStyle(fontSize: 13, color: c.fg2)),
                        ],
                      ),
                    ),
                    if (badge != null) ...[badge, const SizedBox(width: 8)],
                    Icon(Icons.chevron_right, color: c.fg2),
                  ],
                ),
              ),
            ),
          ),
        );

    return Scaffold(
      appBar: AppBar(title: Text(l.meTitle), actions: const [SyncStatusIndicator()]),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            key: const Key('me-header'),
            children: [
              CircleAvatar(
                radius: 28,
                backgroundColor: c.accentSoft,
                child: Icon(Icons.person, color: c.accentStrong, size: 30),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, key: const Key('me-name'), style: Theme.of(context).textTheme.titleLarge),
                    if (sub != null) Text(sub, key: const Key('me-sub'), style: TextStyle(color: c.fg2)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          tile(
            key: const Key('me-body'),
            icon: Icons.monitor_weight_outlined,
            title: l.meSectionBody,
            subtitle: latest == null ? l.meBodyEmpty : l.meBodyLatest(Units.format(latest.weightKg, s.weightUnit)),
            route: Routes.body,
          ),
          const _Big3Card(),
          tile(
            key: const Key('me-profile'),
            icon: Icons.badge_outlined,
            title: l.meSectionProfile,
            subtitle: profileParts.isEmpty ? l.meProfileEmpty : profileParts.join(' · '),
            route: Routes.profile,
          ),
          tile(
            key: const Key('me-ai'),
            icon: Icons.auto_awesome_outlined,
            title: l.meSectionAi,
            subtitle: l.meAiSubtitle,
            badge: pending > 0
                ? Container(
                    key: const Key('me-ai-badge'),
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(color: c.aiSoft, borderRadius: BorderRadius.circular(12)),
                    child: Text(l.meAiPending(pending),
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: c.ai)),
                  )
                : null,
            route: Routes.ai,
          ),
          tile(
            key: const Key('me-export'),
            icon: Icons.ios_share,
            title: l.meSectionExport,
            subtitle: l.meExportSubtitle,
            route: Routes.export,
          ),
          tile(
            key: const Key('me-settings'),
            icon: Icons.settings_outlined,
            title: l.meSectionSettings,
            subtitle: l.meSettingsSubtitle,
            route: Routes.settings,
          ),
        ],
      ),
    );
  }
}

/// MY 탭의 '3대 운동 1RM' 카드: 현재 값과 합계, 입력 버튼. 탭하면 추이 화면.
class _Big3Card extends ConsumerWidget {
  const _Big3Card();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final c = AppColors.of(context);
    final unit = ref.watch(settingsProvider).weightUnit;
    final async = ref.watch(big3CurrentsProvider);
    final cur = async.value;

    Widget cell(int i) {
      final lift = big3Lifts[i];
      final v = cur?[i];
      final muted = v == null || !v.measured;
      return Expanded(
        child: Column(
          key: Key('me-big3-${lift.key}'),
          children: [
            Text(lift.shortName(l), style: TextStyle(fontSize: 13, color: c.fg2)),
            const SizedBox(height: 4),
            Text(
              v == null ? '-' : Units.format(v.kg, unit, withUnit: false),
              style: AppNum.style(context, 26, color: muted ? c.fg2 : null),
            ),
            const SizedBox(height: 2),
            Text(
              v == null
                  ? (async.isLoading ? '' : l.big3NoRecord)
                  : (v.measured ? l.big3SrcMeasured : l.big3SrcEstimated)(shortDate(v.date.toLocal())),
              style: TextStyle(fontSize: 12, color: v != null && v.measured ? c.accentStrong : c.fg2),
            ),
          ],
        ),
      );
    }

    return Card(
      key: const Key('me-big3'),
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: () => context.push(Routes.big3),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.fitness_center, color: c.accentStrong),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(l.big3Title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  ),
                  Text(l.big3ViewTrend, style: TextStyle(fontSize: 13, color: c.fg2)),
                  Icon(Icons.chevron_right, color: c.fg2),
                ],
              ),
              const SizedBox(height: 12),
              if (async.hasError)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    isOfflineError(async.error) ? l.progressOffline : l.big3CardError,
                    key: const Key('me-big3-error'),
                    textAlign: TextAlign.center,
                    style: TextStyle(color: c.fg2),
                  ),
                )
              else
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [for (var i = 0; i < 3; i++) cell(i)]),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      cur == null ? '' : big3TotalLabel(l, big3Total(cur), unit),
                      key: const Key('me-big3-total'),
                      style: TextStyle(fontSize: 14, color: c.fg2),
                    ),
                  ),
                  FilledButton.tonal(
                    key: const Key('me-big3-add'),
                    onPressed: () => showAddOneRmSheet(context, exerciseId: big3Ids.first, choices: big3Ids),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [const Icon(Icons.add, size: 18), const SizedBox(width: 4), Text(l.big3Add)],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
