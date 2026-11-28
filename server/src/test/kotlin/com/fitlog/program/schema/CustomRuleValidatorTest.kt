package com.fitlog.program.schema

import com.fitlog.core.ErrorDetail
import com.fitlog.engine.ExerciseRef
import com.fitlog.engine.Rule
import kotlinx.serialization.json.Json
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue

/** contracts/v1.2/edit.md 9절 C12 + 1절 범위 검증 */
class CustomRuleValidatorTest {
    private val squatId = "019b76da-4000-7000-8000-000000000001"

    private val resolver: ExerciseResolver = { ref: ExerciseRef ->
        if (ref.id == squatId) ResolveResult.Found(squatId) else ResolveResult.Failed("unknown")
    }

    private fun program(rule: String, sets: String = """{"count":5,"reps":5,"load":{"type":"WORKING"}}""", extra: String = "", exExtra: String = "") = """
        {"schemaVersion":1,"name":"P",$extra
         "lifts":{"squat":{"exercise":{"id":"$squatId"}}},
         "progression":{"squat":$rule},
         "days":[{"key":"A","name":"A","exercises":[{"lift":"squat",$exExtra"sets":[$sets]}]}]}
    """.trimIndent()

    private fun errors(s: String): List<ErrorDetail> {
        val r = ProgramValidator.validate(Json.parseToJsonElement(s), resolver)
        assertIs<ValidationResult.Invalid>(r, "expected invalid but was $r")
        return r.errors
    }

    private fun valid(s: String) = (ProgramValidator.validate(Json.parseToJsonElement(s), resolver) as? ValidationResult.Valid
        ?: error("expected valid: " + ProgramValidator.validate(Json.parseToJsonElement(s), resolver))).definition

    private fun paths(s: String) = errors(s).map { it.path }

    private val ok = """{"type":"CUSTOM","success":{"when":"ALL_SETS","amount":2.5}}"""

    @Test
    fun valid_custom_rules_parse() {
        val d = valid(program(ok))
        val r = assertIs<Rule.Custom>(d.progression["squat"])
        assertEquals(1, r.success.afterConsecutive)
        valid(program("""{"type":"CUSTOM","success":{"method":"ADD_PERCENT","amount":0.05},"failure":{"method":"NONE"}}"""))
        valid(program("""{"type":"CUSTOM","target":"TM","success":{"method":"E1RM","amount":0.9}}""", """{"reps":5,"load":{"type":"PERCENT_TM","value":0.8}}"""))
        valid(
            program(
                """{"type":"CUSTOM","applyAt":"WEEK_END","success":{"when":"AMRAP_REPS"},"failure":{"when":"AMRAP_BELOW"},"steps":[{"minReps":1,"maxReps":2,"amount":0},{"minReps":3,"amount":2.5}]}""",
                """{"reps":5,"amrap":true,"load":{"type":"WORKING"}}""",
            ),
        )
        valid(program("""{"type":"CUSTOM","applyAt":"CYCLE_END","success":{"amount":2.5}}""", extra = """"cycleWeeks":4,"""))
    }

    @Test
    fun c12_target_mismatch() {
        // WORKING 하중인데 TM 대상
        assertTrue("/days/0/exercises/0/sets/0/load" in paths(program("""{"type":"CUSTOM","target":"TM","success":{"amount":2.5}}""")))
        // PERCENT_TM 하중인데 WORKING 대상(기본)
        val e = paths(program(ok, sets = """{"reps":5,"load":{"type":"PERCENT_TM","value":0.8}}"""))
        assertTrue("/days/0/exercises/0/sets/0/load" in e, "$e")
    }

    @Test
    fun c12_amrap_reps_without_steps() {
        val e = paths(program("""{"type":"CUSTOM","success":{"when":"AMRAP_REPS"}}""", """{"reps":5,"amrap":true,"load":{"type":"WORKING"}}"""))
        assertTrue("/progression/squat/steps" in e, "$e")
    }

