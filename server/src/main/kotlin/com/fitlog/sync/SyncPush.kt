package com.fitlog.sync

import com.fitlog.body.BodyMeasurement
import com.fitlog.body.checkMeasurement
import com.fitlog.body.softDeleteMeasurementRow
import com.fitlog.body.upsertMeasurementRow
import com.fitlog.core.ApiException
import com.fitlog.core.AppJson
import com.fitlog.core.BodyMeasurements
import com.fitlog.core.ChangeSeq
import com.fitlog.core.ErrorCode
import com.fitlog.core.Exercises
import com.fitlog.core.SessionExercises
import com.fitlog.core.WorkoutSessions
import com.fitlog.core.WorkoutSets
import com.fitlog.core.forbidden
import com.fitlog.core.lockUser
import com.fitlog.core.validation
import com.fitlog.session.WorkoutSet
import com.fitlog.session.checkSet
import com.fitlog.session.checkTz
import com.fitlog.session.exerciseRefs
import com.fitlog.session.softDeleteSession
import com.fitlog.session.softDeleteSessionExercise
import com.fitlog.session.softDeleteSet
import com.fitlog.session.upsertSessionExerciseRow
import com.fitlog.session.upsertSessionRow
import com.fitlog.session.upsertSetRow
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.decodeFromJsonElement
import org.jetbrains.exposed.sql.ResultRow
import org.jetbrains.exposed.sql.SqlExpressionBuilder.eq
import org.jetbrains.exposed.sql.Transaction
import org.jetbrains.exposed.sql.insert
import org.jetbrains.exposed.sql.selectAll
import org.jetbrains.exposed.sql.update
import org.slf4j.LoggerFactory
import java.time.Instant
import java.util.UUID

private val log = LoggerFactory.getLogger("com.fitlog.sync")

internal const val MAX_PUSH = 200

private val MUSCLES = setOf(
    "CHEST", "BACK", "LATS", "TRAPS", "SHOULDERS", "REAR_DELTS", "BICEPS", "TRICEPS", "FOREARMS", "QUADS", "HAMSTRINGS",
    "GLUTES", "CALVES", "ADDUCTORS", "ABS", "OBLIQUES", "LOWER_BACK", "FULL_BODY", "CARDIO",
)
private val TYPES = setOf("BARBELL", "DUMBBELL", "MACHINE", "BODYWEIGHT", "BAND", "CARDIO")

private fun parentMissing(msg: String): Nothing = throw ApiException(ErrorCode.PARENT_MISSING, msg)

private fun applied(c: Change) = ChangeResult(c.id, "applied")

private fun rejected(c: Change, code: String) = ChangeResult(c.id, "rejected", code)

private fun Transaction.conflict(c: Change) =
    ChangeResult(c.id, "conflict", server = buildChanges(c.entity, listOf(c.id)).singleOrNull())

private inline fun <reified T> decodePayload(c: Change, extra: Map<String, JsonElement> = emptyMap()): T {
    val p = c.payload ?: validation("payload is required for UPSERT", "payload")
    return try {
        AppJson.decodeFromJsonElement<T>(JsonObject(p + extra))
    } catch (e: ApiException) {
        throw e
    } catch (e: IllegalArgumentException) { // SerializationException 포함
        validation(e.message ?: "invalid payload", "payload")
    }
}

/** 한 번의 push: 사용자 락 한 번, 변경마다 savepoint 로 독립 처리 */
internal fun Transaction.push(userId: UUID, changes: List<Change>): List<ChangeResult> {
    lockUser(userId)
    return changes.map { c ->
        exec("SAVEPOINT change_sp")
        try {
            val r = applyChange(userId, c)
            exec("RELEASE SAVEPOINT change_sp")
            r
        } catch (e: ApiException) {
            exec("ROLLBACK TO SAVEPOINT change_sp")
            rejected(c, e.code.name)
        } catch (e: Exception) {
            log.error("sync change failed: ${c.entity} ${c.id}", e)
            exec("ROLLBACK TO SAVEPOINT change_sp")
            rejected(c, "SERVER_ERROR")
        }
    }
}

