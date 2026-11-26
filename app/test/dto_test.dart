import 'package:fitlog/core/api/dto.dart';
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
            {'id': '0193f2a0-0000-7000-8000-000000000004', 'position': 0, 'weightKg': 100, 'reps': 5, 'rpe': 8.5}
          ]
        }
      ]
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
        clientUpdatedAt: DateTime.utc(2026, 11, 26));
    expect(c.toJson().containsKey('payload'), isFalse);
    expect(c.toJson()['clientUpdatedAt'], '2026-11-26T00:00:00.000Z');
  });

  test('Units', () {
    expect(Units.format(62.5, WeightUnit.KG), '62.5 kg');
    expect(Units.format(100, WeightUnit.LB), '220.5 lb');
    expect(Units.fromDisplay(225, WeightUnit.LB), 102.06);
  });
}
