package com.fitlog.program.schema

import com.fitlog.engine.EngineTestUtil.E
import com.fitlog.engine.EngineTestUtil.step
import com.fitlog.engine.EngineTestUtil.weights
import com.fitlog.engine.ProgramDefinition
import com.fitlog.engine.Rule
import com.fitlog.program.catalog.ProgramTemplates
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** ppl-3day / upper-lower-4day / phul-4day : 검증 + 구조 + 더블 프로그레션 시뮬레이션 (DB 없음) */
class SplitTemplatesTest {
    private val seedIds: Set<String> by lazy {
        val text = javaClass.getResourceAsStream("/db/SEED_EXERCISES.md")!!.readBytes().toString(Charsets.UTF_8)
        Regex("`(019b76da-4000-7000-8000-[0-9a-f]{12})`").findAll(text).map { it.groupValues[1] }.toSet()
    }
    private val resolver: ExerciseResolver = { ref ->
        val id = ref.id
        if (id != null && id in seedIds) ResolveResult.Found(id) else ResolveResult.Failed("unknown exercise $id")
    }

    private fun load(key: String): ProgramDefinition {
        val r = ProgramValidator.validate(ProgramTemplates.readJson(key), resolver)
        assertTrue(r is ValidationResult.Valid, "$key: ${(r as? ValidationResult.Invalid)?.errors}")
        return (r as ValidationResult.Valid).definition
    }

    private fun checkCommon(p: ProgramDefinition, dayKeys: List<String>) {
        assertEquals(dayKeys, p.days.map { it.key })
        val lifts = p.days.flatMap { it.exercises }.map { it.lift }
        assertEquals(lifts.size, lifts.toSet().size, "각 lift 는 한 번씩만")
        assertTrue(p.progression.values.all { it is Rule.Double })
        assertTrue(p.days.flatMap { it.exercises }.all { !it.accessory && it.restSec != null })
        assertTrue(p.days.flatMap { it.exercises }.flatMap { it.sets }.all { it.repsMax != null && it.repsMax!! > it.reps })
    }

    /** 첫 운동 하루: 시작 무게 없이 계획 → 모든 세트 상한 수행 → 무게 확정 후 증량 */
    private fun checkDoubleCycle(p: ProgramDefinition, liftKey: String, inc: Double, startKg: Double) {
        var s = E.initialState(p, emptyMap(), mapOf(liftKey to startKg))
        val dayIdx = p.days.indexOfFirst { d -> d.exercises.any { it.lift == liftKey } }
        repeat(dayIdx) { s = step(p, s) }
        val day = E.plan(p, s, 1).single()
        assertEquals(startKg, weights(day, liftKey)[0])
        s = step(p, s) { ex, set, _ -> if (ex.key == liftKey) set.targetRepsMax!! else set.targetReps }
        assertEquals(startKg + inc, s.working[liftKey])
    }

    @Test
    fun `ppl structure and progression`() {
        val p = load("ppl-3day")
        checkCommon(p, listOf("PUSH", "PULL", "LEGS"))
        assertEquals(listOf("bench", "row", "squat"), p.days.map { it.exercises[0].lift })
        assertEquals(4, p.days[0].exercises[0].sets[0].count)
        assertEquals(5, p.days[0].exercises[0].sets[0].reps)
        assertEquals(8, p.days[0].exercises[0].sets[0].repsMax)
        checkDoubleCycle(p, "bench", 2.5, 60.0)
        checkDoubleCycle(p, "squat", 5.0, 80.0)
    }

    @Test
    fun `ppl starts without weights and plans null weight`() {
        val p = load("ppl-3day")
        val s = E.initialState(p, emptyMap(), emptyMap())
        assertNull(weights(E.plan(p, s, 1).single(), "bench")[0])
    }

    @Test
    fun `ppl in range keeps weight and three misses deload`() {
        val p = load("ppl-3day")
        var s = E.initialState(p, emptyMap(), mapOf("bench" to 60.0))
        s = step(p, s) { ex, set, _ -> if (ex.key == "bench") 6 else set.targetReps }
        assertEquals(60.0, s.working["bench"])
        repeat(3) {
            s = step(p, s) // PULL
            s = step(p, s) // LEGS
            s = step(p, s) { ex, set, _ -> if (ex.key == "bench") 4 else set.targetReps }
        }
        assertEquals(54.0, s.working["bench"])
    }

    @Test
    fun `upper lower structure`() {
        val p = load("upper-lower-4day")
        checkCommon(p, listOf("UPPER_A", "LOWER_A", "UPPER_B", "LOWER_B"))
        assertEquals(listOf(4, 4), listOf(p.days[0].exercises[0], p.days[1].exercises[0]).map { it.sets[0].count })
        assertEquals(listOf(5 to 6, 5 to 6), listOf(p.days[0].exercises[0], p.days[1].exercises[0]).map { it.sets[0].reps to it.sets[0].repsMax })
        assertTrue(p.days[2].exercises.all { it.sets[0].count == 3 })
        assertTrue(p.days[2].exercises.any { it.sets[0].reps == 8 && it.sets[0].repsMax == 12 })
        checkDoubleCycle(p, "bench", 2.5, 70.0)
        checkDoubleCycle(p, "squat", 5.0, 90.0)
        checkDoubleCycle(p, "hack", 5.0, 80.0)
    }

    @Test
    fun `upper lower four days advance two weeks`() {
        val p = load("upper-lower-4day")
        var s = E.initialState(p, emptyMap(), mapOf("bench" to 70.0, "squat" to 90.0, "incline_db" to 20.0))
        repeat(8) { s = step(p, s) { _, set, _ -> set.targetRepsMax ?: set.targetReps } }
        assertEquals(70.0 + 2 * 2.5, s.working["bench"])
        assertEquals(90.0 + 2 * 5.0, s.working["squat"])
        assertEquals(20.0 + 2 * 2.5, s.working["incline_db"])
    }

    @Test
    fun `phul structure follows power then hypertrophy`() {
        val p = load("phul-4day")
        checkCommon(p, listOf("UPPER_POWER", "LOWER_POWER", "UPPER_HYPER", "LOWER_HYPER"))
        for (i in 0..1) {
            val main = p.days[i].exercises[0].sets[0]
            assertEquals(3 to 5, main.reps to main.repsMax)
            assertTrue(main.count in 3..4)
        }
        assertEquals(listOf("bench", "incline_db", "row", "pulldown", "ohp", "curl", "skull"), p.days[0].exercises.map { it.lift })
        assertTrue(p.days[0].exercises[0].restSec!! >= 150)
        assertTrue(p.days[2].exercises.all { it.sets[0].repsMax == 12 && it.sets[0].reps == 8 })
        assertTrue(p.days[3].exercises.all { it.sets[0].count == 3 })
        checkDoubleCycle(p, "bench", 2.5, 80.0)
        checkDoubleCycle(p, "deadlift", 5.0, 120.0)
        checkDoubleCycle(p, "front_squat", 5.0, 70.0)
    }

    @Test
    fun `phul one cycle all upper limit adds weight on every lift`() {
        val p = load("phul-4day")
        val start = mapOf("bench" to 80.0, "squat" to 100.0, "deadlift" to 120.0, "incline_bb" to 50.0)
        var s = E.initialState(p, emptyMap(), start)
        repeat(4) { s = step(p, s) { _, set, _ -> set.targetRepsMax ?: set.targetReps } }
        assertEquals(82.5, s.working["bench"])
        assertEquals(105.0, s.working["squat"])
        assertEquals(125.0, s.working["deadlift"])
        assertEquals(52.5, s.working["incline_bb"])
    }
}
