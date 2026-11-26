import 'package:fitlog/core/api/program_dto.dart' show RecordPoint;
import 'package:fitlog/core/api/stats_dto.dart';
import 'package:fitlog/features/progress/progress_logic.dart';
import 'package:flutter_test/flutter_test.dart';

ProgressPoint pp(int day, double w, {double? e1rm, double vol = 100, bool wPr = false, bool ePr = false}) =>
    ProgressPoint(
      sessionId: 's$day',
      startedAt: DateTime.utc(2026, 11, day),
      topWeightKg: w,
      topReps: 5,
      bestE1rmKg: e1rm,
      volumeKg: vol,
      workSetCount: 3,
      isWeightPr: wPr,
      isE1rmPr: ePr,
    );

RecordPoint rp(double w, {double? e1rm}) =>
    RecordPoint(weightKg: w, reps: 5, e1rmKg: e1rm, sessionId: 'x', setId: 'y', achievedAt: DateTime.utc(2026));

Snap snap(double? top, double? e1rm, double vol, [List<SnapSet> sets = const []]) => Snap(
  sessionId: 's',
  startedAt: DateTime.utc(2026),
  sets: sets,
  setCount: sets.length,
  topWeightKg: top,
  bestE1rmKg: e1rm,
  volumeKg: vol,
);

void main() {
  group('progressFrom', () {
    final now = DateTime.utc(2026, 11, 26, 9);
    test('기간별 시작 시각', () {
      expect(progressFrom(ProgressPeriod.m3, now), DateTime.utc(2026, 8, 26, 9));
      expect(progressFrom(ProgressPeriod.m6, now), DateTime.utc(2026, 5, 26, 9));
      expect(progressFrom(ProgressPeriod.y1, now), DateTime.utc(2025, 11, 26, 9));
    });
    test('전체는 1970-01-01로 명시하고 limit은 500', () {
      expect(progressFrom(ProgressPeriod.all, now), DateTime.utc(1970));
      expect(progressLimit, 500);
    });
    test('연도를 넘기는 달 계산', () {
      expect(progressFrom(ProgressPeriod.m3, DateTime.utc(2026, 2, 10)), DateTime.utc(2025, 11, 10));
    });
  });

  group('chartPoints', () {
    final pts = [
      pp(1, 100, e1rm: 120, vol: 500),
      pp(2, 105, e1rm: 125, vol: 600, wPr: true),
      pp(3, 105, vol: 700, ePr: true),
    ];
    test('최고 무게: PR은 isWeightPr', () {
      final c = chartPoints(pts, ProgressMetric.weight);
      expect(c.map((e) => e.yKg), [100, 105, 105]);
      expect(c.map((e) => e.isPr), [false, true, false]);
      expect(c.map((e) => e.index), [0, 1, 2]);
    });
    test('추정 1RM: 값 없는 점은 건너뛰고 인덱스를 다시 매김, PR은 isE1rmPr', () {
      final c = chartPoints(pts, ProgressMetric.e1rm);
      expect(c.map((e) => e.yKg), [120, 125]);
      expect(c.map((e) => e.isPr), [false, false]);
      expect(c.map((e) => e.index), [0, 1]);
      final c2 = chartPoints([pp(3, 105, e1rm: 130, ePr: true)], ProgressMetric.e1rm);
      expect(c2.single.isPr, true);
    });
    test('볼륨: PR 구분 없음', () {
      final c = chartPoints(pts, ProgressMetric.volume);
      expect(c.map((e) => e.yKg), [500, 600, 700]);
      expect(c.every((e) => !e.isPr), true);
    });
    test('빈 목록', () => expect(chartPoints(const [], ProgressMetric.weight), isEmpty));
  });

  test('bestLineKg: 지표별 전체 최고, 볼륨은 없음', () {
    final p = ExerciseProgress(exerciseId: 'e', formula: 'EPLEY', bestWeight: rp(140), bestE1rm: rp(130, e1rm: 150));
    expect(bestLineKg(p, ProgressMetric.weight), 140);
    expect(bestLineKg(p, ProgressMetric.e1rm), 150);
    expect(bestLineKg(p, ProgressMetric.volume), isNull);
    expect(bestLineKg(const ExerciseProgress(exerciseId: 'e', formula: 'EPLEY'), ProgressMetric.weight), isNull);
  });

  group('yRange', () {
    test('여백 포함, 0 아래로 내려가지 않음', () {
      final r = yRange([10, 20]);
      expect(r.min, closeTo(8.5, 1e-9));
      expect(r.max, closeTo(21.5, 1e-9));
      expect(yRange([1, 100]).min, 0);
    });
    test('같은 값·빈 값', () {
      final r = yRange([50]);
      expect(r.min < 50 && r.max > 50, true);
      expect(yRange([]), (min: 0.0, max: 1.0));
      expect(yRange([0]).max, 1);
    });
  });

  group('barGroup', () {
    final c = ExerciseComparison(
      exerciseId: 'e',
      current: snap(105, 125, 800),
      previous: snap(100, 120, 700),
      bestWeight: rp(102),
      bestE1rm: rp(100, e1rm: 122),
    );
    test('최고 무게: 지난·오늘·이전 PR', () {
      final b = barGroup(c, CompareMetric.weight);
      expect(b.map((e) => e.kind), [BarKind.previous, BarKind.today, BarKind.previousPr]);
      expect(b.map((e) => e.valueKg), [100, 105, 102]);
    });
    test('추정 1RM', () => expect(barGroup(c, CompareMetric.e1rm).map((e) => e.valueKg), [120, 125, 122]));
    test('볼륨은 지난·오늘 2개만', () {
      final b = barGroup(c, CompareMetric.volume);
      expect(b.map((e) => e.kind), [BarKind.previous, BarKind.today]);
    });
    test('이전 기록 없으면 오늘만', () {
      final first = ExerciseComparison(exerciseId: 'e', current: snap(60, 70, 300));
      expect(barGroup(first, CompareMetric.weight).map((e) => e.kind), [BarKind.today]);
    });
  });

  test('setRows: 길이가 다르면 빈 칸', () {
    final c = ExerciseComparison(
      exerciseId: 'e',
      current: snap(105, null, 0, const [SnapSet(105, 5), SnapSet(105, 4), SnapSet(100, 5)]),
      previous: snap(100, null, 0, const [SnapSet(100, 5), SnapSet(100, 5)]),
    );
    final r = setRows(c);
    expect(r.length, 3);
    expect(r[0].previous?.weightKg, 100);
    expect(r[2].previous, isNull);
    expect(r[2].today?.reps, 5);
    expect(setRows(ExerciseComparison(exerciseId: 'e', current: snap(1, null, 0))), isEmpty);
  });

  test('prBadges: 클라이언트 비교, 이전 기록 없으면 PR 아님', () {
    final pr = ExerciseComparison(
      exerciseId: 'e',
      current: snap(105, 125, 0),
      previous: snap(100, 120, 0),
      bestWeight: rp(100),
      bestE1rm: rp(100, e1rm: 130),
    );
    expect(prBadges(pr), (weight: true, e1rm: false));
    final first = ExerciseComparison(exerciseId: 'e', current: snap(105, 125, 0));
    expect(prBadges(first), (weight: false, e1rm: false));
  });
}
