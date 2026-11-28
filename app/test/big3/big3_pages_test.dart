import 'package:fitlog/core/api/api_client.dart' show ApiException;
import 'package:fitlog/core/api/dto.dart';
import 'package:fitlog/core/api/program_dto.dart';
import 'package:fitlog/core/api/stats_dto.dart';
import 'package:fitlog/core/big3.dart';
import 'package:fitlog/data/memory/memory_repositories.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_env.dart';

/// 측정을 저장하면 종목의 최근 측정값도 갱신하는 대역.
class FakeRecords extends MemoryRecordsRepository {
  Object? failure;
  @override
  Future<ExerciseRecords> records(String id) async {
    if (failure != null) throw failure!;
    return super.records(id);
  }

  @override
  Future<OneRmMeasurement> addOneRm(String id, OneRmMeasurement m) async {
    final saved = await super.addOneRm(id, m);
    final old = recordsByExercise[id] ?? ExerciseRecords(exerciseId: id, formula: 'EPLEY');
    recordsByExercise[id] = ExerciseRecords(
      exerciseId: id,
      formula: old.formula,
      bestE1rm: old.bestE1rm,
      latestMeasured: saved,
    );
    return saved;
  }
}

Exercise ex(String id, String ko) =>
    exercise(id, ko, ExerciseType.BARBELL, Muscle.QUADS);

RecordPoint est(double w, int reps, double e1rm) =>
    RecordPoint(weightKg: w, reps: reps, e1rmKg: e1rm, sessionId: 's', setId: 'x', achievedAt: DateTime.utc(2026, 11, 10));

class Big3Env extends AppEnv {
  Big3Env()
    : super(
        start: DateTime.utc(2026, 11, 28, 3),
        seed: [ex(big3Lifts[0].id, '스쿼트'), ex(big3Lifts[1].id, '벤치프레스'), ex(big3Lifts[2].id, '데드리프트')],
      ) {
    records = recs;
  }

  final recs = FakeRecords();
}

Future<Big3Env> setup(WidgetTester tester, {String initial = '/me', void Function(Big3Env)? seed}) async {
  final env = Big3Env();
  seed?.call(env);
  await env.pump(tester, initial: initial);
  return env;
}

void mixed(Big3Env e) {
  final sq = big3Lifts[0].id, bn = big3Lifts[1].id, dl = big3Lifts[2].id;
  e.recs.recordsByExercise[sq] = ExerciseRecords(
    exerciseId: sq,
    formula: 'EPLEY',
    latestMeasured: OneRmMeasurement(id: 'm1', weightKg: 140, measuredAt: DateTime.utc(2026, 11, 20)),
  );
  e.recs.measured[sq] = [e.recs.recordsByExercise[sq]!.latestMeasured!];
  e.recs.recordsByExercise[bn] = ExerciseRecords(exerciseId: bn, formula: 'EPLEY', bestE1rm: est(100, 1, 100));
  e.recs.recordsByExercise[dl] = ExerciseRecords(
    exerciseId: dl,
    formula: 'EPLEY',
    latestMeasured: OneRmMeasurement(id: 'm2', weightKg: 182.5, measuredAt: DateTime.utc(2026, 11, 1)),
  );
  e.stats.progressByExercise[sq] = ExerciseProgress(
    exerciseId: sq,
    formula: 'EPLEY',
    points: [
      ProgressPoint(
        sessionId: 's1',
        startedAt: DateTime.utc(2026, 10, 1),
        topWeightKg: 100,
        topReps: 5,
        bestE1rmKg: 116,
        volumeKg: 1000,
        workSetCount: 3,
      ),
    ],
  );
}

