// B3 소유. domain/repositories.dart의 drift 구현.
// 모든 쓰기는 한 트랜잭션에서 "행 저장 + outbox 적재"를 한다. 기본 종목은 outbox에 넣지 않는다.
// 쓰기마다 행의 updatedAt을 갱신하고(같은 행에서 항상 증가), outbox의 clientUpdatedAt은 그 값이다.
import 'dart:async';

import 'package:drift/drift.dart';

import '../../core/api/api_client.dart';
import '../../core/api/dto.dart';
import '../../core/api/program_dto.dart';
import '../../core/ids.dart';
import '../../domain/repositories.dart';
import '../sync/sync_engine.dart';
import 'app_database.dart';
import 'local_mappers.dart';

abstract class _DriftBase {
  final AppDatabase db;
  final SyncService sync;
  final DateTime Function() _clock;
  _DriftBase(this.db, this.sync, {DateTime Function()? clock}) : _clock = clock ?? (() => DateTime.now().toUtc());

  /// UTC, 밀리초 정밀도(서버 timestamptz·JSON 왕복에서 값이 달라지지 않게).
  DateTime now() => DateTime.fromMillisecondsSinceEpoch(_clock().millisecondsSinceEpoch, isUtc: true);

  /// 같은 행의 이전 updatedAt보다 항상 큰 새 updatedAt. outbox 정리 때 "그 뒤에 또 바뀌었는지"를 가르는 기준이다.
  DateTime stamp(DateTime? prev) {
    final n = now();
    if (prev == null) return n;
    final p = prev.toUtc();
    return n.isAfter(p) ? n : p.add(const Duration(milliseconds: 1));
  }

  void scheduleSync() => sync.schedule();
}

// ---------- 종목 ----------

class DriftExerciseRepository extends _DriftBase implements ExerciseRepository {
  final ApiClient api;
  DriftExerciseRepository(super.db, super.sync, this.api, {super.clock});

  Selectable<ExerciseRow> _live() => db.select(db.exercises)
    ..where((t) => t.deletedAt.isNull())
    ..orderBy([(t) => OrderingTerm.asc(t.nameKo)]);

  @override
  Stream<List<Exercise>> watchAll() => _live().watch().map((rows) => [for (final r in rows) exerciseOf(r)]);

  @override
  Future<List<Exercise>> search({String? query, Muscle? muscle, ExerciseType? type}) async {
    final q = query?.trim().toLowerCase();
    final all = [for (final r in await _live().get()) exerciseOf(r)];
    return all.where((e) {
      if (muscle != null && e.primaryMuscle != muscle && !e.secondaryMuscles.contains(muscle)) return false;
      if (type != null && e.type != type) return false;
      if (q != null && q.isNotEmpty) {
        return e.nameKo.toLowerCase().contains(q) || (e.nameEn?.toLowerCase().contains(q) ?? false);
      }
      return true;
    }).toList();
  }

  /// 삭제된 내 종목도 돌려준다(지난 기록에서 이름을 보여줘야 하므로).
  @override
  Future<Exercise?> byId(String id) async {
    final r = await (db.select(db.exercises)..where((t) => t.id.equals(id))).getSingleOrNull();
    return r == null ? null : exerciseOf(r);
  }

  @override
  Future<Exercise> createCustom(ExerciseInput input) async {
    final row = await db.transaction(() async {
      final at = stamp(null);
      await db
          .into(db.exercises)
          .insertOnConflictUpdate(
            ExercisesCompanion(
              id: Value(input.id),
              nameKo: Value(input.nameKo),
              nameEn: Value(input.nameEn),
              type: Value(input.type.name),
              primaryMuscle: Value(input.primaryMuscle.name),
              secondaryMuscles: Value(musclesToText(input.secondaryMuscles)),
              builtIn: const Value(false),
              updatedAt: Value(at),
              deletedAt: const Value(null),
            ),
          );
      final r = await (db.select(db.exercises)..where((t) => t.id.equals(input.id))).getSingle();
      await db.enqueue(
        entity: SyncEntity.exercise,
        entityId: r.id,
        op: ChangeOp.UPSERT,
        payload: exercisePayload(r),
        clientUpdatedAt: r.updatedAt,
      );
      return r;
    });
    scheduleSync();
    return exerciseOf(row);
  }

