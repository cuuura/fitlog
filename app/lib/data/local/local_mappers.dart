// B3 소유. drift 행 <-> DTO <-> sync payload 변환, 서버에서 받은 Change를 로컬에 덮어쓰기.
import 'dart:convert';

import 'package:drift/drift.dart';

import '../../core/api/dto.dart';
import 'app_database.dart';

// ---------- 행 -> DTO ----------

List<Muscle> parseMuscles(String s) => [
  for (final n in s.split(','))
    if (n.isNotEmpty) Muscle.values.firstWhere((m) => m.name == n),
];

Exercise exerciseOf(ExerciseRow r) => Exercise(
  id: r.id,
  nameKo: r.nameKo,
  nameEn: r.nameEn,
  type: ExerciseType.values.byName(r.type),
  primaryMuscle: Muscle.values.byName(r.primaryMuscle),
  secondaryMuscles: parseMuscles(r.secondaryMuscles),
  builtIn: r.builtIn,
  updatedAt: r.updatedAt.toUtc(),
  source: r.source == null ? null : SessionSource.values.byName(r.source!),
  importBatchId: r.importBatchId,
);

WorkoutSet setOf(WorkoutSetRow r) => WorkoutSet(
  id: r.id,
  position: r.position,
  isWarmup: r.isWarmup,
  weightKg: r.weightKg,
  addedWeightKg: r.addedWeightKg,
  reps: r.reps,
  durationSec: r.durationSec,
  distanceM: r.distanceM,
  bandLevel: r.bandLevel,
  rpe: r.rpe,
  rir: r.rir,
  restSec: r.restSec,
  note: r.note,
  completedAt: r.completedAt?.toUtc(),
  plannedSetKey: r.plannedSetKey,
  targetReps: r.targetReps,
  targetWeightKg: r.targetWeightKg,
  isAmrap: r.isAmrap,
  targetRepsMax: r.targetRepsMax,
  targetRir: r.targetRir,
  targetRestSec: r.targetRestSec,
);

SessionExercise sessionExerciseOf(SessionExerciseRow r, List<WorkoutSet> sets) => SessionExercise(
  id: r.id,
  exerciseId: r.exerciseId,
  position: r.position,
  note: r.note,
  sets: sets,
  liftKey: r.liftKey,
  accessory: r.accessory,
);

Session sessionOf(SessionRow r, List<SessionExercise> exercises) => Session(
  id: r.id,
  startedAt: r.startedAt.toUtc(),
  endedAt: r.endedAt?.toUtc(),
  tz: r.tz,
  note: r.note,
  source: r.source == null ? null : SessionSource.values.byName(r.source!),
  exercises: exercises,
  updatedAt: r.updatedAt.toUtc(),
  programInstanceId: r.programInstanceId,
  planSeq: r.planSeq,
  planDayKey: r.planDayKey,
  importBatchId: r.importBatchId,
  scheduledWorkoutId: r.scheduledWorkoutId,
);

List<ScheduledItem> parseScheduledItems(String json) {
  try {
    return [for (final i in (jsonDecode(json) as List)) ScheduledItem.fromJson((i as Map).cast())];
  } on Object {
    return const [];
  }
}

ScheduledWorkout scheduledOf(ScheduledWorkoutRow r) => ScheduledWorkout(
  id: r.id,
  plannedDate: r.plannedDate,
  title: r.title,
  note: r.note,
  items: parseScheduledItems(r.itemsJson),
  skippedAt: r.skippedAt?.toUtc(),
  source: r.source == null ? null : SessionSource.values.byName(r.source!),
  importBatchId: r.importBatchId,
  updatedAt: r.updatedAt.toUtc(),
  deletedAt: r.deletedAt?.toUtc(),
);

String scheduledItemsJson(List<ScheduledItem> items) => jsonEncode([for (final i in items) i.toJson()]);

BodyMeasurement measurementOf(BodyMeasurementRow r) => BodyMeasurement(
  id: r.id,
  measuredAt: r.measuredAt.toUtc(),
  weightKg: r.weightKg,
  source: MeasurementSource.values.byName(r.source),
  importBatchId: r.importBatchId,
);

// ---------- 행 -> sync payload (중첩 없음) ----------

Map<String, Object?> exercisePayload(ExerciseRow r) => ExerciseInput(
  id: r.id,
  nameKo: r.nameKo,
  nameEn: r.nameEn,
  type: ExerciseType.values.byName(r.type),
  primaryMuscle: Muscle.values.byName(r.primaryMuscle),
  secondaryMuscles: parseMuscles(r.secondaryMuscles),
).toJson();

