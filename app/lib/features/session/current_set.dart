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

/// 현재 세트. 세션 순서상 처음 만나는 미완료 세트를 고르되, 그 종목이 슈퍼세트 묶음이면
/// 묶음 안에서 완료한 세트가 가장 적은 종목(같으면 앞 종목)의 첫 미완료 세트를 고른다(번갈아 진행).
/// [excluding] 세트는 완료한 것으로 본다.
CurrentSet? currentSetOf(Session session, {String? excluding}) {
  bool open(WorkoutSet w) => !w.isCompleted && w.id != excluding;
  for (final e in session.exercises) {
    if (!e.sets.any(open)) continue;
    final g = e.supersetGroup;
    var pick = e;
    if (g != null) {
      var best = -1;
      for (final m in session.exercises) {
        if (m.supersetGroup != g || !m.sets.any(open)) continue;
        final done = m.sets.where((w) => !open(w)).length;
        if (best < 0 || done < best) {
          best = done;
          pick = m;
        }
      }
    }
    return CurrentSet(pick, pick.sets.firstWhere(open));
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

/// 세트 종류 표시 글자: DROP "D", FAILURE "F", 일반은 null.
String? setTypeBadge(WorkoutSet s) => switch (s.setType) {
  SetType.DROP => 'D',
  SetType.FAILURE => 'F',
  SetType.NORMAL => null,
};

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
  final r = s.isAmrap ? '$reps+' : _repsRange(reps, s.targetRepsMax);
  final w = s.targetWeightKg;
  if (w == null) return r;
  return '${Units.format(w, unit, withUnit: false)}×$r';
}

/// 목표 횟수: "12" 또는 범위 "12~15".
String repsRangeText(int reps, int? max) => _repsRange(reps, max);

String _repsRange(int reps, int? max) => max == null || max <= reps ? '$reps' : '$reps~$max';

/// 예정 운동 세트 목표 한 줄: "80kg × 12~15 · RIR 3". 목표가 하나도 없으면 null.
String? scheduledTargetText(AppLocalizations l, WorkoutSet s, WeightUnit unit) {
  final w = s.targetWeightKg;
  final reps = s.targetReps;
  final main = [
    if (w != null) Units.format(w, unit, withUnit: false) + (unit == WeightUnit.KG ? 'kg' : 'lb'),
    if (reps != null) _repsRange(reps, s.targetRepsMax),
  ];
  final head = main.length == 2 ? '${main[0]} × ${main[1]}' : main.join();
  final parts = [
    if (head.isNotEmpty) head,
    if (s.targetRir != null) l.schedTargetRir(s.targetRir!),
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

/// 이 세트를 끝낸 뒤 휴식 시간(초): 세트의 목표 휴식이 있으면 그 값, 없으면 설정 기본값.
int restSecFor(WorkoutSet s, int defaultRestSec) => s.targetRestSec ?? defaultRestSec;

String formatRestSec(int sec) =>
    '${sec ~/ 60}:${(sec % 60).toString().padLeft(2, '0')}';
