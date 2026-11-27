package com.fitlog.program.schema

import com.fitlog.engine.EngineTestUtil.E
import com.fitlog.engine.EngineTestUtil.step
import com.fitlog.engine.EngineTestUtil.weights
import com.fitlog.engine.ProgramDefinition
import com.fitlog.engine.ProgramState
import com.fitlog.engine.Rule
import com.fitlog.program.catalog.ProgramTemplates
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** novice-3x5-ab / greyskull-lp / madcow-5x5 : 검증 + 구조 + 엔진 시뮬레이션 (DB 없음) */
class NoviceLinearTest {
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

    // ---- 3x5 A/B
    private val nv = load("novice-3x5-ab")
    private fun nvStart() = E.initialState(nv, emptyMap(), mapOf("squat" to 60.0, "bench" to 40.0, "ohp" to 30.0, "deadlift" to 70.0))

    @Test
    fun `novice structure`() {
        assertEquals(listOf("A", "B"), nv.days.map { it.key })
        assertEquals(listOf("squat", "bench", "deadlift"), nv.days[0].exercises.map { it.lift })
        assertEquals(listOf("squat", "ohp", "deadlift"), nv.days[1].exercises.map { it.lift })
        assertEquals(3, nv.days[0].exercises[0].sets[0].count)
        assertEquals(1, nv.days[0].exercises[2].sets[0].count)
        assertEquals(5.0, (nv.progression["deadlift"] as Rule.Linear).incrementKg)
        assertEquals(3, (nv.progression["squat"] as Rule.Linear).failuresBeforeDeload)
    }

    @Test
    fun `novice two weeks all success`() {
        var s = nvStart()
        repeat(6) { s = step(nv, s) } // A B A B A B = squat 6회, bench 3회, ohp 3회, dead 6회
        assertEquals(60.0 + 6 * 2.5, s.working["squat"])
        assertEquals(40.0 + 3 * 2.5, s.working["bench"])
        assertEquals(30.0 + 3 * 1.25, s.working["ohp"])
        assertEquals(70.0 + 6 * 5.0, s.working["deadlift"])
    }

    @Test
    fun `novice three straight squat failures deload 10 percent`() {
        var s = nvStart()
        repeat(3) { s = step(nv, s) { ex, _, i -> if (ex.key == "squat" && i == 2) 4 else 5 } }
        assertEquals(54.0, s.working["squat"])
        assertEquals(0, s.failStreak["squat"])
        assertEquals(List(3) { 53.75 }, weights(E.plan(nv, s, 1).single(), "squat")) // 54 -> 1.25 단위 반올림
    }

    // ---- Greyskull
    private val gs = load("greyskull-lp")
    private fun gsStart() = E.initialState(gs, mapOf("ohp" to 40.0, "squat" to 100.0, "bench" to 60.0, "deadlift" to 120.0), emptyMap())

    @Test
    fun `greyskull structure`() {
        val sq = gs.days[0].exercises.first { it.lift == "squat" }
        assertEquals(listOf(2 to false, 1 to true), sq.sets.map { it.count to it.amrap })
        assertTrue(gs.days.flatMap { it.exercises }.filter { it.lift in setOf("chin", "row") }.all { it.accessory })
        val rule = gs.progression["squat"] as Rule.AmrapTable
        assertEquals(1, rule.failuresBeforeDeload)
        assertEquals(0.1, rule.deloadPercent)
        assertEquals(listOf(0.0, 2.5, 5.0), rule.table.map { it.incrementKg })
    }

    @Test
    fun `greyskull amrap 4 reps deloads to 0_9 immediately`() {
        val s = step(gs, gsStart()) { ex, set, _ -> if (ex.key == "ohp" && set.isAmrap) 4 else set.targetReps }
        assertEquals(36.0, s.tm["ohp"])
        assertEquals(0, s.failStreak["ohp"])
        assertEquals(36.25, weights(E.plan(gs, s, 2)[1], "ohp")[0]) // 다음 A 회차, 36 -> 1.25 단위 반올림
    }

    @Test
    fun `greyskull amrap 10 reps doubles increment and 5 reps adds base`() {
        var s = step(gs, gsStart()) { ex, set, _ -> if (ex.key == "ohp" && set.isAmrap) 10 else set.targetReps }
        assertEquals(42.5, s.tm["ohp"]) // 상체 기본 1.25 의 2배
        s = step(gs, s) // B: 벤치·데드
        s = step(gs, s) // A
        assertEquals(42.5 + 1.25, s.tm["ohp"])
        assertEquals(105.0, s.tm["squat"]) // 두 번 성공 +2.5 씩
        assertEquals(122.5, s.tm["deadlift"])
        assertEquals(61.25, s.tm["bench"])
    }

    @Test
    fun `greyskull first two sets failing is not judged`() {
        val s = step(gs, gsStart()) { ex, set, i -> if (ex.key == "squat" && i < 2) 3 else set.targetReps }
        assertEquals(102.5, s.tm["squat"])
    }

    // ---- Madcow
    private val mc = load("madcow-5x5")
    private fun mcStart() = E.initialState(mc, emptyMap(), mapOf("squat" to 100.0, "bench" to 80.0, "row" to 70.0, "ohp" to 50.0, "deadlift" to 120.0))

    @Test
    fun `madcow structure`() {
        assertEquals(listOf("MON", "WED", "FRI"), mc.days.map { it.key })
        assertTrue(mc.days[0].exercises.all { !it.countsForProgression })
        assertTrue(mc.days[2].exercises.all { it.countsForProgression })
        assertEquals(5, mc.days[0].exercises[0].sets.size)
        val fri = mc.days[2].exercises[0].sets
        assertEquals(6, fri.size)
        assertEquals(3, fri[4].reps)
        assertEquals(8, fri[5].reps)
    }

    @Test
    fun `madcow ramp weights`() {
        val plan = E.plan(mc, mcStart(), 3)
        assertEquals(listOf(50.0, 62.5, 75.0, 87.5, 100.0), weights(plan[0], "squat"))
        assertEquals(listOf(50.0, 62.5, 75.0, 75.0), weights(plan[1], "squat"))
        assertEquals(listOf(50.0, 62.5, 75.0, 87.5, 102.5, 75.0), weights(plan[2], "squat"))
    }

    @Test
    fun `madcow progression only from friday and wed ohp deadlift`() {
        var s = mcStart()
        s = step(mc, s) // 월
        assertEquals(100.0, s.working["squat"])
        s = step(mc, s) // 수
        assertEquals(100.0, s.working["squat"])
        assertEquals(52.5, s.working["ohp"])
        assertEquals(122.5, s.working["deadlift"])
        s = step(mc, s) // 금
        assertEquals(102.5, s.working["squat"])
        assertEquals(82.5, s.working["bench"])
        assertEquals(72.5, s.working["row"])
        assertEquals(2, s.week)
    }

    @Test
    fun `madcow two failed fridays deload`() {
        var s = mcStart()
        repeat(2) {
            s = step(mc, s); s = step(mc, s)
            s = step(mc, s) { ex, set, _ -> if (ex.key == "bench" && set.targetReps == 3) 2 else set.targetReps }
        }
        assertEquals(72.0, s.working["bench"])
    }
}