  @override
  Future<Exercise> updateCustom(ExerciseInput input) async {
    final row = await db.transaction(() async {
      final old = await (db.select(db.exercises)..where((t) => t.id.equals(input.id))).getSingleOrNull();
      if (old == null || old.builtIn || old.deletedAt != null) throw StateError('not a custom exercise: ${input.id}');
      await (db.update(db.exercises)..where((t) => t.id.equals(input.id))).write(
        ExercisesCompanion(
          nameKo: Value(input.nameKo),
          nameEn: Value(input.nameEn),
          type: Value(input.type.name),
          primaryMuscle: Value(input.primaryMuscle.name),
          secondaryMuscles: Value(musclesToText(input.secondaryMuscles)),
          updatedAt: Value(stamp(old.updatedAt)),
        ),
      );
      final r = await (db.select(db.exercises)..where((t) => t.id.equals(input.id))).getSingle();
      await db.enqueue(
        entity: SyncEntity.exercise,
        entityId: r.id,
        op: ChangeOp.UPSERT,
        payload: exercisePayload(r),
        clientUpdatedAt: r.updatedAt,
      );
      return r;
    });
    scheduleSync();
    return exerciseOf(row);
  }

  @override
  Future<void> deleteCustom(String id) async {
    await db.transaction(() async {
      final old = await (db.select(db.exercises)..where((t) => t.id.equals(id))).getSingleOrNull();
      if (old == null || old.builtIn) throw StateError('not a custom exercise: $id');
      final at = stamp(old.updatedAt);
      await (db.update(
        db.exercises,
      )..where((t) => t.id.equals(id))).write(ExercisesCompanion(deletedAt: Value(at), updatedAt: Value(at)));
      await db.enqueue(entity: SyncEntity.exercise, entityId: id, op: ChangeOp.DELETE, clientUpdatedAt: at);
    });
    scheduleSync();
  }

  @override
  Future<void> refreshFromServer() async {
    final List<Exercise> remote;
    try {
      remote = await api.getExercises();
    } on ApiException {
      return; // 오프라인·미로그인이면 조용히 무시
    }
    await db.transaction(() async {
      final pending = {
        for (final o in await (db.select(db.outbox)..where((t) => t.entity.equals(SyncEntity.exercise.name))).get())
          o.entityId,
      };
      for (final e in remote) {
        final local = await (db.select(db.exercises)..where((t) => t.id.equals(e.id))).getSingleOrNull();
        if (e.builtIn) {
          await db.into(db.exercises).insertOnConflictUpdate(exerciseCompanion(e));
        } else if (!pending.contains(e.id) && (local == null || local.updatedAt.isBefore(e.updatedAt))) {
          await db.into(db.exercises).insertOnConflictUpdate(exerciseCompanion(e));
        }
      }
    });
  }
}

// ---------- 세션 ----------

class DriftSessionRepository extends _DriftBase implements SessionRepository {
  DriftSessionRepository(super.db, super.sync, {super.clock});

  /// 세션·종목·세트 중 하나라도 바뀌면 다시 방출하는 트리거.
  Stream<void> get _changes =>
      db.customSelect('SELECT 1', readsFrom: {db.sessions, db.sessionExercises, db.workoutSets}).watch();

  Future<List<Session>> _assemble(List<SessionRow> rows) async {
    if (rows.isEmpty) return const [];
    final ids = [for (final r in rows) r.id];
    final ses =
        await (db.select(db.sessionExercises)
              ..where((t) => t.sessionId.isIn(ids) & t.deletedAt.isNull())
              ..orderBy([(t) => OrderingTerm.asc(t.position)]))
            .get();
    final sets = ses.isEmpty
        ? <WorkoutSetRow>[]
        : await (db.select(db.workoutSets)
                ..where((t) => t.sessionExerciseId.isIn([for (final e in ses) e.id]) & t.deletedAt.isNull())
                ..orderBy([(t) => OrderingTerm.asc(t.position)]))
              .get();
    final setsBySe = <String, List<WorkoutSet>>{};
    for (final s in sets) {
      (setsBySe[s.sessionExerciseId] ??= []).add(setOf(s));
    }
    final seBySession = <String, List<SessionExercise>>{};
    for (final e in ses) {
      (seBySession[e.sessionId] ??= []).add(sessionExerciseOf(e, setsBySe[e.id] ?? const []));
    }
    return [for (final r in rows) sessionOf(r, seBySession[r.id] ?? const [])];
  }

