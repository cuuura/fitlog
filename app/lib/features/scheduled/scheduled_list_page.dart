// 예정 운동 목록: 다가오는 예정(날짜 오름차순)과 지난 예정(최근 순).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/dto.dart';
import '../../core/clock.dart';
import '../../core/routes.dart';
import '../../core/theme.dart';
import '../../l10n/gen/app_localizations.dart';
import '../calendar/calendar_logic.dart';
import 'scheduled_actions.dart';
import 'scheduled_logic.dart';
import 'scheduled_providers.dart';

/// 상태 칩 문구. 예정일이 지난 PLANNED는 "지난 예정".
String scheduledStatusLabel(AppLocalizations l, ScheduledView v, String todayKey) {
  if (v.isLate(todayKey)) return l.schedStatusLate;
  return switch (v.status) {
    ScheduledStatus.PLANNED => l.schedStatusPlanned,
    ScheduledStatus.IN_PROGRESS => l.schedStatusInProgress,
    ScheduledStatus.DONE => l.schedStatusDone,
    ScheduledStatus.SKIPPED => l.schedStatusSkipped,
  };
}

class ScheduledListPage extends ConsumerWidget {
  const ScheduledListPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final todayKey = dayKey(dateOnly(ref.watch(clockProvider)().toLocal()));
    final all = ref.watch(scheduledListProvider);
    final upcoming = [
      for (final v in all)
        if (v.workout.plannedDate.compareTo(todayKey) >= 0) v,
    ];
    final past = [
      for (final v in all.reversed)
        if (v.workout.plannedDate.compareTo(todayKey) < 0) v,
    ];

    // 셸(하단 탭) Scaffold가 스낵바를 대신 띄우면 이 탭의 FAB를 가린다. 탭 전용 ScaffoldMessenger로 감싸 FAB가 스낵바 위로 오게 한다.
    return ScaffoldMessenger(
      child: Scaffold(
        appBar: AppBar(
          title: Text(l.schedListTitle),
        ),
        floatingActionButton: FloatingActionButton.extended(
          key: const Key('sched-list-add'),
          onPressed: () => context.push(Routes.scheduledNew),
          icon: const Icon(Icons.add),
          label: Text(l.schedCreateEntry),
        ),
        body: all.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(l.schedListEmpty, key: const Key('sched-list-empty'), textAlign: TextAlign.center),
                      const SizedBox(height: 12),
                      FilledButton(
                        key: const Key('sched-list-empty-create'),
                        onPressed: () => context.push(Routes.scheduledNew),
                        child: Text(l.schedCreateEntry),
                      ),
                    ],
                  ),
                ),
              )
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                children: [
                  if (upcoming.isNotEmpty) _Header(l.schedListUpcoming),
                  for (final v in upcoming) _Row(view: v, todayKey: todayKey),
                  if (past.isNotEmpty) _Header(l.schedListPast),
                  for (final v in past) _Row(view: v, todayKey: todayKey),
                ],
              ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(0, 16, 0, 8),
    child: Text(text, style: Theme.of(context).textTheme.titleSmall),
  );
}

class _Row extends ConsumerWidget {
  const _Row({required this.view, required this.todayKey});
  final ScheduledView view;
  final String todayKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final c = AppColors.of(context);
    final text = Theme.of(context).textTheme;
    final w = view.workout;
    final d = parsePlannedDate(w.plannedDate);
    final weekdays = l.calendarWeekdays.split(',');
    final dateText = d == null ? w.plannedDate : l.schedListDate(d.month, d.day, weekdays[(d.weekday - 1) % weekdays.length]);
    final canStart = view.status == ScheduledStatus.PLANNED || view.status == ScheduledStatus.IN_PROGRESS;
    final late = view.isLate(todayKey);
    final chipBg = late
        ? c.warnSoft
        : view.status == ScheduledStatus.SKIPPED || view.status == ScheduledStatus.DONE
        ? c.surface3
        : c.accentSoft;
    final chipFg = late
        ? c.warn
        : view.status == ScheduledStatus.SKIPPED || view.status == ScheduledStatus.DONE
        ? c.fg2
        : c.accentStrong;

    void open() {
      switch (view.status) {
        case ScheduledStatus.DONE when view.sessionId != null:
          context.push(Routes.sessionDetail(view.sessionId!));
        case ScheduledStatus.IN_PROGRESS:
          context.push(Routes.session);
        default:
          context.push(Routes.scheduledEdit(view.id));
      }
    }

    return Card(
      key: Key('sched-row-${view.id}'),
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: open,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(dateText, style: text.bodySmall?.copyWith(color: c.fg2)),
                    Text(w.title, style: text.titleMedium),
                    Text(
                      l.schedCounts(w.items.length, w.setCount),
                      style: text.bodySmall?.copyWith(color: c.fg2),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      key: Key('sched-status-${view.id}'),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                      decoration: BoxDecoration(color: chipBg, borderRadius: BorderRadius.circular(999)),
                      child: Text(
                        scheduledStatusLabel(l, view, todayKey),
                        style: text.labelMedium?.copyWith(color: chipFg),
                      ),
                    ),
                  ],
                ),
              ),
              if (canStart)
                IconButton(
                  key: Key('sched-row-start-${view.id}'),
                  tooltip: view.status == ScheduledStatus.IN_PROGRESS ? l.schedResume : l.schedStart,
                  onPressed: () => startOrResume(context, ref, view),
                  icon: const Icon(Icons.play_circle_outline),
                ),
              ScheduledMenu(view: view),
            ],
          ),
        ),
      ),
    );
  }
}
