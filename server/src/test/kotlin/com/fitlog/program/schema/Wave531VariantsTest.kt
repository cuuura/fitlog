package com.fitlog.program.schema

import com.fitlog.engine.PlannedDay
import com.fitlog.engine.ProgramDefinition
import com.fitlog.engine.ProgramEngine
import com.fitlog.engine.ProgramState
import com.fitlog.engine.EngineTestUtil.performed
import com.fitlog.program.catalog.ProgramTemplates
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** 5/3/1 변형 3종(BBS·FSL·초보 전신 3일) 검증. DB 없음 */
class Wave531VariantsTest {
    private val seedIds: Set<String> by lazy {
        val text = javaClass.getResourceAsStream("/db/SEED_EXERCISES.md")!!.readBytes().toString(Charsets.UTF_8)
        Regex("`(019b76da-4000-7000-8000-[0-9a-f]{12})`").findAll(text).map { it.groupValues[1] }.toSet()
    }
    private val resolver: ExerciseResolver = { ref ->
        val id = ref.id
        if (id != null && id in seedIds) ResolveResult.Found(id) else ResolveResult.Failed("unknown exercise $id")
    }
    private val keys = listOf("wendler-531-bbs", "wendler-531-fsl", "wendler-531-beginners")

    private fun def(key: String): ProgramDefinition {
        val r = ProgramValidator.validate(ProgramTemplates.readJson(key), resolver)
        assertTrue(r is ValidationResult.Valid, "$key: ${(r as? ValidationResult.Invalid)?.errors}")
        return r.definition
    }

    private val tm = mapOf("squat" to 100.0, "bench" to 80.0, "deadlift" to 120.0, "ohp" to 50.0)
    private fun start(p: ProgramDefinition) = ProgramEngine.initialState(p, tm, emptyMap())

    /** 한 회차 수행. [missAmrap] 이면 AMRAP 세트를 목표보다 1회 적게 한다 */
    private fun step(p: ProgramDefinition, s: ProgramState, missAmrap: Boolean = false): ProgramState {
        val day: PlannedDay = ProgramEngine.plan(p, s, 1).single()
        val ev = performed(day, repsFor = { _, set, _ -> if (missAmrap && set.isAmrap) set.targetReps - 1 else set.targetReps })
        return ProgramEngine.apply(p, s, ev)
    }

    private fun runCycle(p: ProgramDefinition, s0: ProgramState, missWeek: Int? = null): ProgramState {
        var s = s0
        repeat(4 * p.days.size) {
            s = step(p, s, missAmrap = s.week == missWeek)
        }
        return s
    }

    @Test
    fun all_three_pass_validation() {
        keys.forEach { def(it) }
    }

    @Test
    fun structure_bbs_fsl() {
        val bbs = def("wendler-531-bbs")
        assertEquals(4, bbs.cycleWeeks)
        assertEquals(4, bbs.days.size)
        val main = bbs.days[0].exercises[0]
        assertEquals(3, main.sets.size)
        assertTrue(main.sets.all { it.weekly!!.size == 4 })
        assertEquals(true, main.sets[2].weekly!![2].amrap)
        assertEquals(false, main.sets[2].weekly!![3].amrap ?: false)
        val supp = bbs.days[0].exercises[1]
        assertEquals(10, supp.sets[0].count)
        assertEquals(5, supp.sets[0].reps)
        assertEquals(listOf(0.65, 0.7, 0.75, 0.4), supp.sets[0].weekly!!.map { it.value })

        val fsl = def("wendler-531-fsl")
        val f = fsl.days[0].exercises[1]
        assertEquals(5, f.sets[0].count)
        assertEquals(5, f.sets[0].reps)
        assertEquals(main.sets[0].weekly!!.map { it.value }.take(3), f.sets[0].weekly!!.map { it.value }.take(3))
    }

    @Test
    fun structure_beginners() {
        val b = def("wendler-531-beginners")
        assertEquals(3, b.days.size)
        assertEquals(listOf("squat", "bench", "deadlift", "ohp"), b.progression.keys.toList().let { listOf("squat", "bench", "deadlift", "ohp").filter { k -> k in it } })
        assertEquals(0.9, b.tmPercent)
        val mains = b.days.map { d -> d.exercises.filter { !it.accessory && it.sets.size == 3 }.map { it.lift } }
        assertEquals(listOf(listOf("squat", "bench"), listOf("deadlift", "ohp"), listOf("bench", "squat")), mains)
        assertTrue(b.days[2].exercises.filter { !it.accessory }.all { !it.countsForProgression })
    }

    @Test
    fun deload_week_has_no_accessories_but_keeps_three_main_sets() {
        for (k in listOf("wendler-531-bbb") + keys) {
            val p = def(k)
            val s0 = start(p)
            for (week in 1..4) {
                for (day in ProgramEngine.plan(p, s0.copy(week = week), p.days.size)) {
                    val acc = day.exercises.filter { it.accessory }
                    val mains = day.exercises.filter { !it.accessory }
                    assertTrue(mains.isNotEmpty() && mains.all { it.sets.size == 3 }, "$k ${day.dayKey} week$week main sets")
                    if (week == 4) assertTrue(acc.isEmpty(), "$k ${day.dayKey} week4 accessories ${acc.map { it.key }}")
                    else assertTrue(acc.isNotEmpty(), "$k ${day.dayKey} week$week accessories")
                }
            }
        }
    }

    @Test
    fun one_cycle_all_success_raises_tm() {
        for (k in keys) {
            val p = def(k)
            val s = runCycle(p, start(p))
            assertEquals(2, s.cycle, k)
            assertEquals(1, s.week, k)
            assertEquals(105.0, s.tm["squat"], k)
            assertEquals(82.5, s.tm["bench"], k)
            assertEquals(125.0, s.tm["deadlift"], k)
            assertEquals(52.5, s.tm["ohp"], k)
        }
    }

    @Test
    fun amrap_miss_in_week3_deloads_instead_of_increase() {
        for (k in keys) {
            val p = def(k)
            val s = runCycle(p, start(p), missWeek = 3)
            assertEquals(90.0, s.tm["squat"], k)
            assertEquals(72.0, s.tm["bench"], k)
            assertEquals(108.0, s.tm["deadlift"], k)
            assertEquals(45.0, s.tm["ohp"], k)
        }
    }
}
