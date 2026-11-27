import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/theme.dart';
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

String _chipText(AppLocalizations l, SyncStatus s) =>
    s.phase == SyncPhase.offline && s.pending > 0 ? l.syncChipOfflinePending(s.pending) : _statusText(l, s);

/// 앱바 오른쪽 동기화 칩(목업): 상태 점 + 짧은 문구. 탭하면 [showSyncStatusSheet].
class SyncStatusIndicator extends ConsumerWidget {
  const SyncStatusIndicator({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final s = ref.watch(syncStatusProvider).value ?? const SyncStatus();
    final c = AppColors.of(context);
    final Widget mark;
    if (s.phase == SyncPhase.syncing) {
      mark = const SizedBox(
        key: Key('sync-icon-syncing'),
        width: 12,
        height: 12,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    } else {
      final (IconData data, String key, Color color) = switch (s.phase) {
        SyncPhase.offline => (Icons.cloud_off_outlined, 'offline', c.fg2),
        SyncPhase.error => (Icons.error_outline, 'error', c.fail),
        _ => s.pending > 0 ? (Icons.cloud_upload_outlined, 'pending', c.warn) : (Icons.circle, 'done', c.accent),
      };
      mark = Icon(data, key: Key('sync-icon-$key'), size: data == Icons.circle ? 8 : 14, color: color);
    }
    return Tooltip(
      message: _statusText(l, s),
      child: Semantics(
        button: true,
        label: _chipText(l, s),
        excludeSemantics: true,
        child: InkWell(
          key: const Key('sync-indicator'),
          borderRadius: BorderRadius.circular(24),
          onTap: () => showSyncStatusSheet(context),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
            child: Center(
              child: Container(
                margin: const EdgeInsetsDirectional.only(end: 8),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(color: c.surface3, borderRadius: BorderRadius.circular(24)),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    mark,
                    const SizedBox(width: 6),
                    Text(_chipText(l, s),
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: c.fg)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
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
