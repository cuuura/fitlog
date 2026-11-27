package com.fitlog.sync

import com.fitlog.core.AppJson
import com.fitlog.core.BodyMeasurements
import com.fitlog.core.Exercises
import com.fitlog.core.SessionExercises
import com.fitlog.core.WorkoutSessions
import com.fitlog.core.WorkoutSets
import com.fitlog.body.BodyMeasurement
import com.fitlog.session.toWorkoutSet
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.encodeToJsonElement
import org.jetbrains.exposed.sql.SqlExpressionBuilder.inList
import org.jetbrains.exposed.sql.Transaction
import org.jetbrains.exposed.sql.selectAll
import java.util.UUID

internal const val PULL_LIMIT = 500

internal val ENTITIES = setOf("exercise", "workout_session", "session_exercise", "workout_set", "body_measurement")

private inline fun <reified T> payloadOf(v: T): JsonObject = AppJson.encodeToJsonElement(v).jsonObject

/** 지정한 엔티티 행들을 Change 로 만든다(삭제된 행은 op=DELETE, payload 없음). 소유 확인은 호출자 몫 */
internal fun Transaction.buildChanges(entity: String, ids: Collection<UUID>): List<Change> {
    if (ids.isEmpty()) return emptyList()
    return when (entity) {
        "exercise" -> Exercises.selectAll().where { Exercises.id inList ids }.map {
            val del = it[Exercises.deletedAt] != null
            Change(
                entity, it[Exercises.id], if (del) "DELETE" else "UPSERT", null,
                if (del) null else payloadOf(
                    ExercisePayload(
                        it[Exercises.id], it[Exercises.nameKo], it[Exercises.nameEn], it[Exercises.type],
                        it[Exercises.primaryMuscle], it[Exercises.secondaryMuscles],
                        it[Exercises.sourceCol], it[Exercises.importBatchId],
                    ),
                ),
                it[Exercises.updatedAt], it[Exercises.serverSeq],
            )
        }
        "workout_session" -> WorkoutSessions.selectAll().where { WorkoutSessions.id inList ids }.map {
            val del = it[WorkoutSessions.deletedAt] != null
            Change(
                entity, it[WorkoutSessions.id], if (del) "DELETE" else "UPSERT", null,
                if (del) null else payloadOf(
                    SessionPayload(
                        it[WorkoutSessions.startedAt], it[WorkoutSessions.endedAt], it[WorkoutSessions.tz], it[WorkoutSessions.note],
                        it[WorkoutSessions.programInstanceId], it[WorkoutSessions.planSeq], it[WorkoutSessions.planDayKey],
                        it[WorkoutSessions.sourceCol], it[WorkoutSessions.importBatchId],
                    ),
                ),
                it[WorkoutSessions.updatedAt], it[WorkoutSessions.serverSeq],
            )
        }
        "session_exercise" -> SessionExercises.selectAll().where { SessionExercises.id inList ids }.map {
            val del = it[SessionExercises.deletedAt] != null
            Change(
                entity, it[SessionExercises.id], if (del) "DELETE" else "UPSERT", it[SessionExercises.sessionId],
                if (del) null else payloadOf(
                    SessionExercisePayload(
                        it[SessionExercises.exerciseId], it[SessionExercises.position], it[SessionExercises.note],
                        it[SessionExercises.liftKey], it[SessionExercises.accessory],
                    ),
                ),
                it[SessionExercises.updatedAt], it[SessionExercises.serverSeq],
            )
        }
        "workout_set" -> WorkoutSets.selectAll().where { WorkoutSets.id inList ids }.map {
            val del = it[WorkoutSets.deletedAt] != null
            Change(
                entity, it[WorkoutSets.id], if (del) "DELETE" else "UPSERT", it[WorkoutSets.sessionExerciseId],
                if (del) null else payloadOf(it.toWorkoutSet()),
                it[WorkoutSets.updatedAt], it[WorkoutSets.serverSeq],
            )
        }
        "body_measurement" -> BodyMeasurements.selectAll().where { BodyMeasurements.id inList ids }.map {
            val del = it[BodyMeasurements.deletedAt] != null
            Change(
                entity, it[BodyMeasurements.id], if (del) "DELETE" else "UPSERT", null,
                if (del) null else payloadOf(
                    BodyPayload(
                        it[BodyMeasurements.measuredAt], it[BodyMeasurements.weightKg].toDouble(),
                        it[BodyMeasurements.sourceCol], it[BodyMeasurements.importBatchId],
                    ),
                ),
                it[BodyMeasurements.updatedAt], it[BodyMeasurements.serverSeq],
            )
        }
        else -> emptyList()
    }
}

internal fun Transaction.pull(userId: UUID, since: Long): PullResponse {
    val u = userId.toString()
    // 5개 테이블에서 (entity, id, server_seq)만 뽑아 정렬·제한한 뒤 엔티티별로 행을 읽는다
    val sql = """
        SELECT entity, id, server_seq FROM (
            SELECT 'exercise' AS entity, id, server_seq FROM exercise WHERE owner_id = '$u' AND server_seq > $since
            UNION ALL
            SELECT 'workout_session', id, server_seq FROM workout_session WHERE user_id = '$u' AND server_seq > $since
            UNION ALL
            SELECT 'session_exercise', se.id, se.server_seq FROM session_exercise se
                JOIN workout_session s ON s.id = se.session_id WHERE s.user_id = '$u' AND se.server_seq > $since
            UNION ALL
            SELECT 'workout_set', ws.id, ws.server_seq FROM workout_set ws
                JOIN session_exercise se ON se.id = ws.session_exercise_id
                JOIN workout_session s ON s.id = se.session_id WHERE s.user_id = '$u' AND ws.server_seq > $since
            UNION ALL
            SELECT 'body_measurement', id, server_seq FROM body_measurement WHERE user_id = '$u' AND server_seq > $since
        ) t ORDER BY server_seq LIMIT ${PULL_LIMIT + 1}
    """.trimIndent()
    val heads = exec(sql) { rs ->
        buildList {
            while (rs.next()) add(Triple(rs.getString(1), UUID.fromString(rs.getString(2)), rs.getLong(3)))
        }
    }.orEmpty()
    val hasMore = heads.size > PULL_LIMIT
    val page = heads.take(PULL_LIMIT)
    val byEntity = page.groupBy({ it.first }, { it.second })
    val loaded = byEntity.flatMap { (entity, ids) -> buildChanges(entity, ids) }
        .associateBy { it.id }
    val changes = page.mapNotNull { (entity, id, seq) ->
        loaded[id]?.takeIf { it.entity == entity && it.serverSeq == seq }
    }
    return PullResponse(changes, page.lastOrNull()?.third ?: since, hasMore)
}
