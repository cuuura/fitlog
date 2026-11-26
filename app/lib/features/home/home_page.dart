import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/routes.dart';
import '../../core/settings/settings_controller.dart';
import '../../l10n/gen/app_localizations.dart';
import '../session/session_controller.dart';
import '../session/session_format.dart';

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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final active = ref.watch(activeSessionProvider).value;
    final recent = ref.watch(recentSessionsProvider).value ?? const [];
    final unit = ref.watch(settingsProvider).weightUnit;
    final history = recent.where((s) => s.endedAt != null).toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(l.appTitle),
        actions: [
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
          if (active != null)
            Card(
              key: const Key('home-resume-card'),
              color: Theme.of(context).colorScheme.primaryContainer,
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                title: Text(l.homeResumeTitle),
                subtitle: Text(l.homeSummary(
                    active.exercises.length,
                    active.exercises.fold<int>(0, (a, e) => a + e.sets.length),
                    formatVolume(sessionVolumeKg(active), unit))),
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
          const SizedBox(height: 24),
          Text(l.homeRecent, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (history.isEmpty)
            Padding(padding: const EdgeInsets.all(24), child: Center(child: Text(l.homeEmpty)))
          else
            for (final s in history)
              Card(
                child: ListTile(
                  key: Key('home-session-${s.id}'),
                  title: Text(formatDate(sessionLocalTime(s.startedAt, s.tz))),
                  subtitle: Text(l.homeSummary(s.exerciseCount, s.setCount, formatVolume(s.totalVolumeKg, unit))),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push(Routes.sessionDetail(s.id)),
                ),
              ),
        ],
      ),
    );
  }
}
