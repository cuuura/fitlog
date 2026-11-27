package com.fitlog.program.schema

import com.fitlog.engine.EngineTestUtil.E
import com.fitlog.engine.EngineTestUtil.performed
import com.fitlog.engine.EngineTestUtil.step
import com.fitlog.engine.EngineTestUtil.weights
import com.fitlog.engine.PlannedDay
import com.fitlog.engine.ProgramDefinition
import com.fitlog.engine.ProgramState
import com.fitlog.engine.Rule
import com.fitlog.program.catalog.ProgramTemplates
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** fullbody-3day-beginner / dumbbell-home-3day / rippler-12week : 검증 + 구조 + 엔진 시뮬레이션 (DB 없음) */
class FullbodyRipplerTest {
    private val seedText: String by lazy {
        javaClass.getResourceAsStream("/db/SEED_EXERCISES.md")!!.readBytes().toString(Charsets.UTF_8)
    }
    private val seedIds: Set<String> by lazy {
        Regex("`(019b76da-4000-7000-8000-[0-9a-f]{12})`").findAll(seedText).map { it.groupValues[1] }.toSet()
    }
    private val seedTypes: Map<String, String> by lazy {
        Regex("`(019b76da-4000-7000-8000-[0-9a-f]{12})`\\s*\\|[^|]*\\|[^|]*\\|\\s*([A-Z]+)\\s*\\|")
            .findAll(seedText).associate { it.groupValues[1] to it.groupValues[2] }
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

    /** 계획대로 한 회차 수행, [repsFor] 로 일부 세트 횟수만 바꾼다. 무게는 계획 무게 */
    private fun stepWith(p: ProgramDefinition, s: ProgramState, repsFor: (String, Int) -> Int?): ProgramState =
        step(p, s) { ex, set, i -> repsFor(ex.key, i) ?: set.targetReps }

    // ---------------------------------------------------------------- 초보 전신
    private val fb = load("fullbody-3day-beginner")

    @Test
    fun `fullbody structure`() {
        assertEquals(listOf("A", "B"), fb.days.map { it.key })
        assertEquals(listOf("squat", "bench", "pulldown", "crunch"), fb.days[0].exercises.map { it.lift })
        assertEquals(listOf("rdl", "ohp", "row", "leg_raise"), fb.days[1].exercises.map { it.lift })
        val main = fb.days.flatMap { it.exercises }.filter { it.lift !in setOf("crunch", "leg_raise") }
        assertEquals(6, main.size)
        for (e in main) {
            val s = e.sets.single()
            assertEquals(3, s.count)
            assertEquals(8, s.reps)
            assertEquals(12, s.repsMax)
            assertTrue(!e.accessory)
        }
        assertTrue(fb.progression.values.all { it is Rule.Double })
        assertEquals(fb.lifts.keys, fb.days.flatMap { it.exercises }.map { it.lift }.toSet())
    }

    @Test
    fun `fullbody starts without weights and plans range with rest`() {
        val s = E.initialState(fb, emptyMap(), emptyMap())
        val sq = E.plan(fb, s, 1).single().exercises.first { it.key == "squat" }
        assertEquals(3, sq.sets.size)
        assertTrue(sq.sets.all { it.targetReps == 8 && it.targetRepsMax == 12 && it.targetWeightKg == null && it.restSec == 150 })
    }

    @Test
    fun `fullbody top of range raises weight and in range keeps it`() {
        var s = E.initialState(fb, emptyMap(), mapOf("squat" to 60.0, "bench" to 40.0))
        s = stepWith(fb, s) { key, _ -> if (key == "squat") 12 else 10 }
        assertEquals(62.5, s.working["squat"])
        assertEquals(40.0, s.working["bench"])
        assertEquals(listOf(62.5, 62.5, 62.5), weights(E.plan(fb, s, 3)[1], "squat"))
    }

    @Test
    fun `fullbody three misses below lower bound deload`() {
        var s = E.initialState(fb, emptyMap(), mapOf("bench" to 50.0))
        repeat(3) { s = stepWith(fb, s) { key, i -> if (key == "bench" && i == 2) 7 else null }; s = step(fb, s) }
        assertEquals(45.0, s.working["bench"])
    }

    // ---------------------------------------------------------------- 덤벨 홈트
    private val dh = load("dumbbell-home-3day")

    @Test
    fun `dumbbell home uses only dumbbell and bodyweight exercises`() {
        val ids = dh.lifts.values.map { it.exercise.id!! }
        assertTrue(ids.all { seedTypes[it] in setOf("DUMBBELL", "BODYWEIGHT") }, ids.map { seedTypes[it] }.toString())
        assertEquals(listOf("A", "B"), dh.days.map { it.key })
        for (e in dh.days.flatMap { it.exercises }) {
            val s = e.sets.single()
            assertTrue(s.repsMax != null && s.repsMax!! > s.reps, e.lift)
            val bw = seedTypes[dh.lifts[e.lift]!!.exercise.id!!] == "BODYWEIGHT"
            assertEquals(bw, s.load is com.fitlog.engine.Load.Bodyweight, e.lift)
        }
        assertEquals(0.0, (dh.progression["pushup"] as Rule.Double).incrementKg)
    }

    @Test
    fun `dumbbell home dumbbell lift grows at top and bodyweight stays zero`() {
        var s = E.initialState(dh, emptyMap(), mapOf("goblet" to 12.0))
        s = stepWith(dh, s) { key, _ -> if (key == "goblet") 12 else null }
        assertEquals(14.0, s.working["goblet"])
        assertNull(s.working["pushup"])
        val b = E.plan(dh, s, 1).single().exercises.first { it.key == "pushup" }
        assertTrue(b.sets.all { it.targetReps == 8 && it.targetRepsMax == 20 && it.targetWeightKg == 0.0 })
    }

    // ---------------------------------------------------------------- 12주 물결
    private val rp = load("rippler-12week")
    private val tms = mapOf(
        "bench" to 100.0, "bench_t2" to 80.0, "squat" to 140.0, "squat_t2" to 110.0,
        "ohp" to 60.0, "ohp_t2" to 40.0, "deadlift" to 180.0, "deadlift_t2" to 140.0,
    )
    private fun rpStart() = E.initialState(rp, tms, emptyMap())
    private val plan48: List<PlannedDay> by lazy { E.plan(rp, rpStart(), 48) }
    private fun week(w: Int) = plan48.filter { it.week == w }

    @Test
    fun `rippler structure`() {
        assertEquals(12, rp.cycleWeeks)
        assertEquals(4, rp.days.size)
        assertEquals(listOf("bench", "squat", "ohp", "deadlift"), rp.days.map { it.exercises[0].lift })
        assertEquals(1.0, rp.tmPercent)
        for (k in tms.keys) assertTrue(rp.progression[k] is Rule.Cycle, k)
        assertEquals(5.0, (rp.progression["squat"] as Rule.Cycle).incrementKg)
        assertTrue(rp.days.all { d -> d.exercises.size == 4 && d.exercises.drop(2).all { rp.progression[it.lift] is Rule.Double } })
    }

    @Test
    fun `rippler t1 weekly sets and percents`() {
        assertEquals(48, plan48.size)
        val counts = (1..12).map { w -> week(w)[0].exercises[0].sets.size }
        assertEquals(listOf(3, 4, 3, 5, 3, 4, 3, 9, 3, 1, 4, 1), counts)
        assertEquals(listOf(80.0, 80.0, 80.0), weights(week(1)[0], "bench"))
        assertEquals(List(9) { 92.5 }, weights(week(8)[0], "bench"))
        assertEquals(listOf(95.0), weights(week(12)[0], "bench"))
        assertEquals(listOf(5, 5, 5), week(1)[0].exercises[0].sets.map { it.targetReps })
        val w2 = week(2)[0].exercises[0].sets
        assertEquals(listOf(false, false, false, true), w2.map { it.isAmrap })
        assertEquals(listOf("D1.0.0", "D1.0.1", "D1.0.2", "D1.0.3"), w2.map { it.plannedSetKey }) // 펼친 뒤 인덱스 연속
        assertEquals(180, w2[0].restSec)
    }

    @Test
    fun `rippler t2 and t3 skipped in last two weeks`() {
        for (w in 1..10) assertEquals(4, week(w)[0].exercises.size, "week $w")
        for (w in 11..12) assertTrue(week(w).all { it.exercises.size == 1 }, "week $w")
        assertEquals((1..10).map { listOf(5, 5, 5, 4, 4, 4, 3, 3, 3, 5)[it - 1] }, (1..10).map { week(it)[0].exercises[1].sets.size })
        assertEquals(listOf(5, 5, 5, 4, 4, 4, 3, 3, 3, 2), (1..10).map { week(it)[0].exercises[2].sets.size })
        val t3 = week(1)[0].exercises[2].sets
        assertTrue(t3.all { it.targetReps == 10 && it.targetRepsMax == 12 && it.targetWeightKg == null && it.restSec == 75 })
        assertEquals(List(5) { 55.0 }, weights(week(1)[0], "bench_t2")) // 80 x 0.68 = 54.4 -> 2.5 단위 반올림
    }

    @Test
    fun `rippler cycle end adds tm and starts week 1 of cycle 2`() {
        var s = rpStart()
        repeat(48) { s = step(rp, s) }
        assertEquals(2, s.cycle)
        assertEquals(1, s.week)
        assertEquals(102.5, s.tm["bench"])
        assertEquals(145.0, s.tm["squat"])
        assertEquals(185.0, s.tm["deadlift"])
        assertEquals(62.5, s.tm["ohp"])
    }

    @Test
    fun `rippler missed plus set during cycle lowers tm instead`() {
        var s = rpStart()
        repeat(48) { i ->
            s = step(rp, s) { ex, set, _ -> if (i == 4 && ex.key == "bench" && set.isAmrap) set.targetReps - 1 else set.targetReps } // 2주차 벤치 + 세트
        }
        assertEquals(95.0, s.tm["bench"])
        assertEquals(145.0, s.tm["squat"])
    }

    @Test
    fun `rippler t3 double progression fixes start weight from first log`() {
        val s0 = rpStart()
        assertNull(s0.working["pulldown"])
        val day = E.plan(rp, s0, 1).single()
        val ev = performed(day, repsFor = { ex, set, _ -> if (ex.key == "pulldown") 12 else set.targetReps },
            weightFor = { ex, set, _ -> if (ex.key == "pulldown") 30.0 else set.targetWeightKg })
        val s1 = E.apply(rp, s0, ev)
        assertEquals(32.5, s1.working["pulldown"]) // 상한 12 달성 -> +2.5
    }
}
