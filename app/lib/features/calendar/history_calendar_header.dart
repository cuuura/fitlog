// 기록 탭 맨 위 달력: 접으면 주간 띠, 펼치면 월 달력. 날짜를 누르면 [onSelect]로 알린다.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/dto.dart';
import '../../core/clock.dart';
import '../../core/theme.dart';
import '../../l10n/gen/app_localizations.dart';
import '../scheduled/scheduled_providers.dart';
import 'calendar_cells.dart';
import 'calendar_logic.dart';
import 'calendar_providers.dart';

/// 그 주의 "n월 m주차" (목요일이 속한 달 기준).
({int month, int week}) weekOfMonth(DateTime anyDay) {
  final thu = weekStart(anyDay).add(const Duration(days: 3));
  return (month: thu.month, week: (thu.day - 1) ~/ 7 + 1);
}

class HistoryCalendarHeader extends ConsumerWidget {
  const HistoryCalendarHeader({
    super.key,
    required this.expanded,
    required this.anchor,
    required this.selected,
    required this.onToggle,
    required this.onShift,
    required this.onSelect,
  });

  final bool expanded;

  /// 주 모드: 보고 있는 주에 속한 아무 날. 월 모드: 보고 있는 달의 1일.
  final DateTime anchor;
  final DateTime? selected;
  final VoidCallback onToggle;
  final void Function(int delta) onShift;
  final void Function(DateTime day) onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final c = AppColors.of(context);
    final today = dateOnly(ref.watch(clockProvider)().toLocal());
    final names = l.calendarWeekdays.split(',');
    final days = expanded
        ? monthGrid(anchor.year, anchor.month)
        : weekDays(anchor);
    final byDay =
        ref
            .watch(calendarRangeProvider((first: days.first, last: days.last)))
            .value ??
        const <DateTime, List<SessionSummary>>{};
    final planned = plannedDays(ref, days.first, days.last);
    final sched = ref.watch(
      scheduledViewsProvider((from: dayKey(days.first), to: dayKey(days.last))),
    );
    final schedDays = {for (final v in sched) v.workout.plannedDate};

    final String title;
    if (expanded) {
      title = l.calendarMonthTitle(
        anchor.year,
        anchor.month,
        workedDaysInMonth(byDay, anchor.year, anchor.month),
      );
    } else {
      final w = weekOfMonth(anchor);
      title = l.calendarWeekTitle(w.month, w.week, workedDayCount(byDay, days));
    }

    Widget weekdayRow() => Row(
      children: [
        for (var i = 0; i < 7; i++)
          Expanded(
            child: Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  names[i % names.length],
                  style: TextStyle(fontSize: 12, color: c.fg2),
                ),
              ),
            ),
          ),
      ],
    );

    final body = expanded
        ? Column(
            key: const Key('month-calendar'),
            children: [
              weekdayRow(),
              const SizedBox(height: 4),
              for (var r = 0; r < 6; r++)
                Row(
                  children: [
                    for (var i = 0; i < 7; i++)
                      Expanded(
                        child: MonthDayCell(
                          day: days[r * 7 + i],
                          inMonth: days[r * 7 + i].month == anchor.month,
                          isToday: days[r * 7 + i] == today,
                          isSelected: days[r * 7 + i] == selected,
                          worked: byDay.containsKey(days[r * 7 + i]),
                          scheduled: schedDays.contains(
                            dayKey(days[r * 7 + i]),
                          ),
                          onTap: () => onSelect(days[r * 7 + i]),
                        ),
                      ),
                  ],
                ),
            ],
          )
        : Row(
            key: const Key('week-calendar'),
            children: [
              for (var i = 0; i < 7; i++)
                Expanded(
                  child: WeekDayCell(
                    label: names[i],
                    day: days[i],
                    isToday: days[i] == today,
                    isFuture: days[i].isAfter(today),
                    worked: byDay.containsKey(days[i]),
                    planned:
                        planned.contains(days[i]) &&
                        !byDay.containsKey(days[i]),
                    isSelected: days[i] == selected,
                    onTap: () => onSelect(days[i]),
                  ),
                ),
            ],
          );

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      child: AnimatedSize(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        alignment: Alignment.topCenter,
        child: Column(
          children: [
            Row(
              children: [
                IconButton(
                  key: const Key('cal-prev'),
                  tooltip: expanded ? l.calendarPrevMonth : l.calendarPrevWeek,
                  onPressed: () => onShift(-1),
                  icon: const Icon(Icons.chevron_left),
                ),
                Expanded(
                  // 제목을 눌러도 펼침/접힘이 바뀐다(주간 띠를 눌러 펼치는 용도).
                  child: InkWell(
                    onTap: onToggle,
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        title,
                        key: const Key('cal-title'),
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ),
                IconButton(
                  key: const Key('cal-next'),
                  tooltip: expanded ? l.calendarNextMonth : l.calendarNextWeek,
                  onPressed: () => onShift(1),
                  icon: const Icon(Icons.chevron_right),
                ),
                IconButton(
                  key: const Key('history-cal-expand'),
                  tooltip: expanded ? l.calendarCollapse : l.calendarExpand,
                  onPressed: onToggle,
                  icon: Icon(expanded ? Icons.expand_less : Icons.expand_more),
                ),
              ],
            ),
            body,
          ],
        ),
      ),
    );
  }
}
