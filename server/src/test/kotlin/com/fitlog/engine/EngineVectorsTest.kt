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

/** engine.md 8절 테스트 벡터 14개 */
class EngineVectorsTest {
    private val sl = template("stronglifts-5x5.json")
    private val ns = template("nsuns-4day.json")

    private fun slStart(squat: Double = 100.0) = E.initialState(
        sl, emptyMap(),
        mapOf("squat" to squat, "bench" to 60.0, "row" to 60.0, "ohp" to 40.0, "deadlift" to 100.0),
    )

    private fun nsStart() = E.initialState(
        ns,
        mapOf("bench" to 100.0, "ohp" to 60.0, "squat" to 120.0, "deadlift" to 140.0),
        emptyMap(),
    )

    @Test
    fun `vector01 rounding 61_25 63_75 63_8 and barbell floor`() {
        assertEquals(60.0, E.roundWeight(61.25, 2.5, 20.0, false))
        assertEquals(62.5, E.roundWeight(63.75, 2.5, 20.0, false))
        assertEquals(65.0, E.roundWeight(63.8, 2.5, 20.0, false))
        assertEquals(20.0, E.roundWeight(18.0, 2.5, 20.0, true))
        assertEquals(17.5, E.roundWeight(18.0, 2.5, 20.0, false))
    }

    @Test
    fun `vector02 stronglifts squat all sets done adds 2_5`() {
        val s = step(sl, slStart())
        assertEquals(102.5, s.working["squat"])
        assertEquals(1, s.nextDayIndex)
        assertEquals(1, s.seq)
    }

    @Test
    fun `vector03 stronglifts three straight failures deload to 90`() {
        var s = slStart()
        repeat(3) {
            s = step(sl, s) { ex, _, i -> if (ex.key == "squat" && i == 4) 4 else 5 }
            if (it < 2) assertEquals(100.0, s.working["squat"])
        }
        assertEquals(90.0, s.working["squat"])
        assertEquals(0, s.failStreak["squat"])
        // 다음은 B 회차: 스쿼트 계획 90.0
        val next = E.plan(sl, s, 1).single()
        assertEquals("B", next.dayKey)
        assertEquals(List(5) { 90.0 }, weights(next, "squat"))
    }

    @Test
    fun `vector04 stronglifts deadlift 1x5 adds 5`() {
        var s = slStart()
        s = step(sl, s) // A
        s = step(sl, s) // B (데드리프트)
        assertEquals(105.0, s.working["deadlift"])
        assertEquals(1, E.plan(sl, slStart(), 2)[1].exercises.first { it.key == "deadlift" }.sets.size)
    }

    @Test
    fun `vector05 nsuns bench amrap 4 reps adds 2_5 at week end`() {
        var s = nsStart()
        s = amrapWeek(s, benchReps = 4)
        assertEquals(102.5, s.tm["bench"])
        assertEquals(2, s.week)
        assertEquals(0, s.nextDayIndex)
    }

    @Test
    fun `vector06 nsuns bench amrap 7 reps adds 5 at week end`() {
        val s = amrapWeek(nsStart(), benchReps = 7)
        assertEquals(105.0, s.tm["bench"])
    }

    @Test
    fun `vector07 nsuns tm gain stays pending until week end and keeps remaining plan`() {
        var s = nsStart()
        s = step(ns, s) // D1
        s = step(ns, s) // D2
        val before = E.plan(ns, s, 3) // D3, D4, 다음 주 D1
        val d3 = before[0]
        assertEquals("D3", d3.dayKey)
        s = E.apply(ns, s, performed(d3, repsFor = { ex, set, i -> if (ex.key == "bench" && i == 2) 6 else set.targetReps }))
        // TM 은 그대로, 증가분은 대기
        assertEquals(100.0, s.tm["bench"])
        assertEquals(5.0, s.pendingTmDelta["bench"])
        // 남은 날(D4) 계획은 증가분이 생기기 전 예상과 같다
        val after = E.plan(ns, s, 2)
        assertEquals(before[1].exercises, after[0].exercises)
        // 주가 바뀌면 반영된다
        s = step(ns, s)
        assertEquals(105.0, s.tm["bench"])
        assertEquals(null, s.pendingTmDelta["bench"])
    }