  Future<Session?> _load(String id) async {
    final r = await (db.select(db.sessions)..where((t) => t.id.equals(id) & t.deletedAt.isNull())).getSingleOrNull();
    return r == null ? null : (await _assemble([r])).single;
  }

  Future<SessionRow?> _activeRow() =>
      (db.select(db.sessions)
            ..where((t) => t.deletedAt.isNull() & t.endedAt.isNull())
            ..orderBy([(t) => OrderingTerm.desc(t.startedAt)])
            ..limit(1))
          .getSingleOrNull();

  @override
  Stream<Session?> watchActiveSession() => _changes.asyncMap((_) async {
    final r = await _activeRow();
    return r == null ? null : (await _assemble([r])).single;
  });

  @override
  Stream<Session?> watchSession(String id) => _changes.asyncMap((_) => _load(id));

  @override
  Stream<List<SessionSummary>> watchRecentSessions({int limit = 20}) => _changes.asyncMap((_) async {
    final rows =
        await (db.select(db.sessions)
              ..where((t) => t.deletedAt.isNull())
              ..orderBy([(t) => OrderingTerm.desc(t.startedAt)])
              ..limit(limit))
            .get();
    return [for (final s in await _assemble(rows)) summarize(s)];
  });

  /// SessionSummary 계산 규칙(openapi): setCount·totalVolumeKg는 워밍업 제외, 완료 여부와 무관하게 값이 있는 세트.
  static SessionSummary summarize(Session s) {
    var sets = 0;
    var volume = 0.0;
    for (final e in s.exercises) {
      for (final w in e.sets.where((w) => !w.isWarmup)) {
        sets++;
        volume += (w.weightKg ?? 0) * (w.reps ?? 0);
      }
    }
    return SessionSummary(
      id: s.id,
      startedAt: s.startedAt,
      endedAt: s.endedAt,
      tz: s.tz,
      exerciseCount: s.exercises.length,
      setCount: sets,
      totalVolumeKg: volume,
    );
  }

  // ---- outbox 적재 도우미(트랜잭션 안에서 부른다) ----

  Future<void> _enqSession(SessionRow r) => db.enqueue(
    entity: SyncEntity.workout_session,
    entityId: r.id,
    op: ChangeOp.UPSERT,
    payload: sessionPayload(r),
    clientUpdatedAt: r.updatedAt,
  );

  Future<void> _enqSe(SessionExerciseRow r) => db.enqueue(
    entity: SyncEntity.session_exercise,
    entityId: r.id,
    op: ChangeOp.UPSERT,
    parentId: r.sessionId,
    payload: sessionExercisePayload(r),
    clientUpdatedAt: r.updatedAt,
  );

  Future<void> _enqSet(WorkoutSetRow r) => db.enqueue(
    entity: SyncEntity.workout_set,
    entityId: r.id,
    op: ChangeOp.UPSERT,
    parentId: r.sessionExerciseId,
    payload: setPayload(r),
    clientUpdatedAt: r.updatedAt,
  );

  Future<SessionRow> _sessionRow(String id) => (db.select(db.sessions)..where((t) => t.id.equals(id))).getSingle();
  Future<SessionExerciseRow> _seRow(String id) =>
      (db.select(db.sessionExercises)..where((t) => t.id.equals(id) & t.deletedAt.isNull())).getSingle();

  // ---- 세션 ----

