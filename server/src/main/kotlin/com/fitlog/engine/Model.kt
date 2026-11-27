package com.fitlog.engine

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/*
 * contracts/v0.2/program.schema.json 의 Kotlin 표현 (트랙 리드 소유, 엔진·검증기·API 공용).
 * 엔진 패키지는 DB·HTTP·시계에 의존하지 않는다. 이 파일도 kotlinx.serialization 외 의존 없음.
 * Load·Rule 은 "type" 판별자로 직렬화된다(kotlinx 기본 classDiscriminator = "type").
 */

@Serializable
data class ProgramDefinition(
    val schemaVersion: Int,
    val name: String,
    val description: String? = null,
    val tmPercent: Double = 0.9,
    val workingPercent: Double = 0.8,
    val roundingKg: Double = 2.5,
    val barKg: Double = 20.0,
    val cycleWeeks: Int? = null,
    val lifts: Map<String, Lift>,
    val progression: Map<String, Rule> = emptyMap(),
    val days: List<Day>,
)

/** 저장된 정의에서는 항상 id 가 채워져 있다(검증기가 name 을 id 로 푼다) */
@Serializable
data class ExerciseRef(val id: String? = null, val name: String? = null)

@Serializable
data class Lift(val exercise: ExerciseRef, val tmFrom: String? = null)

@Serializable
sealed interface Load {
    @Serializable @SerialName("PERCENT_TM")
    data class PercentTm(val value: Double, val of: String? = null) : Load

    @Serializable @SerialName("WORKING")
    data class Working(val value: Double = 1.0, val of: String? = null) : Load

    @Serializable @SerialName("FIXED")
    data class Fixed(val kg: Double) : Load

    @Serializable @SerialName("BODYWEIGHT")
    data object Bodyweight : Load

    @Serializable @SerialName("NONE")
    data object NoLoad : Load
}

@Serializable
data class WeeklyOverride(
    val reps: Int? = null,
    val amrap: Boolean? = null,
    val value: Double? = null,
    val repsMax: Int? = null,
    val count: Int? = null,
    val addKg: Double? = null,
    val skip: Boolean? = null,
)

@Serializable
data class SetSpec(
    val count: Int = 1,
    val reps: Int,
    val amrap: Boolean = false,
    val warmup: Boolean = false,
    val load: Load,
    val weekly: List<WeeklyOverride>? = null,
    val repsMax: Int? = null,
    val restSec: Int? = null,
)

@Serializable
data class DayExercise(
    val lift: String,
    val accessory: Boolean = false,
    val amrapSet: Int? = null,
    val sets: List<SetSpec>,
    val countsForProgression: Boolean = true,
    val restSec: Int? = null,
)

@Serializable
data class Day(val key: String, val name: String, val weekday: String? = null, val exercises: List<DayExercise>)

@Serializable
data class TableRow(val minReps: Int, val maxReps: Int? = null, val incrementKg: Double)

@Serializable
data class Stage(val sets: Int, val reps: Int, val lastAmrap: Boolean = false)

@Serializable
sealed interface Rule {
    @Serializable @SerialName("LINEAR")
    data class Linear(val incrementKg: kotlin.Double, val failuresBeforeDeload: Int = 3, val deloadPercent: kotlin.Double = 0.1) : Rule

    @Serializable @SerialName("AMRAP_TABLE")
    data class AmrapTable(
        val table: List<TableRow>,
        val applyAt: ApplyAt = ApplyAt.WEEK_END,
        val failuresBeforeDeload: Int = 2,
        val deloadPercent: kotlin.Double = 0.1,
    ) : Rule

    @Serializable @SerialName("CYCLE")
    data class Cycle(val incrementKg: kotlin.Double, val deloadPercent: kotlin.Double = 0.1) : Rule

    @Serializable @SerialName("STAGES")
    data class Stages(val incrementKg: kotlin.Double, val stages: List<Stage>, val deloadPercent: kotlin.Double = 0.15) : Rule

    @Serializable @SerialName("DOUBLE")
    data class Double(val incrementKg: kotlin.Double, val failuresBeforeDeload: Int = 3, val deloadPercent: kotlin.Double = 0.1) : Rule

    @Serializable @SerialName("NONE")
    data object NoRule : Rule
}

@Serializable
enum class ApplyAt { WEEK_END, SESSION }

// ---------------------------------------------------------------- 상태·이벤트·계획

/** engine.md 1절. 인스턴스마다 하나. JSON 으로 저장된다 */
@Serializable
data class ProgramState(
    val tm: Map<String, Double> = emptyMap(),
    val working: Map<String, Double> = emptyMap(),
    val stage: Map<String, Int> = emptyMap(),
    val failStreak: Map<String, Int> = emptyMap(),
    val pendingTmDelta: Map<String, Double> = emptyMap(),
    val week: Int = 1,
    val cycle: Int = 1,
    val nextDayIndex: Int = 0,
    /** 지금까지 반영한 회차 수. COMPLETED·SKIPPED 마다 +1, ADJUSTED 는 그대로. 다음 회차의 planSeq = seq + 1 */
    val seq: Int = 0,
)

@Serializable
enum class SkipPolicy { SHIFT, FIXED_DATE }

@Serializable
enum class E1rmFormula { EPLEY, BRZYCKI, LOMBARDI }

data class EngineSettings(
    val e1rmFormula: E1rmFormula = E1rmFormula.EPLEY,
    /** 바벨 종목 id(type=BARBELL). 계획 무게가 barKg 미만이면 barKg 로 올린다. API 계층이 DB 에서 채운다 */
    val barbellExerciseIds: Set<String> = emptySet(),
)

/** 실제로 수행한 세트. plannedSetKey 로 계획과 잇는다(없으면 계획 밖 추가 세트) */
data class PerformedSet(
    val plannedSetKey: String?,
    val reps: Int?,
    val weightKg: Double?,
    val isWarmup: Boolean = false,
)

data class PerformedExercise(val liftKey: String?, val accessory: Boolean, val sets: List<PerformedSet>)

sealed interface ProgramEvent {
    /** 끝난 세션 하나. exercises 는 그 세션의 (삭제 안 된) 종목·세트 */
    data class Completed(val planSeq: Int, val exercises: List<PerformedExercise>) : ProgramEvent

    data class Skipped(val planSeq: Int, val policy: SkipPolicy) : ProgramEvent

    /** PATCH adjust: 주어진 키의 tm/working 을 그 값으로 바꾼다 */
    data class Adjusted(val tm: Map<String, Double>, val working: Map<String, Double>) : ProgramEvent
}

@Serializable
data class PlannedSet(
    val plannedSetKey: String,
    val targetReps: Int,
    val targetWeightKg: Double? = null,
    val isAmrap: Boolean,
    val isWarmup: Boolean,
    val targetRepsMax: Int? = null,
    val restSec: Int? = null,
)

@Serializable
data class PlannedExercise(
    val key: String,
    val exerciseId: String,
    val accessory: Boolean,
    val sets: List<PlannedSet>,
)

/** engine.md 7절. instanceId·scheduledDate 는 API 계층이 붙인다 */
@Serializable
data class PlannedDay(
    val planSeq: Int,
    val dayIndex: Int,
    val dayKey: String,
    val dayName: String,
    val week: Int,
    val cycle: Int,
    val confirmed: Boolean,
    val exercises: List<PlannedExercise>,
)

@Serializable
enum class Needs { TM, WORKING }
