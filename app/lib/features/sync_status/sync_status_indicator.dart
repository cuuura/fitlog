import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../data/providers.dart';
import '../../domain/repositories.dart';
import '../../l10n/gen/app_localizations.dart';
import 'sync_status_provider.dart';

export 'sync_status_provider.dart';

String _statusText(AppLocalizations l, SyncStatus s) => switch (s.phase) {
      SyncPhase.syncing => l.syncStatusSyncing,
      SyncPhase.offline => l.syncStatusOffline,
      SyncPhase.error => l.syncStatusError,
      SyncPhase.idle => s.pending > 0 ? l.syncPendingCount(s.pending) : l.syncStatusDone,
    };

String _formatLocal(DateTime t) {
  final d = t.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}

/// 동기화 상태 아이콘. 탭하면 [showSyncStatusSheet].
class SyncStatusIndicator extends ConsumerWidget {
  const SyncStatusIndicator({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final s = ref.watch(syncStatusProvider).value ?? const SyncStatus();
    final scheme = Theme.of(context).colorScheme;
    final Widget icon;
    if (s.phase == SyncPhase.syncing) {
      icon = const SizedBox(
        key: Key('sync-icon-syncing'),
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    } else {
      final (IconData data, String key, Color? color) = switch (s.phase) {
        SyncPhase.offline => (Icons.cloud_off_outlined, 'offline', null),
        SyncPhase.error => (Icons.error_outline, 'error', scheme.error),
        _ => s.pending > 0
            ? (Icons.cloud_upload_outlined, 'pending', null)
            : (Icons.cloud_done_outlined, 'done', null),
      };
      icon = Icon(data, key: Key('sync-icon-$key'), color: color);
    }
    return IconButton(
      key: const Key('sync-indicator'),
      tooltip: _statusText(l, s),
      icon: icon,
      onPressed: () => showSyncStatusSheet(context),
    );
  }
}

Future<void> showSyncStatusSheet(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => const _SyncSheet(),
    );

class _SyncSheet extends ConsumerWidget {
  const _SyncSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final s = ref.watch(syncStatusProvider).value ?? const SyncStatus();
    Widget row(String label, String value, {Key? key, Color? color}) => ListTile(
          dense: true,
          title: Text(label),
          trailing: Text(value, key: key, style: TextStyle(color: color)),
        );
    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(l.syncSheetTitle, style: theme.textTheme.titleMedium),
            ),
            row(
                l.syncStatusLabel,
                switch (s.phase) {
                  SyncPhase.syncing => l.syncStatusSyncing,
                  SyncPhase.offline => l.syncStatusOffline,
                  SyncPhase.error => l.syncStatusError,
                  SyncPhase.idle => l.syncStatusDone,
                },
                key: const Key('sync-sheet-status')),
            row(l.syncPendingLabel, '${s.pending}', key: const Key('sync-sheet-pending')),
            row(l.syncLastSyncedLabel, s.lastSyncedAt == null ? l.syncNever : _formatLocal(s.lastSyncedAt!),
                key: const Key('sync-sheet-last')),
            if (s.lastError != null)
              row(l.syncLastErrorLabel, s.lastError!, key: const Key('sync-sheet-error'), color: theme.colorScheme.error),
            Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: const Key('sync-now'),
                  onPressed: s.phase == SyncPhase.syncing
                      ? null
                      : () async {
                          try {
                            await ref.read(syncServiceProvider).syncNow();
                          } catch (_) {}
                        },
                  child: Text(l.syncNowAction),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
