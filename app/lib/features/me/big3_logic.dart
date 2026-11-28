// 3대 운동 1RM 화면의 데이터 변환. 화면과 분리한 순수 함수.
import '../../core/api/program_dto.dart' show ExerciseRecords, OneRmMeasurement;
import '../../core/api/stats_dto.dart' show ProgressPoint;

/// 한 종목의 현재 1RM. 측정값이 있으면 그것, 없으면 운동 기록 추정값.
class Big3Current {
  const Big3Current({
    required this.kg,
    required this.measured,
    required this.date,
    this.estWeightKg,
    this.estReps,
    this.formula,
  });
  final double kg;
  final bool measured;
  final DateTime date;

  /// 추정일 때 근거가 된 세트(무게·횟수)와 추정식.
  final double? estWeightKg;
  final int? estReps;
  final String? formula;
}

/// 측정 우선, 없으면 추정. 둘 다 없으면 null.
Big3Current? big3Current(ExerciseRecords r) {
  final m = r.latestMeasured;
  if (m != null) return Big3Current(kg: m.weightKg, measured: true, date: m.measuredAt);
  final e = r.bestE1rm;
  if (e != null && e.e1rmKg != null) {
    return Big3Current(
      kg: e.e1rmKg!,
      measured: false,
      date: e.achievedAt,
      estWeightKg: e.weightKg,
      estReps: e.reps,
      formula: r.formula,
    );
  }
  return null;
}

class Big3Total {
  const Big3Total({this.kg, this.includesEstimate = false, this.count = 0});

  /// 셋 다 값이 있을 때만 숫자.
  final double? kg;
  final bool includesEstimate;

  /// 값이 있는 종목 수.
  final int count;
}

Big3Total big3Total(List<Big3Current?> lifts) {
  final have = lifts.whereType<Big3Current>().toList();
  if (have.length < lifts.length || have.isEmpty) return Big3Total(count: have.length);
  return Big3Total(
    kg: have.fold<double>(0, (a, b) => a + b.kg),
    includesEstimate: have.any((c) => !c.measured),
    count: have.length,
  );
}

/// 그래프의 한 점. [x]는 가장 이른 점으로부터의 일수(날짜에 비례).
class Big3Dot {
  const Big3Dot({required this.x, required this.date, required this.kg, required this.measured, this.sessionId});
  final double x;
  final DateTime date;
  final double kg;
  final bool measured;
  final String? sessionId;
}

class Big3Chart {
  const Big3Chart({this.measured = const [], this.estimated = const [], this.maxX = 1, this.origin});

  /// 각 계열은 날짜 오름차순.
  final List<Big3Dot> measured;
  final List<Big3Dot> estimated;
  final double maxX;

  /// x=0에 해당하는 시각(가장 이른 점).
  final DateTime? origin;

  bool get isEmpty => measured.isEmpty && estimated.isEmpty;

  /// 두 계열 전체를 날짜 오름차순으로(같은 날이면 측정이 뒤). 마지막이 가장 최근 점.
  List<Big3Dot> get all =>
      [...measured, ...estimated]..sort((a, b) {
        final c = a.date.compareTo(b.date);
        return c != 0 ? c : (a.measured == b.measured ? 0 : (a.measured ? 1 : -1));
      });

  /// 가장 최근 측정 점(고리 표시용).
  Big3Dot? get latestMeasured => measured.isEmpty ? null : measured.last;

  Iterable<double> get ys => all.map((d) => d.kg);
}

/// 기간(from 이후)의 측정·추정 두 계열. 추정 점은 추정 1RM이 있는 세션만.
Big3Chart big3Chart({
  required List<OneRmMeasurement> measurements,
  required List<ProgressPoint> progress,
  required DateTime from,
}) {
  final ms = measurements.where((m) => !m.measuredAt.isBefore(from)).toList()
    ..sort((a, b) => a.measuredAt.compareTo(b.measuredAt));
  final ps = progress.where((p) => p.bestE1rmKg != null && !p.startedAt.isBefore(from)).toList()
    ..sort((a, b) => a.startedAt.compareTo(b.startedAt));
  if (ms.isEmpty && ps.isEmpty) return const Big3Chart();
  final dates = [...ms.map((m) => m.measuredAt), ...ps.map((p) => p.startedAt)];
  final origin = dates.reduce((a, b) => a.isBefore(b) ? a : b);
  final last = dates.reduce((a, b) => a.isAfter(b) ? a : b);
  double x(DateTime d) => d.difference(origin).inMinutes / (60 * 24);
  final span = x(last);
  return Big3Chart(
    measured: [for (final m in ms) Big3Dot(x: x(m.measuredAt), date: m.measuredAt, kg: m.weightKg, measured: true)],
    estimated: [
      for (final p in ps)
        Big3Dot(x: x(p.startedAt), date: p.startedAt, kg: p.bestE1rmKg!, measured: false, sessionId: p.sessionId),
    ],
    maxX: span < 1 ? 1 : span,
    origin: origin,
  );
}
