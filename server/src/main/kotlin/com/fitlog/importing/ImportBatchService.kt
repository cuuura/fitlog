@file:UseSerializers(InstantSerializer::class, UUIDSerializer::class)

package com.fitlog.importing

import com.fitlog.body.softDeleteMeasurementRow
import com.fitlog.core.AppJson
import com.fitlog.core.BodyMeasurements
import com.fitlog.core.ChangeSeq
import com.fitlog.core.Exercises
import com.fitlog.core.ImportBatches
import com.fitlog.core.ImportItems
import com.fitlog.core.InstantSerializer
import com.fitlog.core.ProgramInstances
import com.fitlog.core.Programs
import com.fitlog.core.ScheduledWorkouts
import com.fitlog.core.SessionExercises
import com.fitlog.core.Times
import com.fitlog.core.UUIDSerializer
import com.fitlog.core.WorkoutSessions
import com.fitlog.core.WorkoutSets
import com.fitlog.core.lockUser
import com.fitlog.core.notFound
import com.fitlog.engine.ProgramEngine
import com.fitlog.program.instance.replayInstances
import com.fitlog.scheduled.softDeleteScheduledRow
import com.fitlog.session.softDeleteSession
import kotlinx.serialization.Serializable
import kotlinx.serialization.UseSerializers
import org.jetbrains.exposed.sql.ResultRow
import org.jetbrains.exposed.sql.SortOrder
import org.jetbrains.exposed.sql.SqlExpressionBuilder.eq
import org.jetbrains.exposed.sql.SqlExpressionBuilder.inList
import org.jetbrains.exposed.sql.SqlExpressionBuilder.isNull
import org.jetbrains.exposed.sql.SqlExpressionBuilder.less
import org.jetbrains.exposed.sql.Transaction
import org.jetbrains.exposed.sql.and
import org.jetbrains.exposed.sql.selectAll
import org.jetbrains.exposed.sql.update
import java.time.Instant
import java.util.UUID

@Serializable
data class ImportItemView(val entity: String, val entityId: UUID, val action: String, val label: String? = null)

/** openapi ImportBatchDetail (ImportBatch + items) */
@Serializable
data class ImportBatchDetail(
    val id: UUID,
    val createdAt: Instant,
    val channel: String,
    val clientName: String? = null,
    val note: String? = null,
    val summary: Map<String, Int>,
    val revertedAt: Instant? = null,
    val items: List<ImportItemView>,
)

internal fun ResultRow.toImportBatch() = ImportBatch(
    id = this[ImportBatches.id],
    createdAt = this[ImportBatches.createdAt],
    channel = this[ImportBatches.channel],
    clientName = this[ImportBatches.clientName],
    note = this[ImportBatches.note],
    summary = runCatching { AppJson.decodeFromString<Map<String, Int>>(this[ImportBatches.summary]) }.getOrDefault(emptyMap()),
    revertedAt = this[ImportBatches.revertedAt],
)

internal fun Transaction.listImports(userId: UUID, before: Instant?, limit: Int): List<ImportBatch> =
    ImportBatches.selectAll().where {
        val base = ImportBatches.userId eq userId
        if (before != null) base and (ImportBatches.createdAt less before) else base
    }.orderBy(ImportBatches.createdAt to SortOrder.DESC, ImportBatches.id to SortOrder.DESC).limit(limit).map { it.toImportBatch() }

private fun Transaction.ownBatch(userId: UUID, id: UUID): ResultRow =
    ImportBatches.selectAll().where { (ImportBatches.id eq id) and (ImportBatches.userId eq userId) }.singleOrNull()
        ?: notFound("import not found")

internal fun Transaction.importDetail(userId: UUID, id: UUID): ImportBatchDetail {
    val row = ownBatch(userId, id)
    val items = ImportItems.selectAll().where { ImportItems.batchId eq id }
        .orderBy(ImportItems.action to SortOrder.ASC, ImportItems.entity to SortOrder.ASC, ImportItems.label to SortOrder.ASC, ImportItems.id to SortOrder.ASC)
        .map { ImportItemView(it[ImportItems.entity], it[ImportItems.entityId], it[ImportItems.action], it[ImportItems.label]) }
    val b = row.toImportBatch()
    return ImportBatchDetail(b.id, b.createdAt, b.channel, b.clientName, b.note, b.summary, b.revertedAt, items)
}

