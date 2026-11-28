// B2 소유. 세션 표시용 순수 함수.
import 'package:intl/intl.dart';

import '../../core/api/dto.dart';
import '../../core/units.dart';

/// 세션이 시작된 날짜(세션 tz 기준)로 보여줄 시각.
/// 지금은 timezone 데이터베이스가 없어 기기 로컬로 근사한다. 같은 기기에서 만든 세션이면 정확하다.
/// 나중에 tz 패키지가 들어오면 이 함수만 바꾼다.
DateTime sessionLocalTime(DateTime startedAtUtc, String tz) => startedAtUtc.toLocal();

String two(int n) => n.toString().padLeft(2, '0');

String formatDate(DateTime local) => '${local.year}-${two(local.month)}-${two(local.day)}';
String formatClock(DateTime local) => '${two(local.hour)}:${two(local.minute)}';

String formatElapsed(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = d.inSeconds % 60;
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}

/// 볼륨(kg 기준)을 사용자 단위로.
String formatVolume(double kg, WeightUnit unit) {
  final v = Units.toDisplay(kg, unit);
  final s = NumberFormat.decimalPattern('en').format(v.round());
  return '$s ${unit == WeightUnit.KG ? 'kg' : 'lb'}';
}

/// "100kg×5" 같은 한 줄 요약. 덤벨 한쪽 무게는 그대로(기록 값 기준).
String formatSetBrief(WorkoutSet s, ExerciseType type, WeightUnit unit) {
  final reps = s.reps?.toString() ?? '-';
  if (type == ExerciseType.BODYWEIGHT) {
    final add = s.addedWeightKg;
    if (add == null || add == 0) return '×$reps';
    return '${add > 0 ? '+' : ''}${Units.format(add, unit)}×$reps';
  }
  final w = s.weightKg;
  return '${w == null ? '-' : Units.format(w, unit)}×$reps';
}

/// 세트의 볼륨(kg): 워밍업 제외는 호출자가 처리한다.
double setVolumeKg(WorkoutSet s) => (s.weightKg ?? 0) * (s.reps ?? 0);

double sessionVolumeKg(Session s) => [
      for (final e in s.exercises)
        for (final w in e.sets)
          if (!w.isWarmup) setVolumeKg(w)
    ].fold(0.0, (a, b) => a + b);

/// 월/일. 예: 11/20
String shortDate(DateTime local) => '${local.month}/${local.day}';
