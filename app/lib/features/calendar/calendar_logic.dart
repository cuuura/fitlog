// 달력·주간 표시용 순수 함수. 날짜 키는 시간 없는 DateTime(로컬 날짜).
import '../../core/api/dto.dart';
import '../session/session_format.dart';

DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

String dayKey(DateTime d) => '${d.year}-${two(d.month)}-${two(d.day)}';

/// 그 날짜가 속한 주의 월요일.
DateTime weekStart(DateTime d) {
  final x = dateOnly(d);
  return DateTime(x.year, x.month, x.day - (x.weekday - DateTime.monday));
}

/// 월~일 7일.
List<DateTime> weekDays(DateTime d) {
  final s = weekStart(d);
  return [for (var i = 0; i < 7; i++) DateTime(s.year, s.month, s.day + i)];
}

/// 월 달력 칸: 항상 6행×7열(42일). 월요일 시작, 앞뒤는 인접 달 날짜.
List<DateTime> monthGrid(int year, int month) {
  final s = weekStart(DateTime(year, month, 1));
  return [for (var i = 0; i < 42; i++) DateTime(s.year, s.month, s.day + i)];
}

/// 끝난 세션만, 세션 자신의 로컬 날짜로 묶는다. 같은 날은 시작 시각 오름차순.
Map<DateTime, List<SessionSummary>> byLocalDay(Iterable<SessionSummary> sessions) {
  final out = <DateTime, List<SessionSummary>>{};
  for (final s in sessions) {
    if (s.endedAt == null) continue;
    final day = dateOnly(sessionLocalTime(s.startedAt, s.tz));
    out.putIfAbsent(day, () => []).add(s);
  }
  for (final l in out.values) {
    l.sort((a, b) => a.startedAt.compareTo(b.startedAt));
  }
  return out;
}

/// [days] 중 운동한 날 수.
int workedDayCount(Map<DateTime, List<SessionSummary>> byDay, Iterable<DateTime> days) =>
    days.where((d) => byDay.containsKey(dateOnly(d))).length;

/// 해당 월에 운동한 날 수.
int workedDaysInMonth(Map<DateTime, List<SessionSummary>> byDay, int year, int month) =>
    byDay.keys.where((d) => d.year == year && d.month == month).length;

/// [today]부터 거꾸로 이어진 연속 운동 일수. 오늘 아직 안 했으면 어제부터 센다.
int currentStreak(Map<DateTime, List<SessionSummary>> byDay, DateTime today) {
  var d = dateOnly(today);
  if (!byDay.containsKey(d)) d = DateTime(d.year, d.month, d.day - 1);
  var n = 0;
  while (byDay.containsKey(d)) {
    n++;
    d = DateTime(d.year, d.month, d.day - 1);
  }
  return n;
}

/// 로컬 날짜 범위 [firstDay, lastDay]를 덮는 UTC 조회 범위(±1일 여유).
({DateTime from, DateTime to}) paddedUtcRange(DateTime firstDay, DateTime lastDay) => (
      from: DateTime.utc(firstDay.year, firstDay.month, firstDay.day - 1),
      to: DateTime.utc(lastDay.year, lastDay.month, lastDay.day + 2),
    );
