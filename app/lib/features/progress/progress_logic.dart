// B1(v1.0). STA-4 차트 데이터 변환. 화면과 분리한 순수 함수.
import '../../core/api/stats_dto.dart';

enum ProgressMetric { weight, e1rm, volume }

enum ProgressPeriod { m3, m6, y1, all }

/// 모든 기간에서 서버에 요청하는 점 개수 상한.
const progressLimit = 500;

/// "전체"는 계약 기본(180일)을 피하려고 from을 명시한다.
final progressEpoch = DateTime.utc(1970);

/// 기간의 시작 시각(UTC). "전체"는 1970-01-01.
DateTime progressFrom(ProgressPeriod p, DateTime now) {
  final n = now.toUtc();
  return switch (p) {
    ProgressPeriod.m3 => DateTime.utc(n.year, n.month - 3, n.day, n.hour, n.minute, n.second),
    ProgressPeriod.m6 => DateTime.utc(n.year, n.month - 6, n.day, n.hour, n.minute, n.second),
    ProgressPeriod.y1 => DateTime.utc(n.year - 1, n.month, n.day, n.hour, n.minute, n.second),
    ProgressPeriod.all => progressEpoch,
  };
}

/// 차트의 한 점. [yKg]는 kg 값(화면에서 표시 단위로 바꾼다).
class ChartPoint {
  final int index;
  final String sessionId;
  final DateTime date;
  final double yKg;
  final bool isPr;
  final double topWeightKg;
  final int topReps;
  const ChartPoint({
    required this.index,
    required this.sessionId,
    required this.date,
    required this.yKg,
    required this.isPr,
    required this.topWeightKg,
    required this.topReps,
  });
}

/// 지표에 맞는 y 값과 PR 플래그. 추정 1RM이 없는 점은 건너뛴다. 볼륨에는 PR 구분이 없다.
List<ChartPoint> chartPoints(List<ProgressPoint> points, ProgressMetric metric) {
  final out = <ChartPoint>[];
  for (final p in points) {
    final double? y = switch (metric) {
      ProgressMetric.weight => p.topWeightKg,
      ProgressMetric.e1rm => p.bestE1rmKg,
      ProgressMetric.volume => p.volumeKg,
    };
    if (y == null) continue;
    out.add(
      ChartPoint(
        index: out.length,
        sessionId: p.sessionId,
        date: p.startedAt,
        yKg: y,
        isPr: switch (metric) {
          ProgressMetric.weight => p.isWeightPr,
          ProgressMetric.e1rm => p.isE1rmPr,
          ProgressMetric.volume => false,
        },
        topWeightKg: p.topWeightKg,
        topReps: p.topReps,
      ),
    );
  }
  return out;
}

/// 전체 최고 수평선 값(kg). 볼륨은 없다.
double? bestLineKg(ExerciseProgress p, ProgressMetric metric) => switch (metric) {
  ProgressMetric.weight => p.bestWeight?.weightKg,
  ProgressMetric.e1rm => p.bestE1rm?.e1rmKg,
  ProgressMetric.volume => null,
};

/// y축 범위(표시 단위 값). 점과 최고선을 포함하고 위아래에 여백을 둔다.
({double min, double max}) yRange(Iterable<double> values) {
  final list = values.toList();
  if (list.isEmpty) return (min: 0, max: 1);
  var lo = list.reduce((a, b) => a < b ? a : b);
  var hi = list.reduce((a, b) => a > b ? a : b);
  if (hi == lo) {
    final pad = hi == 0 ? 1.0 : hi * 0.1;
    return (min: (lo - pad).clamp(0, double.infinity).toDouble(), max: hi + pad);
  }
  final pad = (hi - lo) * 0.15;
  lo = (lo - pad).clamp(0, double.infinity).toDouble();
  return (min: lo, max: hi + pad);
}

enum CompareMetric { weight, e1rm, volume }

enum BarKind { previous, today, previousPr }

class BarEntry {
  final BarKind kind;
  final double valueKg;
  const BarEntry(this.kind, this.valueKg);
}

/// 막대 그룹: 지난 같은 세션 / 오늘 / 이전 PR(볼륨은 PR 없음 → 지난·오늘만). 값이 없는 막대는 뺀다.
List<BarEntry> barGroup(ExerciseComparison c, CompareMetric m) {
  final double? prev, today, pr;
  switch (m) {
    case CompareMetric.weight:
      prev = c.previous?.topWeightKg;
      today = c.current.topWeightKg;
      pr = c.bestWeight?.weightKg;
    case CompareMetric.e1rm:
      prev = c.previous?.bestE1rmKg;
      today = c.current.bestE1rmKg;
      pr = c.bestE1rm?.e1rmKg;
    case CompareMetric.volume:
      prev = c.previous?.volumeKg;
      today = c.current.volumeKg;
      pr = null;
  }
  return [
    if (prev != null) BarEntry(BarKind.previous, prev),
    if (today != null) BarEntry(BarKind.today, today),
    if (pr != null) BarEntry(BarKind.previousPr, pr),
  ];
}

/// 세트별 비교 한 줄. 어느 쪽에 세트가 없으면 null.
class SetRow {
  final int number;
  final SnapSet? previous;
  final SnapSet? today;
  const SetRow(this.number, this.previous, this.today);
}

List<SetRow> setRows(ExerciseComparison c) {
  final prev = c.previous?.sets ?? const <SnapSet>[];
  final cur = c.current.sets;
  final n = prev.length > cur.length ? prev.length : cur.length;
  return [for (var i = 0; i < n; i++) SetRow(i + 1, i < prev.length ? prev[i] : null, i < cur.length ? cur[i] : null)];
}

/// 이 종목 비교에서 보여 줄 PR 배지.
({bool weight, bool e1rm}) prBadges(ExerciseComparison c) => (weight: c.isWeightPr, e1rm: c.isE1rmPr);
