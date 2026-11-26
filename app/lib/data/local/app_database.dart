// B3 소유. 로컬 DB(drift). 로컬이 진실의 원천이고 outbox로 서버와 맞춘다(contracts/v0.1/sync.md).
// 시각은 모두 UTC(build.yaml: store_date_time_values_as_text). 무게는 kg.
import 'dart:convert';

import 'package:drift/drift.dart';

import '../../core/api/dto.dart';

part 'app_database.g.dart';

@DataClassName('ExerciseRow')
@TableIndex(name: 'idx_exercises_deleted', columns: {#deletedAt})
class Exercises extends Table {
  TextColumn get id => text()();
  TextColumn get nameKo => text()();
  TextColumn get nameEn => text().nullable()();
  TextColumn get type => text()();
  TextColumn get primaryMuscle => text()();

  /// 쉼표로 이은 Muscle 이름.
  TextColumn get secondaryMuscles => text().withDefault(const Constant(''))();
  BoolColumn get builtIn => boolean().withDefault(const Constant(false))();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('SessionRow')
@TableIndex(name: 'idx_sessions_started', columns: {#startedAt})
@TableIndex(name: 'idx_sessions_ended', columns: {#endedAt})
class Sessions extends Table {
  TextColumn get id => text()();
  DateTimeColumn get startedAt => dateTime()();
  DateTimeColumn get endedAt => dateTime().nullable()();
  TextColumn get tz => text()();
  TextColumn get note => text().nullable()();
  TextColumn get source => text().nullable()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('SessionExerciseRow')
@TableIndex(name: 'idx_se_session', columns: {#sessionId})
@TableIndex(name: 'idx_se_exercise', columns: {#exerciseId})
class SessionExercises extends Table {
  TextColumn get id => text()();
  TextColumn get sessionId => text()();
  TextColumn get exerciseId => text()();
  IntColumn get position => integer()();
  TextColumn get note => text().nullable()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('WorkoutSetRow')
@TableIndex(name: 'idx_sets_se', columns: {#sessionExerciseId})
class WorkoutSets extends Table {
  TextColumn get id => text()();
  TextColumn get sessionExerciseId => text()();
  IntColumn get position => integer()();
  BoolColumn get isWarmup => boolean().withDefault(const Constant(false))();
  RealColumn get weightKg => real().nullable()();
  RealColumn get addedWeightKg => real().nullable()();
  IntColumn get reps => integer().nullable()();
  IntColumn get durationSec => integer().nullable()();
  RealColumn get distanceM => real().nullable()();
  TextColumn get bandLevel => text().nullable()();
  RealColumn get rpe => real().nullable()();
  IntColumn get rir => integer().nullable()();
  IntColumn get restSec => integer().nullable()();
  TextColumn get note => text().nullable()();
  DateTimeColumn get completedAt => dateTime().nullable()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('BodyMeasurementRow')
@TableIndex(name: 'idx_body_measured', columns: {#measuredAt})
class BodyMeasurements extends Table {
  TextColumn get id => text()();
  DateTimeColumn get measuredAt => dateTime()();
  RealColumn get weightKg => real()();
  TextColumn get source => text().withDefault(const Constant('MANUAL'))();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 아직 서버에 못 보낸 변경. 같은 (entity, entityId)는 한 줄로 합친다.
@DataClassName('OutboxRow')
@TableIndex(name: 'idx_outbox_entity', columns: {#entity, #entityId}, unique: true)
class Outbox extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// [SyncEntity] 이름(workout_session 등).
  TextColumn get entity => text()();
  TextColumn get entityId => text()();

  /// [ChangeOp] 이름.
  TextColumn get op => text()();
  TextColumn get parentId => text().nullable()();

  /// UPSERT의 엔티티 필드 JSON(중첩 없음). DELETE면 null.
  TextColumn get payload => text().nullable()();
  DateTimeColumn get clientUpdatedAt => dateTime()();
  IntColumn get attempts => integer().withDefault(const Constant(0))();
  TextColumn get lastError => text().nullable()();
}

@DataClassName('SyncStateRow')
class SyncState extends Table {
  /// 항상 1.
  IntColumn get id => integer()();
  IntColumn get lastServerSeq => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

@DriftDatabase(tables: [Exercises, Sessions, SessionExercises, WorkoutSets, BodyMeasurements, Outbox, SyncState])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          await into(syncState).insert(SyncStateCompanion.insert(id: const Value(1)));
        },
      );

  // ---------- sync_state ----------

  Future<int> getLastServerSeq() async {
    final row = await (select(syncState)..where((t) => t.id.equals(1))).getSingleOrNull();
    return row?.lastServerSeq ?? 0;
  }

  Future<void> setLastServerSeq(int seq) =>
      into(syncState).insertOnConflictUpdate(SyncStateCompanion(id: const Value(1), lastServerSeq: Value(seq)));

  // ---------- outbox ----------

  /// 같은 엔티티의 미전송 항목이 있으면 그 자리(오래된 id)에서 내용만 바꾼다. 부모 먼저 보내는 순서를 유지하려는 것.
  Future<void> enqueue({
    required SyncEntity entity,
    required String entityId,
    required ChangeOp op,
    String? parentId,
    Map<String, Object?>? payload,
    required DateTime clientUpdatedAt,
  }) async {
    final json = op == ChangeOp.DELETE || payload == null ? null : jsonEncode(payload);
    final existing = await (select(outbox)..where((t) => t.entity.equals(entity.name) & t.entityId.equals(entityId)))
        .getSingleOrNull();
    if (existing == null) {
      await into(outbox).insert(OutboxCompanion.insert(
        entity: entity.name,
        entityId: entityId,
        op: op.name,
        parentId: Value(parentId),
        payload: Value(json),
        clientUpdatedAt: clientUpdatedAt,
      ));
    } else {
      await (update(outbox)..where((t) => t.id.equals(existing.id))).write(OutboxCompanion(
        op: Value(op.name),
        parentId: Value(parentId),
        payload: Value(json),
        clientUpdatedAt: Value(clientUpdatedAt),
        attempts: const Value(0),
        lastError: const Value(null),
      ));
    }
  }

  Stream<int> watchOutboxCount() {
    final c = outbox.id.count();
    return (selectOnly(outbox)..addColumns([c])).map((r) => r.read(c) ?? 0).watchSingle();
  }

  Future<int> outboxCount() async {
    final c = outbox.id.count();
    return (selectOnly(outbox)..addColumns([c])).map((r) => r.read(c) ?? 0).getSingle();
  }

  /// 모든 테이블을 비운다(로그아웃·계정 삭제). lastServerSeq도 0으로.
  Future<void> wipe() => transaction(() async {
        for (final t in allTables) {
          await delete(t).go();
        }
        await into(syncState).insert(SyncStateCompanion.insert(id: const Value(1)));
      });
}
