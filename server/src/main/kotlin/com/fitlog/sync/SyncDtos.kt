@file:UseSerializers(InstantSerializer::class, UUIDSerializer::class)

package com.fitlog.sync

import com.fitlog.core.InstantSerializer
import com.fitlog.core.UUIDSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.UseSerializers
import kotlinx.serialization.json.JsonObject
import java.time.Instant
import java.util.UUID

/** entity: exercise | workout_session | session_exercise | workout_set | body_measurement, op: UPSERT | DELETE */
@Serializable
data class Change(
    val entity: String,
    val id: UUID,
    val op: String,
    val parentId: UUID? = null,
    val payload: JsonObject? = null,
    val clientUpdatedAt: Instant,
    val serverSeq: Long? = null,
)

@Serializable
data class PushRequest(val changes: List<Change>)

/** status: applied | conflict | rejected. code: VALIDATION_FAILED | PARENT_MISSING | FORBIDDEN | ... */
@Serializable
data class ChangeResult(
    val id: UUID,
    val status: String,
    val code: String? = null,
    val server: Change? = null,
)

@Serializable
data class PushResponse(val results: List<ChangeResult>)

@Serializable
data class PullResponse(val changes: List<Change>, val nextSince: Long, val hasMore: Boolean)

// ---- entity 별 payload (openapi 스키마 camelCase) ----

@Serializable
internal data class SessionPayload(
    val startedAt: Instant,
    val endedAt: Instant? = null,
    val tz: String,
    val note: String? = null,
    val programInstanceId: UUID? = null,
    val planSeq: Int? = null,
    val planDayKey: String? = null,
    /** pull 전용(readOnly): APP | AI_JSON | AI_MCP | IMPORT. 앱의 출처 배지가 쓴다. push 에서는 무시 */
    val source: String? = null,
    /** pull 전용(readOnly): 가져오기 묶음 id */
    val importBatchId: UUID? = null,
)

@Serializable
internal data class SessionExercisePayload(
    val exerciseId: UUID,
    val position: Int,
    val note: String? = null,
    val liftKey: String? = null,
    val accessory: Boolean = false,
)

@Serializable
internal data class BodyPayload(
    val measuredAt: Instant,
    val weightKg: Double,
    val source: String? = null,
    /** pull 전용(readOnly) */
    val importBatchId: UUID? = null,
)

/** ExerciseInput */
@Serializable
internal data class ExercisePayload(
    val id: UUID? = null,
    val nameKo: String,
    val nameEn: String? = null,
    val type: String,
    val primaryMuscle: String,
    val secondaryMuscles: List<String> = emptyList(),
    /** pull 전용(readOnly): 출처와 가져오기 묶음 id. push 에서는 무시 */
    val source: String? = null,
    val importBatchId: UUID? = null,
)
