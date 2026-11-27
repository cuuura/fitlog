// drift 스키마 v3 -> v4: scheduled_workouts 테이블, sessions.scheduled_workout_id, workout_sets 목표 3열.
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fitlog/data/local/app_database.dart';
import 'package:flutter_test/flutter_test.dart';

/// v3 시점의 sessions·workout_sets 정의(필요한 열만 정확히, 시각은 텍스트).
const _v3 = [
  '''CREATE TABLE sessions (
    id TEXT NOT NULL PRIMARY KEY, started_at TEXT NOT NULL, ended_at TEXT, tz TEXT NOT NULL, note TEXT, source TEXT,
    updated_at TEXT NOT NULL, deleted_at TEXT, program_instance_id TEXT, plan_seq INTEGER, plan_day_key TEXT,
    import_batch_id TEXT)''',
  '''CREATE TABLE workout_sets (
    id TEXT NOT NULL PRIMARY KEY, session_exercise_id TEXT NOT NULL, position INTEGER NOT NULL,
    is_warmup INTEGER NOT NULL DEFAULT 0 CHECK (is_warmup IN (0, 1)), weight_kg REAL, added_weight_kg REAL,
    reps INTEGER, duration_sec INTEGER, distance_m REAL, band_level TEXT, rpe REAL, rir INTEGER, rest_sec INTEGER,
    note TEXT, completed_at TEXT, updated_at TEXT NOT NULL, deleted_at TEXT, planned_set_key TEXT,
    target_reps INTEGER, target_weight_kg REAL, is_amrap INTEGER NOT NULL DEFAULT 0 CHECK (is_amrap IN (0, 1)))''',
  "INSERT INTO sessions (id, started_at, tz, updated_at, program_instance_id, plan_seq) "
      "VALUES ('s1', '2026-11-20T01:00:00.000Z', 'Asia/Seoul', '2026-11-20T01:00:00.000Z', 'inst-1', 3)",
  "INSERT INTO workout_sets (id, session_exercise_id, position, weight_kg, reps, updated_at, target_reps, target_weight_kg) "
      "VALUES ('w1', 'se1', 0, 100, 5, '2026-11-20T01:00:00.000Z', 5, 100)",
  'PRAGMA user_version = 3',
];

void main() {
  test('v3 데이터가 그대로 남고 새 열·테이블이 생긴다', () async {
    final db = AppDatabase(
      NativeDatabase.memory(
        setup: (raw) {
          for (final sql in _v3) {
            raw.execute(sql);
          }
        },
      ),
    );
    addTearDown(db.close);

    // 기존 행: 값 유지, 새 열은 null.
    final s = await db.select(db.sessions).getSingle();
    expect(s.id, 's1');
    expect(s.programInstanceId, 'inst-1');
    expect(s.planSeq, 3);
    expect(s.scheduledWorkoutId, isNull);
    final w = await db.select(db.workoutSets).getSingle();
    expect(w.weightKg, 100);
    expect(w.targetReps, 5);
    expect(w.targetRepsMax, isNull);
    expect(w.targetRir, isNull);
    expect(w.targetRestSec, isNull);

    // 새 열에 쓸 수 있다.
    await (db.update(db.sessions)..where((t) => t.id.equals('s1'))).write(
      const SessionsCompanion(scheduledWorkoutId: Value('sw1')),
    );
    await (db.update(db.workoutSets)..where((t) => t.id.equals('w1'))).write(
      const WorkoutSetsCompanion(targetRepsMax: Value(8), targetRir: Value(2), targetRestSec: Value(90)),
    );
    expect((await db.select(db.sessions).getSingle()).scheduledWorkoutId, 'sw1');
    final w2 = await db.select(db.workoutSets).getSingle();
    expect((w2.targetRepsMax, w2.targetRir, w2.targetRestSec), (8, 2, 90));

    // scheduled_workouts 테이블.
    expect(await db.select(db.scheduledWorkouts).get(), isEmpty);
    await db
        .into(db.scheduledWorkouts)
        .insert(
          ScheduledWorkoutsCompanion.insert(
            id: 'sw1',
            plannedDate: '2026-11-28',
            title: 'B-2 하체 2',
            updatedAt: DateTime.utc(2026, 11, 27),
          ),
        );
    final row = await db.select(db.scheduledWorkouts).getSingle();
    expect(row.itemsJson, '[]');
    expect(row.skippedAt, isNull);
    expect(row.deletedAt, isNull);
  });

  test('새 설치(onCreate)도 v4', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    expect(db.schemaVersion, 4);
    expect(await db.select(db.scheduledWorkouts).get(), isEmpty);
    expect(await db.getLastServerSeq(), 0);
  });
}
