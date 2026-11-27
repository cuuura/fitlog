import 'package:fitlog/core/api/ai_dto.dart';
import 'package:fitlog/core/clock.dart';
import 'package:fitlog/core/routes.dart';
import 'package:fitlog/core/theme.dart';
import 'package:fitlog/data/providers.dart';
import 'package:fitlog/l10n/gen/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../sync_status/sync_status_indicator.dart';
import 'ai_avatar.dart';

final _hubConnectionsProvider = FutureProvider.autoDispose<List<AiConnection>>(
  (ref) => ref.watch(aiConnectionRepositoryProvider).connections(),
);
final _hubConnectedCountProvider = FutureProvider.autoDispose<int>(
  (ref) async => (await ref.watch(_hubConnectionsProvider.future)).length,
);

/// "연결됨 · 마지막 사용 2일 전" / "연결됨 · 아직 사용 안 함".
String connectedLine(AppLocalizations l, AiConnection c, DateTime now) {
  final used = c.lastUsedAt;
  if (used == null) return l.aiConnectedNever;
  final days = now.difference(used).inDays;
  return days <= 0 ? l.aiConnectedToday : l.aiConnectedDaysAgo(days);
}
final _hubPendingCountProvider = FutureProvider.autoDispose<int>(
  (ref) => ref.watch(deletionRequestRepositoryProvider).pendingCount(),
);

class AiHubPage extends ConsumerWidget {
  const AiHubPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final connected = ref.watch(_hubConnectedCountProvider).asData?.value;
    final pending = ref.watch(_hubPendingCountProvider).asData?.value; // 오류면 숨김
    final conns = ref.watch(_hubConnectionsProvider).asData?.value;
    final now = ref.watch(clockProvider)();
    Widget tile(IconData icon, String title, String desc, String route, {Widget? trailing}) => ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(desc),
      isThreeLine: true,
      trailing: trailing ?? const Icon(Icons.chevron_right),
      onTap: () async {
        await context.push(route);
        ref.invalidate(_hubConnectionsProvider);
        ref.invalidate(_hubConnectedCountProvider);
        ref.invalidate(_hubPendingCountProvider);
      },
    );
    return Scaffold(
      appBar: AppBar(title: Text(l.aiHubTitle), actions: const [SyncStatusIndicator(), SizedBox(width: 8)]),
      body: ListView(
        children: [
          if (conns != null && conns.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Column(
                key: const Key('hub-connected-list'),
                children: [
                  for (final c in conns)
                    Container(
                      key: Key('hub-ai-${c.id}'),
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: AppColors.of(context).surface2,
                        borderRadius: BorderRadius.circular(AppRadius.md),
                      ),
                      child: Row(
                        children: [
                          AiAvatar(c.clientName),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(c.clientName, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                                Text(
                                  connectedLine(l, c, now),
                                  style: TextStyle(fontSize: 12, color: AppColors.of(context).fg2),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          tile(
            Icons.hub_outlined,
            l.aiHubConnect,
            connected == null ? l.aiHubConnectDesc : '${l.aiHubConnectDesc}\n${l.aiHubConnectedCount(connected)}',
            Routes.aiConnect,
          ),
          tile(Icons.content_paste_go_outlined, l.aiHubImport, l.aiHubImportDesc, Routes.importJson),
          tile(Icons.history, l.aiHubHistory, l.aiHubHistoryDesc, Routes.aiHistory),
          tile(
            Icons.delete_sweep_outlined,
            l.aiHubDeletions,
            l.aiHubDeletionsDesc,
            Routes.deletionRequests,
            trailing: pending != null && pending > 0
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [Badge(backgroundColor: AppColors.of(context).fail, label: Text(l.aiHubPending(pending))), const SizedBox(width: 8), const Icon(Icons.chevron_right)],
                  )
                : null,
          ),
          tile(Icons.ios_share, l.aiHubExport, l.aiHubExportDesc, Routes.export),
        ],
      ),
    );
  }
}
