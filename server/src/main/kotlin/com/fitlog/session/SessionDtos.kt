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
)

@Serializable
data class SessionExercise(
    val id: UUID,
    val exerciseId: UUID,
    val position: Int,
    val note: String? = null,
    val sets: List<WorkoutSet> = emptyList(),
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
)

@Serializable
data class LastSets(val sessionId: UUID, val startedAt: Instant, val sets: List<WorkoutSet>)
