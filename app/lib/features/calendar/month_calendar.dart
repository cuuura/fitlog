// 월 달력: 운동한 날은 점, 날짜를 누르면 그날의 세션을 아래에 보여준다.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/dto.dart';
import '../../core/clock.dart';
import '../../core/routes.dart';
import '../../core/settings/settings_controller.dart';
import '../../core/theme.dart';
import '../../l10n/gen/app_localizations.dart';
import '../scheduled/scheduled_list_page.dart' show scheduledStatusLabel;
import '../scheduled/scheduled_logic.dart';
import '../scheduled/scheduled_providers.dart';
import '../session/session_format.dart';
import 'calendar_logic.dart';
import 'calendar_providers.dart';

class MonthCalendar extends ConsumerStatefulWidget {
  const MonthCalendar({super.key});

  @override
  ConsumerState<MonthCalendar> createState() => _MonthCalendarState();
}

class _MonthCalendarState extends ConsumerState<MonthCalendar> {
  DateTime? _month; // 그 달 1일
  DateTime? _selected;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = AppColors.of(context);
    final unit = ref.watch(settingsProvider).weightUnit;
    final today = dateOnly(ref.watch(clockProvider)().toLocal());
    final month = _month ?? DateTime(today.year, today.month);
    final selected = _selected ?? today;
    final grid = monthGrid(month.year, month.month);
    final byDay =
        ref.watch(calendarRangeProvider((first: grid.first, last: grid.last))).value ?? const <DateTime, List<SessionSummary>>{};
    final names = l.calendarWeekdays.split(',');
    final worked = workedDaysInMonth(byDay, month.year, month.month);
    final daySessions = byDay[selected] ?? const <SessionSummary>[];
    // 하루짜리 예정 운동: 날짜별로 묶어 윤곽 점으로 표시하고, 고른 날의 목록에도 보여 준다.
    final sched = ref.watch(scheduledViewsProvider((from: dayKey(grid.first), to: dayKey(grid.last))));
    final schedByDay = <String, List<ScheduledView>>{};
    for (final v in sched) {
      (schedByDay[v.workout.plannedDate] ??= []).add(v);
    }
    final daySched = schedByDay[dayKey(selected)] ?? const <ScheduledView>[];

    void go(int delta) => setState(() {
          _month = DateTime(month.year, month.month + delta);
          _selected = null;
          // 새 달에서는 오늘(해당 달이면) 또는 1일을 선택한다.
          final m = _month!;
          _selected = (m.year == today.year && m.month == today.month) ? today : m;
        });