  @override
  Future<Session> startSession({required String tz, PlannedWorkout? plan}) async {
    final session = await db.transaction(() async {
      final active = await _activeRow();
      if (active != null) return (await _assemble([active])).single;
      final at = stamp(null);
      final id = newId();
      await db
          .into(db.sessions)
          .insert(
            SessionsCompanion.insert(
              id: id,
              startedAt: at,
              tz: tz,
              source: const Value('APP'),
              updatedAt: at,
              programInstanceId: Value(plan?.instanceId),
              planSeq: Value(plan?.planSeq),
              planDayKey: Value(plan?.dayKey),
            ),
          );
      await _enqSession(await _sessionRow(id));
      if (plan != null) {
        for (var ei = 0; ei < plan.exercises.length; ei++) {
          final pe = plan.exercises[ei];
          final seId = newId();
          await db
              .into(db.sessionExercises)
              .insert(
                SessionExercisesCompanion.insert(
                  id: seId,
                  sessionId: id,
                  exerciseId: pe.exerciseId,
                  position: ei,
                  updatedAt: at,
                  liftKey: Value(pe.key),
                  accessory: Value(pe.accessory),
                ),
              );
          await _enqSe(await _seRow(seId));
          for (var si = 0; si < pe.sets.length; si++) {
            final ps = pe.sets[si];
            final set = WorkoutSet(
              id: newId(),
              position: si,
              isWarmup: ps.isWarmup,
              weightKg: ps.targetWeightKg,
              reps: ps.targetReps,
              plannedSetKey: ps.plannedSetKey,
              targetReps: ps.targetReps,
              targetWeightKg: ps.targetWeightKg,
              isAmrap: ps.isAmrap,
            );
            await db.into(db.workoutSets).insert(setCompanion(set, sessionExerciseId: seId, updatedAt: at));
            await _enqSet(await (db.select(db.workoutSets)..where((t) => t.id.equals(set.id))).getSingle());
          }
        }
      }
      return (await _assemble([await _sessionRow(id)])).single;
    });
    scheduleSync();
    return session;
  }

  @override
  Future<void> reorderExercises(String sessionId, List<String> sessionExerciseIds) async {
    await db.transaction(() async {
      for (var i = 0; i < sessionExerciseIds.length; i++) {
        final se = await _seRow(sessionExerciseIds[i]);
        if (se.sessionId != sessionId) throw StateError('not in session: ${se.id}');
        if (se.position == i) continue;
        await (db.update(db.sessionExercises)..where((t) => t.id.equals(se.id))).write(
          SessionExercisesCompanion(position: Value(i), updatedAt: Value(stamp(se.updatedAt))),
        );
        await _enqSe(await _seRow(se.id));
      }
    });
    scheduleSync();
  }

  @override
  Future<void> reorderSets(String sessionExerciseId, List<String> setIds) async {
    await db.transaction(() async {
      for (var i = 0; i < setIds.length; i++) {
        final w = await (db.select(
          db.workoutSets,
        )..where((t) => t.id.equals(setIds[i]) & t.deletedAt.isNull())).getSingle();
        if (w.sessionExerciseId != sessionExerciseId) throw StateError('not in exercise: ${w.id}');
        if (w.position == i) continue;
        await (db.update(db.workoutSets)..where((t) => t.id.equals(w.id))).write(
          WorkoutSetsCompanion(position: Value(i), updatedAt: Value(stamp(w.updatedAt))),
        );
        await _enqSet(await (db.select(db.workoutSets)..where((t) => t.id.equals(w.id))).getSingle());
      }
    });
    scheduleSync();
  }

  @override
  Future<void> updateSessionTimes(String sessionId, {DateTime? startedAt, DateTime? endedAt}) async {
    if (startedAt == null && endedAt == null) return;
    await db.transaction(() async {
      final r = await _sessionRow(sessionId);
      await (db.update(db.sessions)..where((t) => t.id.equals(sessionId))).write(
        SessionsCompanion(
          startedAt: startedAt == null ? const Value.absent() : Value(startedAt.toUtc()),
          endedAt: endedAt == null ? const Value.absent() : Value(endedAt.toUtc()),
          updatedAt: Value(stamp(r.updatedAt)),
        ),
      );
      await _enqSession(await _sessionRow(sessionId));
    });
    scheduleSync();
  }

