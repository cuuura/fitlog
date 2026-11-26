// B1 소유. 진행 중 프로그램 / 프로그램(템플릿·내 프로그램) 목록.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/program_dto.dart';
import '../../core/routes.dart';
import '../../data/providers.dart';
import '../../l10n/gen/app_localizations.dart';
import 'program_common.dart';
import 'programs_providers.dart';

class ProgramsPage extends ConsumerWidget {
  const ProgramsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(l.programsTitle),
          bottom: TabBar(tabs: [Tab(text: l.programsTabActive), Tab(text: l.programsTabPrograms)]),
        ),
        body: const TabBarView(children: [_ActiveTab(), _ProgramsTab()]),
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
            children: [
              for (final i in list)
                ListTile(
                  title: Text(i.name),
                  subtitle: Text([
                    statusLabel(l, i.status),
                    if (i.state.week != null) l.instanceProgress(i.state.week!, i.state.cycle ?? 1),
                    if (i.next != null) l.instanceNextLabel(i.next!.dayName),
                  ].join(' · ')),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    await context.push(Routes.instanceDetail(i.id));
                    ref.invalidate(instanceListProvider);
                  },
                ),
            ],
          ),
        );
      },
    );
  }
}

class _ProgramsTab extends ConsumerWidget {
  const _ProgramsTab();

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
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => ErrorRetry(error: e, onRetry: () => ref.invalidate(programListProvider)),
      data: (list) {
        final templates = [for (final p in list) if (p.builtIn) p];
        final mine = [for (final p in list) if (!p.builtIn) p];
        Widget tile(ProgramSummary p) => ListTile(
          title: Text(p.name),
          subtitle: Text([l.programDayCount(p.dayCount), if (p.description != null) p.description!].join(' · '), maxLines: 2, overflow: TextOverflow.ellipsis),
          trailing: p.builtIn
              ? const Icon(Icons.chevron_right)
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
            children: [
              if (templates.isNotEmpty) _Header(l.programTemplates),
              for (final p in templates) tile(p),
              if (mine.isNotEmpty) _Header(l.programMine),
              for (final p in mine) tile(p),
            ],
          ),
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Text(text, style: Theme.of(context).textTheme.titleSmall),
  );
}
