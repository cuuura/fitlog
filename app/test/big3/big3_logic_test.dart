import 'package:fitlog/core/api/program_dto.dart';
import 'package:fitlog/core/api/stats_dto.dart';
import 'package:fitlog/features/me/big3_logic.dart';
import 'package:flutter_test/flutter_test.dart';

RecordPoint rp(double w, int reps, double? e1rm, DateTime at) =>
    RecordPoint(weightKg: w, reps: reps, e1rmKg: e1rm, sessionId: 's', setId: 'x', achievedAt: at);

OneRmMeasurement om(String id, double kg, DateTime at) => OneRmMeasurement(id: id, weightKg: kg, measuredAt: at);

ProgressPoint pp(DateTime at, double? e1rm) => ProgressPoint(
  sessionId: 's${at.millisecondsSinceEpoch}',
  startedAt: at,
  topWeightKg: 100,
  topReps: 5,
  bestE1rmKg: e1rm,
  volumeKg: 100,
  workSetCount: 3,
);

void main() {
  final d = DateTime.utc(2026, 11, 20);

  group('big3Current', () {
    test('측정값이 있으면 추정보다 우선', () {
      final c = big3Current(
        ExerciseRecords(
          exerciseId: 'a',
          formula: 'EPLEY',
          latestMeasured: om('m', 140, d),
          bestE1rm: rp(120, 5, 150, d),
        ),
      )!;
      expect(c.kg, 140);
      expect(c.measured, isTrue);
      expect(c.date, d);
    });

    test('측정이 없으면 추정 1RM으로 대체하고 근거 세트를 남긴다', () {
      final c = big3Current(ExerciseRecords(exerciseId: 'a', formula: 'BRZYCKI', bestE1rm: rp(100, 5, 116.7, d)))!;
      expect(c.kg, 116.7);
      expect(c.measured, isFalse);
      expect((c.estWeightKg, c.estReps, c.formula), (100, 5, 'BRZYCKI'));
    });

    test('둘 다 없거나 추정값이 비면 null', () {
      expect(big3Current(const ExerciseRecords(exerciseId: 'a', formula: 'EPLEY')), isNull);
      expect(big3Current(ExerciseRecords(exerciseId: 'a', formula: 'EPLEY', bestE1rm: rp(60, 20, null, d))), isNull);
    });
  });

  group('big3Total', () {
    Big3Current c(double kg, bool m) => Big3Current(kg: kg, measured: m, date: d);

    test('셋 다 측정이면 합계, 추정 포함 아님', () {
      final t = big3Total([c(140, true), c(100, true), c(180, true)]);
      expect((t.kg, t.includesEstimate, t.count), (420, false, 3));
    });

    test('추정이 섞이면 추정 포함', () {
      final t = big3Total([c(140, true), c(100, false), c(182.5, true)]);
      expect((t.kg, t.includesEstimate), (422.5, true));
    });

    test('하나라도 없으면 합계 없이 개수만', () {
      final t = big3Total([c(140, true), null, c(180, true)]);
      expect((t.kg, t.count), (null, 2));
      expect(big3Total([null, null, null]).count, 0);
    });
  });

  group('big3Chart', () {
    test('기간 앞 점은 빼고 날짜순 정렬, x는 일수에 비례', () {
      final from = DateTime.utc(2026, 6, 1);
      final chart = big3Chart(
        measurements: [
          om('b', 130, DateTime.utc(2026, 11, 20)),
          om('old', 100, DateTime.utc(2026, 5, 1)),
          om('a', 120, DateTime.utc(2026, 10, 1)),
        ],
        progress: [pp(DateTime.utc(2026, 11, 1), 125), pp(DateTime.utc(2026, 9, 1), 110), pp(DateTime.utc(2026, 10, 5), null)],
        from: from,
      );
      expect(chart.measured.map((e) => e.kg), [120, 130]);
      expect(chart.estimated.map((e) => e.kg), [110, 125]);
      // 가장 이른 점 9/1이 x=0, 10/1은 30일째
      expect(chart.estimated.first.x, 0);
      expect(chart.measured.first.x, closeTo(30, 0.001));
      expect(chart.maxX, closeTo(80, 0.001));
      expect(chart.all.last.kg, 130);
      expect(chart.latestMeasured!.kg, 130);
    });

    test('모두 비면 isEmpty', () {
      final chart = big3Chart(measurements: [om('old', 1, DateTime.utc(2020))], progress: [], from: DateTime.utc(2026));
      expect(chart.isEmpty, isTrue);
    });

    test('점이 하루 안에 모여도 maxX는 1 이상', () {
      final chart = big3Chart(measurements: [om('a', 100, d)], progress: [], from: DateTime.utc(2026));
      expect(chart.maxX, 1);
    });
  });
}
