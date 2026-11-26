package com.fitlog.engine

import com.fitlog.engine.EngineTestUtil.E
import com.fitlog.engine.EngineTestUtil.lift
import com.fitlog.engine.EngineTestUtil.performed
import com.fitlog.engine.EngineTestUtil.spec
import com.fitlog.engine.EngineTestUtil.step
import com.fitlog.engine.EngineTestUtil.template
import com.fitlog.engine.EngineTestUtil.weights
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class EngineRulesTest {
    private val sl = template("stronglifts-5x5.json")
    private val ns = template("nsuns-4day.json")

    private fun slStart() = E.initialState(
        sl, emptyMap(),
        mapOf("squat" to 100.0, "bench" to 60.0, "row" to 60.0, "ohp" to 40.0, "deadlift" to 100.0),
    )

    private fun nsStart() = E.initialState(
        ns, mapOf("bench" to 100.0, "ohp" to 60.0, "squat" to 120.0, "deadlift" to 140.0), emptyMap(),
    )

    // ------------------------------------------------------------ 입력

    @Test
    fun `required inputs resolve to real state keys`() {
        val nsReq = E.requiredInputs(ns)
        assertEquals(setOf("bench", "ohp", "squat", "deadlift"), nsReq.keys)
        assertTrue(nsReq.values.all { it == Needs.TM })
        val slReq = E.requiredInputs(sl)
        assertEquals(setOf("squat", "bench", "row", "ohp", "deadlift"), slReq.keys)
        assertTrue(slReq.values.all { it == Needs.WORKING })
    }

    @Test
    fun `initial state reports missing key`() {
        val e = assertFailsWith<IllegalArgumentException> {
            E.initialState(ns, mapOf("bench" to 100.0, "ohp" to 60.0, "squat" to 120.0), emptyMap())
        }
        assertTrue(e.message!!.contains("deadlift"))
        val e2 = assertFailsWith<IllegalArgumentException> { E.initialState(sl, emptyMap(), mapOf("squat" to 100.0)) }
        assertTrue(e2.message!!.contains("bench") || e2.message!!.contains("row"))
    }

    @Test
    fun `initial state stores two decimals`() {
        val s = E.initialState(ns, mapOf("bench" to 100.123, "ohp" to 60.0, "squat" to 120.0, "deadlift" to 140.0), emptyMap())
        assertEquals(100.12, s.tm["bench"])
        assertEquals(1, s.week)
        assertEquals(0, s.seq)
    }

    // ------------------------------------------------------------ 계획

    @Test
    fun `plan first is confirmed and keys follow dayKey exercise set index`() {
        val plan = E.plan(sl, slStart(), 3)
        assertEquals(listOf(true, false, false), plan.map { it.confirmed })
        assertEquals(listOf("A", "B", "A"), plan.map { it.dayKey })
        assertEquals(listOf(1, 2, 3), plan.map { it.planSeq })
        assertEquals(listOf(100.0, 102.5, 105.0), listOf(0, 1, 2).map { plan[it].exercises.first { e -> e.key == "squat" }.sets[0].targetWeightKg })
        assertEquals("A.0.0", plan[0].exercises[0].sets[0].plannedSetKey)
        assertEquals("B.2.0", plan[1].exercises[2].sets[0].plannedSetKey)
        assertEquals("A.1.4", plan[0].exercises[1].sets[4].plannedSetKey)
        assertEquals(2, plan[1].week.let { it + 1 }) // 주 1
    }

    @Test
    fun `plan across week boundary advances week`() {
        val plan = E.plan(sl, slStart(), 3)
        assertEquals(listOf(1, 1, 2), plan.map { it.week })
    }

    @Test
    fun `nsuns plan resolves weights tmFrom and weekly sets`() {
        val s = nsStart()
        val d1 = E.plan(ns, s, 1).single()
        // 벤치 TM 100 × 0.65 = 65.0, 0.75 = 75.0, 0.85 = 85.0
        assertEquals(listOf(65.0, 75.0, 85.0, 85.0, 85.0, 80.0, 75.0, 70.0, 65.0), weights(d1, "bench"))
        assertEquals(9, d1.exercises[0].sets.size)
        assertTrue(d1.exercises[0].sets.last().isAmrap)
        val d2 = E.plan(ns, s.copy(nextDayIndex = 1), 1).single()
        // 스모는 tmFrom deadlift 140 × 0.5 = 70.0
        assertEquals(70.0, weights(d2, "sumo").first())
        // 스쿼트 TM 120 × 0.95 = 114.0 → 115.0
        assertEquals(115.0, weights(d2, "squat")[2])
        val d3 = E.plan(ns, s.copy(nextDayIndex = 2), 1).single()
        assertEquals(40.0, weights(d3, "cgbp").first()) // bench 100 × 0.4
    }

    @Test
    fun `barbell floor applies only to barbell exercises`() {
        val s = E.initialState(sl, emptyMap(), mapOf("squat" to 15.0, "bench" to 15.0, "row" to 60.0, "ohp" to 40.0, "deadlift" to 100.0))
        val squatId = sl.lifts["squat"]!!.exercise.id!!
        val plain = E.plan(sl, s, 1).single()
        assertEquals(15.0, weights(plain, "squat").first())
        val bar = E.plan(sl, s, 1, EngineSettings(barbellExerciseIds = setOf(squatId))).single()
        assertEquals(20.0, weights(bar, "squat").first())
        assertEquals(15.0, weights(bar, "bench").first())
    }

    @Test
    fun `fixed bodyweight and none loads`() {
        val p = ProgramDefinition(
            schemaVersion = 1, name = "mixed",
            lifts = mapOf("a" to lift("a-id"), "b" to lift("b-id"), "c" to lift("c-id")),
            days = listOf(
                Day("X", "X", null, listOf(
                    DayExercise("a", sets = listOf(spec(5, Load.Fixed(22.5)))),
                    DayExercise("b", sets = listOf(spec(8, Load.Bodyweight))),
                    DayExercise("c", accessory = true, sets = listOf(spec(10, Load.NoLoad, count = 3))),
                )),
            ),
        )
        val d = E.plan(p, ProgramState(), 1).single()
        assertEquals(22.5, weights(d, "a").single())
        assertEquals(0.0, weights(d, "b").single())
        assertEquals(listOf(null, null, null), weights(d, "c"))
    }

    // ------------------------------------------------------------ 판정

    @Test
    fun `warmup accessory and uncounted sets do not affect judgement`() {
        val p = ProgramDefinition(
            schemaVersion = 1, name = "judge",
            lifts = mapOf("squat" to lift("sq"), "curl" to lift("cu")),
            progression = mapOf(
                "squat" to Rule.Linear(2.5), "curl" to Rule.Linear(1.0),
            ),
            days = listOf(Day("D", "D", null, listOf(
                DayExercise("squat", sets = listOf(spec(5, Load.Working(0.5), warmup = true), spec(5, Load.Working(), count = 3))),
                DayExercise("curl", accessory = true, sets = listOf(spec(10, Load.Working(), count = 2))),
            ))),
        )
        var s = E.initialState(p, emptyMap(), mapOf("squat" to 100.0, "curl" to 20.0))
        val day = E.plan(p, s, 1).single()
        assertTrue(day.exercises[0].sets[0].isWarmup)
        // 워밍업 기록 없음, 보조운동 전부 실패해도 스쿼트 본세트 성공이면 성공
        val ev = performed(day, repsFor = { ex, set, _ -> if (ex.accessory || set.isWarmup) 0 else set.targetReps })
        s = E.apply(p, s, ev)
        assertEquals(102.5, s.working["squat"])
        assertEquals(20.0, s.working["curl"])
    }

    @Test
    fun `missing planned set counts as failure`() {
        var s = slStart()
        val day = E.plan(sl, s, 1).single()
        val ev = performed(day)
        val trimmed = ev.copy(exercises = ev.exercises.map { ex ->
            if (ex.liftKey == "bench") ex.copy(sets = ex.sets.dropLast(1)) else ex
        })
        s = E.apply(sl, s, trimmed)
        assertEquals(60.0, s.working["bench"])
        assertEquals(1, s.failStreak["bench"])
        assertEquals(102.5, s.working["squat"])
    }

    @Test
    fun `extra sets without planned key are ignored`() {
        var s = slStart()
        val day = E.plan(sl, s, 1).single()
        val ev = performed(day)
        val withExtra = ev.copy(exercises = ev.exercises.map { ex ->
            if (ex.liftKey == "squat") ex.copy(sets = ex.sets + PerformedSet(null, 1, 50.0)) else ex
        })
        s = E.apply(sl, s, withExtra)
        assertEquals(102.5, s.working["squat"])
    }

    @Test
    fun `success resets fail streak`() {
        var s = slStart()
        s = step(sl, s) { ex, _, i -> if (ex.key == "squat" && i == 0) 1 else 5 }
        assertEquals(1, s.failStreak["squat"])
        s = step(sl, s) // B 성공
        assertEquals(0, s.failStreak["squat"])
        assertEquals(102.5, s.working["squat"])
    }

    // ------------------------------------------------------------ STAGES

    private fun stagesProgram() = ProgramDefinition(
        schemaVersion = 1, name = "stages",
        lifts = mapOf("squat" to lift("sq")),
        progression = mapOf("squat" to Rule.Stages(5.0, listOf(Stage(5, 3), Stage(6, 2), Stage(10, 1, lastAmrap = true)), 0.1)),
        days = listOf(Day("T1", "T1", null, listOf(DayExercise("squat", sets = listOf(spec(3, Load.Working())))))),
    )

    @Test
    fun `stages success adds increment and keeps stage and last set is amrap on last stage`() {
        val p = stagesProgram()
        var s = E.initialState(p, emptyMap(), mapOf("squat" to 100.0))
        s = step(p, s)
        assertEquals(105.0, s.working["squat"])
        assertEquals(null, s.stage["squat"])
        val last = E.plan(p, s.copy(stage = mapOf("squat" to 2)), 1).single().exercises.single().sets
        assertEquals(10, last.size)
        assertTrue(last.last().isAmrap)
        assertFalse(last.first().isAmrap)
    }

    @Test
    fun `stages plan assumes success and keeps stage`() {
        val p = stagesProgram()
        val s = E.initialState(p, emptyMap(), mapOf("squat" to 100.0))
        val plan = E.plan(p, s, 2)
        assertEquals(100.0, plan[0].exercises.single().sets.first().targetWeightKg)
        assertEquals(105.0, plan[1].exercises.single().sets.first().targetWeightKg)
        assertEquals(5, plan[1].exercises.single().sets.size)
    }

    // ------------------------------------------------------------ CYCLE

    private fun cycleProgram() = ProgramDefinition(
        schemaVersion = 1, name = "531",
        cycleWeeks = 4,
        lifts = mapOf("squat" to lift("sq")),
        progression = mapOf("squat" to Rule.Cycle(5.0, 0.1)),
        days = listOf(Day("D", "D", null, listOf(DayExercise("squat", sets = listOf(
            spec(5, Load.PercentTm(0.85), amrap = true, weekly = listOf(
                WeeklyOverride(reps = 5, amrap = true, value = 0.85),
                WeeklyOverride(reps = 3, amrap = true, value = 0.90),
                WeeklyOverride(reps = 1, amrap = true, value = 0.95),
                WeeklyOverride(reps = 5, amrap = false, value = 0.60),
            )),
        ))))),
    )

    @Test
    fun `weekly overrides change reps amrap and weight per week`() {
        val p = cycleProgram()
        val s = E.initialState(p, mapOf("squat" to 100.0), emptyMap())
        val plan = E.plan(p, s, 5)
        val sets = plan.map { it.exercises.single().sets.single() }
        assertEquals(listOf(5, 3, 1, 5, 5), sets.map { it.targetReps })
        assertEquals(listOf(85.0, 90.0, 95.0, 60.0, 90.0), sets.map { it.targetWeightKg })
        assertEquals(listOf(true, true, true, false, true), sets.map { it.isAmrap })
        assertEquals(listOf(1, 2, 3, 4, 1), plan.map { it.week })
        assertEquals(listOf(1, 1, 1, 1, 2), plan.map { it.cycle })
    }

    @Test
    fun `cycle end adds increment when amrap targets met`() {
        val p = cycleProgram()
        var s = E.initialState(p, mapOf("squat" to 100.0), emptyMap())
        repeat(3) {
            s = step(p, s)
            assertEquals(100.0, s.tm["squat"])
        }
        s = step(p, s)
        assertEquals(105.0, s.tm["squat"])
        assertEquals(1, s.week)
        assertEquals(2, s.cycle)
    }

    @Test
    fun `cycle end deloads when an amrap week misses target`() {
        val p = cycleProgram()
        var s = E.initialState(p, mapOf("squat" to 100.0), emptyMap())
        s = step(p, s)
        s = step(p, s) { _, _, _ -> 2 } // 2주차 목표 3회 미달
        s = step(p, s)
        s = step(p, s)
        assertEquals(90.0, s.tm["squat"])
        assertEquals(2, s.cycle)
        assertEquals(null, s.failStreak["squat"]?.takeIf { it > 0 })
        // 다음 사이클은 새로 판정
        repeat(4) { s = step(p, s) }
        assertEquals(95.0, s.tm["squat"])
    }

    @Test
    fun `cycle last week is not judged`() {
        val p = cycleProgram()
        var s = E.initialState(p, mapOf("squat" to 100.0), emptyMap())
        repeat(3) { s = step(p, s) }
        s = step(p, s) { _, _, _ -> 0 }
        assertEquals(105.0, s.tm["squat"])
    }

    // ------------------------------------------------------------ AMRAP_TABLE

    @Test
    fun `amrap table two zero increment weeks in a row deloads`() {
        var s = nsStart()
        fun week(benchReps: Int): ProgramState {
            repeat(4) {
                val day = E.plan(ns, s, 1).single()
                s = E.apply(ns, s, performed(day, repsFor = { ex, set, i ->
                    val de = ns.days[day.dayIndex].exercises.first { it.lift == ex.key }
                    val idx = de.amrapSet ?: ex.sets.indexOfFirst { it.isAmrap }
                    if (!ex.accessory && i == idx) (if (ex.key == "bench") benchReps else 5) else set.targetReps
                }))
            }
            return s
        }
        week(1)
        assertEquals(100.0, s.tm["bench"])
        assertEquals(1, s.failStreak["bench"])
        week(0)
        assertEquals(90.0, s.tm["bench"])
        assertEquals(0, s.failStreak["bench"])
        // 같은 주 하체는 정상 증가
        assertEquals(130.0, s.tm["squat"])
    }

    @Test
    fun `amrap table zero then positive week resets streak`() {
        var s = nsStart()
        s = amrapWeekOf(s, 1)
        s = amrapWeekOf(s, 5)
        assertEquals(102.5, s.tm["bench"])
        assertEquals(0, s.failStreak["bench"])
    }

    private fun amrapWeekOf(start: ProgramState, benchReps: Int): ProgramState {
        var s = start
        repeat(4) {
            val day = E.plan(ns, s, 1).single()
            s = E.apply(ns, s, performed(day, repsFor = { ex, set, i ->
                val de = ns.days[day.dayIndex].exercises.first { it.lift == ex.key }
                val idx = de.amrapSet ?: ex.sets.indexOfFirst { it.isAmrap }
                if (!ex.accessory && i == idx) (if (ex.key == "bench") benchReps else 5) else set.targetReps
            }))
        }
        return s
    }

    @Test
    fun `amrap table session mode applies immediately`() {
        val p = ProgramDefinition(
            schemaVersion = 1, name = "sess",
            lifts = mapOf("bench" to lift("b")),
            progression = mapOf("bench" to Rule.AmrapTable(listOf(TableRow(0, 3, 0.0), TableRow(4, null, 2.5)), ApplyAt.SESSION)),
            days = listOf(Day("D", "D", null, listOf(DayExercise("bench", sets = listOf(spec(1, Load.PercentTm(0.9), amrap = true)))))),
        )
        var s = E.initialState(p, mapOf("bench" to 100.0), emptyMap())
        s = step(p, s) { _, _, _ -> 6 }
        assertEquals(102.5, s.tm["bench"])
        assertNull(s.pendingTmDelta["bench"])
    }

    @Test
    fun `plan assumption does not stall amrap table on zero increment rows`() {
        val plan = E.plan(ns, nsStart(), 9)
        assertEquals(115.0, weights(plan[1], "squat")[2]) // 1주차 D2 스쿼트 120 x 0.95
        val w2 = plan[4] // 2주차 D1
        assertEquals(2, w2.week)
        // 모두 성공 가정이므로 벤치 TM 이 올라 있다(디로드 아님)
        assertTrue(weights(w2, "bench")[0]!! >= 65.0)
        // 3주차 D2 스쿼트: 가정상 매주 증가하므로 1주차보다 무겁다
        assertTrue(weights(plan[5], "squat")[2]!! > 115.0)
    }

    // ------------------------------------------------------------ 이벤트·결정성

    @Test
    fun `adjusted event overrides tm and working without advancing`() {
        val s0 = nsStart()
        val s1 = E.apply(ns, s0, ProgramEvent.Adjusted(mapOf("bench" to 90.555), emptyMap()))
        assertEquals(90.56, s1.tm["bench"])
        assertEquals(s0.seq, s1.seq)
        assertEquals(s0.nextDayIndex, s1.nextDayIndex)
        val l0 = slStart()
        val l1 = E.apply(sl, l0, ProgramEvent.Adjusted(emptyMap(), mapOf("squat" to 80.0)))
        assertEquals(80.0, l1.working["squat"])
        assertEquals(l0.working["bench"], l1.working["bench"])
    }

    @Test
    fun `replay is deterministic and equals sequential apply`() {
        val events = ArrayList<ProgramEvent>()
        var s = slStart()
        repeat(7) { n ->
            val day = E.plan(sl, s, 1).single()
            val ev: ProgramEvent = when {
                n == 2 -> ProgramEvent.Skipped(day.planSeq, SkipPolicy.FIXED_DATE)
                n == 4 -> ProgramEvent.Adjusted(emptyMap(), mapOf("bench" to 70.0))
                n == 5 -> performed(day, repsFor = { ex, set, i -> if (ex.key == "squat" && i == 1) 4 else set.targetReps })
                else -> performed(day)
            }
            events += ev
            s = E.apply(sl, s, ev)
        }
        val a = E.replay(sl, slStart(), events)
        val b = E.replay(sl, slStart(), events)
        assertEquals(s, a)
        assertEquals(a, b)
    }

    @Test
    fun `estimate one rm formulas and limits`() {
        assertEquals(116.67, E.estimateOneRm(E1rmFormula.EPLEY, 100.0, 5))
        assertEquals(100.0, E.estimateOneRm(E1rmFormula.EPLEY, 100.0, 1))
        assertEquals(112.5, E.estimateOneRm(E1rmFormula.BRZYCKI, 100.0, 5))
        assertEquals(117.46, E.estimateOneRm(E1rmFormula.LOMBARDI, 100.0, 5))
        assertEquals(133.33, E.estimateOneRm(E1rmFormula.EPLEY, 100.0, 10))
        assertNull(E.estimateOneRm(E1rmFormula.EPLEY, 100.0, 11))
        assertNull(E.estimateOneRm(E1rmFormula.EPLEY, 100.0, 0))
        assertNull(E.estimateOneRm(E1rmFormula.EPLEY, null, 5))
        assertNull(E.estimateOneRm(E1rmFormula.EPLEY, 0.0, 5))
        assertNull(E.estimateOneRm(E1rmFormula.EPLEY, 100.0, null))
    }

    @Test
    fun `rounding ties go down and custom step`() {
        assertEquals(60.0, E.roundWeight(61.25, 2.5, null, false))
        assertEquals(1.0, E.roundWeight(1.25, 0.5, null, false).let { if (it == 1.0) 1.0 else it })
        assertEquals(22.0, E.roundWeight(22.4, 1.0, null, false))
        assertEquals(20.0, E.roundWeight(20.0, 2.5, 20.0, true))
        assertEquals(22.5, E.roundWeight(22.5, 2.5, 20.0, true))
    }

    @Test
    fun `stored tm and working keep two decimals unrounded to step`() {
        var s = E.initialState(sl, emptyMap(), mapOf("squat" to 61.0, "bench" to 60.0, "row" to 60.0, "ohp" to 40.0, "deadlift" to 100.0))
        repeat(3) { s = step(sl, s) { ex, _, i -> if (ex.key == "squat" && i == 0) 1 else 5 } }
        assertEquals(54.9, s.working["squat"]) // 61 × 0.9
        assertEquals(55.0, weights(E.plan(sl, s, 1).single(), "squat").first())
    }
}
