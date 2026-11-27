// 예정 운동의 계산 상태와 표시용 순수 함수(contracts/v1.0/scheduled-workout.md §1).
import '../../core/api/dto.dart';
import '../../domain/repositories.dart';
import '../calendar/calendar_logic.dart';

/// 예정 운동 하나와 그 계산 상태. 상태는 저장하지 않고 로컬 세션에서 구한다.
class ScheduledView {
  final ScheduledWorkout workout;
  final ScheduledStatus status;

  /// 이 예정으로 시작한 세션(있으면).
  final String? sessionId;
  const ScheduledView({required this.workout, required this.status, this.sessionId});

  String get id => workout.id;

  /// plannedDate가 [todayKey](YYYY-MM-DD)보다 앞인데 아직 안 한(PLANNED) 예정. 표시만 한다(자동 건너뛰기 없음).
  bool isLate(String todayKey) => status == ScheduledStatus.PLANNED && workout.plannedDate.compareTo(todayKey) < 0;
}

/// 계산 상태. 살아 있는 세션이 있으면 끝났으면 DONE, 진행 중이면 IN_PROGRESS.
/// 세션이 없고 skippedAt이 있으면 SKIPPED. 그 밖은 PLANNED.
ScheduledView scheduledView(ScheduledWorkout w, Iterable<ScheduledLink> links) {
  final mine = [
    for (final l in links)
      if (l.scheduledWorkoutId == w.id) l,
  ];
  final active = mine.where((l) => l.isActive).firstOrNull;
  if (active != null) {
    return ScheduledView(workout: w, status: ScheduledStatus.IN_PROGRESS, sessionId: active.sessionId);
  }
  if (mine.isNotEmpty) {
    return ScheduledView(workout: w, status: ScheduledStatus.DONE, sessionId: mine.first.sessionId);
  }
  return ScheduledView(workout: w, status: w.skippedAt != null ? ScheduledStatus.SKIPPED : ScheduledStatus.PLANNED);
}

List<ScheduledView> scheduledViews(Iterable<ScheduledWorkout> workouts, Iterable<ScheduledLink> links) => [
  for (final w in workouts) scheduledView(w, links),
];

/// YYYY-MM-DD(로컬 날짜) 문자열 -> 날짜만 있는 DateTime. 잘못된 값이면 null.
DateTime? parsePlannedDate(String s) {
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(s);
  if (m == null) return null;
  return DateTime(int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!));
}

/// 날짜를 [days]일 옮긴 YYYY-MM-DD.
String shiftDayKey(DateTime day, int days) => dayKey(DateTime(day.year, day.month, day.day + days));

/// 홈에 보이는 카드: 오늘 예정(PLANNED·IN_PROGRESS), 지난 7일의 안 한 예정(PLANNED).
/// 진행 중인 예정은 예정일이 달라도 "오늘" 쪽에 둬서 "이어서"를 누를 수 있게 한다.
class HomeScheduled {
  final List<ScheduledView> today;
  final List<ScheduledView> late;
  const HomeScheduled({this.today = const [], this.late = const []});
  bool get isEmpty => today.isEmpty && late.isEmpty;
}

HomeScheduled homeScheduled(Iterable<ScheduledView> views, String todayKey) {
  final today = <ScheduledView>[];
  final late = <ScheduledView>[];
  for (final v in views) {
    final d = v.workout.plannedDate;
    if (v.status == ScheduledStatus.IN_PROGRESS) {
      today.add(v);
    } else if (v.status == ScheduledStatus.PLANNED) {
      if (d == todayKey) {
        today.add(v);
      } else if (d.compareTo(todayKey) < 0) {
        late.add(v);
      }
    }
  }
  return HomeScheduled(today: today, late: late);
}
