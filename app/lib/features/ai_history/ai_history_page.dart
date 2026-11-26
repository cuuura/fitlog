// B2 소유. AI-6 가져오기 이력(온라인 전용). before 커서로 더 보기.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/ai_dto.dart';
import '../../core/routes.dart';
import '../../data/providers.dart';
import '../../l10n/gen/app_localizations.dart';
import '../programs/program_common.dart' show ErrorRetry;
import 'ai_labels.dart';

const aiHistoryPageSize = 20;

class AiHistoryPage extends ConsumerStatefulWidget {
  const AiHistoryPage({super.key});

  @override
  ConsumerState<AiHistoryPage> createState() => _AiHistoryPageState();
}

class _AiHistoryPageState extends ConsumerState<AiHistoryPage> {
  final List<ImportBatch> _items = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await ref.read(importRepositoryProvider).history(limit: aiHistoryPageSize);
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(page);
        _hasMore = page.length >= aiHistoryPageSize;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _more() async {
    if (_loadingMore || _items.isEmpty) return;
    setState(() => _loadingMore = true);
    try {
      final page = await ref
          .read(importRepositoryProvider)
          .history(before: _items.last.createdAt, limit: aiHistoryPageSize);
      if (!mounted) return;
      setState(() {
        _items.addAll(page);
        _hasMore = page.length >= aiHistoryPageSize;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
    }
  }

  String _summary(AppLocalizations l, ImportBatch b) {
    final parts = <String>[];
    for (final e in b.summary.entries) {
      if (e.value == 0) continue;
      parts.add(switch (e.key) {
        'sessions' => l.aiHistorySummarySessions(e.value),
        'programs' => l.aiHistorySummaryPrograms(e.value),
        'replaced' => l.aiHistorySummaryReplaced(e.value),
        _ => l.aiHistorySummaryOther(e.key, e.value),
      });
    }
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    Widget body;
    if (_loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_error != null) {
      body = ErrorRetry(error: _error!, onRetry: _reload);
    } else if (_items.isEmpty) {
      body = Center(child: Text(l.aiHistoryEmpty, key: const Key('ai-history-empty')));
    } else {
      body = RefreshIndicator(
        onRefresh: _reload,
        child: ListView(
          key: const Key('ai-history-list'),
          children: [
            for (final b in _items)
              ListTile(
                key: Key('ai-batch-${b.id}'),
                title: Text(
                  [
                    aiDateTime(b.createdAt),
                    b.channel == ImportChannel.MCP ? l.aiHistoryChannelMcp : l.aiHistoryChannelApp,
                    if (b.clientName != null) b.clientName!,
                  ].join(' · '),
                ),
                subtitle: Text([if (b.note != null) b.note!, _summary(l, b)].where((s) => s.isNotEmpty).join('\n')),
                isThreeLine: b.note != null,
                trailing: b.isReverted
                    ? Chip(
                        key: Key('ai-batch-reverted-${b.id}'),
                        label: Text(l.aiHistoryReverted),
                        visualDensity: VisualDensity.compact,
                      )
                    : const Icon(Icons.chevron_right),
                onTap: () async {
                  await context.push(Routes.aiHistoryDetail(b.id));
                  if (mounted) _reload();
                },
              ),
            if (_hasMore)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Center(
                  child: _loadingMore
                      ? const CircularProgressIndicator()
                      : OutlinedButton(
                          key: const Key('ai-history-more'),
                          onPressed: _more,
                          child: Text(l.aiHistoryLoadMore),
                        ),
                ),
              ),
          ],
        ),
      );
    }
    return Scaffold(appBar: AppBar(title: Text(l.aiHistoryTitle)), body: body);
  }
}
