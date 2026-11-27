import 'package:fitlog/core/api/program_dto.dart';
import 'package:fitlog/data/memory/memory_repositories.dart';
import 'package:fitlog/features/session/current_set.dart';
import 'package:flutter_test/flutter_test.dart';

PlannedWorkout _plan() => const PlannedWorkout(
  instanceId: 'i1',
  planSeq: 1,
  dayIndex: 0,
  dayKey: 'A',
  dayName: 'A',
  week: 1,
  cycle: 1,
  confirmed: true,
  exercises: [
    PlannedExercise(
      key: 'curl',
      exerciseId: 'ex-curl',
      accessory: false,
      sets: [
        PlannedSet(
          plannedSetKey: 'A.0.0',
          targetReps: 8,
          targetRepsMax: 12,
          targetWeightKg: 40,
          isAmrap: false,
          isWarmup: false,
          restSec: 90,
        ),
        PlannedSet(plannedSetKey: 'A.0.1', targetReps: 5, isAmrap: false, isWarmup: false),
      ],
    ),
  ],
);

void main() {
  test('PlannedSet 왕복: 새 필드 보존, 없으면 JSON에서 생략', () {
    final w = PlannedWorkout.fromJson(_plan().toJson());
    final a = w.exercises.single.sets[0];
    expect(a.targetRepsMax, 12);
    expect(a.restSec, 90);
    final b = w.exercises.single.sets[1];
    expect(b.targetRepsMax, isNull);
    expect(b.restSec, isNull);
    final j = b.toJson();
    expect(j.containsKey('targetRepsMax'), isFalse);
    expect(j.containsKey('restSec'), isFalse);
  });

  test('SuggestItem.optional 기본 false, 파싱', () {
    final base = {'key': 'k', 'exerciseId': 'e', 'needs': 'WORKING'};
    expect(SuggestItem.fromJson(base).optional, isFalse);
    expect(SuggestItem.fromJson({...base, 'optional': true}).optional, isTrue);
  });

  test('시작 시 범위·휴식이 세트로 복사된다', () async {
    final s = await MemorySessionRepository().startSession(tz: 'Asia/Seoul', plan: _plan());
    final sets = s.exercises.single.sets;
    expect(sets[0].targetRepsMax, 12);
    expect(sets[0].targetRestSec, 90);
    expect(sets[1].targetRepsMax, isNull);
    expect(sets[1].targetRestSec, isNull);
    expect(repsRangeText(8, 12), '8~12');
  });
}