    @Test
    fun `vector08 changed weight judged by reps only and next plan follows rule`() {
        val s0 = slStart()
        val day = E.plan(sl, s0, 1).single()
        assertEquals(100.0, day.exercises.first { it.key == "squat" }.sets[0].targetWeightKg)
        val ev = performed(day, weightFor = { ex, set, _ -> if (ex.key == "squat") 90.0 else set.targetWeightKg })
        val s1 = E.apply(sl, s0, ev)
        assertEquals(102.5, s1.working["squat"])
        val next = E.plan(sl, s1, 1).single() // B
        assertEquals(List(5) { 102.5 }, weights(next, "squat"))
    }

    @Test
    fun `vector09 shift skip keeps same day and same weight`() {
        val s0 = slStart()
        val s1 = E.apply(sl, s0, ProgramEvent.Skipped(1, SkipPolicy.SHIFT))
        assertEquals(1, s1.seq)
        assertEquals(s0.nextDayIndex, s1.nextDayIndex)
        assertEquals(s0.week, s1.week)
        assertEquals(s0.working, s1.working)
        val p0 = E.plan(sl, s0, 1).single()
        val p1 = E.plan(sl, s1, 1).single()
        assertEquals(p0.dayKey, p1.dayKey)
        assertEquals(p0.exercises, p1.exercises)
        assertEquals(2, p1.planSeq)
    }

    @Test
    fun `vector10 fixed date skip moves to next day without judging`() {
        var s = slStart()
        s = step(sl, s) { ex, _, i -> if (ex.key == "bench" && i == 0) 3 else 5 } // 벤치 한 번 실패: failStreak 1
        assertEquals(1, s.failStreak["bench"])
        val s1 = E.apply(sl, s, ProgramEvent.Skipped(2, SkipPolicy.FIXED_DATE))
        assertEquals(0, s1.nextDayIndex) // B -> A, 주 넘김
        assertEquals(2, s1.week)
        assertEquals(2, s1.seq)
        assertEquals(s.failStreak, s1.failStreak)
        assertEquals(s.working, s1.working)
    }

    @Test
    fun `vector11 replay reflects edited past session reps`() {
        val events = ArrayList<ProgramEvent>()
        var s = slStart()
        repeat(3) { // A B A
            val day = E.plan(sl, s, 1).single()
            val ev = performed(day)
            events += ev
            s = E.apply(sl, s, ev)
        }
        assertEquals(107.5, E.replay(sl, slStart(), events).working["squat"])

        // 세 번째 세션(A)의 스쿼트 한 세트를 5 -> 3 으로 수정
        val last = events[2] as ProgramEvent.Completed
        val edited = last.copy(exercises = last.exercises.map { ex ->
            if (ex.liftKey != "squat") ex
            else ex.copy(sets = ex.sets.mapIndexed { i, ps -> if (i == 2) ps.copy(reps = 3) else ps })
        })
        val replayed = E.replay(sl, slStart(), listOf(events[0], events[1], edited))
        // 수정 반영 값을 직접 계산: 두 번 성공(105.0), 세 번째 실패 -> 그대로 105.0, failStreak 1
        assertEquals(105.0, replayed.working["squat"])
        assertEquals(1, replayed.failStreak["squat"])
        val manual = E.apply(sl, E.apply(sl, E.apply(sl, slStart(), events[0]), events[1]), edited)
        assertEquals(manual, replayed)
    }

