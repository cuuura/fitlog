import 'package:fitlog/core/api/ai_dto.dart';
import 'package:fitlog/core/auth/auth_controller.dart';
import 'package:fitlog/core/theme.dart';
import 'package:fitlog/core/ui/confirm.dart';
import 'package:fitlog/data/providers.dart';
import 'package:fitlog/l10n/gen/app_localizations.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import 'ai_avatar.dart';

final _mcpInfoProvider = FutureProvider.autoDispose<McpInfo>(
  (ref) => ref.watch(aiConnectionRepositoryProvider).mcpInfo(),
);
final _connectionsProvider = FutureProvider.autoDispose<List<AiConnection>>(
  (ref) => ref.watch(aiConnectionRepositoryProvider).connections(),
);

class AiConnectPage extends ConsumerWidget {
  const AiConnectPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    ref.watch(authControllerProvider);
    final info = ref.watch(_mcpInfoProvider);
    final conns = ref.watch(_connectionsProvider);
    void retry() {
      ref.invalidate(_mcpInfoProvider);
      ref.invalidate(_connectionsProvider);
    }

    Widget error() => Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l.aiConnectLoadFailed, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(onPressed: retry, child: Text(l.aiConnectRetry)),
          ],
        ),
      ),
    );

    return Scaffold(
      appBar: AppBar(title: Text(l.aiConnectTitle)),
      body: info.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => error(),
        data: (i) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(l.aiConnectUrlLabel, style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 4),
            SelectableText(i.mcpUrl, style: const TextStyle(fontFamily: 'monospace', fontSize: 14)),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.copy),
                label: Text(l.aiConnectCopyUrl),
                onPressed: () => _copy(context, i.mcpUrl),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: ListTile(leading: Icon(Icons.shield_outlined, color: AppColors.of(context).ai), title: Text(l.aiConnectPermission)),
            ),
            const SizedBox(height: 16),
            Text(l.aiConnectGuides, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (i.clients.isEmpty)
              _GuideCard(
                key: const ValueKey('guide-default'),
                name: l.aiConnectDefaultName,
                steps: [
                  l.aiConnectDefaultStep1,
                  l.aiConnectDefaultStep2,
                  l.aiConnectDefaultStep3,
                  l.aiConnectDefaultStep4,
                ],
                docUrl: null,
              )
            else
              for (final c in i.clients)
                _GuideCard(key: ValueKey('guide-${c.key}'), name: c.name, steps: c.steps, docUrl: c.docUrl),
            const SizedBox(height: 16),
            Text(l.aiConnectConnected, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            conns.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (_, _) => Column(
                children: [
                  Text(l.aiConnectLoadFailed),
                  TextButton(onPressed: () => ref.invalidate(_connectionsProvider), child: Text(l.aiConnectRetry)),
                ],
              ),
              data: (list) => list.isEmpty
                  ? Text(l.aiConnectNone)
                  : Column(
                      children: [for (final c in list) _ConnectionTile(key: ValueKey('conn-${c.id}'), conn: c)],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _copy(BuildContext context, String text) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(AppLocalizations.of(context).aiConnectCopied)));
  }
}

class _GuideCard extends StatelessWidget {
  final String name;
  final List<String> steps;
  final String? docUrl;
  const _GuideCard({super.key, required this.name, required this.steps, required this.docUrl});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Card(
      child: ExpansionTile(
        title: Text(name),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var n = 0; n < steps.length; n++)
            Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: Text('${n + 1}. ${steps[n]}')),
          if (docUrl != null) ...[
            const SizedBox(height: 8),
            Text('${l.aiConnectDocUrl}: $docUrl'),
            TextButton.icon(
              icon: const Icon(Icons.copy),
              label: Text(l.aiConnectCopyDoc),
              onPressed: () => _copy(context, docUrl!),
            ),
          ],
        ],
      ),
    );
  }
}

class _ConnectionTile extends ConsumerWidget {
  final AiConnection conn;
  const _ConnectionTile({super.key, required this.conn});

  Future<void> _disconnect(BuildContext context, WidgetRef ref) async {
    final l = AppLocalizations.of(context);
    final ok = await confirmAction(
      context,
      title: l.aiConnectDisconnectTitle(conn.clientName),
      body: l.aiConnectDisconnectBody,
      action: l.aiConnectDisconnect,
      destructive: true,
    );
    if (!ok) return;
    try {
      await ref.read(aiConnectionRepositoryProvider).disconnect(conn.id);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.aiConnectActionFailed)));
      }
    }
    ref.invalidate(_connectionsProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final fmt = DateFormat.yMd(Localizations.localeOf(context).toString()).add_Hm();
    final perm = conn.canWrite ? '${l.aiConnectRead}·${l.aiConnectWrite}' : l.aiConnectRead;
    final used = conn.lastUsedAt == null
        ? l.aiConnectNeverUsed
        : l.aiConnectLastUsed(fmt.format(conn.lastUsedAt!.toLocal()));
    return Card(
      child: ListTile(
        leading: AiAvatar(conn.clientName),
        title: Text(conn.clientName),
        subtitle: Text('$perm\n${l.aiConnectCreated(fmt.format(conn.createdAt.toLocal()))}\n$used'),
        isThreeLine: true,
        trailing: TextButton(onPressed: () => _disconnect(context, ref), child: Text(l.aiConnectDisconnect)),
      ),
    );
  }
}
