// 세션 화면의 "현재 세트" 계산과 세트 표시 문자열(순수 함수).
import '../../core/api/dto.dart';
import '../../core/units.dart';
import '../../l10n/gen/app_localizations.dart';

/// 세션 순서상 처음 만나는 미완료 세트.
class CurrentSet {
  const CurrentSet(this.se, this.set);
  final SessionExercise se;
  final WorkoutSet set;
}

CurrentSet? currentSetOf(Session session, {String? excluding}) {
  for (final e in session.exercises) {
    for (final w in e.sets) {
      if (!w.isCompleted && w.id != excluding) return CurrentSet(e, w);
    }
  }
  return null;
}

/// 워밍업을 뺀 세트 진행: (완료, 전체).
({int done, int total}) exerciseProgress(SessionExercise se) {
  var done = 0, total = 0;
  for (final w in se.sets) {
    if (w.isWarmup) continue;
    total++;
    if (w.isCompleted) done++;
  }
  return (done: done, total: total);
}

/// 종목 안 세트 번호: 워밍업은 W1, W2, 본 세트는 1, 2, 3 (각각 따로 센다).
({bool warmup, int n}) setNumber(SessionExercise se, WorkoutSet s) {
  var n = 0;
  for (final w in se.sets) {
    if (w.isWarmup == s.isWarmup) n++;
    if (w.id == s.id) break;
  }
  return (warmup: s.isWarmup, n: n);
}

String setShortLabel(AppLocalizations l, SessionExercise se, WorkoutSet s) {
  final x = setNumber(se, s);
  return x.warmup ? '${l.sessionWarmupShort}${x.n}' : '${x.n}';
}

/// "3세트" / "W1".
String setLongLabel(AppLocalizations l, SessionExercise se, WorkoutSet s) {
  final x = setNumber(se, s);
  return x.warmup
      ? '${l.sessionWarmupShort}${x.n}'
      : l.sessionTableSetLabel(x.n);
}

/// 계획 열: "77.5×8", AMRAP "97.5×1+", 자유 세트 "—".
String planCellText(WorkoutSet s, WeightUnit unit) {
  final reps = s.targetReps;
  if (reps == null) return '—';
  final r = s.isAmrap ? '$reps+' : '$reps';
  final w = s.targetWeightKg;
  if (w == null) return r;
  return '${Units.format(w, unit, withUnit: false)}×$r';
}

String formatRestSec(int sec) =>
    '${sec ~/ 60}:${(sec % 60).toString().padLeft(2, '0')}';
