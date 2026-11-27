import 'package:fitlog/core/api/dto.dart';
import 'package:fitlog/core/api/program_dto.dart';
import 'package:fitlog/features/programs/program_common.dart';
import 'package:fitlog/l10n/gen/app_localizations_ko.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../b2/harness.dart';

PlannedWorkout _plan(DateTime? date) => PlannedWorkout(
  instanceId: 'i1',
  planSeq: 2,
  dayIndex: 0,
  dayKey: 'A',
  dayName: '데이 A',
  week: 3,
  cycle: 1,
  confirmed: true,
  scheduledDate: date,
  exercises: [
    PlannedExercise(
      key: 'squat',
      exerciseId: squat.id,
      accessory: false,
      sets: [
        for (var i = 0; i < 3; i++)
          PlannedSet(plannedSetKey: 'A.0.$i', targetReps: 5, targetWeightKg: 92.5, isAmrap: false, isWarmup: false),
      ],
    ),
  ],
);

Future<Harness> _home(WidgetTester t, DateTime? date) async {
  final h = Harness();
  h.programs.instances['i1'] = Instance(
    id: 'i1',
    programId: 'p1',
    name: 'GZCLP',
    status: InstanceStatus.ACTIVE,
    skipPolicy: SkipPolicy.SHIFT,
    startDate: DateTime(2026, 11, 1),
    state: const InstanceState(week: 3, cycle: 1, seq: 1),
  );
  h.programs.plans['i1'] = [_plan(date)];
  await h.planCache.refresh();
  await h.pump(t);
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
  return h;
}

void main() {
  testWidgets('홈: 오늘 예정 카드는 채움 시작 버튼과 큰 메인 무게', (t) async {
    await _home(t, DateTime(2026, 11, 26));
    expect(find.text('3주차 · 데이 A · 오늘 예정'), findsOneWidget);
    expect(find.byKey(const Key('home-date')), findsOneWidget);
    expect(find.text('11월 26일 목요일'), findsOneWidget);
    expect(find.byKey(const Key('plan-main-weight-i1')), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '운동 시작'), findsOneWidget);
    expect(find.byKey(const Key('plan-skip-i1')), findsNothing);
    expect(find.text('자유 운동 시작'), findsOneWidget);
  });

  testWidgets('홈: 밀린 카드는 하루 밀림 칩, 테두리 시작과 건너뛰기', (t) async {
    await _home(t, DateTime(2026, 11, 25));
    expect(find.text('하루 밀림'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, '시작'), findsOneWidget);
    expect(find.byKey(const Key('plan-skip-i1')), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '운동 시작'), findsNothing);
  });

  test('규칙 목록: AMRAP 표·실패·반올림, 디로드는 정의에 있을 때만', () {
    final l = AppLocalizationsKo();
    final def = <String, Object?>{
      'roundingKg': 2.5,
      'progression': {
        'bench': {
          'type': 'AMRAP_TABLE',
          'table': [
            {'minReps': 0, 'maxReps': 1, 'incrementKg': 0},
            {'minReps': 2, 'maxReps': 3, 'incrementKg': 2.5},
            {'minReps': 6, 'incrementKg': 5},
          ],
        },
      },
    };
    final rules = programRuleEntries(l, def, WeightUnit.KG);
    expect(rules.first.table, [('0–1회', '유지'), ('2–3회', '+2.5'), ('6+회', '+5')]);
    expect(rules.map((r) => r.title), isNot(contains('디로드')));
    def['progression'] = {
      'squat': {'type': 'LINEAR', 'incrementKg': 2.5, 'failuresBeforeDeload': 3, 'deloadPercent': 0.1},
    };
    final linear = programRuleEntries(l, def, WeightUnit.KG);
    expect(linear.map((r) => r.title), contains('디로드'));
    expect(linear.firstWhere((r) => r.title == '실패').body, '3회 연속 실패하면 디로드');
  });
}
