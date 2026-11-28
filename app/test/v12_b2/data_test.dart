// v1.2 B2: drift v4 -> v5 마이그레이션, 동기화 DTO·payload 왕복.
import 'package:drift/native.dart';
import 'package:fitlog/core/api/dto.dart';
import 'package:fitlog/core/ids.dart';
import 'package:fitlog/data/local/app_database.dart';
import 'package:fitlog/data/local/drift_repositories.dart';
import 'package:fitlog/data/local/local_mappers.dart';
import 'package:flutter_test/flutter_test.dart';

import '../b3/fake_server.dart';

const _v4 = [
  '''CREATE TABLE session_exercises (
    id TEXT NOT NULL PRIMARY KEY, session_id TEXT NOT NULL, exercise_id TEXT NOT NULL, position INTEGER NOT NULL,
    note TEXT, updated_at TEXT NOT NULL, deleted_at TEXT, lift_key TEXT,
    accessory INTEGER NOT NULL DEFAULT 0 CHECK (accessory IN (0, 1)))''',
  '''CREATE TABLE workout_sets (
    id TEXT NOT NULL PRIMARY KEY, session_exercise_id TEXT NOT NULL, position INTEGER NOT NULL,
    is_warmup INTEGER NOT NULL DEFAULT 0 CHECK (is_warmup IN (0, 1)), weight_kg REAL, added_weight_kg REAL,
    reps INTEGER, duration_sec INTEGER, distance_m REAL, band_level TEXT, rpe REAL, rir INTEGER, rest_sec INTEGER,
    note TEXT, completed_at TEXT, updated_at TEXT NOT NULL, deleted_at TEXT, planned_set_key TEXT,
    target_reps INTEGER, target_weight_kg REAL, is_amrap INTEGER NOT NULL DEFAULT 0 CHECK (is_amrap IN (0, 1)),
    target_reps_max INTEGER, target_rir INTEGER, target_rest_sec INTEGER)''',
  "INSERT INTO session_exercises (id, session_id, exercise_id, position, updated_at, lift_key) "
      "VALUES ('se1', 's1', 'ex1', 0, '2026-11-20T01:00:00.000Z', 'squat')",
  "INSERT INTO workout_sets (id, session_exercise_id, position, weight_kg, reps, updated_at) "
      "VALUES ('w1', 'se1', 0, 100, 5, '2026-11-20T01:00:00.000Z')",
  'PRAGMA user_version = 4',
];

void main() {
  test('v4 -> v5: 기존 데이터 유지, 새 열 기본값', () async {
    final db = AppDatabase(
      NativeDatabase.memory(
        setup: (raw) {
          for (final sql in _v4) {
            raw.execute(sql);
          }
        },
      ),
    );
    addTearDown(db.close);
    final se = await db.select(db.sessionExercises).getSingle();
    expect(se.liftKey, 'squat');
    expect(se.supersetGroup, isNull);
    final w = await db.select(db.workoutSets).getSingle();
    expect((w.weightKg, w.reps), (100, 5));
    expect(w.setType, 'NORMAL');
  });

  test('DTO 왕복: supersetGroup·setType', () {
    final set = WorkoutSet(id: 'w', position: 0, setType: SetType.DROP);
    expect(set.toJson()['setType'], 'DROP');
    expect(WorkoutSet.fromJson(set.toJson()).setType, SetType.DROP);
    expect(WorkoutSet.fromJson({'id': 'w', 'position': 0}).setType, SetType.NORMAL);
    final se = SessionExercise(id: 'e', exerciseId: 'x', position: 0, supersetGroup: 'A', sets: [set]);
    final back = SessionExercise.fromJson(se.toJson());
    expect(back.supersetGroup, 'A');
    expect(back.sets.single.setType, SetType.DROP);
    expect(SessionExercise.fromJson({'id': 'e', 'exerciseId': 'x', 'position': 0}).supersetGroup, isNull);
  });

  test('동기화: push payload에 새 필드가 실리고 서버 변경을 받아 로컬에 반영', () async {
    final env = makeEnv();
    addTearDown(env.close);
    final repo = DriftSessionRepository(env.db, env.engine, clock: () => env.now);
    final s = await repo.startSession(tz: 'Asia/Seoul');
    final se = await repo.addExercise(s.id, 'ex1');
    final w = await repo.addSet(se.id, WorkoutSet(id: newId(), position: 0, weightKg: 50, reps: 8));
    await repo.setExerciseSuperset(se.id, 'B');
    await repo.updateSet(w.copyWith(setType: SetType.FAILURE));
    await env.engine.syncNow();

    final sent = env.server.pushes.expand((p) => p).toList();
    final sePayload = sent.lastWhere((c) => c['entity'] == 'session_exercise')['payload'] as Map;
    final setPayload = sent.lastWhere((c) => c['entity'] == 'workout_set')['payload'] as Map;
    expect(sePayload['supersetGroup'], 'B');
    expect(setPayload['setType'], 'FAILURE');

    // 서버에서 받은 변경을 로컬에 덮어쓴다.
    await env.db.applyServerChange(
      Change(
        entity: SyncEntity.workout_set,
        id: w.id,
        op: ChangeOp.UPSERT,
        parentId: se.id,
        payload: {...setPayload.cast<String, Object?>(), 'setType': 'DROP'},
        clientUpdatedAt: DateTime.utc(2030),
      ),
    );
    final row = await (env.db.select(env.db.workoutSets)..where((t) => t.id.equals(w.id))).getSingle();
    expect(row.setType, 'DROP');
    await env.db.applyServerChange(
      Change(
        entity: SyncEntity.session_exercise,
        id: se.id,
        op: ChangeOp.UPSERT,
        parentId: s.id,
        payload: {...sePayload.cast<String, Object?>(), 'supersetGroup': null},
        clientUpdatedAt: DateTime.utc(2030),
      ),
    );
    final seRow = await (env.db.select(env.db.sessionExercises)..where((t) => t.id.equals(se.id))).getSingle();
    expect(seRow.supersetGroup, isNull);
    expect(sessionExerciseOf(seRow, const []).supersetGroup, isNull);
  });
}
