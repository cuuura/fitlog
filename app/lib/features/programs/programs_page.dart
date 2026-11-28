// B1 소유. 진행 중 프로그램 / 프로그램(템플릿·내 프로그램) 목록.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/program_dto.dart';
import '../../core/routes.dart';
import '../../data/providers.dart';
import '../../core/theme.dart';
import '../../core/ui/confirm.dart';
import '../../core/ui/row_menu.dart';
import '../../l10n/gen/app_localizations.dart';
import '../source_badge/source_badge.dart';
import '../sync_status/sync_status_indicator.dart';
import '../program_editor/program_editor.dart';
import 'program_add_sheet.dart';
import 'program_common.dart';
import 'programs_providers.dart';

enum _Seg { active, mine }

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
    final activeCount = ref.watch(instanceListProvider).value?.length ?? 0;
    final mineCount = ref
        .watch(programListProvider)
        .value
        ?.where((p) => !p.builtIn)
        .length;
    // 셸(하단 탭)의 Scaffold가 스낵바를 대신 띄우면 이 탭의 FAB를 가린다(바깥 Scaffold는 안쪽 FAB 위치를 몰라서).
    // 이 탭 전용 ScaffoldMessenger로 감싸 스낵바를 이 Scaffold가 띄우게 하면 FAB가 스낵바 위로 올라간다.
    return ScaffoldMessenger(
      child: Scaffold(
        appBar: AppBar(
          title: Text(l.programsTitle),
          actions: const [SyncStatusIndicator(), SizedBox(width: 8)],
        ),
        floatingActionButton: FloatingActionButton.extended(
          key: const Key('programs-add'),
          onPressed: () => showProgramAddSheet(context),
          icon: const Icon(Icons.add),
          label: Text(l.progAdd),
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: SizedBox(
                width: double.infinity,
                child: SegmentedButton<_Seg>(
                  key: const Key('programs-segments'),
                  showSelectedIcon: false,
                  segments: [
                    ButtonSegment(
                      value: _Seg.active,
                      label: Text(
                        l.progSegActive(activeCount),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    ButtonSegment(
                      value: _Seg.mine,
                      label: Text(
                        mineCount == null
                            ? l.progSegMine
                            : '${l.progSegMine} $mineCount',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                  selected: {_seg},
                  onSelectionChanged: (s) => setState(() => _seg = s.first),
                ),
              ),
            ),
            Expanded(
              child: switch (_seg) {
                _Seg.active => const _ActiveTab(),
                _Seg.mine => const _MineTab(),
              },
            ),
          ],
        ),
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
      error: (e, _) => ErrorRetry(
        error: e,
        onRetry: () => ref.invalidate(instanceListProvider),
      ),
      data: (list) {
        if (list.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(l.programsActiveEmpty, textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    key: const Key('programs-first-pick'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(48, 48),
                    ),
                    onPressed: () => showProgramAddSheet(context),
                    icon: const Icon(Icons.add),
                    label: Text(l.progPickFirst),
                  ),
                ],
              ),
            ),
          );
        }
        return RefreshIndicator(
          onRefresh: () => ref.refresh(instanceListProvider.future),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 88),
            children: [
              for (final i in list)
                _ProgramCard(
                  key: Key('instance-${i.id}'),
                  title: i.name,
                  meta: [
                    statusLabel(l, i.status),
                    if (i.state.week != null)
                      l.instanceProgress(i.state.week!, i.state.cycle ?? 1),
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

/// 내가 만든 프로그램(AI 가져오기 등). 시작은 "프로그램 추가"에서 고르고, 여기서는 자세히·삭제.
class _MineTab extends ConsumerWidget {
  const _MineTab();

  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    ProgramSummary p,
  ) async {
    final l = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final ok = await confirmAction(
      context,
      title: l.programDeleteConfirmTitle(p.name),
      body: l.programDeleteConfirmBody,
      action: l.commonDelete,
      destructive: true,
    );
    if (!ok) return;
    try {
      await ref.read(programRepositoryProvider).deleteProgram(p.id);
      ref.invalidate(programListProvider);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(errorMessage(l, e, fallback: l.programDeleteFailed)),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final async = ref.watch(programListProvider);
    final running = {
      for (final i in ref.watch(instanceListProvider).value ?? const <Instance>[])
        i.programId,
    };
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => ErrorRetry(
        error: e,
        onRetry: () => ref.invalidate(programListProvider),
      ),
      data: (list) {
        final mine = [
          for (final p in list)
            if (!p.builtIn) p,
        ];
        return RefreshIndicator(
          onRefresh: () => ref.refresh(programListProvider.future),
          child: mine.isEmpty
              ? LayoutBuilder(
                  builder: (context, box) => ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      SizedBox(
                        height: box.maxHeight,
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              l.progMineEmpty,
                              key: const Key('programs-empty'),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 88),
                  children: [
                    for (final p in mine)
                      _ProgramCard(
                        key: Key('program-${p.id}'),
                        title: p.name,
                        badge:
                            p.source == ProgramSource.AI_JSON ||
                                p.source == ProgramSource.AI_MCP
                            ? SourceBadge(
                                key: Key('source-${p.id}'),
                                source: p.source,
                                importBatchId: p.importBatchId,
                              )
                            : null,
                        meta: [
                          if (running.contains(p.id)) l.progRunning,
                          l.progWeekDays(p.dayCount),
                          ?programCategoryLabel(l, p.category),
                        ].join(' · '),
                        description: p.description,
                        sessionMinutes: sessionMinutesText(l, p.sessionMinutes),
                        minutesKey: Key('program-session-minutes-${p.id}'),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            TextButton(
                              key: Key('program-detail-${p.id}'),
                              style: TextButton.styleFrom(
                                minimumSize: const Size(48, 48),
                              ),
                              onPressed: () =>
                                  context.push(Routes.programDetail(p.id)),
                              child: Text(l.progDetailLink),
                            ),
                            RowMenu<String>(
                              key: Key('program-menu-${p.id}'),
                              items: [
                                RowMenuItem(
                                  value: 'edit',
                                  label: '편집',
                                  key: Key('program-edit-${p.id}'),
                                ),
                                RowMenuItem(
                                  value: 'delete',
                                  label: l.programDeleteAction,
                                  destructive: true,
                                  key: Key('program-delete-${p.id}'),
                                ),
                              ],
                              onSelected: (v) async {
                                if (v == 'edit') {
                                  await openProgramEditor(context, programId: p.id);
                                  ref.invalidate(programListProvider);
                                } else {
                                  _delete(context, ref, p);
                                }
                              },
                            ),
                          ],
                        ),
                        onTap: () => context.push(Routes.programDetail(p.id)),
                      ),
                  ],
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
    this.sessionMinutes,
    this.minutesKey,
  });
  final String title;
  final String meta;

  /// "회당 약 45~70분". 없으면 숨김.
  final String? sessionMinutes;
  final Key? minutesKey;
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
                            Flexible(
                              child: Text(title, style: text.titleSmall),
                            ),
                            if (badge != null) ...[
                              const SizedBox(width: 8),
                              badge!,
                            ],
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          meta,
                          style: text.bodySmall?.copyWith(color: c.fg2),
                        ),
                        if (sessionMinutes != null)
                          Text(
                            sessionMinutes!,
                            key: minutesKey,
                            style: text.bodySmall?.copyWith(color: c.fg2),
                          ),
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
