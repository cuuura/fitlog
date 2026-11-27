// 주간 띠·기록 탭 달력이 함께 쓰는 날짜 칸, 예정 운동 표시/타일.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/dto.dart';
import '../../core/api/program_dto.dart';
import '../../core/routes.dart';
import '../../core/theme.dart';
import '../../l10n/gen/app_localizations.dart';
import '../scheduled/scheduled_list_page.dart' show scheduledStatusLabel;
import '../scheduled/scheduled_logic.dart';
import '../scheduled/scheduled_providers.dart';
import '../session/session_controller.dart' show planItemsProvider;
import 'calendar_logic.dart';

/// [first]~[last] 사이 "예정" 윤곽 점을 찍을 날: FIXED_DATE 프로그램의 다음 회차 예정일 +
/// 하루짜리 예정 운동(건너뜀·완료 제외).
Set<DateTime> plannedDays(WidgetRef ref, DateTime first, DateTime last) {
  final planned = <DateTime>{};
  for (final p in ref.watch(planItemsProvider).value ?? const []) {
    final sd = p.next?.scheduledDate;
    if (p.instance.skipPolicy != SkipPolicy.FIXED_DATE || sd == null) continue;
    planned.add(dateOnly(sd));
  }
  final views = ref.watch(
    scheduledViewsProvider((from: dayKey(first), to: dayKey(last))),
  );
  for (final v in views) {
    if (v.status == ScheduledStatus.PLANNED ||
        v.status == ScheduledStatus.IN_PROGRESS) {
      final d = parsePlannedDate(v.workout.plannedDate);
      if (d != null) planned.add(d);
    }
  }
  return planned;
}

class WeekDayCell extends StatelessWidget {
  const WeekDayCell({
    super.key,
    required this.label,
    required this.day,
    required this.isToday,
    required this.isFuture,
    required this.worked,
    required this.planned,
    this.isSelected = false,
    this.onTap,
  });
  final String label;
  final DateTime day;
  final bool isToday, isFuture, worked, planned, isSelected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = AppColors.of(context);
    final key = dayKey(day);
    final muted = isFuture && !isToday;
    final fg = muted
        ? c.fg2.withValues(alpha: 0.6)
        : (isToday ? c.accentStrong : c.fg2);
    final cell = Semantics(
      label:
          '${day.month}/${day.day}${worked ? ' ${l.calendarWorkedDay}' : ''}${planned ? ' ${l.calendarPlanned}' : ''}',
      excludeSemantics: true,
      button: onTap != null,
      selected: isSelected,
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(label, style: TextStyle(fontSize: 12, color: fg)),
          ),
          const SizedBox(height: 4),
          Container(
            key: Key('week-day-$key'),
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isToday || isSelected ? c.accentSoft : null,
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
                    16,
                    color: muted ? fg : (isToday ? c.accentStrong : null),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: 8,
            child: worked
                ? Container(
                    key: Key('week-dot-$key'),
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: c.accent,
                      shape: BoxShape.circle,
                    ),
                  )
                : planned
                ? Container(
                    key: Key('week-planned-$key'),
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: c.accent, width: 1.5),
                    ),
                  )
                : null,
          ),
        ],
      ),
    );
    if (onTap == null) return cell;
    return InkWell(
      key: Key('cal-day-$key'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: cell,
    );
  }
}

class MonthDayCell extends StatelessWidget {
  const MonthDayCell({
    super.key,
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
                    border: isToday
                        ? Border.all(color: c.accent, width: 2)
                        : null,
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
                          color: fade
                              ? c.fg2.withValues(alpha: 0.4)
                              : (isToday ? c.accentStrong : null),
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
                            color: fade
                                ? c.accent.withValues(alpha: 0.4)
                                : c.accent,
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
                            border: Border.all(
                              color: fade
                                  ? c.accent.withValues(alpha: 0.4)
                                  : c.accent,
                              width: 1.5,
                            ),
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

class DayScheduledTile extends StatelessWidget {
  const DayScheduledTile({
    super.key,
    required this.view,
    required this.todayKey,
  });
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
                    Text(
                      w.title,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
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