Map<String, Object?> sessionPayload(SessionRow r) => sessionOf(r, const []).toJson()..remove('exercises');

Map<String, Object?> sessionExercisePayload(SessionExerciseRow r) =>
    sessionExerciseOf(r, const []).toJson()..remove('sets');

Map<String, Object?> setPayload(WorkoutSetRow r) => setOf(r).toJson();

Map<String, Object?> measurementPayload(BodyMeasurementRow r) => measurementOf(r).toJson();

/// items는 중첩 JSON 그대로 보낸다(문서 단위 동기화, scheduled-workout.md §2·§4).
Map<String, Object?> scheduledPayload(ScheduledWorkoutRow r) => scheduledOf(r).toJson();

// ---------- DTO -> companion ----------

String musclesToText(List<Muscle> m) => m.map((e) => e.name).join(',');

SessionsCompanion sessionCompanion(Session s, {required DateTime updatedAt}) => SessionsCompanion(
  id: Value(s.id),
  startedAt: Value(s.startedAt.toUtc()),
  endedAt: Value(s.endedAt?.toUtc()),
  tz: Value(s.tz),
  note: Value(s.note),
  source: Value(s.source?.name),
  updatedAt: Value(updatedAt.toUtc()),
  deletedAt: const Value(null),
  programInstanceId: Value(s.programInstanceId),
  planSeq: Value(s.planSeq),
  planDayKey: Value(s.planDayKey),
  importBatchId: Value(s.importBatchId),
  scheduledWorkoutId: Value(s.scheduledWorkoutId),
);

ScheduledWorkoutsCompanion scheduledCompanion(ScheduledWorkout w, {required DateTime updatedAt}) =>
    ScheduledWorkoutsCompanion(
      id: Value(w.id),
      plannedDate: Value(w.plannedDate),
      title: Value(w.title),
      note: Value(w.note),
      itemsJson: Value(scheduledItemsJson(w.items)),
      skippedAt: Value(w.skippedAt?.toUtc()),
      source: Value(w.source?.name),
      importBatchId: Value(w.importBatchId),
      updatedAt: Value(updatedAt.toUtc()),
      deletedAt: const Value(null),
    );

WorkoutSetsCompanion setCompanion(WorkoutSet w, {required String sessionExerciseId, required DateTime updatedAt}) =>
    WorkoutSetsCompanion(
      id: Value(w.id),
      sessionExerciseId: Value(sessionExerciseId),
      position: Value(w.position),
      isWarmup: Value(w.isWarmup),
      weightKg: Value(w.weightKg),
      addedWeightKg: Value(w.addedWeightKg),
      reps: Value(w.reps),
      durationSec: Value(w.durationSec),
      distanceM: Value(w.distanceM),
      bandLevel: Value(w.bandLevel),
      rpe: Value(w.rpe),
      rir: Value(w.rir),
      restSec: Value(w.restSec),
      note: Value(w.note),
      completedAt: Value(w.completedAt?.toUtc()),
      updatedAt: Value(updatedAt.toUtc()),
      deletedAt: const Value(null),
      plannedSetKey: Value(w.plannedSetKey),
      targetReps: Value(w.targetReps),
      targetWeightKg: Value(w.targetWeightKg),
      isAmrap: Value(w.isAmrap),
      targetRepsMax: Value(w.targetRepsMax),
      targetRir: Value(w.targetRir),
      targetRestSec: Value(w.targetRestSec),
    );

ExercisesCompanion exerciseCompanion(Exercise e, {DateTime? updatedAt}) => ExercisesCompanion(
  id: Value(e.id),
  nameKo: Value(e.nameKo),
  nameEn: Value(e.nameEn),
  type: Value(e.type.name),
  primaryMuscle: Value(e.primaryMuscle.name),
  secondaryMuscles: Value(musclesToText(e.secondaryMuscles)),
  builtIn: Value(e.builtIn),
  updatedAt: Value((updatedAt ?? e.updatedAt).toUtc()),
  deletedAt: const Value(null),
  source: Value(e.source?.name),
  importBatchId: Value(e.importBatchId),
);

// ---------- 서버 Change를 로컬에 덮어쓰기 ----------

