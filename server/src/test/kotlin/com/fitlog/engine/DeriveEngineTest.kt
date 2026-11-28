package com.fitlog.engine

import com.fitlog.engine.EngineTestUtil.E
import com.fitlog.engine.EngineTestUtil.lift
import com.fitlog.engine.EngineTestUtil.spec
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** v1.1 계약 4절: derive(자동 계산)와 fromFirstSession(첫 운동에서 정하기) 엔진 동작 */
class DeriveEngineTest {
    private fun def(
        rounding: Double = 2.5,
        derive: Derive? = Derive("squat", 0.8),
        firstSession: Boolean = false,
        fsRule: Rule = Rule.Linear(2.5),
    ) = ProgramDefinition(
        schemaVersion = 1, name = "d", roundingKg = rounding,
        lifts = mapOf(
            "squat" to lift("a"),
            "front" to lift("b").copy(derive = derive),
            "curl" to lift("c").copy(fromFirstSession = firstSession),
        ),
        progression = mapOf("squat" to Rule.Linear(5.0), "curl" to fsRule),
        days = listOf(
            Day("A", "A", null, listOf(
                DayExercise("squat", sets = listOf(spec(5, Load.Working(), count = 3))),
                DayExercise("front", sets = listOf(spec(5, Load.Working(), count = 3))),
                DayExercise("curl", sets = listOf(spec(10, Load.Working(), count = 2))),
            )),
        ),
    )

    @Test
    fun derive_key_is_optional_and_filled_with_floor_rounding() {
        val p = def()
        assertTrue("front" in E.optionalInputs(p))
        // 101 x 0.8 = 80.8 -> 2.5 단위 내림 80.0
        val s = E.initialState(p, emptyMap(), mapOf("squat" to 101.0, "curl" to 10.0))
        assertEquals(80.0, s.working["front"])
        // 123 x 0.8 = 98.4 -> 97.5 (반올림이면 97.5 가 아닌 값이 나오는 경계: 내림 확인)
        assertEquals(97.5, E.initialState(p, emptyMap(), mapOf("squat" to 123.0, "curl" to 10.0)).working["front"])
        // 124 x 0.8 = 99.2 -> 97.5 (가까운 반올림이면 100.0)
        assertEquals(97.5, E.initialState(p, emptyMap(), mapOf("squat" to 124.0, "curl" to 10.0)).working["front"])
    }

    @Test
    fun user_value_wins_over_derive() {
        val s = E.initialState(def(), emptyMap(), mapOf("squat" to 100.0, "front" to 70.0, "curl" to 10.0))
        assertEquals(70.0, s.working["front"])
    }

    @Test
    fun derive_result_below_one_step_becomes_rounding_unit() {
        val p = def(derive = Derive("squat", 0.05))
        val s = E.initialState(p, emptyMap(), mapOf("squat" to 20.0, "curl" to 10.0)) // 1.0 -> 0 -> 2.5
        assertEquals(2.5, s.working["front"])
    }

    @Test
    fun missing_required_non_derive_key_still_fails() {
        assertFailsWith<IllegalArgumentException> { E.initialState(def(), emptyMap(), mapOf("squat" to 100.0)) }
        assertFailsWith<IllegalArgumentException> { E.initialState(def(), emptyMap(), mapOf("front" to 60.0, "curl" to 10.0)) }
    }

    @Test
    fun derive_from_tm_key_fills_tm() {
        val p = ProgramDefinition(
            schemaVersion = 1, name = "t", roundingKg = 2.5,
            lifts = mapOf("squat" to lift("a"), "front" to lift("b").copy(derive = Derive("squat", 0.8))),
            days = listOf(Day("A", "A", null, listOf(
                DayExercise("squat", sets = listOf(spec(5, Load.PercentTm(0.9)))),
                DayExercise("front", sets = listOf(spec(5, Load.PercentTm(0.9)))),
            ))),
        )
        val s = E.initialState(p, mapOf("squat" to 100.0), emptyMap())
        assertEquals(80.0, s.tm["front"])
        assertEquals(72.5, E.plan(p, s, 1).single().exercises[1].sets[0].targetWeightKg) // 80 x 0.9 = 72 -> 72.5
    }