  @override
  Future<Set<int>> planSeqsUsed(String instanceId) async {
    final rows = await (db.select(
      db.sessions,
    )..where((t) => t.programInstanceId.equals(instanceId) & t.deletedAt.isNull() & t.planSeq.isNotNull())).get();
    return {for (final r in rows) r.planSeq!};
  }

  @override
  Future<Session?> lastSessionForDay(String instanceId, String dayKey, {String? excludeSessionId}) async {
    final q = db.select(db.sessions)
      ..where(
        (t) =>
            t.programInstanceId.equals(instanceId) &
            t.planDayKey.equals(dayKey) &
            t.deletedAt.isNull() &
            t.endedAt.isNotNull() &
            (excludeSessionId == null ? const Constant(true) : t.id.equals(excludeSessionId).not()),
      )
      ..orderBy([(t) => OrderingTerm.desc(t.startedAt)])
      ..limit(1);
    final r = await q.getSingleOrNull();
    return r == null ? null : (await _assemble([r])).single;
  }

  @override
  Future<void> endSession(String sessionId) async {
    await db.transaction(() async {
      final r = await (db.select(
        db.sessions,
      )..where((t) => t.id.equals(sessionId) & t.deletedAt.isNull())).getSingleOrNull();
      if (r == null) return;
      final at = stamp(r.updatedAt);
      await (db.update(db.sessions)..where((t) => t.id.equals(sessionId))).write(
        SessionsCompanion(endedAt: Value(r.endedAt ?? at), updatedAt: Value(at)),
      );
      await _enqSession(await _sessionRow(sessionId));
    });
    unawaited(sync.syncNow()); // 세션 종료는 즉시 동기화
  }

  @override
  Future<void> updateSessionNote(String sessionId, String? note) async {
    await db.transaction(() async {
      final r = await _sessionRow(sessionId);
      await (db.update(db.sessions)..where((t) => t.id.equals(sessionId))).write(
        SessionsCompanion(note: Value(note), updatedAt: Value(stamp(r.updatedAt))),
      );
      await _enqSession(await _sessionRow(sessionId));
    });
    scheduleSync();
  }

  @override
  Future<void> deleteSession(String sessionId) async {
    await db.transaction(() async {
      final r = await (db.select(db.sessions)..where((t) => t.id.equals(sessionId))).getSingleOrNull();
      if (r == null || r.deletedAt != null) return;
      final ses = await (db.select(
        db.sessionExercises,
      )..where((t) => t.sessionId.equals(sessionId) & t.deletedAt.isNull())).get();
      for (final se in ses) {
        await _softDeleteExercise(se);
      }
      final at = stamp(r.updatedAt);
      await (db.update(
        db.sessions,
      )..where((t) => t.id.equals(sessionId))).write(SessionsCompanion(deletedAt: Value(at), updatedAt: Value(at)));
      await db.enqueue(
        entity: SyncEntity.workout_session,
        entityId: sessionId,
        op: ChangeOp.DELETE,
        clientUpdatedAt: at,
      );
    });
    scheduleSync();
  }

  // ---- 종목 ----

  @override
  Future<SessionExercise> addExercise(String sessionId, String exerciseId, {bool accessory = false}) async {
    final se = await db.transaction(() async {
      final maxPos = db.sessionExercises.position.max();
      final top =
          await (db.selectOnly(db.sessionExercises)
                ..addColumns([maxPos])
                ..where(db.sessionExercises.sessionId.equals(sessionId) & db.sessionExercises.deletedAt.isNull()))
              .map((r) => r.read(maxPos))
              .getSingle();
      final id = newId();
      await db
          .into(db.sessionExercises)
          .insert(
            SessionExercisesCompanion.insert(
              id: id,
              sessionId: sessionId,
              exerciseId: exerciseId,
              position: top == null ? 0 : top + 1,
              updatedAt: stamp(null),
              accessory: Value(accessory),
            ),
          );
      final r = await _seRow(id);
      await _enqSe(r);
      return r;
    });
    scheduleSync();
    return sessionExerciseOf(se, const []);
  }

