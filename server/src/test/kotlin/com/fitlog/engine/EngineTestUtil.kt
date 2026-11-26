package com.fitlog.engine

import com.fitlog.core.AppJson
import java.io.File

/** 엔진 테스트 공용 도구 */
object EngineTestUtil {
    val E = ProgramEngine

    fun template(name: String): ProgramDefinition =
        AppJson.decodeFromString(File("../contracts/v0.2/templates/$name").readText())

    /** 계획대로(목표 횟수·계획 무게) 수행한 COMPLETED 이벤트. [repsFor] 로 일부 세트만 바꾼다 */
    fun performed(
        day: PlannedDay,
        repsFor: (ex: PlannedExercise, set: PlannedSet, setIndex: Int) -> Int = { _, s, _ -> s.targetReps },
        weightFor: (ex: PlannedExercise, set: PlannedSet, setIndex: Int) -> Double? = { _, s, _ -> s.targetWeightKg },
    ): ProgramEvent.Completed = ProgramEvent.Completed(
        day.planSeq,
        day.exercises.map { ex ->
            PerformedExercise(
                ex.key,
                ex.accessory,
                ex.sets.mapIndexed { i, s -> PerformedSet(s.plannedSetKey, repsFor(ex, s, i), weightFor(ex, s, i), s.isWarmup) },
            )
        },
    )

    /** 확정 회차 하나를 계획해 수행하고 다음 상태를 돌려준다 */
    fun step(
        p: ProgramDefinition,
        s: ProgramState,
        settings: EngineSettings = EngineSettings(),
        repsFor: (ex: PlannedExercise, set: PlannedSet, setIndex: Int) -> Int = { _, set, _ -> set.targetReps },
    ): ProgramState {
        val day = E.plan(p, s, 1, settings).single()
        return E.apply(p, s, performed(day, repsFor), settings)
    }

    fun weights(day: PlannedDay, key: String): List<Double?> =
        day.exercises.first { it.key == key }.sets.map { it.targetWeightKg }

    fun lift(id: String) = Lift(ExerciseRef(id = id))

    fun spec(reps: Int, load: Load, count: Int = 1, amrap: Boolean = false, warmup: Boolean = false, weekly: List<WeeklyOverride>? = null) =
        SetSpec(count = count, reps = reps, amrap = amrap, warmup = warmup, load = load, weekly = weekly)
}
