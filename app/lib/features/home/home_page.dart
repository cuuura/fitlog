import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/routes.dart';
import '../../core/settings/settings_controller.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../domain/repositories.dart';
import '../deletion_requests/pending_deletion_banner.dart';
import '../exercise_picker/exercise_labels.dart';
import '../session/plan_logic.dart';
import '../session/session_controller.dart';
import '../session/session_format.dart';
import '../sync_status/sync_status_indicator.dart';

class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  Future<void> _start(BuildContext context, WidgetRef ref) async {
    final l = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    try {
      await ref.read(sessionControllerProvider).start();
      router.push(Routes.session);
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(l.homeStartError)));
    }
  }

  Future<void> _startPlan(
    BuildContext context,
    WidgetRef ref,
    InstancePlan p,
  ) async {
    final l = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    try {
      await ref
          .read(sessionControllerProvider)
          .startProgram(p.instance.id, programName: p.instance.name);
      router.push(Routes.session);
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(l.homePlanStartError)));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final plans = ref.watch(planItemsProvider).value ?? const <InstancePlan>[];
    final exerciseNames = ref.watch(exerciseMapProvider).value ?? const {};
    final active = ref.watch(activeSessionProvider).value;
    final recent = ref.watch(recentSessionsProvider).value ?? const [];
    final unit = ref.watch(settingsProvider).weightUnit;
    final history = recent.where((s) => s.endedAt != null).toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(l.appTitle),
        actions: [
          const SyncStatusIndicator(),
          IconButton(
            key: const Key('home-programs'),
            icon: const Icon(Icons.view_list_outlined),
            tooltip: l.homeProgramsTooltip,
            onPressed: () => context.push(Routes.programs),
          ),
          IconButton(
            key: const Key('home-history'),
            icon: const Icon(Icons.history),
            tooltip: l.homeHistoryTooltip,
            onPressed: () => context.push(Routes.history),
          ),
          IconButton(
            key: const Key('home-body'),
            icon: const Icon(Icons.monitor_weight_outlined),
            tooltip: l.homeBodyTooltip,
            onPressed: () => context.push(Routes.body),
          ),
          IconButton(
            key: const Key('home-profile'),
            icon: const Icon(Icons.person_outline),
            tooltip: l.homeProfileTooltip,
            onPressed: () => context.push(Routes.profile),
          ),
          IconButton(
            key: const Key('home-settings'),
            icon: const Icon(Icons.settings_outlined),
            tooltip: l.homeSettingsTooltip,
            onPressed: () => context.push(Routes.settings),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const PendingDeletionBanner(),
          if (active != null)
            Card(
              key: const Key('home-resume-card'),
              color: Theme.of(context).colorScheme.primaryContainer,
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                title: Text(l.homeResumeTitle),
                subtitle: Text(
                  l.homeSummary(
                    active.exercises.length,
                    active.exercises.fold<int>(0, (a, e) => a + e.sets.length),
                    formatVolume(sessionVolumeKg(active), unit),
                  ),
                ),
                trailing: FilledButton(
                  key: const Key('home-resume'),
                  onPressed: () => context.push(Routes.session),
                  child: Text(l.homeResumeAction),
                ),
              ),
            )
          else
            FilledButton.icon(
              key: const Key('home-start'),
              icon: const Icon(Icons.play_arrow),
              label: Text(l.homeStartFree),
              onPressed: () => _start(context, ref),
            ),
          if (plans.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text(
              l.homePlanSection,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            for (final p in plans)
              Card(
                key: Key('plan-card-${p.instance.id}'),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              p.instance.name,
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            const SizedBox(height: 4),
                            if (p.next == null)
                              Text(l.homePlanUnavailable)
                            else ...[
                              Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      '${p.next!.dayName} · ${l.homePlanWeek(p.next!.week)}',
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium,
                                    ),
                                  ),
                                  if (p.fromCache) ...[
                                    const SizedBox(width: 8),
                                    Chip(
                                      key: Key(
                                        'plan-estimated-${p.instance.id}',
                                      ),
                                      label: Text(l.homePlanEstimated),
                                      visualDensity: VisualDensity.compact,
                                    ),
                                  ],
                                ],
                              ),
                              for (final e in p.next!.exercises.where(
                                (e) => !e.accessory,
                              ))
                                Text(
                                  planExerciseLine(
                                    exerciseNames[e.exerciseId] == null
                                        ? e.key
                                        : exerciseDisplayName(
                                            context,
                                            exerciseNames[e.exerciseId]!,
                                          ),
                                    e,
                                    unit,
                                  ),
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                            ],
                          ],
                        ),
                      ),
                      FilledButton(
                        key: Key('plan-start-${p.instance.id}'),
                        onPressed: p.next == null || active != null
                            ? null
                            : () => _startPlan(context, ref, p),
                        child: Text(l.homePlanStart),
                      ),
                    ],
                  ),
                ),
              ),
          ],
          const SizedBox(height: 24),
          Text(l.homeRecent, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (history.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Center(child: Text(l.homeEmpty)),
            )
          else
            for (final s in history)
              Card(
                child: ListTile(
                  key: Key('home-session-${s.id}'),
                  title: Text(formatDate(sessionLocalTime(s.startedAt, s.tz))),
                  subtitle: Text(
                    l.homeSummary(
                      s.exerciseCount,
                      s.setCount,
                      formatVolume(s.totalVolumeKg, unit),
                    ),
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push(Routes.sessionDetail(s.id)),
                ),
              ),
        ],
      ),
    );
  }
}
