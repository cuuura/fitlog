package com.fitlog.engine

import com.fitlog.core.AppJson
import com.fitlog.engine.EngineTestUtil.E
import com.fitlog.engine.EngineTestUtil.performed
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** contracts/v1.2/edit.md 9절 C1~C11 (엔진). C12 는 program/schema/CustomRuleValidatorTest */
class EngineV12Test {
    private val exId = "019b76da-4000-7000-8000-000000000001"

    private val working5x5 = """{"count":5,"reps":5,"load":{"type":"WORKING"}}"""

    private fun def(
        rule: String,
        sets: String = working5x5,
        extra: String = "",
        days: String? = null,
    ): ProgramDefinition = AppJson.decodeFromString(
        """{"schemaVersion":1,"name":"P","roundingKg":2.5,"barKg":0,$extra
          "lifts":{"squat":{"exercise":{"id":"$exId"}}},
          "progression":{"squat":$rule},
          "days":${days ?: """[{"key":"A","name":"A","exercises":[{"lift":"squat","sets":[$sets]}]}]"""}}""",
    )

    private fun three(sets: String) =
        """[{"key":"A","name":"A","exercises":[{"lift":"squat","sets":[$sets]}]},
            {"key":"B","name":"B","exercises":[{"lift":"squat","sets":[$sets]}]},
            {"key":"C","name":"C","exercises":[{"lift":"squat","sets":[$sets]}]}]"""

    private fun start(p: ProgramDefinition, tm: Double? = null, working: Double? = null) =
        E.initialState(p, tm?.let { mapOf("squat" to it) } ?: emptyMap(), working?.let { mapOf("squat" to it) } ?: emptyMap())

    /** 계획대로 한 회차. [reps] 로 모든 세트 횟수를 바꾼다 */
    private fun doStep(p: ProgramDefinition, s: ProgramState, reps: ((Int) -> Int)? = null, weight: Double? = null): ProgramState {
        val day = E.plan(p, s, 1).single()
        val ev = performed(
            day,
            repsFor = { _, set, i -> reps?.invoke(i) ?: set.targetReps },
            weightFor = { _, set, _ -> weight ?: set.targetWeightKg },
        )
        return E.apply(p, s, ev)
    }

    private fun fail(p: ProgramDefinition, s: ProgramState) = doStep(p, s, reps = { 0 })

    private val c1 = """{"type":"CUSTOM","success":{"when":"ALL_SETS","method":"ADD_KG","amount":2.5}}"""

    @Test
    fun c1_all_sets_add_kg() {
        val p = def(c1)
        val s = doStep(p, start(p, working = 100.0))
        assertEquals(102.5, s.working["squat"])
    }

    @Test
    fun c2_after_consecutive_two() {
        val p = def("""{"type":"CUSTOM","success":{"when":"ALL_SETS","afterConsecutive":2,"method":"ADD_KG","amount":2.5}}""")
        val s1 = doStep(p, start(p, working = 100.0))
        assertEquals(100.0, s1.working["squat"])
        assertEquals(1, s1.successStreak["squat"])
        val s2 = doStep(p, s1)
        assertEquals(102.5, s2.working["squat"])
        assertEquals(0, s2.successStreak["squat"])
    }

    @Test
    fun c3_failure_multiply_after_two() {
        val p = def("""{"type":"CUSTOM","success":{"amount":2.5},"failure":{"when":"ANY_SET","afterConsecutive":2,"method":"MULTIPLY","amount":0.9}}""")
        val s1 = fail(p, start(p, working = 100.0))
        assertEquals(100.0, s1.working["squat"])
        assertEquals(1, s1.failStreak["squat"])
        val s2 = fail(p, s1)
        assertEquals(90.0, s2.working["squat"])
        assertEquals(0, s2.failStreak["squat"])
    }

    @Test
    fun c4_no_failure_rule_keeps_weight() {
        val p = def(c1)
        var s = start(p, working = 100.0)
        repeat(5) { s = fail(p, s) }
        assertEquals(100.0, s.working["squat"])
    }

    @Test
    fun c5_add_percent() {
        val p = def("""{"type":"CUSTOM","success":{"method":"ADD_PERCENT","amount":0.05}}""")
        assertEquals(105.0, doStep(p, start(p, working = 100.0)).working["squat"])
    }

    private val tmAmrap = """{"count":1,"reps":5,"amrap":true,"load":{"type":"PERCENT_TM","value":1.0}}"""

