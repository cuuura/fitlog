// B1 소유. 진행 중 프로그램 / 프로그램(템플릿·내 프로그램) 목록.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/program_dto.dart';
import '../../core/routes.dart';
import '../../data/providers.dart';
import '../../core/theme.dart';
import '../../l10n/gen/app_localizations.dart';
import '../source_badge/source_badge.dart';
import '../sync_status/sync_status_indicator.dart';
import 'program_common.dart';
import 'programs_providers.dart';

enum _Seg { active, templates, mine }

class ProgramsPage extends ConsumerStatefulWidget {
  const ProgramsPage({super.key});

  @override
  ConsumerState<ProgramsPage> createState() => _ProgramsPageState();
}

class _ProgramsPageState extends ConsumerState<ProgramsPage> {
  _Seg _seg = _Seg.active;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final ai = AppColors.of(context).ai;
    final activeCount = ref.watch(instanceListProvider).value?.length ?? 0;
    return Scaffold(
      appBar: AppBar(title: Text(l.programsTitle), actions: const [SyncStatusIndicator(), SizedBox(width: 8)]),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: SizedBox(
              width: double.infinity,
              child: SegmentedButton<_Seg>(
                key: const Key('programs-segments'),
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(
                    value: _Seg.active,
                    label: Text(l.progSegActive(activeCount), maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                  ButtonSegment(
                    value: _Seg.templates,
                    label: Text(l.progSegTemplates, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                  ButtonSegment(
                    value: _Seg.mine,
                    label: Text(l.progSegMine, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                ],
                selected: {_seg},
                onSelectionChanged: (s) => setState(() => _seg = s.first),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                key: const Key('programs-import-ai'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: ai,
                  side: BorderSide(color: ai),
                  minimumSize: const Size(48, 48),
                ),
                onPressed: () => context.push(Routes.importJson),
                icon: const Icon(Icons.auto_awesome),
                label: Text(l.progImportAi),
              ),
            ),
          ),
          Expanded(
            child: switch (_seg) {
              _Seg.active => const _ActiveTab(),
              _Seg.templates => const _ProgramsTab(builtIn: true),
              _Seg.mine => const _ProgramsTab(builtIn: false),
            },
          ),
        ],
      ),
    );
  }
}

class _ActiveTab extends ConsumerWidget {
  const _ActiveTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final async = ref.watch(instanceListProvider);
    final c = AppColors.of(context);
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => ErrorRetry(error: e, onRetry: () => ref.invalidate(instanceListProvider)),
      data: (list) {
        if (list.isEmpty) {
          return Center(
            child: Padding(padding: const EdgeInsets.all(24), child: Text(l.programsActiveEmpty, textAlign: TextAlign.center)),
          );
        }
        return RefreshIndicator(
          onRefresh: () => ref.refresh(instanceListProvider.future),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              for (final i in list)
                _ProgramCard(
                  key: Key('instance-${i.id}'),
                  title: i.name,
                  meta: [
                    statusLabel(l, i.status),
                    if (i.state.week != null) l.instanceProgress(i.state.week!, i.state.cycle ?? 1),
                    if (i.next != null) l.instanceNextLabel(i.next!.dayName),
                  ].join(' · '),
                  onTap: () async {
                    await context.push(Routes.instanceDetail(i.id));
                    ref.invalidate(instanceListProvider);
                  },
                  trailing: Icon(Icons.chevron_right, color: c.fg2),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _ProgramsTab extends ConsumerWidget {
  const _ProgramsTab({required this.builtIn});
  final bool builtIn;

  Future<void> _delete(BuildContext context, WidgetRef ref, ProgramSummary p) async {
    final l = AppLocalizations.of(context);
    final ok = await confirmDialog(
      context,
      title: l.programDeleteConfirmTitle,
      body: l.programDeleteConfirmBody(p.name),
      action: l.commonDelete,
    );
    if (!ok) return;
    try {
      await ref.read(programRepositoryProvider).deleteProgram(p.id);
      ref.invalidate(programListProvider);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errorMessage(l, e, fallback: l.programDeleteFailed))));
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final async = ref.watch(programListProvider);
    final c = AppColors.of(context);
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => ErrorRetry(error: e, onRetry: () => ref.invalidate(programListProvider)),
      data: (list) {
        final shown = [for (final p in list) if (p.builtIn == builtIn) p];
        Widget tile(ProgramSummary p) => _ProgramCard(
          key: Key('program-${p.id}'),
          title: p.name,
          badge: p.source == ProgramSource.AI_JSON || p.source == ProgramSource.AI_MCP
              ? SourceBadge(key: Key('source-${p.id}'), source: p.source, importBatchId: p.importBatchId)
              : null,
          meta: l.progWeekDays(p.dayCount),
          description: p.description,
          trailing: p.builtIn
              ? Icon(Icons.chevron_right, color: c.fg2)
              : IconButton(
                  tooltip: l.programDeleteAction,
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _delete(context, ref, p),
                ),
          onTap: () => context.push(Routes.programDetail(p.id)),
        );
        return RefreshIndicator(
          onRefresh: () => ref.refresh(programListProvider.future),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [for (final p in shown) tile(p)],
          ),
        );
      },
    );
  }
}

class _ProgramCard extends StatelessWidget {
  const _ProgramCard({
    super.key,
    required this.title,
    required this.meta,
    required this.onTap,
    required this.trailing,
    this.badge,
    this.description,
  });
  final String title;
  final String meta;
  final String? description;
  final Widget? badge;
  final Widget trailing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          side: BorderSide(color: c.line),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.md),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 64),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(child: Text(title, style: text.titleSmall)),
                            if (badge != null) ...[const SizedBox(width: 8), badge!],
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(meta, style: text.bodySmall?.copyWith(color: c.fg2)),
                        if (description != null)
                          Text(
                            description!,
                            style: text.bodySmall?.copyWith(color: c.fg2),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                  trailing,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
