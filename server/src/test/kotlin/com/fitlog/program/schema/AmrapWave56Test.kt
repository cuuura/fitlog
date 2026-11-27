package com.fitlog.program.schema

import com.fitlog.engine.EngineTestUtil.E
import com.fitlog.engine.EngineTestUtil.performed
import com.fitlog.engine.ProgramDefinition
import com.fitlog.engine.ProgramState
import com.fitlog.program.catalog.ProgramTemplates
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class AmrapWave56Test {
    private val seedIds: Set<String> by lazy {
        val text = javaClass.getResourceAsStream("/db/SEED_EXERCISES.md")!!.readBytes().toString(Charsets.UTF_8)
        Regex("`(019b76da-4000-7000-8000-[0-9a-f]{12})`").findAll(text).map { it.groupValues[1] }.toSet()
    }
    private val resolver: ExerciseResolver = { ref ->
        val id = ref.id
        if (id != null && id in seedIds) ResolveResult.Found(id) else ResolveResult.Failed("unknown exercise $id")
    }

    private fun def(key: String): ProgramDefinition {
        val r = ProgramValidator.validate(ProgramTemplates.readJson(key), resolver)
        assertTrue(r is ValidationResult.Valid, "$key: ${(r as? ValidationResult.Invalid)?.errors}")
        return r.definition
    }

    private fun start(p: ProgramDefinition) = E.initialState(
        p, mapOf("bench" to 100.0, "ohp" to 60.0, "squat" to 120.0, "deadlift" to 140.0), emptyMap(),
    )

    /** 한 주를 수행한다. 표 판정 세트는 [amrapReps] 회, 나머지는 목표대로 */
    private fun week(p: ProgramDefinition, s0: ProgramState, amrapReps: (String) -> Int): ProgramState {
        var s = s0
        repeat(p.days.size) {
            val day = E.plan(p, s, 1).single()
            val ev = performed(day, repsFor = { ex, set, i ->
                val de = p.days[day.dayIndex].exercises.first { it.lift == ex.key }
                val idx = de.amrapSet ?: ex.sets.indexOfFirst { it.isAmrap }
                if (!ex.accessory && de.countsForProgression && i == idx) amrapReps(ex.key) else set.targetReps
            })
            s = E.apply(p, s, ev)
        }
        return s
    }

    @Test
    fun five_day_structure() {
        val p = def("nsuns-5day")
        assertEquals("AMRAP 볼륨 웨이브 5일", p.name)
        assertEquals(5, p.days.size)
        val bench = p.days.flatMap { it.exercises }.filter { it.lift == "bench" }
        assertEquals(listOf(false, true), bench.map { it.countsForProgression })
        val ohp = p.days.flatMap { it.exercises }.filter { it.lift == "ohp" }
        assertEquals(listOf(false, true), ohp.map { it.countsForProgression })
        assertEquals(9, p.days[1].exercises[0].sets.sumOf { it.count })
        assertEquals(8, p.days[1].exercises[1].sets.sumOf { it.count })
    }

    @Test
    fun six_day_structure() {
        val p = def("nsuns-6day")
        assertEquals("AMRAP 볼륨 웨이브 6일", p.name)
        assertEquals(6, p.days.size)
        val squat = p.days.flatMap { it.exercises }.filter { it.lift == "squat" }
        assertEquals(listOf(true, false), squat.map { it.countsForProgression })
        assertEquals(8, p.days[5].exercises[0].sets.sumOf { it.count })
    }

    @Test
    fun five_day_three_weeks_all_success() {
        val p = def("nsuns-5day")
        var s = start(p)
        // 1+ 세트 5회: 벤치·OHP +2.5, 스쿼트·데드 +5, 주 한 번만 판정
        repeat(3) { w ->
            s = week(p, s) { 5 }
            assertEquals(100.0 + 2.5 * (w + 1), s.tm["bench"])
            assertEquals(60.0 + 2.5 * (w + 1), s.tm["ohp"])
            assertEquals(120.0 + 5.0 * (w + 1), s.tm["squat"])
            assertEquals(140.0 + 5.0 * (w + 1), s.tm["deadlift"])
        }
    }

    @Test
    fun five_day_zero_gain_week_keeps_tm() {
        val p = def("nsuns-5day")
        val s = week(p, start(p)) { 1 }
        assertEquals(100.0, s.tm["bench"])
        assertEquals(120.0, s.tm["squat"])
    }

    @Test
    fun six_day_three_weeks_squat_judged_once() {
        val p = def("nsuns-6day")
        var s = start(p)
        repeat(3) { w ->
            s = week(p, s) { 5 }
            assertEquals(120.0 + 5.0 * (w + 1), s.tm["squat"])
            assertEquals(100.0 + 2.5 * (w + 1), s.tm["bench"])
            assertEquals(140.0 + 5.0 * (w + 1), s.tm["deadlift"])
        }
        assertEquals(4, s.week)
    }
}