    @Test
    fun c6_e1rm_on_tm() {
        val p = def(
            """{"type":"CUSTOM","target":"TM","success":{"method":"E1RM","amount":0.9}}""",
            sets = tmAmrap,
        )
        val day = E.plan(p, start(p, tm = 100.0), 1).single()
        val ev = performed(day, repsFor = { _, _, _ -> 8 }, weightFor = { _, _, _ -> 100.0 })
        assertEquals(114.0, E.apply(p, start(p, tm = 100.0), ev).tm["squat"]) // r2(126.67*0.9)
        // 현재 TM 이 더 크면 유지
        val s = start(p, tm = 120.0)
        val ev2 = performed(E.plan(p, s, 1).single(), repsFor = { _, _, _ -> 8 }, weightFor = { _, _, _ -> 100.0 })
        assertEquals(120.0, E.apply(p, s, ev2).tm["squat"])
        // 유효 세트(무게 없음)가 없으면 HOLD
        val ev3 = performed(E.plan(p, s, 1).single(), repsFor = { _, _, _ -> 8 }, weightFor = { _, _, _ -> null })
        // 계획 무게로 대체되므로 120*(1+8/30)*0.9 = 136.8 ≥ 120 → 오른다(무게가 아예 없는 경우만 HOLD)
        assertEquals(136.8, E.apply(p, s, ev3).tm["squat"])
    }

    private val amrapSteps = """"steps":[{"minReps":1,"maxReps":2,"amount":0},{"minReps":3,"maxReps":4,"amount":2.5},{"minReps":5,"amount":5}]"""

    @Test
    fun c7_amrap_reps_week_end_adds_at_week_end_and_failure_follows_amrap_below() {
        val p = def(
            """{"type":"CUSTOM","target":"TM","applyAt":"WEEK_END","success":{"when":"AMRAP_REPS"},"failure":{"when":"AMRAP_BELOW"},$amrapSteps}""",
            sets = """{"count":1,"reps":3,"amrap":true,"load":{"type":"PERCENT_TM","value":1.0}}""",
            days = three("""{"count":1,"reps":3,"amrap":true,"load":{"type":"PERCENT_TM","value":1.0}}"""),
        )
        var s = start(p, tm = 100.0)
        for (reps in listOf(3, 5)) {
            s = doStep(p, s, reps = { reps })
            assertEquals(100.0, s.tm["squat"], "주 중에는 반영하지 않는다")
        }
        s = doStep(p, s, reps = { 1 })
        assertEquals(107.5, s.tm["squat"])
        assertEquals(1, s.failStreak["squat"]) // 주 안에 AMRAP_BELOW(1 < 3) 가 있어 기간 FAIL
        assertTrue(s.periodResult.isEmpty() && s.pendingTmDelta.isEmpty())
    }

    @Test
    fun c8_week_end_all_sets_fail_beats_success() {
        val p = def(
            """{"type":"CUSTOM","applyAt":"WEEK_END","success":{"amount":2.5},"failure":{"afterConsecutive":3,"amount":0.9}}""",
            days = three(working5x5),
        )
        var s = start(p, working = 100.0)
        s = doStep(p, s)
        s = fail(p, s)
        assertEquals("FAIL", s.periodResult["squat"])
        s = doStep(p, s)
        assertEquals(100.0, s.working["squat"])
        assertEquals(1, s.failStreak["squat"])
        assertEquals(0, s.successStreak["squat"] ?: 0)
        assertTrue(s.periodResult.isEmpty())
    }

    @Test
    fun c8b_week_end_all_success_adds_once() {
        val p = def("""{"type":"CUSTOM","applyAt":"WEEK_END","success":{"amount":2.5}}""", days = three(working5x5))
        var s = start(p, working = 100.0)
        repeat(3) { s = doStep(p, s) }
        assertEquals(102.5, s.working["squat"])
    }

    @Test
    fun c9_cycle_end_only_at_cycle_end() {
        val p = def("""{"type":"CUSTOM","applyAt":"CYCLE_END","success":{"amount":5}}""", extra = """"cycleWeeks":3,""")
        var s = start(p, working = 100.0)
        repeat(2) { s = doStep(p, s) }
        assertEquals(100.0, s.working["squat"])
        s = doStep(p, s)
        assertEquals(105.0, s.working["squat"])
        assertEquals(2, s.cycle)
    }

    @Test
    fun c10_range_top_working_without_start_weight() {
        val p = def(
            """{"type":"CUSTOM","success":{"when":"RANGE_TOP","amount":2.5}}""",
            sets = """{"count":3,"reps":8,"repsMax":12,"load":{"type":"WORKING"}}""",
        )
        assertEquals(setOf("squat"), E.optionalInputs(p))
        val s0 = start(p)
        assertNull(E.plan(p, s0, 1).single().exercises.single().sets.first().targetWeightKg)
        // 첫 회차: 실제 무게 중 최소로 확정하고 판정(모두 12회 → 증량)
        val s1 = doStep(p, s0, reps = { 12 }, weight = 60.0)
        assertEquals(62.5, s1.working["squat"])
        // 범위 안(8~11)이면 확정만 하고 유지
        val s1b = doStep(p, s0, reps = { 10 }, weight = 60.0)
        assertEquals(60.0, s1b.working["squat"])
    }

    @Test
    fun c10b_plan_assumes_hold_for_range_top() {
        val p = def(
            """{"type":"CUSTOM","success":{"when":"RANGE_TOP","amount":2.5}}""",
            sets = """{"count":3,"reps":8,"repsMax":12,"load":{"type":"WORKING"}}""",
        )
        val plan = E.plan(p, start(p, working = 60.0), 3)
        assertEquals(listOf(60.0, 60.0, 60.0), plan.map { it.exercises.single().sets.first().targetWeightKg })
    }

