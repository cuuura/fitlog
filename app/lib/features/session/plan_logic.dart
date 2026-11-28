// B2 소유. 프로그램 세션 표시용 순수 함수(engine.md §3 판정, 목표·요약 문자열 재료).
import '../../core/api/dto.dart';
import '../../core/api/program_dto.dart';
import '../../core/units.dart';
import 'session_format.dart';

/// 판정 대상 세트: 프로그램 세션(programInstanceId != null)의 계획 세트이며 워밍업이 아니고 보조운동 종목이 아니다.
/// 예정 운동 세션·자유 세션은 목표가 있어도 판정하지 않는다(scheduled-workout.md §1).
bool isJudged(Session session, SessionExercise se, WorkoutSet s) =>
    session.programInstanceId != null &&
    s.targetReps != null &&
    !s.isWarmup &&
    s.setType != SetType.DROP && // 드롭 세트는 판정 제외(워밍업과 같음)
    !se.accessory;

/// 완료한 세트가 목표 횟수에 못 미치면 실패(무게는 보지 않는다, PRG-5).
bool isSetFailed(Session session, SessionExercise se, WorkoutSet s) =>
    isJudged(session, se, s) && s.isCompleted && (s.reps ?? 0) < s.targetReps!;

/// 기록 무게가 계획 무게와 다르다(PRG-5 "계획과 다름").
bool differsFromPlan(WorkoutSet s) =>
    s.targetWeightKg != null &&
    s.weightKg != null &&
    (s.weightKg! - s.targetWeightKg!).abs() > 1e-9;

enum ExerciseVerdict { success, failure }

/// 종목 판정(요약용): 판정 대상 세트가 하나도 없으면 null. 미완료 세트는 실패로 본다.
ExerciseVerdict? exerciseVerdict(Session session, SessionExercise se) {
  final judged = [
    for (final s in se.sets)
      if (isJudged(session, se, s)) s,
  ];
  if (judged.isEmpty) return null;
  final ok = judged.every(
    (s) => s.isCompleted && (s.reps ?? 0) >= s.targetReps!,
  );
  return ok ? ExerciseVerdict.success : ExerciseVerdict.failure;
}

/// 지난 같은 세션 한 줄: "100kg×5,5,5,5,4". 무게가 섞이면 "100kg×5, 105kg×3".
String formatPastSets(
  List<WorkoutSet> sets,
  ExerciseType type,
  WeightUnit unit,
) {
  final done = [
    for (final s in sets)
      if (!s.isWarmup && s.reps != null) s,
  ];
  if (done.isEmpty) return '';
  String w(WorkoutSet s) {
    if (type == ExerciseType.BODYWEIGHT) {
      final a = s.addedWeightKg;
      return a == null || a == 0
          ? ''
          : '${a > 0 ? '+' : ''}${Units.format(a, unit)}';
    }
    return s.weightKg == null ? '' : Units.format(s.weightKg!, unit);
  }

  final groups = <(String, List<int>)>[];
  for (final s in done) {
    if (groups.isNotEmpty && groups.last.$1 == w(s)) {
      groups.last.$2.add(s.reps!);
    } else {
      groups.add((w(s), [s.reps!]));
    }
  }
  return groups.map((g) => '${g.$1}×${g.$2.join(',')}').join(', ');
}

/// 계획의 주요 종목(보조 제외) 대표 무게: 워밍업 제외 최대 목표 무게. 무게 없는 종목은 null.
double? topWeight(PlannedExercise e) {
  double? best;
  for (final s in e.sets) {
    if (s.isWarmup || s.targetWeightKg == null) continue;
    if (best == null || s.targetWeightKg! > best) best = s.targetWeightKg;
  }
  return best;
}

/// "스쿼트 100kg" 목록용 한 줄.
String planExerciseLine(String name, PlannedExercise e, WeightUnit unit) {
  final w = topWeight(e);
  return w == null ? name : '$name ${Units.format(w, unit)}';
}

String sessionDuration(Session s) {
  final end = s.endedAt;
  if (end == null) return '';
  return formatElapsed(end.difference(s.startedAt));
}
