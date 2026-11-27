import 'package:fitlog/core/api/dto.dart';
import 'package:fitlog/core/api/program_dto.dart';
import 'package:fitlog/data/memory/memory_repositories.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'harness.dart';

RecordPoint pt(double w, int reps, {double? e1rm, int day = 10}) => RecordPoint(
  weightKg: w,
  reps: reps,
  e1rmKg: e1rm,
  sessionId: 's',
  setId: 'w$w$reps',
  achievedAt: DateTime.utc(2026, 11, day, 12),
);

/// 처음 [failures]번은 실패하는 저장소.
class FlakyRecords extends MemoryRecordsRepository {
  FlakyRecords(this.failures);
  int failures;
  @override
  Future<ExerciseRecords> records(String exerciseId) async {
    if (failures > 0) {
      failures--;
      throw Exception('offline');
    }
    return super.records(exerciseId);
  }
}

void main() {
  const route = '/exercises/ex-squat/records';

  testWidgets('최고 무게·추정 1RM(식)·최근 측정·횟수별 표', (tester) async {
    final h = B3Harness();
    h.records.recordsByExercise['ex-squat'] = ExerciseRecords(
      exerciseId: 'ex-squat',
      formula: 'BRZYCKI',
      bestWeight: pt(140, 3),
      bestE1rm: pt(130, 5, e1rm: 146.3),
      latestMeasured: OneRmMeasurement(id: 'm1', weightKg: 150, measuredAt: DateTime.utc(2026, 10, 1, 12)),
      byReps: [(reps: 1, point: pt(145, 1)), (reps: 5, point: pt(130, 5, day: 9))],
    );
    await h.pump(tester, route);
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('스쿼트'), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('records-best-weight')), matching: find.text('140 kg')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('records-best-e1rm')), matching: find.text('146.3 kg')), findsOneWidget);
    expect(find.textContaining('추정식 Brzycki'), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('records-latest-measured')), matching: find.text('150 kg')), findsOneWidget);

    expect(find.byKey(const Key('reps-row-1')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('reps-row-1')), matching: find.text('145 kg')), findsOneWidget);
    expect(find.text(' · 2026-11-10'), findsOneWidget);
    expect(find.text('130 kg'), findsOneWidget);
    expect(find.text(' · 2026-11-09'), findsOneWidget);
    expect(find.text('-'), findsNWidgets(8));
  });

  testWidgets('lb 설정이면 lb로 표시', (tester) async {
    final h = B3Harness(settings: const Settings(weightUnit: WeightUnit.LB));
    h.records.recordsByExercise['ex-squat'] = ExerciseRecords(exerciseId: 'ex-squat', formula: 'EPLEY', bestWeight: pt(100, 5));
    await h.pump(tester, route);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('220.5 lb'), findsOneWidget);
  });

  testWidgets('기록이 없으면 "기록 없음"', (tester) async {
    final h = B3Harness();
    await h.pump(tester, route);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('기록 없음'), findsNWidgets(3));
    expect(find.text('직접 측정한 1RM이 없어요'), findsOneWidget);
  });

  testWidgets('1RM 측정 추가(무게·메모)와 삭제(확인)', (tester) async {
    final h = B3Harness();
    await h.pump(tester, route);
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.byKey(const Key('records-add-onerm')));
    await tester.pumpAndSettle();
    // 0 이하는 거부
    await tester.enterText(find.byKey(const Key('onerm-weight')), '0');
    await tester.tap(find.byKey(const Key('onerm-save')));
    await tester.pump();
    expect(find.text('0보다 큰 무게를 입력해 주세요.'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('onerm-weight')), '152.5');
    await tester.enterText(find.byKey(const Key('onerm-note')), '컨디션 최고');
    await tester.tap(find.byKey(const Key('onerm-save')));
    await tester.pumpAndSettle();

    final saved = await h.records.oneRms('ex-squat');
    expect(saved.single.weightKg, 152.5);
    expect(saved.single.note, '컨디션 최고');
    expect(saved.single.measuredAt, DateTime.utc(2026, 11, 26, 12));
    expect(saved.single.id, isNotEmpty);
    expect(find.text('152.5 kg'), findsOneWidget);
    expect(find.textContaining('컨디션 최고'), findsOneWidget);

    await tester.tap(find.byKey(Key('onerm-delete-${saved.single.id}')));
    await tester.pumpAndSettle();
    expect(await h.records.oneRms('ex-squat'), hasLength(1), reason: '확인 전에는 삭제하지 않는다');
    await tester.tap(find.byKey(const Key('records-delete-confirm')));
    await tester.pumpAndSettle();
    expect(await h.records.oneRms('ex-squat'), isEmpty);
    expect(find.text('직접 측정한 1RM이 없어요'), findsOneWidget);
  });

  testWidgets('lb로 입력한 1RM은 kg로 저장', (tester) async {
    final h = B3Harness(settings: const Settings(weightUnit: WeightUnit.LB));
    await h.pump(tester, route);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const Key('records-add-onerm')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('onerm-weight')), '225');
    await tester.tap(find.byKey(const Key('onerm-save')));
    await tester.pumpAndSettle();
    expect((await h.records.oneRms('ex-squat')).single.weightKg, closeTo(102.06, 0.01));
  });

  testWidgets('오프라인이면 오류 문구와 다시 시도', (tester) async {
    final h = B3Harness();
    final flaky = FlakyRecords(1);
    flaky.recordsByExercise['ex-squat'] = ExerciseRecords(exerciseId: 'ex-squat', formula: 'EPLEY', bestWeight: pt(100, 5));
    h.recordsOverride = flaky;
    await h.pump(tester, route);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const Key('records-error')), findsOneWidget);
    expect(find.byKey(const Key('records-best-weight')), findsNothing);

    await tester.tap(find.byKey(const Key('records-retry')));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const Key('records-error')), findsNothing);
    expect(find.byKey(const Key('records-best-weight')), findsOneWidget);
  });
}