    @Test
    fun plan_assumes_success_for_all_sets() {
        val p = def(c1)
        val plan = E.plan(p, start(p, working = 100.0), 3)
        assertEquals(listOf(100.0, 102.5, 105.0), plan.map { it.exercises.single().sets.first().targetWeightKg })
    }

    @Test
    fun plan_assumes_hold_for_e1rm() {
        val p = def("""{"type":"CUSTOM","success":{"method":"E1RM","amount":0.9}}""")
        val plan = E.plan(p, start(p, working = 100.0), 3)
        assertEquals(listOf(100.0, 100.0, 100.0), plan.map { it.exercises.single().sets.first().targetWeightKg })
    }

    @Test
    fun plan_amrap_reps_assumes_success_with_positive_step() {
        val p = def(
            """{"type":"CUSTOM","target":"TM","success":{"when":"AMRAP_REPS"},$amrapSteps}""",
            sets = tmAmrap,
        )
        val plan = E.plan(p, start(p, tm = 100.0), 3)
        assertEquals(listOf(100.0, 105.0, 110.0), plan.map { it.exercises.single().sets.first().targetWeightKg }) // 목표 5회가 steps 5+ 구간(+5)
    }

    private val withDrop = """{"count":3,"reps":5,"load":{"type":"WORKING"}},{"count":1,"reps":10,"drop":true,"load":{"type":"WORKING","value":0.8}}"""

    @Test
    fun c11_drop_set_is_not_judged_and_plan_marks_it() {
        val p = def(c1, sets = withDrop)
        val s0 = start(p, working = 100.0)
        val day = E.plan(p, s0, 1).single()
        val sets = day.exercises.single().sets
        assertEquals(listOf(null, null, null, "DROP"), sets.map { it.setType })
        // 드롭 세트가 0회여도 성공
        val s1 = E.apply(p, s0, performed(day, repsFor = { _, set, _ -> if (set.setType == "DROP") 0 else set.targetReps }))
        assertEquals(102.5, s1.working["squat"])
        // 다른 규칙(LINEAR)에서도 제외
        val lin = def("""{"type":"LINEAR","incrementKg":2.5}""", sets = withDrop)
        val l1 = E.apply(lin, start(lin, working = 100.0), performed(E.plan(lin, start(lin, working = 100.0), 1).single(), repsFor = { _, set, _ -> if (set.setType == "DROP") 0 else set.targetReps }))
        assertEquals(102.5, l1.working["squat"])
    }

    @Test
    fun c11b_app_side_drop_set_type_is_excluded_like_warmup() {
        val p = def(c1)
        val s0 = start(p, working = 100.0)
        val day = E.plan(p, s0, 1).single()
        val ev = ProgramEvent.Completed(
            day.planSeq,
            listOf(
                PerformedExercise(
                    "squat", false,
                    day.exercises.single().sets.mapIndexed { i, s ->
                        PerformedSet(s.plannedSetKey, if (i == 4) 2 else 5, 100.0, false, if (i == 4) "DROP" else "NORMAL")
                    },
                ),
            ),
        )
        assertEquals(102.5, E.apply(p, s0, ev).working["squat"])
        // FAILURE 는 일반 세트처럼 판정
        val ev2 = ev.copy(exercises = listOf(ev.exercises.single().copy(sets = ev.exercises.single().sets.map { if (it.setType == "DROP") it.copy(setType = "FAILURE") else it })))
        assertEquals(100.0, E.apply(p, s0, ev2).working["squat"])
    }

    @Test
    fun superset_is_copied_to_plan_and_old_json_decodes() {
        val p = def(
            c1,
            days = """[{"key":"A","name":"A","exercises":[{"lift":"squat","superset":"A","sets":[$working5x5]}]}]""",
        )
        assertEquals("A", E.plan(p, start(p, working = 100.0), 1).single().exercises.single().superset)
        val old = AppJson.decodeFromString<ProgramState>("""{"tm":{},"working":{"squat":100.0},"seq":2}""")
        assertEquals(emptyMap(), old.successStreak)
        assertEquals(emptyMap(), old.periodResult)
    }

    @Test
    fun fail_beats_success_when_both_true() {
        // 모든 세트 하한 이상이면서(AMRAP_BELOW 가 아닌) RANGE_TOP 성공과 실패가 동시에 참일 수는 없지만,
        // AMRAP_REPS 에서 steps amount>0 인데 AMRAP_BELOW 이면 FAIL 이 이긴다
        val p = def(
            """{"type":"CUSTOM","target":"TM","success":{"when":"AMRAP_REPS"},"failure":{"when":"AMRAP_BELOW","afterConsecutive":1,"amount":0.9},
               "steps":[{"minReps":1,"amount":2.5}]}""",
            sets = """{"count":1,"reps":5,"amrap":true,"load":{"type":"PERCENT_TM","value":1.0}}""",
        )
        val s = doStep(p, start(p, tm = 100.0), reps = { 3 })
        assertEquals(90.0, s.tm["squat"])
    }
}