    return ListView(
      key: const Key('month-calendar'),
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
      children: [
        Row(
          children: [
            IconButton(
              key: const Key('cal-prev'),
              tooltip: l.calendarPrevMonth,
              onPressed: () => go(-1),
              icon: const Icon(Icons.chevron_left),
            ),
            Expanded(
              child: Text(
                l.calendarMonthTitle(month.year, month.month, worked),
                key: const Key('cal-title'),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
            IconButton(
              key: const Key('cal-next'),
              tooltip: l.calendarNextMonth,
              onPressed: () => go(1),
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
        Row(
          children: [
            for (var i = 0; i < 7; i++)
              Expanded(
                child: Center(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(names[i % names.length], style: TextStyle(fontSize: 12, color: c.fg2)),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        for (var r = 0; r < 6; r++)
          Row(
            children: [
              for (var i = 0; i < 7; i++)
                Expanded(
                  child: _MonthCell(
                    day: grid[r * 7 + i],
                    inMonth: grid[r * 7 + i].month == month.month,
                    isToday: grid[r * 7 + i] == today,
                    isSelected: grid[r * 7 + i] == selected,
                    worked: byDay.containsKey(grid[r * 7 + i]),
                    scheduled: schedByDay.containsKey(dayKey(grid[r * 7 + i])),
                    onTap: () => setState(() {
                      final d = grid[r * 7 + i];
                      _selected = d;
                      if (d.month != month.month) _month = DateTime(d.year, d.month);
                    }),
                  ),
                ),
            ],
          ),
        const SizedBox(height: 12),
        Divider(height: 1, color: c.line),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
          child: Text(
            l.calendarDayHeading(selected.month, selected.day, names[(selected.weekday - 1) % names.length]),
            key: const Key('cal-day-heading'),
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          ),
        ),
        if (daySched.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
            child: Text(
              l.calendarScheduledHeading,
              key: const Key('cal-sched-heading'),
              style: TextStyle(fontSize: 12, color: c.fg2),
            ),
          ),
          for (final v in daySched) _DayScheduledTile(view: v, todayKey: dayKey(today)),
        ],
        if (daySessions.isEmpty && daySched.isEmpty)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(l.calendarEmptyDay, key: const Key('cal-empty'), style: TextStyle(color: c.fg2)),
          )
        else
          for (final s in daySessions) _DaySessionTile(summary: s, unit: unit),
      ],
    );
  }
}

class _MonthCell extends StatelessWidget {
  const _MonthCell({
    required this.day,
    required this.inMonth,
    required this.isToday,
    required this.isSelected,
    required this.worked,
    this.scheduled = false,
    required this.onTap,
  });
  final DateTime day;
  final bool inMonth, isToday, isSelected, worked, scheduled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = AppColors.of(context);
    final key = dayKey(day);
    final fade = !inMonth;
    return Semantics(
      label:
          '${day.month}/${day.day}${worked ? ' ${l.calendarWorkedDay}' : ''}${scheduled ? ' ${l.calendarScheduledDay}' : ''}',
      button: true,
      selected: isSelected,
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        key: Key('cal-day-$key'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: SizedBox(
          height: 52,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 34,
                  height: 34,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isSelected ? c.accentSoft : null,
                    border: isToday ? Border.all(color: c.accent, width: 2) : null,
                  ),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: Text(
                        '${day.day}',
                        style: AppNum.style(
                          context,
                          15,
                          color: fade ? c.fg2.withValues(alpha: 0.4) : (isToday ? c.accentStrong : null),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 2),
                SizedBox(
                  height: 7,
                  child: worked
                      ? Container(
                          key: Key('cal-dot-$key'),
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: fade ? c.accent.withValues(alpha: 0.4) : c.accent,
                            shape: BoxShape.circle,
                          ),
                        )
                      : scheduled
                      // 예정 운동만 있는 날: 채운 점(운동한 날)과 구별되는 윤곽 점.
                      ? Container(
                          key: Key('cal-sched-$key'),
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: fade ? c.accent.withValues(alpha: 0.4) : c.accent, width: 1.5),
                          ),
                        )
                      : null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DayScheduledTile extends StatelessWidget {
  const _DayScheduledTile({required this.view, required this.todayKey});
  final ScheduledView view;
  final String todayKey;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = AppColors.of(context);
    final w = view.workout;
    return InkWell(
      key: Key('cal-sched-tile-${w.id}'),
      onTap: () => view.status == ScheduledStatus.DONE && view.sessionId != null
          ? context.push(Routes.sessionDetail(view.sessionId!))
          : context.push(Routes.scheduledEdit(w.id)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            children: [
              Icon(Icons.event_note_outlined, color: c.fg2),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(w.title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                    Text(
                      '${scheduledStatusLabel(l, view, todayKey)} · ${l.schedCounts(w.items.length, w.setCount)}',
                      style: TextStyle(fontSize: 13, color: c.fg2),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: c.fg2),
            ],
          ),
        ),
      ),
    );
  }
}

class _DaySessionTile extends StatelessWidget {
  const _DaySessionTile({required this.summary, required this.unit});
  final SessionSummary summary;
  final WeightUnit unit;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = AppColors.of(context);
    final s = summary;
    final local = sessionLocalTime(s.startedAt, s.tz);
    return InkWell(
      key: Key('cal-session-${s.id}'),
      onTap: () => context.push(Routes.sessionDetail(s.id)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            children: [
              Text(formatClock(local), style: AppNum.style(context, 16)),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  l.calendarSessionSummary(s.exerciseCount, s.setCount, formatVolume(s.totalVolumeKg, unit)),
                  style: TextStyle(fontSize: 14, color: c.fg2),
                ),
              ),
              Icon(Icons.chevron_right, color: c.fg2),
            ],
          ),
        ),
      ),
    );
  }
}
