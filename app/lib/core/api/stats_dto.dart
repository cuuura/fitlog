// contracts/v1.0/openapi.yaml STA-4 DTO(종목 추이, 회차 비교). 트랙 리드 소유.
import 'program_dto.dart' show RecordPoint;

DateTime _dt(Object? v) => DateTime.parse(v as String).toUtc();
double? _num(Object? v) => v == null ? null : (v as num).toDouble();
RecordPoint? _rp(Object? v) => v == null ? null : RecordPoint.fromJson((v as Map).cast());

/// 종목 추이의 한 점(세션당 1점).
class ProgressPoint {
  final String sessionId;
  final DateTime startedAt;
  final double topWeightKg;
  final int topReps;
  final double? bestE1rmKg;
  final double volumeKg;
  final int workSetCount;

  /// 그 세션 이전 누적 최대보다 엄격히 클 때.
  final bool isWeightPr;
  final bool isE1rmPr;
  const ProgressPoint({
    required this.sessionId,
    required this.startedAt,
    required this.topWeightKg,
    required this.topReps,
    this.bestE1rmKg,
    required this.volumeKg,
    required this.workSetCount,
    this.isWeightPr = false,
    this.isE1rmPr = false,
  });

  factory ProgressPoint.fromJson(Map<String, Object?> j) => ProgressPoint(
    sessionId: j['sessionId'] as String,
    startedAt: _dt(j['startedAt']),
    topWeightKg: _num(j['topWeightKg'])!,
    topReps: j['topReps'] as int,
    bestE1rmKg: _num(j['bestE1rmKg']),
    volumeKg: _num(j['volumeKg']) ?? 0,
    workSetCount: j['workSetCount'] as int? ?? 0,
    isWeightPr: j['isWeightPr'] as bool? ?? false,
    isE1rmPr: j['isE1rmPr'] as bool? ?? false,
  );
}

class ExerciseProgress {
  final String exerciseId;
  final String formula;

  /// startedAt 오름차순.
  final List<ProgressPoint> points;

  /// 기간과 무관한 전체 최고.
  final RecordPoint? bestWeight;
  final RecordPoint? bestE1rm;
  const ExerciseProgress({
    required this.exerciseId,
    required this.formula,
    this.points = const [],
    this.bestWeight,
    this.bestE1rm,
  });

  factory ExerciseProgress.fromJson(Map<String, Object?> j) => ExerciseProgress(
    exerciseId: j['exerciseId'] as String,
    formula: j['formula'] as String? ?? 'EPLEY',
    points: [for (final p in (j['points'] as List? ?? const [])) ProgressPoint.fromJson((p as Map).cast())],
    bestWeight: _rp(j['bestWeight']),
    bestE1rm: _rp(j['bestE1rm']),
  );
}

class SnapSet {
  final double weightKg;
  final int reps;
  const SnapSet(this.weightKg, this.reps);
  factory SnapSet.fromJson(Map<String, Object?> j) => SnapSet(_num(j['weightKg'])!, j['reps'] as int);
}

/// 한 세션에서 한 종목의 끝낸 작업 세트 요약.
class Snap {
  final String sessionId;
  final DateTime startedAt;
  final List<SnapSet> sets;
  final int setCount;
  final double? topWeightKg;
  final double? bestE1rmKg;
  final double volumeKg;
  const Snap({
    required this.sessionId,
    required this.startedAt,
    this.sets = const [],
    required this.setCount,
    this.topWeightKg,
    this.bestE1rmKg,
    required this.volumeKg,
  });

  factory Snap.fromJson(Map<String, Object?> j) => Snap(
    sessionId: j['sessionId'] as String,
    startedAt: _dt(j['startedAt']),
    sets: [for (final s in (j['sets'] as List? ?? const [])) SnapSet.fromJson((s as Map).cast())],
    setCount: j['setCount'] as int? ?? 0,
    topWeightKg: _num(j['topWeightKg']),
    bestE1rmKg: _num(j['bestE1rmKg']),
    volumeKg: _num(j['volumeKg']) ?? 0,
  );
}

class ExerciseComparison {
  final String exerciseId;
  final Snap current;
  final Snap? previous;

  /// 이 세션 이전까지의 최고(이 세션 제외).
  final RecordPoint? bestWeight;
  final RecordPoint? bestE1rm;
  const ExerciseComparison({
    required this.exerciseId,
    required this.current,
    this.previous,
    this.bestWeight,
    this.bestE1rm,
  });

  /// 오늘 최고 무게가 이전 최고보다 엄격히 큰가(이전 기록이 없으면 false).
  bool get isWeightPr {
    final top = current.topWeightKg;
    final best = bestWeight?.weightKg;
    return top != null && best != null && top > best;
  }

  bool get isE1rmPr {
    final top = current.bestE1rmKg;
    final best = bestE1rm?.e1rmKg;
    return top != null && best != null && top > best;
  }

  factory ExerciseComparison.fromJson(Map<String, Object?> j) => ExerciseComparison(
    exerciseId: j['exerciseId'] as String,
    current: Snap.fromJson((j['current'] as Map).cast()),
    previous: j['previous'] == null ? null : Snap.fromJson((j['previous'] as Map).cast()),
    bestWeight: _rp(j['bestWeight']),
    bestE1rm: _rp(j['bestE1rm']),
  );
}

class SessionComparison {
  final String sessionId;
  final String formula;

  /// 세션의 종목 순서대로.
  final List<ExerciseComparison> exercises;
  const SessionComparison({required this.sessionId, required this.formula, this.exercises = const []});

  factory SessionComparison.fromJson(Map<String, Object?> j) => SessionComparison(
    sessionId: j['sessionId'] as String,
    formula: j['formula'] as String? ?? 'EPLEY',
    exercises: [for (final e in (j['exercises'] as List? ?? const [])) ExerciseComparison.fromJson((e as Map).cast())],
  );
}