extension ApplyServerChange on AppDatabase {
  /// 서버가 준 변경(pull, conflict의 server)을 로컬 행에 덮어쓴다. outbox는 건드리지 않는다.
  /// 받은 행의 updatedAt은 change.clientUpdatedAt(서버 updated_at)이다.
  /// 모양이 깨진 payload는 건너뛴다(한 건 때문에 동기화가 멈추지 않게). 적용했으면 true.
  Future<bool> applyServerChange(Change c) async {
    final at = c.clientUpdatedAt.toUtc();
    try {
      if (c.op == ChangeOp.DELETE) {
        await _applyDelete(c.entity, c.id, at);
        return true;
      }
      final p = <String, Object?>{...?c.payload, 'id': c.id};
      switch (c.entity) {
        case SyncEntity.exercise:
          final e = Exercise.fromJson({'builtIn': false, 'updatedAt': at.toIso8601String(), ...p});
          await into(exercises).insertOnConflictUpdate(exerciseCompanion(e, updatedAt: at));
        case SyncEntity.workout_session:
          final s = Session.fromJson(p);
          await into(sessions).insertOnConflictUpdate(sessionCompanion(s, updatedAt: at));
        case SyncEntity.session_exercise:
          final sessionId = (c.parentId ?? p['sessionId']) as String;
          final se = SessionExercise.fromJson(p);
          await into(sessionExercises).insertOnConflictUpdate(
            SessionExercisesCompanion(
              id: Value(se.id),
              sessionId: Value(sessionId),
              exerciseId: Value(se.exerciseId),
              position: Value(se.position),
              note: Value(se.note),
              updatedAt: Value(at),
              deletedAt: const Value(null),
              liftKey: Value(se.liftKey),
              accessory: Value(se.accessory),
            ),
          );
        case SyncEntity.workout_set:
          final seId = (c.parentId ?? p['sessionExerciseId']) as String;
          final w = WorkoutSet.fromJson(p);
          await into(workoutSets).insertOnConflictUpdate(setCompanion(w, sessionExerciseId: seId, updatedAt: at));
        case SyncEntity.scheduled_workout:
          final w = ScheduledWorkout.fromJson(p);
          await into(scheduledWorkouts).insertOnConflictUpdate(scheduledCompanion(w, updatedAt: at));
        case SyncEntity.body_measurement:
          final m = BodyMeasurement.fromJson(p);
          await into(bodyMeasurements).insertOnConflictUpdate(
            BodyMeasurementsCompanion(
              id: Value(m.id),
              measuredAt: Value(m.measuredAt),
              weightKg: Value(m.weightKg),
              source: Value(m.source.name),
              updatedAt: Value(at),
              deletedAt: const Value(null),
              importBatchId: Value(m.importBatchId),
            ),
          );
      }
      return true;
    } on TypeError {
      return false;
    } on FormatException {
      return false;
    } on ArgumentError {
      return false;
    }
  }

  /// 소프트 삭제. 세션·종목은 자식도 같이 지운다(서버가 자식 삭제를 따로 보내지 않아도 일관되게).
  Future<void> _applyDelete(SyncEntity entity, String id, DateTime at) async {
    final del = Value<DateTime?>(at);
    switch (entity) {
      case SyncEntity.exercise:
        await (update(
          exercises,
        )..where((t) => t.id.equals(id))).write(ExercisesCompanion(deletedAt: del, updatedAt: Value(at)));
      case SyncEntity.workout_session:
        final ses = await (select(sessionExercises)..where((t) => t.sessionId.equals(id))).get();
        for (final se in ses) {
          await _applyDelete(SyncEntity.session_exercise, se.id, at);
        }
        await (update(
          sessions,
        )..where((t) => t.id.equals(id))).write(SessionsCompanion(deletedAt: del, updatedAt: Value(at)));
      case SyncEntity.session_exercise:
        await (update(workoutSets)..where((t) => t.sessionExerciseId.equals(id))).write(
          WorkoutSetsCompanion(deletedAt: del, updatedAt: Value(at)),
        );
        await (update(
          sessionExercises,
        )..where((t) => t.id.equals(id))).write(SessionExercisesCompanion(deletedAt: del, updatedAt: Value(at)));
      case SyncEntity.workout_set:
        await (update(
          workoutSets,
        )..where((t) => t.id.equals(id))).write(WorkoutSetsCompanion(deletedAt: del, updatedAt: Value(at)));
      case SyncEntity.scheduled_workout:
        await (update(
          scheduledWorkouts,
        )..where((t) => t.id.equals(id))).write(ScheduledWorkoutsCompanion(deletedAt: del, updatedAt: Value(at)));
      case SyncEntity.body_measurement:
        await (update(
          bodyMeasurements,
        )..where((t) => t.id.equals(id))).write(BodyMeasurementsCompanion(deletedAt: del, updatedAt: Value(at)));
    }
  }
}
