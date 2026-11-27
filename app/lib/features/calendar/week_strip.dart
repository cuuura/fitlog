// 이번 주(월~일) 운동한 날을 점으로 보여주는 띠. 누르면 기록 탭의 달력이 열린다.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/dto.dart';
import '../../core/clock.dart';
import '../../core/routes.dart';
import '../../core/theme.dart';
import '../../l10n/gen/app_localizations.dart';
import 'calendar_cells.dart';
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
        ref
            .watch(calendarRangeProvider((first: days.first, last: days.last)))
            .value ??
        const <DateTime, List<SessionSummary>>{};
    final planned = plannedDays(ref, days.first, days.last);
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
                        count == 0
                            ? l.calendarWeekNone
                            : l.calendarWeekSummary(count),
                        key: const Key('week-summary'),
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Icon(
                      Icons.chevron_right,
                      size: 20,
                      color: c.fg2,
                      semanticLabel: l.calendarOpenHint,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  for (var i = 0; i < 7; i++)
                    Expanded(
                      child: WeekDayCell(
                        label: names[i % names.length],
                        day: days[i],
                        isToday: days[i] == today,
                        isFuture: days[i].isAfter(today),
                        worked: byDay.containsKey(days[i]),
                        planned:
                            planned.contains(days[i]) &&
                            !byDay.containsKey(days[i]),
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
