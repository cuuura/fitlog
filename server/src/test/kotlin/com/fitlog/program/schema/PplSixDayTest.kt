package com.fitlog.program.schema

import com.fitlog.engine.EngineTestUtil.E
import com.fitlog.engine.EngineTestUtil.performed
import com.fitlog.engine.ProgramDefinition
import com.fitlog.engine.ProgramState
import com.fitlog.engine.Rule
import com.fitlog.program.catalog.ProgramTemplates
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** reddit-ppl-6day : 검증 + 구조 + 엔진 시뮬레이션 (DB 없음) */
class PplSixDayTest {
    private val seedIds: Set<String> by lazy {
        val text = javaClass.getResourceAsStream("/db/SEED_EXERCISES.md")!!.readBytes().toString(Charsets.UTF_8)
        Regex("`(019b76da-4000-7000-8000-[0-9a-f]{12})`").findAll(text).map { it.groupValues[1] }.toSet()
    }
    private val resolver: ExerciseResolver = { ref ->
        val id = ref.id
        if (id != null && id in seedIds) ResolveResult.Found(id) else ResolveResult.Failed("unknown exercise $id")
    }
    private val p: ProgramDefinition by lazy {
        val r = ProgramValidator.validate(ProgramTemplates.readJson("reddit-ppl-6day"), resolver)
        assertTrue(r is ValidationResult.Valid, (r as? ValidationResult.Invalid)?.errors.toString())
        (r as ValidationResult.Valid).definition
    }
    private val mains = setOf("deadlift", "row", "bench", "ohp", "squat")

    /** 메인 5종만 작업 무게 입력, 보조는 비움 */
    private fun start(): ProgramState =
        E.initialState(p, emptyMap(), mapOf("deadlift" to 100.0, "row" to 60.0, "bench" to 60.0, "ohp" to 40.0, "squat" to 80.0))

    @Test
    fun `structure`() {
        assertEquals(listOf("PULL1", "PUSH1", "LEGS1", "PULL2", "PUSH2", "LEGS2"), p.days.map { it.key })
        assertEquals(listOf("deadlift"), p.days[0].exercises.filter { it.lift in mains }.map { it.lift })
        assertEquals(listOf("bench"), p.days[1].exercises.filter { it.lift in mains }.map { it.lift })
        assertEquals(listOf("row"), p.days[3].exercises.filter { it.lift in mains }.map { it.lift })
        assertEquals(listOf("ohp"), p.days[4].exercises.filter { it.lift in mains }.map { it.lift })
        val bench = p.days[1].exercises[0].sets
        assertEquals(listOf(4 to false, 1 to true), bench.map { it.count to it.amrap })
        val squat = p.days[2].exercises[0].sets
        assertEquals(listOf(2 to false, 1 to true), squat.map { it.count to it.amrap })
        assertEquals(1, p.days[0].exercises[0].sets.size)
        assertTrue(p.days[0].exercises[0].sets[0].amrap)
        assertEquals(5.0, (p.progression["deadlift"] as Rule.Linear).incrementKg)
        for (k in listOf("row", "bench", "ohp", "squat")) assertEquals(2.5, (p.progression[k] as Rule.Linear).incrementKg, k)
        // 스쿼트는 첫 하체 날만 판정
        assertTrue(p.days[2].exercises[0].countsForProgression)
        assertTrue(!p.days[5].exercises[0].countsForProgression)
        // 보조는 모두 DOUBLE, accessory=false, 범위, 휴식
        val accs = p.days.flatMap { it.exercises }.filter { it.lift !in mains }
        assertTrue(accs.isNotEmpty())
        for (a in accs) {
            assertTrue(p.progression[a.lift] is Rule.Double, a.lift)
            assertTrue(!a.accessory, a.lift)
            assertTrue(a.sets.all { it.repsMax != null && it.repsMax!! > it.reps }, a.lift)
            assertTrue((a.restSec ?: 0) in 60..90, a.lift)
        }
        assertEquals(150, p.days[0].exercises[0].restSec)
        // 키는 종목 항목당 한 번만(스쿼트 제외)
        val used = p.days.flatMap { it.exercises }.map { it.lift }
        assertEquals(setOf("squat"), used.groupBy { it }.filter { it.value.size > 1 }.keys)
    }

    @Test
    fun `first plan has accessory without weight and main with weight`() {
        val s = start()
        val plan = E.plan(p, s, 1).single()
        assertEquals(100.0, plan.exercises[0].sets[0].targetWeightKg)
        assertEquals(listOf(8, 8, 8), plan.exercises[1].sets.map { it.targetReps })
        assertEquals(listOf(12, 12, 12), plan.exercises[1].sets.map { it.targetRepsMax })
        assertNull(plan.exercises[1].sets[0].targetWeightKg)
    }

    @Test
    fun `one week all success raises mains and accessory top of range`() {
        var s = start()
        var weightedPulldown = false
        repeat(6) {
            val day = E.plan(p, s, 1).single()
            val ev = performed(
                day,
                repsFor = { ex, set, _ -> if (set.targetRepsMax != null) set.targetRepsMax!! else if (ex.key in mains && set.isAmrap) 8 else set.targetReps },
                weightFor = { ex, set, _ -> set.targetWeightKg ?: if (ex.key == "pulldown") 40.0.also { weightedPulldown = true } else null },
            )
            s = E.apply(p, s, ev)
        }
        assertTrue(weightedPulldown)
        assertEquals(105.0, s.working["deadlift"])
        assertEquals(62.5, s.working["bench"])
        assertEquals(62.5, s.working["row"])
        assertEquals(42.5, s.working["ohp"])
        assertEquals(82.5, s.working["squat"]) // 첫 하체 날 한 번만 판정
        assertEquals(42.5, s.working["pulldown"]) // 첫 회차에 40 확정 + 상한 달성
        assertEquals(2, s.week)
    }

    @Test
    fun `three failures deload bench by 10 percent`() {
        var s = start()
        repeat(3) {
            repeat(6) {
                val day = E.plan(p, s, 1).single()
                s = E.apply(p, s, performed(day, repsFor = { ex, set, si -> if (ex.key == "bench" && si == 0) 4 else set.targetReps }))
            }
        }
        // 3주 연속 벤치 첫 세트 실패 -> 60 * 0.9 = 54
        assertEquals(54.0, s.working["bench"])
    }
}