    @Test
    fun `vector12 gzclp t1 stages 5x3 6x2 10x1 then reset with deload`() {
        val p = gzclp()
        var s = E.initialState(p, emptyMap(), mapOf("squat" to 100.0))
        fun shape(st: ProgramState) = E.plan(p, st, 1).single().exercises.single().sets.let { it.size to it.first().targetReps }
        assertEquals(5 to 3, shape(s))
        // 실패 = 세트 기록 없음
        val fail = { st: ProgramState -> E.apply(p, st, ProgramEvent.Completed(st.seq + 1, emptyList())) }
        s = fail(s)
        assertEquals(1, s.stage["squat"])
        assertEquals(100.0, s.working["squat"])
        assertEquals(6 to 2, shape(s))
        s = fail(s)
        assertEquals(2, s.stage["squat"])
        assertEquals(10 to 1, shape(s))
        s = fail(s)
        assertEquals(0, s.stage["squat"])
        assertEquals(90.0, s.working["squat"])
        assertEquals(5 to 3, shape(s))
        assertEquals(90.0, E.plan(p, s, 1).single().exercises.single().sets.first().targetWeightKg)
    }

    @Test
    fun `vector13 stronglifts four weeks of A B alternation all success`() {
        val p = sl
        var s = slStart()
        val start = s.working
        var expectedSquat = 100.0
        repeat(12) { n ->
            s = step(p, s)
            expectedSquat += 2.5
            assertEquals(expectedSquat, s.working["squat"], "after session ${n + 1}")
        }
        assertEquals(start["squat"]!! + 30.0, s.working["squat"])
        // A 6회, B 6회: 벤치·로우 +15, 오버헤드프레스 +15, 데드리프트 +30
        assertEquals(start["bench"]!! + 15.0, s.working["bench"])
        assertEquals(start["row"]!! + 15.0, s.working["row"])
        assertEquals(start["ohp"]!! + 15.0, s.working["ohp"])
        assertEquals(start["deadlift"]!! + 30.0, s.working["deadlift"])
        assertEquals(12, s.seq)
        assertEquals(7, s.week) // A/B 두 날이 한 주(days 한 바퀴)
    }

    @Test
    fun `vector14 nsuns four weeks amrap 5 each time lower plus 5 upper plus 2_5`() {
        var s = nsStart()
        val start = s.tm
        val seen = ArrayList<Map<String, Double>>()
        repeat(4) {
            s = amrapWeek(s, benchReps = 5)
            seen += s.tm
        }
        assertEquals(5, s.week)
        for (w in 1..4) {
            assertEquals(start["bench"]!! + 2.5 * w, seen[w - 1]["bench"])
            assertEquals(start["ohp"]!! + 2.5 * w, seen[w - 1]["ohp"])
            assertEquals(start["squat"]!! + 5.0 * w, seen[w - 1]["squat"])
            assertEquals(start["deadlift"]!! + 5.0 * w, seen[w - 1]["deadlift"])
        }
    }

    /** nSuns 한 주(4회차). 각 키의 AMRAP 표 세트는 5회(벤치는 [benchReps]), 나머지 세트는 목표대로 */
    private fun amrapWeek(start: ProgramState, benchReps: Int): ProgramState {
        var s = start
        repeat(ns.days.size) {
            val day = E.plan(ns, s, 1).single()
            val ev = performed(day, repsFor = { ex, set, i ->
                val de = ns.days[day.dayIndex].exercises.first { it.lift == ex.key }
                val idx = de.amrapSet ?: ex.sets.indexOfFirst { it.isAmrap }
                if (!ex.accessory && i == idx) (if (ex.key == "bench") benchReps else 5) else set.targetReps
            })
            s = E.apply(ns, s, ev)
        }
        return s
    }

    private fun gzclp() = ProgramDefinition(
        schemaVersion = 1,
        name = "gzclp-t1",
        lifts = mapOf("squat" to lift("sq-id")),
        progression = mapOf(
            "squat" to Rule.Stages(
                incrementKg = 5.0,
                stages = listOf(Stage(5, 3), Stage(6, 2), Stage(10, 1, lastAmrap = true)),
                deloadPercent = 0.1,
            ),
        ),
        days = listOf(Day("T1", "T1", null, listOf(DayExercise("squat", sets = listOf(spec(3, Load.Working())))))),
    )
}