private fun Transaction.applyChange(userId: UUID, c: Change): ChangeResult {
    if (c.entity !in ENTITIES) validation("unknown entity ${c.entity}", "entity")
    if (c.op != "UPSERT" && c.op != "DELETE") validation("op must be UPSERT or DELETE", "op")
    // 서버 시계 정밀도(ms)에 맞춘다. 같은 변경을 다시 보내도 같은 값이 된다
    val at = Instant.ofEpochMilli(c.clientUpdatedAt.toEpochMilli())
    return when (c.entity) {
        "workout_session" -> applySession(userId, c, at)
        "session_exercise" -> applySessionExercise(userId, c, at)
        "workout_set" -> applySet(userId, c, at)
        "body_measurement" -> applyBody(userId, c, at)
        else -> applyExercise(userId, c, at)
    }
}

private fun Transaction.applySession(userId: UUID, c: Change, at: Instant): ChangeResult {
    val row = WorkoutSessions.selectAll().where { WorkoutSessions.id eq c.id }.singleOrNull()
    if (row != null) {
        if (row[WorkoutSessions.userId] != userId) forbidden()
        if (row[WorkoutSessions.updatedAt] > at) return conflict(c)
    }
    if (c.op == "DELETE") {
        if (row != null) softDeleteSession(c.id, at)
        return applied(c)
    }
    val p = decodePayload<SessionPayload>(c)
    checkTz(p.tz, "payload.tz")
    if (p.endedAt != null && p.endedAt < p.startedAt) validation("endedAt must be >= startedAt", "payload.endedAt")
    upsertSessionRow(userId, c.id, p.startedAt, p.endedAt, p.tz, p.note, at)
    return applied(c)
}

private fun Transaction.sessionOwner(sessionId: UUID): ResultRow? =
    WorkoutSessions.selectAll().where { WorkoutSessions.id eq sessionId }.singleOrNull()

private fun Transaction.applySessionExercise(userId: UUID, c: Change, at: Instant): ChangeResult {
    val row = SessionExercises.selectAll().where { SessionExercises.id eq c.id }.singleOrNull()
    if (row != null) {
        val owner = sessionOwner(row[SessionExercises.sessionId])?.get(WorkoutSessions.userId)
        if (owner != userId) forbidden()
        if (row[SessionExercises.updatedAt] > at) return conflict(c)
    }
    if (c.op == "DELETE") {
        if (row != null) softDeleteSessionExercise(c.id, at)
        return applied(c)
    }
    val p = decodePayload<SessionExercisePayload>(c)
    val parentId = c.parentId ?: validation("parentId (sessionId) is required", "parentId")
    val parent = sessionOwner(parentId) ?: parentMissing("session not found")
    if (parent[WorkoutSessions.userId] != userId) forbidden()
    if (parent[WorkoutSessions.deletedAt] != null) parentMissing("session deleted")
    if (p.position < 0) validation("position must be >= 0", "payload.position")
    val ref = exerciseRefs(listOf(p.exerciseId))[p.exerciseId] ?: parentMissing("exercise not found")
    if (ref.ownerId != null && ref.ownerId != userId) validation("unknown exercise", "payload.exerciseId")
    upsertSessionExerciseRow(c.id, parentId, p.exerciseId, p.position, p.note, at)
    return applied(c)
}