/** import.md 6절. 이미 되돌렸으면 변화 없이 그대로 돌려준다 */
internal fun Transaction.revertImport(userId: UUID, id: UUID): ImportBatch {
    lockUser(userId)
    val row = ownBatch(userId, id)
    if (row[ImportBatches.revertedAt] != null) return row.toImportBatch()
    val items = ImportItems.selectAll().where { ImportItems.batchId eq id }.toList()
    val now = Times.now()
    val affected = mutableSetOf<UUID>()

    // 1) 묶음이 만든 행을 소프트 삭제
    for (item in items.filter { it[ImportItems.action] == "CREATED" }) {
        val eid = item[ImportItems.entityId]
        when (item[ImportItems.entity]) {
            "exercise" -> Exercises.update({ (Exercises.id eq eid) and (Exercises.ownerId eq userId) and Exercises.deletedAt.isNull() }) { u ->
                u[deletedAt] = now
                u[updatedAt] = now
                u[serverSeq] = ChangeSeq.next
            }
            "program" -> Programs.update({ (Programs.id eq eid) and (Programs.ownerId eq userId) and Programs.deletedAt.isNull() }) { u ->
                u[deletedAt] = now
                u[updatedAt] = now
            }
            "program_instance" -> ProgramInstances.update({ (ProgramInstances.id eq eid) and (ProgramInstances.userId eq userId) and ProgramInstances.deletedAt.isNull() }) { u ->
                u[deletedAt] = now
                u[updatedAt] = now
            }
            "workout_session" -> {
                val s = WorkoutSessions.selectAll().where { (WorkoutSessions.id eq eid) and (WorkoutSessions.userId eq userId) }.singleOrNull()
                if (s != null && s[WorkoutSessions.deletedAt] == null) {
                    s[WorkoutSessions.programInstanceId]?.let { i -> affected += i }
                    softDeleteSession(eid, now)
                }
            }
            "scheduled_workout" -> softDeleteScheduledRow(userId, eid, now)
            "body_measurement" -> {
                val b = BodyMeasurements.selectAll().where { (BodyMeasurements.id eq eid) and (BodyMeasurements.userId eq userId) }.singleOrNull()
                if (b != null && b[BodyMeasurements.deletedAt] == null) softDeleteMeasurementRow(eid, now)
            }
        }
    }

    // 2) REPLACE 로 지운 행을 되살림
    for (item in items.filter { it[ImportItems.action] == "REPLACED_OLD" }) {
        val eid = item[ImportItems.entityId]
        when (item[ImportItems.entity]) {
            "program" -> Programs.update({ (Programs.id eq eid) and (Programs.ownerId eq userId) }) { u ->
                u[deletedAt] = null
                u[updatedAt] = now
            }
            "body_measurement" -> BodyMeasurements.update({ (BodyMeasurements.id eq eid) and (BodyMeasurements.userId eq userId) }) { u ->
                u[deletedAt] = null
                u[updatedAt] = now
                u[serverSeq] = ChangeSeq.next
            }
            "workout_session" -> restoreSession(userId, eid, now, affected)
            "scheduled_workout" -> ScheduledWorkouts.update({ (ScheduledWorkouts.id eq eid) and (ScheduledWorkouts.userId eq userId) }) { u ->
                u[deletedAt] = null
                u[updatedAt] = now
                u[serverSeq] = ChangeSeq.next
            }
        }
    }

    ImportBatches.update({ ImportBatches.id eq id }) { it[revertedAt] = now }
    replayInstances(ProgramEngine, userId, affected)
    return ownBatch(userId, id).toImportBatch()
}

/** 소프트 삭제된 세션과, 그때 함께 지워진(deletedAt 이 같은) 종목·세트를 되살린다 */
private fun Transaction.restoreSession(userId: UUID, sid: UUID, now: Instant, affected: MutableSet<UUID>) {
    val s = WorkoutSessions.selectAll().where { (WorkoutSessions.id eq sid) and (WorkoutSessions.userId eq userId) }.singleOrNull() ?: return
    val deletedAt = s[WorkoutSessions.deletedAt] ?: return
    // 같은 (인스턴스, planSeq) 에 이미 다른 살아있는 세션이 있으면 연결 없이 되살린다
    val inst = s[WorkoutSessions.programInstanceId]
    val seq = s[WorkoutSessions.planSeq]
    val clash = inst != null && seq != null && WorkoutSessions.selectAll().where {
        (WorkoutSessions.programInstanceId eq inst) and (WorkoutSessions.planSeq eq seq) and WorkoutSessions.deletedAt.isNull()
    }.any()
    WorkoutSessions.update({ WorkoutSessions.id eq sid }) {
        it[WorkoutSessions.deletedAt] = null
        it[updatedAt] = now
        it[serverSeq] = ChangeSeq.next
        if (clash) {
            it[programInstanceId] = null
            it[planSeq] = null
            it[planDayKey] = null
        }
    }
    val seIds = SessionExercises.selectAll().where { (SessionExercises.sessionId eq sid) and (SessionExercises.deletedAt eq deletedAt) }
        .map { it[SessionExercises.id] }
    if (seIds.isNotEmpty()) {
        WorkoutSets.update({ (WorkoutSets.sessionExerciseId inList seIds) and (WorkoutSets.deletedAt eq deletedAt) }) {
            it[WorkoutSets.deletedAt] = null
            it[updatedAt] = now
            it[serverSeq] = ChangeSeq.next
        }
        SessionExercises.update({ SessionExercises.id inList seIds }) {
            it[SessionExercises.deletedAt] = null
            it[updatedAt] = now
            it[serverSeq] = ChangeSeq.next
        }
    }
    if (!clash) inst?.let { affected += it }
}
