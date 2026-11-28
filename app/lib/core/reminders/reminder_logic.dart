// B3(v1.2) 운동 알림 날짜 모으기·시각 계산(순수 함수).
import 'reminder_settings.dart';

/// 앞으로 알림을 잡는 날 수(오늘 포함).
const reminderWindowDays = 14;

/// 알림 id 범위. 휴식 타이머(7001~7003)와 겹치지 않게 7100부터 날짜마다 하나씩.
const reminderIdBase = 7100;
const reminderIdCount = 30; // 이전 버전이 남긴 것까지 지우려고 창(14)보다 넉넉하게 취소한다.

/// 전날 저녁 알림 시각.
const reminderEveHour = 20;

class ReminderEntry {
  final int id;

  /// 알림이 울리는 기기 현지 시각.
  final DateTime at;

  /// 운동이 있는 날(YYYY-MM-DD).
  final String dateKey;

  /// true면 "내일 운동"(전날 알림).
  final bool tomorrow;
  const ReminderEntry({required this.id, required this.at, required this.dateKey, required this.tomorrow});
}

String _two(int n) => n.toString().padLeft(2, '0');
String reminderDayKey(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';

/// 오늘부터 14일 안의 운동 날짜를 모아 날짜순·중복 없이 돌려준다.
/// [planDates]는 진행 중 프로그램 계획의 scheduledDate(날짜만 의미), [scheduledDates]는 안 끝난 예정 운동의 YYYY-MM-DD.
List<String> collectReminderDates({
  required DateTime now,
  Iterable<DateTime?> planDates = const [],
  Iterable<String> scheduledDates = const [],
}) {
  final today = DateTime(now.year, now.month, now.day);
  final first = reminderDayKey(today);
  final last = reminderDayKey(DateTime(today.year, today.month, today.day + reminderWindowDays - 1));
  final out = <String>{};
  void add(String k) {
    if (k.compareTo(first) >= 0 && k.compareTo(last) <= 0) out.add(k);
  }

  for (final d in planDates) {
    if (d != null) add(reminderDayKey(d));
  }
  scheduledDates.forEach(add);
  return out.toList()..sort();
}

/// 날짜별 알림 시각을 정한다. 이미 지난 시각은 뺀다.
List<ReminderEntry> buildReminderEntries({
  required DateTime now,
  required List<String> dates,
  required ReminderSettings settings,
}) {
  final today = DateTime(now.year, now.month, now.day);
  final out = <ReminderEntry>[];
  for (final k in dates) {
    final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(k);
    if (m == null) continue;
    final day = DateTime(int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!));
    final eve = settings.when == ReminderWhen.eveBefore;
    final at = eve
        ? DateTime(day.year, day.month, day.day - 1, reminderEveHour)
        : DateTime(day.year, day.month, day.day, settings.hour, settings.minute);
    if (!at.isAfter(now)) continue;
    final offset = DateTime.utc(day.year, day.month, day.day).difference(DateTime.utc(today.year, today.month, today.day)).inDays;
    out.add(ReminderEntry(id: reminderIdBase + offset.clamp(0, reminderIdCount - 1), at: at, dateKey: k, tomorrow: eve));
  }
  return out;
}