    @Test
    fun c12_amrap_rules_without_amrap_set() {
        val steps = """"steps":[{"minReps":1,"amount":2.5}]"""
        assertTrue("/progression/squat" in paths(program("""{"type":"CUSTOM","success":{"when":"AMRAP_REPS"},$steps}""")))
        assertTrue("/progression/squat" in paths(program("""{"type":"CUSTOM","success":{"amount":2.5},"failure":{"when":"AMRAP_BELOW"}}""")))
    }

    @Test
    fun c12_cycle_end_without_cycle_weeks() {
        val e = paths(program("""{"type":"CUSTOM","applyAt":"CYCLE_END","success":{"amount":2.5}}"""))
        assertTrue("/progression/squat/applyAt" in e, "$e")
    }

    @Test
    fun c12_drop_with_amrap_or_warmup() {
        val a = paths(program(ok, """{"reps":5,"amrap":true,"drop":true,"load":{"type":"WORKING"}}"""))
        assertTrue("/days/0/exercises/0/sets/0/drop" in a, "$a")
        val w = paths(program(ok, """{"reps":5,"warmup":true,"drop":true,"load":{"type":"WORKING"}}"""))
        assertTrue("/days/0/exercises/0/sets/0/drop" in w, "$w")
        // 단독 drop 은 통과
        assertTrue(valid(program(ok, """{"reps":5,"load":{"type":"WORKING"}},{"reps":8,"drop":true,"load":{"type":"WORKING","value":0.8}}""")).days[0].exercises[0].sets[1].drop)
    }

    @Test
    fun ranges_are_enforced() {
        fun bad(rule: String, path: String) = assertTrue(path in paths(program(rule)), "$rule -> ${paths(program(rule))}")
        bad("""{"type":"CUSTOM","success":{"amount":60}}""", "/progression/squat/success/amount")
        bad("""{"type":"CUSTOM","success":{"method":"ADD_PERCENT","amount":0.6}}""", "/progression/squat/success/amount")
        bad("""{"type":"CUSTOM","success":{"method":"E1RM","amount":0.4}}""", "/progression/squat/success/amount")
        bad("""{"type":"CUSTOM","success":{"amount":1,"afterConsecutive":11}}""", "/progression/squat/success/afterConsecutive")
        bad("""{"type":"CUSTOM","success":{"amount":1},"failure":{"afterConsecutive":0,"amount":0.9}}""", "/progression/squat/failure/afterConsecutive")
        bad("""{"type":"CUSTOM","success":{"amount":1},"failure":{"amount":0.4}}""", "/progression/squat/failure/amount")
        bad("""{"type":"CUSTOM","success":{"amount":1},"failure":{"method":"SUBTRACT_KG"}}""", "/progression/squat/failure")
        bad("""{"type":"CUSTOM","success":{"amount":1},"failure":{"method":"BAD","amount":1}}""", "/progression/squat/failure/method")
        bad("""{"type":"CUSTOM","success":{"amount":1},"steps":[{"minReps":1,"amount":1}]}""", "/progression/squat/steps")
        bad("""{"type":"CUSTOM","applyAt":"WEEK_END","success":{"method":"E1RM","amount":0.9}}""", "/progression/squat/applyAt")
        bad("""{"type":"CUSTOM"}""", "/progression/squat")
        bad("""{"type":"CUSTOM","success":{"amount":1},"target":"X"}""", "/progression/squat/target")
    }

    @Test
    fun superset_is_validated_and_kept() {
        val d = valid(program(ok, exExtra = """"superset":"A","""))
        assertEquals("A", d.days[0].exercises[0].superset)
        assertTrue("/days/0/exercises/0/superset" in paths(program(ok, exExtra = """"superset":"","""))
        )
        assertTrue("/days/0/exercises/0/superset" in paths(program(ok, exExtra = """"superset":"123456789","""))
        )
    }
}
