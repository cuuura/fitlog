package com.fitlog.program.schema

import com.fitlog.core.ErrorDetail
import com.fitlog.engine.ExerciseRef
import kotlinx.serialization.json.Json
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue

/** v1.1 계약 4절 검증 규칙 */
class DeriveValidatorTest {
    private val ids = listOf("019b76da-4000-7000-8000-000000000001", "019b76da-4000-7000-8000-000000000002", "019b76da-4000-7000-8000-000000000003")
    private val resolver: ExerciseResolver = { r: ExerciseRef -> if (r.id in ids) ResolveResult.Found(r.id!!) else ResolveResult.Failed("no") }

    private fun lift(id: Int, extra: String = "") = """{"exercise":{"id":"${ids[id]}"}$extra}"""

    private val defaultProgression = """"squat":{"type":"LINEAR","incrementKg":2.5},"curl":{"type":"LINEAR","incrementKg":2.5}"""

    private fun program(
        lifts: String,
        progression: String = defaultProgression,
        curlLoad: String = """{"type":"WORKING"}""",
        frontLoad: String = """{"type":"WORKING"}""",
    ) = """
        {"schemaVersion":1,"name":"P","lifts":{$lifts},"progression":{$progression},
         "days":[{"key":"A","name":"A","exercises":[
           {"lift":"squat","sets":[{"count":3,"reps":5,"load":{"type":"WORKING"}}]},
           {"lift":"front","sets":[{"count":3,"reps":5,"load":$frontLoad}]},
           {"lift":"curl","sets":[{"count":2,"reps":10,"load":$curlLoad}]}]}]}
    """.trimIndent()

    private fun result(s: String) = ProgramValidator.validate(Json.parseToJsonElement(s), resolver)
    private fun errors(s: String): List<ErrorDetail> = (result(s) as? ValidationResult.Invalid ?: error("expected invalid")).errors
    private fun assertValid(s: String) = assertIs<ValidationResult.Valid>(result(s))

    private fun lifts(front: String = "", curl: String = "", squat: String = "") =
        """"squat":${lift(0, squat)},"front":${lift(1, front)},"curl":${lift(2, curl)}"""

    private val derive08 = ""","derive":{"from":"squat","ratio":0.8}"""

    @Test
    fun valid_derive_and_first_session_are_accepted_and_kept() {
        val r = result(program(lifts(front = derive08, curl = ""","fromFirstSession":true""")))
        val d = assertIs<ValidationResult.Valid>(r).definition
        assertEquals(0.8, d.lifts["front"]!!.derive!!.ratio)
        assertEquals("squat", d.lifts["front"]!!.derive!!.from)
        assertTrue(d.lifts["curl"]!!.fromFirstSession)
    }

    @Test
    fun derive_from_itself_is_rejected() {
        val e = errors(program(lifts(front = ""","derive":{"from":"front","ratio":0.8}""")))
        assertTrue(e.any { it.path == "/lifts/front/derive/from" })
    }

    @Test
    fun derive_chain_is_rejected() {
        val e = errors(program(lifts(front = derive08, squat = ""","derive":{"from":"curl","ratio":0.5}""")))
        assertTrue(e.any { it.path == "/lifts/front/derive/from" && "chain" in it.message })
    }

    @Test
    fun derive_unknown_from_and_ratio_range_are_rejected() {
        assertTrue(errors(program(lifts(front = ""","derive":{"from":"nope","ratio":0.8}"""))).any { it.path == "/lifts/front/derive/from" })
        assertTrue(errors(program(lifts(front = ""","derive":{"from":"squat","ratio":0.04}"""))).any { it.path == "/lifts/front/derive/ratio" })
        assertTrue(errors(program(lifts(front = ""","derive":{"from":"squat","ratio":2.1}"""))).any { it.path == "/lifts/front/derive/ratio" })
        assertValid(program(lifts(front = ""","derive":{"from":"squat","ratio":2.0}""")))
        assertValid(program(lifts(front = ""","derive":{"from":"squat","ratio":0.05}""")))
    }

    @Test
    fun derive_with_tm_from_is_rejected() {
        val e = errors(program(lifts(front = ""","tmFrom":"squat","derive":{"from":"squat","ratio":0.8}""")))
        assertTrue(e.any { it.path == "/lifts/front/tmFrom" })
    }

    @Test
    fun derive_on_key_without_input_or_from_key_without_input_is_rejected() {
        val fixed = errors(program(lifts(front = derive08), frontLoad = """{"type":"FIXED","kg":20}"""))
        assertTrue(fixed.any { it.path == "/lifts/front/derive" })
        val src = errors(program(lifts(front = ""","derive":{"from":"curl","ratio":0.8}"""), curlLoad = """{"type":"BODYWEIGHT"}"""))
        assertTrue(src.any { it.path == "/lifts/front/derive/from" })
    }

    @Test
    fun from_first_session_on_tm_key_is_rejected() {
        val e = errors(program(lifts(curl = ""","fromFirstSession":true"""), curlLoad = """{"type":"PERCENT_TM","value":0.8}"""))
        assertTrue(e.any { it.path == "/lifts/curl/fromFirstSession" && "WORKING" in it.message })
    }

    @Test
    fun from_first_session_needs_a_judging_rule_and_no_tm_from() {
        val noRule = errors(program(lifts(curl = ""","fromFirstSession":true"""), progression = """"squat":{"type":"LINEAR","incrementKg":2.5}"""))
        assertTrue(noRule.any { it.path == "/lifts/curl/fromFirstSession" })
        val withTmFrom = errors(program(lifts(curl = ""","tmFrom":"squat","fromFirstSession":true""")))
        assertTrue(withTmFrom.any { it.path == "/lifts/curl/tmFrom" })
    }

    @Test
    fun derive_from_a_key_that_can_start_empty_needs_a_judging_rule() {
        val doubleSquat = """"squat":{"type":"DOUBLE","incrementKg":2.5}"""
        val e = errors(program(lifts(front = derive08), progression = """$doubleSquat,"curl":{"type":"NONE"}"""))
        assertTrue(e.any { it.path == "/lifts/front/derive/from" })
        assertValid(program(lifts(front = derive08), progression = """$doubleSquat,"front":{"type":"DOUBLE","incrementKg":2.5},"curl":{"type":"NONE"}"""))
    }

    @Test
    fun unknown_property_in_derive_is_rejected() {
        val e = errors(program(lifts(front = ""","derive":{"from":"squat","ratio":0.8,"x":1}""")))
        assertTrue(e.any { it.path == "/lifts/front/derive/x" })
    }
}
