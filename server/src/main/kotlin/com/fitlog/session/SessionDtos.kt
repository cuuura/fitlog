@file:UseSerializers(InstantSerializer::class, UUIDSerializer::class)

package com.fitlog.session

import com.fitlog.core.InstantSerializer
import com.fitlog.core.UUIDSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.UseSerializers
import java.time.Instant
import java.util.UUID

@Serializable
data class WorkoutSet(
    val id: UUID,
    val position: Int,
    val isWarmup: Boolean = false,
    /** v1.2: NORMAL | DROP | FAILURE (isWarmup 과 별개) */
    val setType: String = "NORMAL",
    val weightKg: Double? = null,
    val addedWeightKg: Double? = null,
    val reps: Int? = null,
    val durationSec: Int? = null,
    val distanceM: Double? = null,
    val bandLevel: String? = null,
    val rpe: Double? = null,
    val rir: Int? = null,
    val restSec: Int? = null,
    val note: String? = null,
    val completedAt: Instant? = null,
    // v0.2 계획 연결(모두 선택)
    val plannedSetKey: String? = null,
    val targetReps: Int? = null,
    val targetWeightKg: Double? = null,
    val isAmrap: Boolean = false,
    // v1.0 예정 운동 목표(모두 선택)
    val targetRepsMax: Int? = null,
    val targetRir: Int? = null,
    val targetRestSec: Int? = null,
)

@Serializable
data class SessionExercise(
    val id: UUID,
    val exerciseId: UUID,
    val position: Int,
    val note: String? = null,
    val sets: List<WorkoutSet> = emptyList(),
    val liftKey: String? = null,
    val accessory: Boolean = false,
    /** v1.2: 슈퍼세트 묶음 글자(1~8자) 또는 null */
    val supersetGroup: String? = null,
)

@Serializable
data class Session(
    val id: UUID,
    val startedAt: Instant,
    val endedAt: Instant? = null,
    val tz: String,
    val note: String? = null,
    /** readOnly: 요청 값은 무시한다 */
    val source: String? = null,
    val exercises: List<SessionExercise> = emptyList(),
    /** readOnly */
    val updatedAt: Instant? = null,
    val programInstanceId: UUID? = null,
    val planSeq: Int? = null,
    val planDayKey: String? = null,
    /** readOnly (v0.3): 가져오기 묶음으로 만들었으면 그 id, 아니면 생략 */
    val importBatchId: UUID? = null,
    /** v1.0: 이 세션이 시작한 예정 운동(scheduled_workout) */
    val scheduledWorkoutId: UUID? = null,
)

@Serializable
data class SessionSummary(
    val id: UUID,
    val startedAt: Instant,
    val endedAt: Instant? = null,
    val tz: String,
    val exerciseCount: Int,
    val setCount: Int,
    val totalVolumeKg: Double,
    /** v0.3 출처 */
    val source: String? = null,
    val importBatchId: UUID? = null,
)

@Serializable
data class LastSets(val sessionId: UUID, val startedAt: Instant, val sets: List<WorkoutSet>)
