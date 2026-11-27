import 'package:drift/drift.dart' show OrderingTerm;
import 'package:drift/native.dart';
import 'package:dio/dio.dart';
import 'package:fitlog/core/api/api_client.dart';
import 'package:fitlog/core/api/dto.dart';
import 'package:fitlog/core/api/program_dto.dart';
import 'package:fitlog/core/ids.dart';
import 'package:fitlog/data/local/app_database.dart';
import 'package:fitlog/data/local/drift_repositories.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_server.dart';

void main() {
  late AppDatabase db;
  late SpySync sync;
  late DriftSessionRepository sessions;
  late DriftExerciseRepository exercises;
  late DriftBodyRepository body;
  late FakeServer server;
  var now = t(0);

  setUp(() {
    now = t(0);
    db = AppDatabase(NativeDatabase.memory());
    sync = SpySync();
    server = FakeServer();
    final api = ApiClient(Dio(BaseOptions(baseUrl: 'http://test'))..httpClientAdapter = server);
    sessions = DriftSessionRepository(db, sync, clock: () => now);
    exercises = DriftExerciseRepository(db, sync, api, clock: () => now);
    body = DriftBodyRepository(db, sync, clock: () => now);
  });
  tearDown(() => db.close());

  ExerciseInput input(String id, {String name = '스쿼트'}) =>
      ExerciseInput(id: id, nameKo: name, nameEn: 'Squat', type: ExerciseType.BARBELL, primaryMuscle: Muscle.QUADS);

  Future<List<OutboxRow>> outbox() => (db.select(db.outbox)..orderBy([(t) => OrderingTerm.asc(t.id)])).get();

  test('세션 시작 -> 종목 -> 세트 -> watch 조립', () async {
    final ex = await exercises.createCustom(input(newId()));
    final s = await sessions.startSession(tz: 'Asia/Seoul');
    final se = await sessions.addExercise(s.id, ex.id);
    final w1 = await sessions.addSet(se.id, WorkoutSet(id: newId(), position: 99, weightKg: 100, reps: 5));
    final w2 = await sessions.addSet(se.id, WorkoutSet(id: newId(), position: 99, weightKg: 100, reps: 5));
    expect([w1.position, w2.position], [0, 1]);

    final got = await sessions.watchSession(s.id).first;
    expect(got!.exercises.single.exerciseId, ex.id);
    expect(got.exercises.single.sets.map((e) => e.id), [w1.id, w2.id]);
    expect((await sessions.watchActiveSession().first)!.id, s.id);
  });

  test('startSession은 진행 중 세션을 돌려준다', () async {
    final a = await sessions.startSession(tz: 'Asia/Seoul');
    final b = await sessions.startSession(tz: 'Asia/Seoul');
    expect(b.id, a.id);
    await sessions.endSession(a.id);
    expect(await sessions.watchActiveSession().first, isNull);
    final c = await sessions.startSession(tz: 'Asia/Seoul');
    expect(c.id, isNot(a.id));
  });

  test('watch는 쓰기에 반응한다', () async {
    final s = await sessions.startSession(tz: 'Asia/Seoul');
    final emitted = <int>[];
    final sub = sessions.watchSession(s.id).listen((x) => emitted.add(x!.exercises.length));
    await pumpEventQueue();
    await sessions.addExercise(s.id, 'ex1');
    await pumpEventQueue();
    await sub.cancel();
    expect(emitted.first, 0);
    expect(emitted.last, 1);
  });

  test('summarize: 워밍업 제외, 완료 여부 무관', () async {
    final s = await sessions.startSession(tz: 'Asia/Seoul');
    final se = await sessions.addExercise(s.id, 'ex1');
    await sessions.addSet(se.id, WorkoutSet(id: newId(), position: 0, isWarmup: true, weightKg: 20, reps: 10));
    await sessions.addSet(se.id, WorkoutSet(id: newId(), position: 0, weightKg: 100, reps: 5));
    await sessions.addSet(se.id, WorkoutSet(id: newId(), position: 0, weightKg: 80.5, reps: 3, completedAt: t(5)));
    final list = await sessions.watchRecentSessions().first;
    expect(list.single.exerciseCount, 1);
    expect(list.single.setCount, 2);
    expect(list.single.totalVolumeKg, 100 * 5 + 80.5 * 3);
  });

  test('쓰기는 행과 outbox를 같이 저장하고, 같은 엔티티는 합친다', () async {
    final s = await sessions.startSession(tz: 'Asia/Seoul');
    var rows = await outbox();
    expect(rows.single.entity, 'workout_session');
    expect(rows.single.op, 'UPSERT');
    final firstId = rows.single.id;

    now = t(10);
    await sessions.updateSessionNote(s.id, '메모');
    rows = await outbox();
    expect(rows.single.id, firstId, reason: '같은 엔티티는 한 줄');
    expect(rows.single.clientUpdatedAt, t(10));
    expect(rows.single.payload, contains('메모'));
    expect(rows.single.payload, isNot(contains('exercises')));
    expect(sync.scheduled, greaterThan(0));
  });

  test('같은 ms의 연속 쓰기도 updatedAt이 증가한다', () async {
    final s = await sessions.startSession(tz: 'Asia/Seoul');
    await sessions.updateSessionNote(s.id, 'a');
    final r1 = (await outbox()).single.clientUpdatedAt;
    await sessions.updateSessionNote(s.id, 'b');
    final r2 = (await outbox()).single.clientUpdatedAt;
    expect(r2.isAfter(r1), isTrue);
  });

  test('트랜잭션: 실패하면 행도 outbox도 남지 않는다', () async {
    final s = await sessions.startSession(tz: 'Asia/Seoul');
    final before = (await outbox()).length;
    // 존재하지 않는 종목 노트 수정 -> getSingle 예외
    await expectLater(sessions.updateExerciseNote('nope', 'x'), throwsA(anything));
    expect((await outbox()).length, before);
    expect((await sessions.watchSession(s.id).first)!.exercises, isEmpty);
  });

  test('endSession은 즉시 syncNow, 세트 쓰기는 schedule', () async {
    final s = await sessions.startSession(tz: 'Asia/Seoul');
    final se = await sessions.addExercise(s.id, 'ex1');
    final set = await sessions.addSet(se.id, WorkoutSet(id: newId(), position: 0, weightKg: 50, reps: 5));
    sync.scheduled = 0;
    await sessions.updateSet(set.copyWith(completedAt: () => t(30)));
    expect(sync.scheduled, 1);
    await sessions.endSession(s.id);
    expect(sync.syncNows, 1);
  });

  test('deleteSession은 자식까지 소프트 삭제하고 DELETE를 쌓는다', () async {
    final s = await sessions.startSession(tz: 'Asia/Seoul');
    final se = await sessions.addExercise(s.id, 'ex1');
    final set = await sessions.addSet(se.id, WorkoutSet(id: newId(), position: 0, weightKg: 50, reps: 5));
    await sessions.deleteSession(s.id);

    expect(await sessions.watchSession(s.id).first, isNull);
    expect(await sessions.watchRecentSessions().first, isEmpty);
    final byId = {for (final o in await outbox()) o.entityId: o};
    expect(byId[s.id]!.op, 'DELETE');
    expect(byId[se.id]!.op, 'DELETE');
    expect(byId[set.id]!.op, 'DELETE');
    expect(byId[set.id]!.payload, isNull);
    expect(byId[set.id]!.parentId, se.id);
    // 행은 남아 있고 deletedAt이 채워진다
    final row = await (db.select(db.workoutSets)..where((t) => t.id.equals(set.id))).getSingle();
    expect(row.deletedAt, isNotNull);
  });

  test('removeExercise / deleteSet', () async {
    final s = await sessions.startSession(tz: 'Asia/Seoul');
    final se = await sessions.addExercise(s.id, 'ex1');
    final se2 = await sessions.addExercise(s.id, 'ex2');
    expect(se2.position, 1);
    final set = await sessions.addSet(se.id, WorkoutSet(id: newId(), position: 0, weightKg: 50, reps: 5));
    await sessions.deleteSet(set.id);
    expect((await sessions.watchSession(s.id).first)!.exercises.first.sets, isEmpty);
    await sessions.removeExercise(se.id);
    expect((await sessions.watchSession(s.id).first)!.exercises.map((e) => e.id), [se2.id]);
  });

  test('lastSetsFor: 끝난 세션만, 가장 최근, 제외 세션 반영', () async {
    final a = await sessions.startSession(tz: 'Asia/Seoul');
    final sea = await sessions.addExercise(a.id, 'ex1');
    await sessions.addSet(sea.id, WorkoutSet(id: newId(), position: 0, weightKg: 60, reps: 5));
    expect(await sessions.lastSetsFor('ex1'), isNull, reason: '진행 중 세션은 제외');
    await sessions.endSession(a.id);

    now = t(1000);
    final b = await sessions.startSession(tz: 'Asia/Seoul');
    final seb = await sessions.addExercise(b.id, 'ex1');
    await sessions.addSet(seb.id, WorkoutSet(id: newId(), position: 0, weightKg: 70, reps: 5));
    await sessions.endSession(b.id);

    expect((await sessions.lastSetsFor('ex1'))!.sessionId, b.id);
    expect((await sessions.lastSetsFor('ex1', excludeSessionId: b.id))!.sessionId, a.id);
    expect(await sessions.lastSetsFor('other'), isNull);
  });

  test('종목: 내 종목 outbox, 기본 종목은 outbox 없음, search', () async {
    final id = newId();
    await exercises.createCustom(input(id, name: '내 스쿼트'));
    expect((await outbox()).single.entity, 'exercise');
    // 기본 종목(서버 캐시)을 직접 심는다
    server.exercises = [
      {
        'id': 'b1',
        'nameKo': '벤치프레스',
        'nameEn': 'Bench Press',
        'type': 'BARBELL',
        'primaryMuscle': 'CHEST',
        'secondaryMuscles': ['TRICEPS'],
        'builtIn': true,
        'updatedAt': '2026-01-01T00:00:00Z',
      },
    ];
    await exercises.refreshFromServer();
    expect((await outbox()).length, 1, reason: '기본 종목은 outbox에 넣지 않는다');
    expect((await exercises.search(query: 'bench')).single.id, 'b1');
    expect((await exercises.search(muscle: Muscle.TRICEPS)).single.id, 'b1');
    expect((await exercises.search(type: ExerciseType.DUMBBELL)), isEmpty);
    expect((await exercises.watchAll().first).length, 2);

    await expectLater(exercises.deleteCustom('b1'), throwsStateError);
    await exercises.updateCustom(input(id, name: '내 스쿼트2'));
    expect((await exercises.byId(id))!.nameKo, '내 스쿼트2');
    await exercises.deleteCustom(id);
    expect((await exercises.watchAll().first).map((e) => e.id), ['b1']);
    expect((await exercises.byId(id)), isNotNull, reason: '삭제된 내 종목도 byId로는 보인다');
    expect((await outbox()).single.op, 'DELETE');
  });

  test('refreshFromServer: 오프라인이면 조용히 무시', () async {
    server.failNetwork = 1;
    await exercises.refreshFromServer();
    expect(await exercises.watchAll().first, isEmpty);
  });

  test('체중 add/delete', () async {
    final m = BodyMeasurement(id: newId(), measuredAt: t(0), weightKg: 70.5);
    await body.add(m);
    await body.add(BodyMeasurement(id: newId(), measuredAt: t(100), weightKg: 71));
    var list = await body.watchMeasurements().first;
    expect(list.map((e) => e.weightKg), [71, 70.5], reason: 'measuredAt 내림차순');
    await body.delete(m.id);
    list = await body.watchMeasurements().first;
    expect(list.length, 1);
    final o = (await outbox()).firstWhere((o) => o.entityId == m.id);
    expect(o.op, 'DELETE');
  });

  test('clearAll: 전부 비우고 lastServerSeq 0', () async {
    await sessions.startSession(tz: 'Asia/Seoul');
    await db.setLastServerSeq(42);
    await DriftLocalDataStore(db).clearAll();
    expect(await sessions.watchActiveSession().first, isNull);
    expect(await db.outboxCount(), 0);
    expect(await db.getLastServerSeq(), 0);
    expect(await db.select(db.sessions).get(), isEmpty);
  });

  test('스키마 버전 4', () => expect(db.schemaVersion, 4));

  // ---- v0.2 골격 ----

  PlannedWorkout plan() => const PlannedWorkout(
    instanceId: 'inst-1',
    planSeq: 4,
    dayIndex: 0,
    dayKey: 'A',
    dayName: 'Workout A',
    week: 1,
    cycle: 1,
    confirmed: true,
    exercises: [
      PlannedExercise(
        key: 'squat',
        exerciseId: 'ex-sq',
        accessory: false,
        sets: [
          PlannedSet(plannedSetKey: 'A.0.0', targetReps: 5, targetWeightKg: 100, isAmrap: false, isWarmup: false),
          PlannedSet(plannedSetKey: 'A.0.1', targetReps: 5, targetWeightKg: 100, isAmrap: true, isWarmup: false),
        ],
      ),
      PlannedExercise(
        key: 'acc:1',
        exerciseId: 'ex-curl',
        accessory: true,
        sets: [PlannedSet(plannedSetKey: 'A.1.0', targetReps: 10, isAmrap: false, isWarmup: false)],
      ),
    ],
  );

  test('v0.2 계획으로 세션 시작: 종목·세트 미리 채움, payload에 계획 필드', () async {
    final s = await sessions.startSession(tz: 'Asia/Seoul', plan: plan());
    expect(s.programInstanceId, 'inst-1');
    expect(s.planSeq, 4);
    expect(s.planDayKey, 'A');
    expect(s.exercises.map((e) => e.liftKey), ['squat', 'acc:1']);
    expect(s.exercises[1].accessory, isTrue);
    final sq = s.exercises[0].sets;
    expect(sq.map((w) => w.plannedSetKey), ['A.0.0', 'A.0.1']);
    expect(sq[0].weightKg, 100);
    expect(sq[0].reps, 5);
    expect(sq[0].isCompleted, isFalse);
    expect(sq[1].isAmrap, isTrue);
    expect(s.exercises[1].sets.single.weightKg, isNull);

    final ob = await outbox();
    expect(ob.map((o) => o.entity), [
      'workout_session',
      'session_exercise',
      'workout_set',
      'workout_set',
      'session_exercise',
      'workout_set',
    ]);
    expect(ob.first.payload, contains('"planSeq":4'));
    expect(ob[1].payload, contains('"liftKey":"squat"'));
    expect(ob[2].payload, contains('"plannedSetKey":"A.0.0"'));
    expect(ob[2].payload, contains('"targetWeightKg":100'));

    expect(await sessions.planSeqsUsed('inst-1'), {4});
    expect(await sessions.lastSessionForDay('inst-1', 'A'), isNull, reason: '진행 중은 제외');
    await sessions.endSession(s.id);
    expect((await sessions.lastSessionForDay('inst-1', 'A'))?.id, s.id);
  });

  test('v0.2 순서 변경과 시각 수정', () async {
    final s = await sessions.startSession(tz: 'Asia/Seoul', plan: plan());
    final sq = s.exercises[0];
    await sessions.reorderSets(sq.id, [sq.sets[1].id, sq.sets[0].id]);
    await sessions.reorderExercises(s.id, [s.exercises[1].id, sq.id]);
    final after = (await sessions.watchSession(s.id).first)!;
    expect(after.exercises.first.liftKey, 'acc:1');
    expect(after.exercises.last.sets.first.plannedSetKey, 'A.0.1');
    final start = DateTime.utc(2026, 11, 1, 9);
    await sessions.updateSessionTimes(s.id, startedAt: start, endedAt: start.add(const Duration(hours: 1)));
    final edited = (await sessions.watchSession(s.id).first)!;
    expect(edited.startedAt, start);
    expect(edited.endedAt, start.add(const Duration(hours: 1)));
  });
}