    @Test
    fun from_first_session_starts_empty_then_sets_working_and_progresses_linear() {
        val p = def(firstSession = true)
        assertTrue("curl" in E.optionalInputs(p))
        val s0 = E.initialState(p, emptyMap(), mapOf("squat" to 100.0))
        assertNull(s0.working["curl"])
        val day1 = E.plan(p, s0, 1).single()
        assertNull(day1.exercises[2].sets[0].targetWeightKg)
        // 첫 세트 15, 둘째 세트 12.5: 판정 세트 중 최소 무게(12.5)가 working, 목표를 채웠으니 +2.5
        val ev = EngineTestUtil.performed(day1, weightFor = { ex, set, i -> if (ex.key == "curl") (if (i == 0) 15.0 else 12.5) else set.targetWeightKg })
        val s1 = E.apply(p, s0, ev)
        assertEquals(15.0, s1.working["curl"])
        assertEquals(15.0, EngineTestUtil.weights(E.plan(p, s1, 1).single(), "curl")[0])
    }

    @Test
    fun from_first_session_failure_keeps_weight_and_counts_fail() {
        val p = def(firstSession = true)
        val s0 = E.initialState(p, emptyMap(), mapOf("squat" to 100.0))
        val day1 = E.plan(p, s0, 1).single()
        val ev = EngineTestUtil.performed(
            day1,
            repsFor = { ex, set, _ -> if (ex.key == "curl") 5 else set.targetReps },
            weightFor = { ex, set, _ -> if (ex.key == "curl") 10.0 else set.targetWeightKg },
        )
        val s1 = E.apply(p, s0, ev)
        assertEquals(10.0, s1.working["curl"])
        assertEquals(1, s1.failStreak["curl"])
    }

    @Test
    fun from_first_session_works_for_stages_and_waits_for_a_weight() {
        val stages = Rule.Stages(2.5, listOf(Stage(3, 10), Stage(4, 8)))
        val p = def(firstSession = true, fsRule = stages)
        val s0 = E.initialState(p, emptyMap(), mapOf("squat" to 100.0))
        val day1 = E.plan(p, s0, 1).single()
        // 무게 기록이 없으면 아직 정해지지 않는다
        val noWeight = E.apply(p, s0, EngineTestUtil.performed(day1, weightFor = { ex, set, _ -> if (ex.key == "curl") null else set.targetWeightKg }))
        assertNull(noWeight.working["curl"])
        val ev = EngineTestUtil.performed(day1, weightFor = { ex, set, _ -> if (ex.key == "curl") 20.0 else set.targetWeightKg })
        assertEquals(22.5, E.apply(p, s0, ev).working["curl"])
    }

    @Test
    fun replay_with_first_session_is_deterministic() {
        val p = def(firstSession = true)
        val s0 = E.initialState(p, emptyMap(), mapOf("squat" to 100.0))
        val events = ArrayList<ProgramEvent>()
        var s = s0
        for (i in 0 until 4) {
            val day = E.plan(p, s, 1).single()
            val ev = EngineTestUtil.performed(day, weightFor = { ex, set, _ -> if (ex.key == "curl" && i == 0) 12.5 else set.targetWeightKg })
            events += ev
            s = E.apply(p, s, ev)
        }
        assertEquals(s, E.replay(p, s0, events))
        assertEquals(s, E.replay(p, s0, events))
        assertEquals(22.5, s.working["curl"]) // 12.5 에서 시작해 네 번 모두 성공: +2.5 x 4 = 22.5
    }

    @Test
    fun definition_without_new_fields_has_no_new_optional_keys() {
        assertEquals(emptySet(), E.optionalInputs(def(derive = null)))
    }
}
