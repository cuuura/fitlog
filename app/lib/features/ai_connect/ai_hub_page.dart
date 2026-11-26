import 'package:fitlog/core/routes.dart';
import 'package:fitlog/data/providers.dart';
import 'package:fitlog/l10n/gen/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

final _hubConnectedCountProvider = FutureProvider.autoDispose<int>(
  (ref) async => (await ref.watch(aiConnectionRepositoryProvider).connections()).length,
);
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
    Widget tile(IconData icon, String title, String desc, String route, {Widget? trailing}) => ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(desc),
      isThreeLine: true,
      trailing: trailing ?? const Icon(Icons.chevron_right),
      onTap: () async {
        await context.push(route);
        ref.invalidate(_hubConnectedCountProvider);
        ref.invalidate(_hubPendingCountProvider);
      },
    );
    return Scaffold(
      appBar: AppBar(title: Text(l.aiHubTitle)),
      body: ListView(
        children: [
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
                    children: [Badge(label: Text(l.aiHubPending(pending))), const SizedBox(width: 8), const Icon(Icons.chevron_right)],
                  )
                : null,
          ),
          tile(Icons.ios_share, l.aiHubExport, l.aiHubExportDesc, Routes.export),
        ],
      ),
    );
  }
}
