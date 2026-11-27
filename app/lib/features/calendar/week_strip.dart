// 이번 주(월~일) 운동한 날을 점으로 보여주는 띠. 누르면 기록 탭의 달력이 열린다.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/dto.dart';
import '../../core/api/program_dto.dart';
import '../../core/clock.dart';
import '../../core/routes.dart';
import '../../core/theme.dart';
import '../../l10n/gen/app_localizations.dart';
import '../session/session_controller.dart' show planItemsProvider;
import 'calendar_logic.dart';
import 'calendar_providers.dart';

class WeekStrip extends ConsumerWidget {
  const WeekStrip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final c = AppColors.of(context);
    final now = ref.watch(clockProvider)().toLocal();
    final today = dateOnly(now);
    final days = weekDays(today);
    final byDay =
        ref.watch(calendarRangeProvider((first: days.first, last: days.last))).value ?? const <DateTime, List<SessionSummary>>{};
    // FIXED_DATE 프로그램의 다음 회차 예정일(SHIFT는 날짜가 없어 제외).
    final planned = <DateTime>{};
    for (final p in ref.watch(planItemsProvider).value ?? const []) {
      final sd = p.next?.scheduledDate;
      if (p.instance.skipPolicy != SkipPolicy.FIXED_DATE || sd == null) continue;
      planned.add(dateOnly(sd));
    }
    final count = workedDayCount(byDay, days);
    final names = l.calendarWeekdays.split(',');

    return Card(
      key: const Key('week-strip'),
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          ref.read(historyCalendarRequestProvider.notifier).request();
          context.go(Routes.history);
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 12, 8, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        count == 0 ? l.calendarWeekNone : l.calendarWeekSummary(count),
                        key: const Key('week-summary'),
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Icon(Icons.chevron_right, size: 20, color: c.fg2, semanticLabel: l.calendarOpenHint),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  for (var i = 0; i < 7; i++)
                    Expanded(
                      child: _DayCell(
                        label: names[i % names.length],
                        day: days[i],
                        isToday: days[i] == today,
                        isFuture: days[i].isAfter(today),
                        worked: byDay.containsKey(days[i]),
                        planned: planned.contains(days[i]) && !byDay.containsKey(days[i]),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.label,
    required this.day,
    required this.isToday,
    required this.isFuture,
    required this.worked,
    required this.planned,
  });
  final String label;
  final DateTime day;
  final bool isToday, isFuture, worked, planned;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = AppColors.of(context);
    final key = dayKey(day);
    final muted = isFuture && !isToday;
    final fg = muted ? c.fg2.withValues(alpha: 0.6) : (isToday ? c.accentStrong : c.fg2);
    return Semantics(
      label: '${day.month}/${day.day}${worked ? ' ${l.calendarWorkedDay}' : ''}${planned ? ' ${l.calendarPlanned}' : ''}',
      excludeSemantics: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FittedBox(fit: BoxFit.scaleDown, child: Text(label, style: TextStyle(fontSize: 12, color: fg))),
          const SizedBox(height: 4),
          Container(
            key: Key('week-day-$key'),
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isToday ? c.accentSoft : null,
              border: isToday ? Border.all(color: c.accent, width: 2) : null,
            ),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: Text(
                  '${day.day}',
                  style: AppNum.style(context, 16, color: muted ? fg : (isToday ? c.accentStrong : null)),
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
                    decoration: BoxDecoration(color: c.accent, shape: BoxShape.circle),
                  )
                : planned
                    ? Container(
                        key: Key('week-planned-$key'),
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: c.accent, width: 1.5)),
                      )
                    : null,
          ),
        ],
      ),
    );
  }
}
