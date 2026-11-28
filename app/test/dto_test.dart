import 'package:fitlog/core/api/dto.dart';
import 'package:fitlog/core/api/program_dto.dart';
import 'package:fitlog/core/units.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Session JSON round trip keeps nested sets and UTC', () {
    final j = {
      'id': '0193f2a0-0000-7000-8000-000000000001',
      'startedAt': '2026-11-26T10:00:00Z',
      'tz': 'Asia/Seoul',
      'source': 'APP',
      'exercises': [
        {
          'id': '0193f2a0-0000-7000-8000-000000000002',
          'exerciseId': '0193f2a0-0000-7000-8000-000000000003',
          'position': 0,
          'sets': [
            {'id': '0193f2a0-0000-7000-8000-000000000004', 'position': 0, 'weightKg': 100, 'reps': 5, 'rpe': 8.5},
          ],
        },
      ],
    };
    final s = Session.fromJson(j);
    expect(s.startedAt.isUtc, isTrue);
    expect(s.exercises.single.sets.single.weightKg, 100.0);
    final out = s.toJson();
    expect(out.containsKey('source'), isFalse, reason: 'readOnly');
    expect(out.containsKey('endedAt'), isFalse, reason: 'null 키는 뺀다');
    expect(((out['exercises'] as List).single as Map)['sets'], hasLength(1));
  });

  test('Change DELETE omits payload', () {
    final c = Change(
      entity: SyncEntity.workout_set,
      id: 'x',
      op: ChangeOp.DELETE,
      payload: const {'a': 1},
      clientUpdatedAt: DateTime.utc(2026, 11, 26),
    );
    expect(c.toJson().containsKey('payload'), isFalse);
    expect(c.toJson()['clientUpdatedAt'], '2026-11-26T00:00:00.000Z');
  });

  test('Units', () {
    expect(Units.format(62.5, WeightUnit.KG), '62.5 kg');
    expect(Units.format(100, WeightUnit.LB), '220.5 lb');
    expect(Units.fromDisplay(225, WeightUnit.LB), 102.06);
  });

  test('v0.2 Settings는 비울 필드를 null로 명시한다(merge-patch)', () {
    final j = const Settings(heightCm: null, e1rmFormula: E1rmFormula.BRZYCKI).toJson();
    expect(j.containsKey('heightCm'), isTrue);
    expect(j['heightCm'], isNull);
    expect(j['e1rmFormula'], 'BRZYCKI');
    expect(Settings.fromJson(j).e1rmFormula, E1rmFormula.BRZYCKI);
  });

  test('v0.2 Instance·PlannedWorkout 파싱', () {
    final i = Instance.fromJson({
      'id': 'i',
      'programId': 'p',
      'name': '5x5',
      'status': 'ACTIVE',
      'skipPolicy': 'SHIFT',
      'startDate': '2026-11-26',
      'state': {
        'tm': {},
        'working': {'squat': 100},
        'week': 1,
        'cycle': 1,
        'seq': 3,
      },
      'next': {
        'instanceId': 'i',
        'planSeq': 4,
        'dayIndex': 1,
        'dayKey': 'B',
        'dayName': 'B',
        'week': 1,
        'cycle': 1,
        'confirmed': true,
        'exercises': [
          {
            'key': 'squat',
            'exerciseId': 'e',
            'accessory': false,
            'sets': [
              {'plannedSetKey': 'B.0.0', 'targetReps': 5, 'targetWeightKg': 102.5, 'isAmrap': false, 'isWarmup': false},
            ],
          },
        ],
      },
    });
    expect(i.state.working['squat'], 100.0);
    expect(i.next!.planSeq, i.state.seq! + 1);
    expect(i.next!.exercises.single.sets.single.targetWeightKg, 102.5);
    expect(formatDate(i.startDate), '2026-11-26');
    expect(PlannedWorkout.fromJson(i.next!.toJson()).dayKey, 'B');
  });

  group('Program display fields', () {
    Map<String, Object?> base() => {'id': 'p1', 'name': 'N', 'builtIn': true, 'dayCount': 4};

    test('parses level, family, variantLabel, aka, rules', () {
      final p = ProgramSummary.fromJson({
        ...base(),
        'level': 'INTERMEDIATE',
        'family': 'nsuns-amrap-wave',
        'variantLabel': '주 4일',
        'aka': ['nSuns 5/3/1 LP'],
        'rules': {'progress': '올려요.', 'failure': '다시 해요.', 'deload': '낮춰요.'},
      });
      expect(p.level, 'INTERMEDIATE');
      expect(p.family, 'nsuns-amrap-wave');
      expect(p.variantLabel, '주 4일');
      expect(p.aka, ['nSuns 5/3/1 LP']);
      expect(p.rules!.progress, '올려요.');
      expect(p.rules!.deload, '낮춰요.');
    });

    test('missing fields give null and empty aka (old server)', () {
      final p = ProgramSummary.fromJson(base());
      expect(p.level, isNull);
      expect(p.family, isNull);
      expect(p.variantLabel, isNull);
      expect(p.aka, isEmpty);
      expect(p.rules, isNull);
    });

    test('unknown level string is kept, malformed values do not throw', () {
      final p = ProgramSummary.fromJson({
        ...base(),
        'level': 'EXPERT',
        'family': 3,
        'variantLabel': ['x'],
        'aka': ['ok', 7, null, 'b'],
        'rules': {'progress': 'a', 'failure': 5, 'deload': 'c'},
      });
      expect(p.level, 'EXPERT');
      expect(p.family, isNull);
      expect(p.variantLabel, isNull);
      expect(p.aka, ['ok', 'b']);
      expect(p.rules, isNull);
      expect(ProgramSummary.fromJson({...base(), 'aka': 'x', 'rules': 'y'}).aka, isEmpty);
      expect(ProgramSummary.fromJson({...base(), 'rules': 'y'}).rules, isNull);
    });

    test('Program.fromJson carries the fields over', () {
      final p = Program.fromJson({
        ...base(),
        'level': 'BEGINNER',
        'family': 'wendler-531',
        'variantLabel': 'BBB',
        'aka': ['a'],
        'rules': {'progress': 'a', 'failure': 'b', 'deload': 'c'},
        'definition': <String, Object?>{},
      });
      expect(p.level, 'BEGINNER');
      expect(p.family, 'wendler-531');
      expect(p.variantLabel, 'BBB');
      expect(p.aka, ['a']);
      expect(p.rules!.failure, 'b');
    });
  });

  test('SuggestItem: 모르는 oneRmSource 는 null 로 받는다', () {
    final item = SuggestItem.fromJson({
      'key': 'squat',
      'exerciseId': 'e1',
      'needs': SuggestNeeds.values.first.name,
      'oneRmSource': 'INFERRED_FROM_BIG3',
    });
    expect(item.oneRmSource, isNull);
    expect(item.key, 'squat');
  });
}
