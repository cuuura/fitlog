// B2 소유. 묶음 상세와 되돌리기(import.md §6).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/ai_dto.dart';
import '../../core/ui/confirm.dart';
import '../../data/providers.dart';
import '../../l10n/gen/app_localizations.dart';
import '../programs/program_common.dart' show ErrorRetry;
import 'ai_labels.dart';

final aiBatchDetailProvider = FutureProvider.autoDispose.family<ImportBatchDetail, String>(
  (ref, id) => ref.watch(importRepositoryProvider).detail(id),
);

/// 되돌리기 확인 문구. "이 묶음으로 만든 세션 3개, 프로그램 1개가 지워집니다. 교체된 1개가 복원됩니다."
String revertConfirmText(AppLocalizations l, List<ImportItem> items) {
  final created = <String, int>{};
  var restored = 0;
  for (final i in items) {
    if (i.action == ImportItemAction.CREATED) {
      created[i.entity] = (created[i.entity] ?? 0) + 1;
    } else {
      restored++;
    }
  }
  final keys = [...aiEntityOrder.where(created.containsKey), ...created.keys.where((k) => !aiEntityOrder.contains(k))];
  final parts = [
    if (keys.isEmpty)
      l.aiHistoryRevertNothingCreated
    else
      l.aiHistoryRevertCreated(keys.map((k) => aiEntityCount(l, k, created[k]!)).join(', ')),
    if (restored > 0) l.aiHistoryRevertRestored(restored),
  ];
  return parts.join(' ');
}

class AiHistoryDetailPage extends ConsumerStatefulWidget {
  const AiHistoryDetailPage({super.key, required this.batchId});
  final String batchId;

  @override
  ConsumerState<AiHistoryDetailPage> createState() => _AiHistoryDetailPageState();
}

class _AiHistoryDetailPageState extends ConsumerState<AiHistoryDetailPage> {
  bool _busy = false;

  Future<void> _revert(ImportBatchDetail d) async {
    final l = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final ok = await confirmAction(
      context,
      title: l.aiHistoryRevertTitle,
      body: revertConfirmText(l, d.items),
      action: l.aiHistoryRevert,
      destructive: true,
      confirmKey: const Key('ai-revert-confirm'),
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref.read(importRepositoryProvider).revert(d.id);
      ref.invalidate(aiBatchDetailProvider(d.id));
      messenger.showSnackBar(SnackBar(content: Text(l.aiHistoryRevertDone)));
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(l.aiHistoryRevertFailed)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final async = ref.watch(aiBatchDetailProvider(widget.batchId));
    return Scaffold(
      appBar: AppBar(title: Text(l.aiHistoryDetailTitle)),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorRetry(error: e, onRetry: () => ref.invalidate(aiBatchDetailProvider(widget.batchId))),
        data: (d) {
          final theme = Theme.of(context);
          final byEntity = <String, List<ImportItem>>{};
          for (final i in d.items) {
            byEntity.putIfAbsent(i.entity, () => []).add(i);
          }
          final entities = [
            ...aiEntityOrder.where(byEntity.containsKey),
            ...byEntity.keys.where((k) => !aiEntityOrder.contains(k)),
          ];
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                [
                  aiDateTime(d.createdAt),
                  d.channel == ImportChannel.MCP ? l.aiHistoryChannelMcp : l.aiHistoryChannelApp,
                  if (d.clientName != null) d.clientName!,
                ].join(' · '),
                style: theme.textTheme.titleMedium,
              ),
              if (d.note != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(d.note!)),
              const SizedBox(height: 16),
              if (d.items.isEmpty) Text(l.aiHistoryNoItems),
              for (final e in entities) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 4),
                  child: Text(aiEntityLabel(l, e), style: theme.textTheme.titleSmall),
                ),
                for (final i in byEntity[e]!)
                  ListTile(
                    key: Key('ai-item-${i.entityId}-${i.action.name}'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(i.label ?? i.entityId),
                    trailing: Text(
                      i.action == ImportItemAction.CREATED ? l.aiHistoryActionCreated : l.aiHistoryActionReplacedOld,
                    ),
                  ),
              ],
              const SizedBox(height: 24),
              if (d.isReverted)
                Text(
                  l.aiHistoryRevertedAt(aiDateTime(d.revertedAt!)),
                  key: const Key('ai-reverted-at'),
                  style: theme.textTheme.bodyMedium,
                )
              else
                FilledButton.icon(
                  key: const Key('ai-revert'),
                  icon: const Icon(Icons.undo),
                  label: Text(l.aiHistoryRevert),
                  onPressed: _busy ? null : () => _revert(d),
                ),
            ],
          );
        },
      ),
    );
  }
}
