// 홈의 "오늘 예정"·"지난 예정" 카드. 홈의 프로그램 카드(_PlanCard)와 같은 모양.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/dto.dart';
import '../../core/theme.dart';
import '../../l10n/gen/app_localizations.dart';
import '../exercise_picker/exercise_labels.dart';
import 'scheduled_actions.dart';
import 'scheduled_logic.dart';

/// 카드에 이름을 보여 줄 종목 수.
const kScheduledCardNames = 3;

class ScheduledCard extends ConsumerWidget {
  const ScheduledCard({super.key, required this.view, required this.exercises, required this.todayKey});
  final ScheduledView view;
  final Map<String, Exercise> exercises;
  final String todayKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final c = AppColors.of(context);
    final text = Theme.of(context).textTheme;
    final w = view.workout;
    final id = w.id;
    final late = view.isLate(todayKey);
    final inProgress = view.status == ScheduledStatus.IN_PROGRESS;
    final planned = parsePlannedDate(w.plannedDate);

    String name(ScheduledItem i) {
      final ex = exercises[i.exerciseId];
      return ex == null ? i.exerciseId : exerciseDisplayName(context, ex);
    }

    final shown = w.items.take(kScheduledCardNames).toList();
    final more = w.items.length - shown.length;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        key: Key('sched-card-$id'),
        padding: const EdgeInsets.fromLTRB(16, 16, 4, 16),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          border: Border.all(color: c.line),
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(w.title, key: Key('sched-title-$id'), style: text.titleMedium),
                      Text(
                        l.schedCounts(w.items.length, w.setCount),
                        key: Key('sched-counts-$id'),
                        style: text.bodySmall?.copyWith(color: c.fg2),
                      ),
                    ],
                  ),
                ),
                ScheduledMenu(view: view),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(top: 8, right: 12),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  if (inProgress)
                    _Chip(
                      key: Key('sched-chip-progress-$id'),
                      label: l.schedStatusInProgress,
                      bg: c.accentSoft,
                      fg: c.accentStrong,
                    )
                  else if (late)
                    _Chip(
                      key: Key('sched-chip-late-$id'),
                      label: planned == null ? l.schedStatusLate : l.schedLateChip(planned.month, planned.day),
                      bg: c.warnSoft,
                      fg: c.warn,
                      icon: Icons.schedule,
                    )
                  else
                    _Chip(
                      key: Key('sched-chip-planned-$id'),
                      label: l.schedStatusPlanned,
                      bg: c.accentSoft,
                      fg: c.accentStrong,
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(color: c.surface2, borderRadius: BorderRadius.circular(AppRadius.md)),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final i in shown)
                            Text(name(i), style: text.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                          if (more > 0)
                            Text(
                              l.schedMoreExercises(more),
                              style: text.bodySmall?.copyWith(color: c.fg2),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 110),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text.rich(
                          key: Key('sched-sets-$id'),
                          TextSpan(
                            text: '${w.setCount}',
                            style: AppNum.large(context),
                            children: [
                              TextSpan(
                                text: ' ${l.summarySetsShort}',
                                style: text.bodySmall?.copyWith(color: c.fg2),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: Key('sched-start-$id'),
                  onPressed: () => startOrResume(context, ref, view),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.play_arrow),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(inProgress ? l.schedResume : l.schedStart, textAlign: TextAlign.center),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({super.key, required this.label, required this.bg, required this.fg, this.icon});
  final String label;
  final Color bg, fg;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[Icon(icon, size: 14, color: fg), const SizedBox(width: 4)],
        Flexible(
          child: Text(label, style: Theme.of(context).textTheme.labelMedium?.copyWith(color: fg)),
        ),
      ],
    ),
  );
}