  Future<void> _softDeleteExercise(SessionExerciseRow se) async {
    final sets = await (db.select(
      db.workoutSets,
    )..where((t) => t.sessionExerciseId.equals(se.id) & t.deletedAt.isNull())).get();
    for (final s in sets) {
      final at = stamp(s.updatedAt);
      await (db.update(
        db.workoutSets,
      )..where((t) => t.id.equals(s.id))).write(WorkoutSetsCompanion(deletedAt: Value(at), updatedAt: Value(at)));
      await db.enqueue(
        entity: SyncEntity.workout_set,
        entityId: s.id,
        op: ChangeOp.DELETE,
        parentId: se.id,
        clientUpdatedAt: at,
      );
    }
    final at = stamp(se.updatedAt);
    await (db.update(
      db.sessionExercises,
    )..where((t) => t.id.equals(se.id))).write(SessionExercisesCompanion(deletedAt: Value(at), updatedAt: Value(at)));
    await db.enqueue(
      entity: SyncEntity.session_exercise,
      entityId: se.id,
      op: ChangeOp.DELETE,
      parentId: se.sessionId,
      clientUpdatedAt: at,
    );
  }

  @override
  Future<void> removeExercise(String sessionExerciseId) async {
    await db.transaction(() async {
      final se = await (db.select(
        db.sessionExercises,
      )..where((t) => t.id.equals(sessionExerciseId) & t.deletedAt.isNull())).getSingleOrNull();
      if (se != null) await _softDeleteExercise(se);
    });
    scheduleSync();
  }

  @override
  Future<void> updateExerciseNote(String sessionExerciseId, String? note) async {
    await db.transaction(() async {
      final se = await _seRow(sessionExerciseId);
      await (db.update(db.sessionExercises)..where((t) => t.id.equals(se.id))).write(
        SessionExercisesCompanion(note: Value(note), updatedAt: Value(stamp(se.updatedAt))),
      );
      await _enqSe(await _seRow(se.id));
    });
    scheduleSync();
  }

  // ---- 세트 ----

  @override
  Future<WorkoutSet> addSet(String sessionExerciseId, WorkoutSet draft) async {
    final row = await db.transaction(() async {
      final maxPos = db.workoutSets.position.max();
      final top =
          await (db.selectOnly(db.workoutSets)
                ..addColumns([maxPos])
                ..where(db.workoutSets.sessionExerciseId.equals(sessionExerciseId) & db.workoutSets.deletedAt.isNull()))
              .map((r) => r.read(maxPos))
              .getSingle();
      final set = draft.copyWith(position: top == null ? 0 : top + 1);
      await db
          .into(db.workoutSets)
          .insert(setCompanion(set, sessionExerciseId: sessionExerciseId, updatedAt: stamp(null)));
      final r = await (db.select(db.workoutSets)..where((t) => t.id.equals(set.id))).getSingle();
      await _enqSet(r);
      return r;
    });
    scheduleSync();
    return setOf(row);
  }

  @override
  Future<void> updateSet(WorkoutSet set) async {
    await db.transaction(() async {
      final old = await (db.select(
        db.workoutSets,
      )..where((t) => t.id.equals(set.id) & t.deletedAt.isNull())).getSingleOrNull();
      if (old == null) throw StateError('set not found: ${set.id}');
      await (db.update(db.workoutSets)..where((t) => t.id.equals(set.id))).write(
        setCompanion(set, sessionExerciseId: old.sessionExerciseId, updatedAt: stamp(old.updatedAt)),
      );
      await _enqSet(await (db.select(db.workoutSets)..where((t) => t.id.equals(set.id))).getSingle());
    });
    scheduleSync(); // 세트 완료(completedAt)도 여기로 온다: 5초 디바운스
  }

  @override
  Future<void> deleteSet(String setId) async {
    await db.transaction(() async {
      final old = await (db.select(
        db.workoutSets,
      )..where((t) => t.id.equals(setId) & t.deletedAt.isNull())).getSingleOrNull();
      if (old == null) return;
      final at = stamp(old.updatedAt);
      await (db.update(
        db.workoutSets,
      )..where((t) => t.id.equals(setId))).write(WorkoutSetsCompanion(deletedAt: Value(at), updatedAt: Value(at)));
      await db.enqueue(
        entity: SyncEntity.workout_set,
        entityId: setId,
        op: ChangeOp.DELETE,
        parentId: old.sessionExerciseId,
        clientUpdatedAt: at,
      );
    });
    scheduleSync();
  }