private fun Transaction.applySet(userId: UUID, c: Change, at: Instant): ChangeResult {
    val row = WorkoutSets.selectAll().where { WorkoutSets.id eq c.id }.singleOrNull()
    if (row != null) {
        val se = SessionExercises.selectAll().where { SessionExercises.id eq row[WorkoutSets.sessionExerciseId] }.singleOrNull()
        val owner = se?.let { sessionOwner(it[SessionExercises.sessionId])?.get(WorkoutSessions.userId) }
        if (owner != userId) forbidden()
        if (row[WorkoutSets.updatedAt] > at) return conflict(c)
    }
    if (c.op == "DELETE") {
        if (row != null) softDeleteSet(c.id, at)
        return applied(c)
    }
    val parentId = c.parentId ?: validation("parentId (sessionExerciseId) is required", "parentId")
    val se = SessionExercises.selectAll().where { SessionExercises.id eq parentId }.singleOrNull()
        ?: parentMissing("session exercise not found")
    val session = sessionOwner(se[SessionExercises.sessionId]) ?: parentMissing("session not found")
    if (session[WorkoutSessions.userId] != userId) forbidden()
    if (se[SessionExercises.deletedAt] != null || session[WorkoutSessions.deletedAt] != null) parentMissing("parent deleted")
    val set = decodePayload<WorkoutSet>(c, mapOf("id" to JsonPrimitive(c.id.toString())))
    val type = exerciseRefs(listOf(se[SessionExercises.exerciseId]))[se[SessionExercises.exerciseId]]?.type
    upsertSetRow(parentId, checkSet(set, type, ""), at)
    return applied(c)
}

private fun Transaction.applyBody(userId: UUID, c: Change, at: Instant): ChangeResult {
    val row = BodyMeasurements.selectAll().where { BodyMeasurements.id eq c.id }.singleOrNull()
    if (row != null) {
        if (row[BodyMeasurements.userId] != userId) forbidden()
        if (row[BodyMeasurements.updatedAt] > at) return conflict(c)
    }
    if (c.op == "DELETE") {
        if (row != null) softDeleteMeasurementRow(c.id, at)
        return applied(c)
    }
    val p = decodePayload<BodyPayload>(c)
    val m = checkMeasurement(BodyMeasurement(c.id, p.measuredAt, p.weightKg, p.source))
    upsertMeasurementRow(userId, m, at)
    return applied(c)
}

private fun Transaction.applyExercise(userId: UUID, c: Change, at: Instant): ChangeResult {
    val row = Exercises.selectAll().where { Exercises.id eq c.id }.singleOrNull()
    if (row != null) {
        if (row[Exercises.ownerId] != userId) forbidden() // 기본 종목(null)·남의 종목
        if (row[Exercises.updatedAt] > at) return conflict(c)
    }
    if (c.op == "DELETE") {
        if (row != null) {
            Exercises.update({ Exercises.id eq c.id }) {
                it[deletedAt] = at
                it[updatedAt] = at
                it[serverSeq] = ChangeSeq.next
            }
        }
        return applied(c)
    }
    val p = decodePayload<ExercisePayload>(c)
    if (p.nameKo.isBlank() || p.nameKo.length > 60) validation("nameKo must be 1..60 chars", "payload.nameKo")
    if ((p.nameEn?.length ?: 0) > 60) validation("nameEn must be <= 60 chars", "payload.nameEn")
    if (p.type !in TYPES) validation("invalid type", "payload.type")
    if (p.primaryMuscle !in MUSCLES) validation("invalid primaryMuscle", "payload.primaryMuscle")
    p.secondaryMuscles.forEachIndexed { i, m -> if (m !in MUSCLES) validation("invalid muscle", "payload.secondaryMuscles[$i]") }
    val n = Exercises.update({ Exercises.id eq c.id }) {
        it[nameKo] = p.nameKo
        it[nameEn] = p.nameEn
        it[type] = p.type
        it[primaryMuscle] = p.primaryMuscle
        it[secondaryMuscles] = p.secondaryMuscles
        it[updatedAt] = at
        it[deletedAt] = null
        it[serverSeq] = ChangeSeq.next
    }
    if (n == 0) Exercises.insert {
        it[id] = c.id
        it[ownerId] = userId
        it[nameKo] = p.nameKo
        it[nameEn] = p.nameEn
        it[type] = p.type
        it[primaryMuscle] = p.primaryMuscle
        it[secondaryMuscles] = p.secondaryMuscles
        it[createdAt] = at
        it[updatedAt] = at
        it[serverSeq] = ChangeSeq.next
    }
    return applied(c)
}