void main() {
  group('MY 카드', () {
    testWidgets('측정·추정이 섞이면 출처와 합계(추정 포함)를 보인다', (t) async {
      await setup(t, seed: mixed);
      expect(find.text('3대 운동 1RM'), findsOneWidget);
      expect(find.text('측정 11/20'), findsOneWidget);
      expect(find.text('추정 11/10'), findsOneWidget);
      expect(find.text('140'), findsOneWidget);
      expect(find.text('합계 422.5 kg (추정 포함)'), findsOneWidget);
    });

    testWidgets('하나라도 비면 합계 대신 개수 안내', (t) async {
      await setup(t, seed: (e) {
        final sq = big3Lifts[0].id;
        e.recs.recordsByExercise[sq] = ExerciseRecords(
          exerciseId: sq,
          formula: 'EPLEY',
          latestMeasured: OneRmMeasurement(id: 'm1', weightKg: 140, measuredAt: DateTime.utc(2026, 11, 20)),
        );
      });
      expect(find.text('1개 입력됨'), findsOneWidget);
      expect(find.text('기록 없음'), findsNWidgets(2));
    });

    testWidgets('값이 전혀 없으면 안내', (t) async {
      await setup(t);
      expect(find.text('아직 입력한 1RM이 없어요'), findsOneWidget);
      expect(find.text('-'), findsNWidgets(3));
    });

    testWidgets('오류면 한 줄 안내(오프라인 문구 포함), 입력 버튼은 유지', (t) async {
      await setup(t, seed: (e) => e.recs.failure = const ApiException(code: 'NETWORK', message: 'x'));
      expect(find.byKey(const Key('me-big3-error')), findsOneWidget);
      expect(find.text('연결 후 볼 수 있어요'), findsOneWidget);
      expect(find.byKey(const Key('me-big3-add')), findsOneWidget);
    });

    testWidgets('카드를 탭하면 3대 운동 화면으로', (t) async {
      await setup(t, seed: mixed);
      await t.tap(find.byKey(const Key('me-big3')));
      await settle(t);
      expect(find.byKey(const Key('big3-row-squat')), findsOneWidget);
    });

    testWidgets('입력 버튼: 기본 스쿼트, 종목 칩으로 바꿔 저장하면 카드가 갱신', (t) async {
      await setup(t);
      await t.tap(find.byKey(const Key('me-big3-add')));
      await settle(t);
      expect(find.text('1RM 측정 추가'), findsOneWidget);
      await t.tap(find.byKey(Key('onerm-lift-${big3Lifts[1].id}')));
      await settle(t);
      await t.enterText(find.byKey(const Key('onerm-weight')), '100');
      await t.tap(find.byKey(const Key('onerm-save')));
      await settle(t);
      expect(find.byKey(const Key('onerm-save')), findsNothing);
      expect(find.text('100'), findsOneWidget);
      expect(find.text('1개 입력됨'), findsOneWidget);
      expect(find.text('기록 없음'), findsNWidgets(2));
    });

    testWidgets('시트에 지난 측정 안내(선택 종목 기준)', (t) async {
      await setup(t, seed: mixed);
      await t.tap(find.byKey(const Key('me-big3-add')));
      await settle(t);
      expect(find.text('지난 측정 140 kg (11/20)'), findsOneWidget);
      await t.tap(find.byKey(Key('onerm-lift-${big3Lifts[1].id}')));
      await settle(t);
      expect(find.textContaining('지난 측정'), findsNothing);
    });
  });

  group('Big3Page', () {
    testWidgets('세 줄과 합계, 그래프, 기본 선택(가장 최근 점)', (t) async {
      await setup(t, initial: '/me/big3', seed: mixed);
      expect(find.text('3대 운동 1RM'), findsOneWidget);
      expect(find.text('벤치프레스'), findsOneWidget);
      expect(find.text('측정 · 2026-11-20'), findsOneWidget);
      expect(find.text('추정 · 100 kg×1회 · Epley'), findsOneWidget);
      expect(find.byKey(const Key('big3-total')), findsOneWidget);
      expect(find.text('합계 422.5 kg (추정 포함)'), findsOneWidget);
      expect(find.byKey(const Key('big3-chart')), findsOneWidget);
      expect(find.text('측정 1RM'), findsOneWidget);
      expect(find.text('운동 기록 추정 1RM'), findsOneWidget);
      expect(find.text('11/20 · 140 kg · 측정'), findsOneWidget);
      expect(find.byTooltip('스쿼트 1RM 측정 추가'), findsOneWidget);
    });

    testWidgets('종목을 바꾸면 비어 있는 안내, 기간 칩 전환', (t) async {
      await setup(t, initial: '/me/big3', seed: mixed);
      await t.tap(find.descendant(of: find.byKey(const Key('big3-lift')), matching: find.text('벤치')));
      await settle(t);
      expect(find.byKey(const Key('big3-empty')), findsOneWidget);
      await t.tap(find.descendant(of: find.byKey(const Key('big3-lift')), matching: find.text('스쿼트')));
      await settle(t);
      expect(find.byKey(const Key('big3-chart')), findsOneWidget);
      // 3개월 기간이면 10/1 추정 점은 남고(11/28 기준 8/28~), 측정은 그대로.
      await t.tap(find.byKey(const Key('big3-period-m3')));
      await settle(t);
      expect(find.byKey(const Key('big3-chart')), findsOneWidget);
    });

    testWidgets('+ 버튼은 그 종목이 골라진 시트를 열고, 저장하면 줄·그래프가 갱신', (t) async {
      await setup(t, initial: '/me/big3', seed: mixed);
      await t.tap(find.byKey(const Key('big3-add-bench')));
      await settle(t);
      final chip = t.widget<ChoiceChip>(find.byKey(Key('onerm-lift-${big3Lifts[1].id}')));
      expect(chip.selected, isTrue);
      await t.enterText(find.byKey(const Key('onerm-weight')), '110');
      await t.tap(find.byKey(const Key('onerm-save')));
      await settle(t);
      expect(find.text('110'), findsOneWidget);
      expect(find.text('합계 432.5 kg'), findsOneWidget);
      // 벤치로 바꾸면 측정 점이 생겨 그래프가 보인다.
      await t.tap(find.descendant(of: find.byKey(const Key('big3-lift')), matching: find.text('벤치')));
      await settle(t);
      expect(find.byKey(const Key('big3-chart')), findsOneWidget);
      expect(find.textContaining('110 kg · 측정'), findsOneWidget);
    });

    testWidgets('줄을 탭하면 종목 기록 화면', (t) async {
      await setup(t, initial: '/me/big3', seed: mixed);
      await t.tap(find.byKey(const Key('big3-row-dead')));
      await settle(t);
      expect(find.byKey(const Key('records-add-onerm')), findsOneWidget);
    });

    testWidgets('불러오기 오류면 안내와 다시 시도', (t) async {
      await setup(t, initial: '/me/big3', seed: (e) => e.recs.failure = const ApiException(code: 'NETWORK', message: 'x'));
      expect(find.byKey(const Key('big3-offline')), findsWidgets);
      expect(find.byKey(const Key('big3-retry')), findsWidgets);
    });
  });

  testWidgets('기존 종목 기록 화면의 측정 추가 시트는 종목 칩 없이 동작', (t) async {
    await setup(t, initial: '/exercises/${big3Lifts[0].id}/records');
    await t.tap(find.byKey(const Key('records-add-onerm')));
    await settle(t);
    expect(find.byKey(Key('onerm-lift-${big3Lifts[0].id}')), findsNothing);
    expect(find.text('측정 추가'), findsWidgets);
    await t.enterText(find.byKey(const Key('onerm-weight')), '120');
    await t.tap(find.byKey(const Key('onerm-save')));
    await settle(t);
    expect(find.byKey(const Key('onerm-save')), findsNothing);
    expect(find.text('120 kg'), findsWidgets);
  });
}
