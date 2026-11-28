@file:UseSerializers(UUIDSerializer::class)

package com.fitlog.program.instance

import com.fitlog.core.UUIDSerializer
import com.fitlog.engine.PlannedExercise
import kotlinx.serialization.Serializable
import kotlinx.serialization.UseSerializers
import java.util.UUID

@Serializable
data class StartInstance(
    val id: UUID,
    val programId: UUID,
    /** yyyy-MM-dd */
    val startDate: String,
    val tz: String,
    val skipPolicy: String? = null,
    val tm: Map<String, Double> = emptyMap(),
    val working: Map<String, Double> = emptyMap(),
)

/** Instance.state: engine.md State 중 화면에 필요한 것 */
@Serializable
data class InstanceState(
    val tm: Map<String, Double> = emptyMap(),
    val working: Map<String, Double> = emptyMap(),
    val stage: Map<String, Int> = emptyMap(),
    val failStreak: Map<String, Int> = emptyMap(),
    val week: Int = 1,
    val cycle: Int = 1,
    val seq: Int = 0,
)

@Serializable
data class PlannedWorkout(
    val instanceId: UUID,
    val planSeq: Int,
    val dayIndex: Int,
    val dayKey: String,
    val dayName: String,
    val week: Int,
    val cycle: Int,
    /** FIXED_DATE 일 때만, yyyy-MM-dd */
    val scheduledDate: String? = null,
    val confirmed: Boolean = false,
    val exercises: List<PlannedExercise>,
)

@Serializable
data class Instance(
    val id: UUID,
    val programId: UUID,
    val name: String,
    val status: String,
    val skipPolicy: String,
    val startDate: String,
    val state: InstanceState,
    val next: PlannedWorkout? = null,
    /** v1.2: {dayKey: 정의 종목 인덱스 순열}. 없으면 빈 객체 */
    val dayOrder: Map<String, List<Int>> = emptyMap(),
)

/** PUT /program-instances/{id}/definition */
@Serializable
data class ReplaceDefinition(
    val definition: kotlinx.serialization.json.JsonElement,
    val tm: Map<String, Double> = emptyMap(),
    val working: Map<String, Double> = emptyMap(),
)

/** POST /program-instances/{id}/swap */
@Serializable
data class SwapLift(
    val liftKey: String,
    val exerciseId: UUID,
    val tm: Double? = null,
    val working: Double? = null,
)

/** PUT /program-instances/{id}/day-order */
@Serializable
data class DayOrderRequest(val dayKey: String, val order: List<Int>)

@Serializable
data class DayOrderResponse(val dayOrder: Map<String, List<Int>>)

@Serializable
data class AdjustInput(
    val tm: Map<String, Double> = emptyMap(),
    val working: Map<String, Double> = emptyMap(),
)

@Serializable
data class PatchInstance(
    val status: String? = null,
    val skipPolicy: String? = null,
    val adjust: AdjustInput? = null,
)

@Serializable
data class SkipRequest(val planSeq: Int)

@Serializable
data class Accessory(
    val id: UUID,
    val dayKey: String,
    val exerciseId: UUID,
    val position: Int,
    val sets: Int,
    val reps: Int,
    val weightKg: Double? = null,
)