  @override
  Future<LastSets?> lastSetsFor(String exerciseId, {String? excludeSessionId}) async {
    final q =
        db.select(db.sessions).join([
            innerJoin(db.sessionExercises, db.sessionExercises.sessionId.equalsExp(db.sessions.id)),
          ])
          ..where(
            db.sessions.deletedAt.isNull() &
                db.sessions.endedAt.isNotNull() &
                db.sessionExercises.deletedAt.isNull() &
                db.sessionExercises.exerciseId.equals(exerciseId) &
                (excludeSessionId == null ? const Constant(true) : db.sessions.id.equals(excludeSessionId).not()),
          )
          ..orderBy([OrderingTerm.desc(db.sessions.startedAt)]);
    for (final row in await q.get()) {
      final s = row.readTable(db.sessions);
      final se = row.readTable(db.sessionExercises);
      final sets =
          await (db.select(db.workoutSets)
                ..where((t) => t.sessionExerciseId.equals(se.id) & t.deletedAt.isNull())
                ..orderBy([(t) => OrderingTerm.asc(t.position)]))
              .get();
      if (sets.isNotEmpty) {
        return LastSets(sessionId: s.id, startedAt: s.startedAt.toUtc(), sets: [for (final w in sets) setOf(w)]);
      }
    }
    return null;
  }
}

// ---------- 체중 ----------

class DriftBodyRepository extends _DriftBase implements BodyRepository {
  DriftBodyRepository(super.db, super.sync, {super.clock});

  @override
  Stream<List<BodyMeasurement>> watchMeasurements() =>
      (db.select(db.bodyMeasurements)
            ..where((t) => t.deletedAt.isNull())
            ..orderBy([(t) => OrderingTerm.desc(t.measuredAt)]))
          .watch()
          .map((rows) => [for (final r in rows) measurementOf(r)]);

  @override
  Future<void> add(BodyMeasurement m) async {
    await db.transaction(() async {
      final old = await (db.select(db.bodyMeasurements)..where((t) => t.id.equals(m.id))).getSingleOrNull();
      await db
          .into(db.bodyMeasurements)
          .insertOnConflictUpdate(
            BodyMeasurementsCompanion(
              id: Value(m.id),
              measuredAt: Value(m.measuredAt.toUtc()),
              weightKg: Value(m.weightKg),
              source: Value(m.source.name),
              updatedAt: Value(stamp(old?.updatedAt)),
              deletedAt: const Value(null),
            ),
          );
      final r = await (db.select(db.bodyMeasurements)..where((t) => t.id.equals(m.id))).getSingle();
      await db.enqueue(
        entity: SyncEntity.body_measurement,
        entityId: m.id,
        op: ChangeOp.UPSERT,
        payload: measurementPayload(r),
        clientUpdatedAt: r.updatedAt,
      );
    });
    scheduleSync();
  }

  @override
  Future<void> delete(String id) async {
    await db.transaction(() async {
      final old = await (db.select(
        db.bodyMeasurements,
      )..where((t) => t.id.equals(id) & t.deletedAt.isNull())).getSingleOrNull();
      if (old == null) return;
      final at = stamp(old.updatedAt);
      await (db.update(
        db.bodyMeasurements,
      )..where((t) => t.id.equals(id))).write(BodyMeasurementsCompanion(deletedAt: Value(at), updatedAt: Value(at)));
      await db.enqueue(entity: SyncEntity.body_measurement, entityId: id, op: ChangeOp.DELETE, clientUpdatedAt: at);
    });
    scheduleSync();
  }
}

// ---------- 로컬 데이터 삭제 ----------

class DriftLocalDataStore implements LocalDataStore {
  final AppDatabase db;
  final SyncEngine? engine;
  DriftLocalDataStore(this.db, {this.engine});

  @override
  Future<void> clearAll() async {
    await engine?.reset();
    await db.wipe();
  }
}
