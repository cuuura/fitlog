// "지난 세션 값" 매칭(순수 함수). 세트 순서를 바꿔도 같은 계획 세트·같은 종류 n번째끼리 맞춘다.
import '../../core/api/dto.dart';

/// [current] 안 [index]번째 세트에 대응하는 지난 세트.
/// 1) plannedSetKey가 같고 워밍업 여부가 같은 지난 세트
/// 2) 같은 종류(워밍업/본) 안에서 같은 순번(n번째)
/// 3) 같은 종류의 마지막 세트, 그것도 없으면 지난 세트의 마지막
WorkoutSet? matchPreviousSet(
  List<WorkoutSet> current,
  int index,
  List<WorkoutSet> previous,
) {
  if (previous.isEmpty || index < 0 || index >= current.length) {
    return previous.isEmpty ? null : previous.last;
  }
  final me = current[index];
  final key = me.plannedSetKey;
  if (key != null) {
    for (final p in previous) {
      if (p.plannedSetKey == key && p.isWarmup == me.isWarmup) return p;
    }
  }
  var nth = 0;
  for (var i = 0; i < index; i++) {
    if (current[i].isWarmup == me.isWarmup) nth++;
  }
  final same = [
    for (final p in previous)
      if (p.isWarmup == me.isWarmup) p,
  ];
  if (same.isEmpty) return previous.last;
  return nth < same.length ? same[nth] : same.last;
}

/// 새 세트를 [existing] 끝에 붙일 때 기본값으로 쓸 지난 세트(본 세트 기준).
WorkoutSet? previousForNewSet(
  List<WorkoutSet> existing,
  List<WorkoutSet> previous,
) {
  if (previous.isEmpty) return null;
  final nth = existing.where((w) => !w.isWarmup).length;
  final work = [
    for (final p in previous)
      if (!p.isWarmup) p,
  ];
  if (work.isEmpty) return previous.last;
  return nth < work.length ? work[nth] : work.last;
}
