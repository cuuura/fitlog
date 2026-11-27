package com.fitlog.program.schema

import com.fitlog.core.ErrorDetail
import com.fitlog.engine.ExerciseRef
import com.fitlog.engine.Load
import com.fitlog.engine.Rule
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue

class ProgramValidatorTest {
    private val squatId = "019b76da-4000-7000-8000-000000000001"
    private val benchId = "019b76da-4000-7000-8000-000000000003"
    private val myId = "11111111-1111-7111-8111-111111111111"

    /** 이름 사전을 가진 가짜 풀이. 알려진 id 와 이름 몇 개만 */
    private val resolver: ExerciseResolver = { ref: ExerciseRef ->
        val id = ref.id
        val name = ref.name
        when {
            id != null && id in setOf(squatId, benchId, myId) -> ResolveResult.Found(id)
            id != null -> ResolveResult.Failed("exercise '$id' does not exist")
            name != null && ProgramValidator.normalizeName(name) == "스쿼트" -> ResolveResult.Found(squatId)
            name != null && ProgramValidator.normalizeName(name) == "benchpress" -> ResolveResult.Found(benchId)
            else -> ResolveResult.Failed("no exercise named '$name'")
        }
    }

    private fun parse(s: String): JsonElement = Json.parseToJsonElement(s)

    private fun errors(s: String): List<ErrorDetail> {
        val r = ProgramValidator.validate(parse(s), resolver)
        assertIs<ValidationResult.Invalid>(r, "expected invalid but was $r")
        return r.errors
    }

    private fun valid(s: String) = (ProgramValidator.validate(parse(s), resolver) as? ValidationResult.Valid
        ?: error("expected valid: " + ProgramValidator.validate(parse(s), resolver))).definition

    private fun List<ErrorDetail>.paths() = map { it.path }

    private val base = """
        {"schemaVersion":1,"name":"P",
         "lifts":{"squat":{"exercise":{"id":"$squatId"}},"bench":{"exercise":{"name":"Bench Press"}}},
         "progression":{"squat":{"type":"LINEAR","incrementKg":2.5}},
         "days":[{"key":"A","name":"Day A","exercises":[
            {"lift":"squat","sets":[{"count":5,"reps":5,"load":{"type":"WORKING"}}]}]}]}
    """.trimIndent()

    @Test
    fun minimal_program_is_valid_and_names_are_resolved() {
        val d = valid(base)
        assertEquals(squatId, d.lifts["squat"]!!.exercise.id)
        assertEquals(benchId, d.lifts["bench"]!!.exercise.id)
        assertEquals(null, d.lifts["bench"]!!.exercise.name)
        assertEquals(2.5, d.roundingKg)
        assertIs<Rule.Linear>(d.progression["squat"])
        assertIs<Load.Working>(d.days[0].exercises[0].sets[0].load)
    }

    @Test
    fun category_is_optional_and_accepts_known_values() {
        assertEquals(null, valid(base).category)
        for (c in listOf("BODYBUILDING", "POWERBUILDING", "POWERLIFTING", "GENERAL_STRENGTH", "BODYWEIGHT")) {
            assertEquals(c, valid(base.replaceFirst("\"name\":\"P\",", "\"name\":\"P\",\"category\":\"$c\",")).category)
        }
    }

    @Test
    fun unknown_category_is_rejected_at_its_path() {
        val bad = base.replaceFirst("\"name\":\"P\",", "\"name\":\"P\",\"category\":\"CARDIO\",")
        assertTrue("/category" in errors(bad).paths())
        val lower = base.replaceFirst("\"name\":\"P\",", "\"name\":\"P\",\"category\":\"powerlifting\",")
        assertTrue("/category" in errors(lower).paths())
    }

    @Test
    fun name_resolution_failure_is_reported_at_the_name_path() {
        val e = errors(base.replace("Bench Press", "Nope"))
        assertEquals(listOf("/lifts/bench/exercise/name"), e.paths())
    }

    @Test
    fun unknown_id_is_reported() {
        val e = errors(base.replace(squatId, "019b76da-4000-7000-8000-0000000000ff"))
        assertEquals(listOf("/lifts/squat/exercise/id"), e.paths())
    }

    @Test
    fun non_uuid_id_and_both_id_and_name_are_errors() {
        val e1 = errors(base.replace("\"id\":\"$squatId\"", "\"id\":\"abc\""))
        assertEquals(listOf("/lifts/squat/exercise/id"), e1.paths())
        val e2 = errors(base.replace("\"id\":\"$squatId\"", "\"id\":\"$squatId\",\"name\":\"x\""))
        assertEquals(listOf("/lifts/squat/exercise"), e2.paths())
    }

    @Test
    fun many_errors_are_reported_together() {
        val e = errors(
            """
            {"schemaVersion":2,"name":"","bogus":1,"roundingKg":3,
             "lifts":{"Bad Key":{"exercise":{"id":"$squatId"}},"squat":{"exercise":{"id":"$squatId"},"x":1}},
             "progression":{"ghost":{"type":"LINEAR","incrementKg":2.5}},
             "days":[{"key":"A","name":"a","exercises":[{"lift":"nope","sets":[{"reps":5,"load":{"type":"WORKING"}}]}]},
                     {"key":"A","name":"b","exercises":[{"lift":"squat","sets":[{"reps":500,"load":{"type":"FIXED"}}]}]}]}
            """.trimIndent(),
        ).paths().toSet()
        val expected = setOf(
            "/schemaVersion", "/name", "/bogus", "/roundingKg", "/lifts/Bad Key", "/lifts/squat/x", "/progression/ghost",
            "/days/0/exercises/0/lift", "/days/1/key", "/days/1/exercises/0/sets/0/reps", "/days/1/exercises/0/sets/0/load",
        )
        assertTrue(e.size >= expected.size)
        for (p in expected) assertTrue(p in e, "missing $p in $e")
    }

    @Test
    fun missing_required_fields_and_wrong_types() {
        val e = errors("""{"name":5,"lifts":[],"days":"x"}""")
        val p = e.paths()
        assertTrue("" in p)               // missing schemaVersion
        assertTrue("/name" in p)
        assertTrue("/lifts" in p)
        assertTrue("/days" in p)
        assertTrue(errors("[]").paths() == listOf(""))
    }

    @Test
    fun ranges_and_enums() {
        val e = errors(
            base.replace("\"name\":\"P\"", "\"name\":\"P\",\"tmPercent\":0,\"workingPercent\":1.5,\"barKg\":-1,\"cycleWeeks\":53,\"roundingKg\":2")
                .replace("\"count\":5,\"reps\":5", "\"count\":0,\"reps\":-1")
                .replace("\"incrementKg\":2.5", "\"incrementKg\":2.5,\"failuresBeforeDeload\":0,\"deloadPercent\":0.6"),
        ).paths().toSet()
        for (p in listOf("/tmPercent", "/workingPercent", "/barKg", "/cycleWeeks", "/roundingKg", "/days/0/exercises/0/sets/0/count",
            "/days/0/exercises/0/sets/0/reps", "/progression/squat/failuresBeforeDeload", "/progression/squat/deloadPercent")) {
            assertTrue(p in e, "missing $p in $e")
        }
    }

    @Test
    fun array_sizes() {
        val e = errors(
            """{"schemaVersion":1,"name":"P","lifts":{"squat":{"exercise":{"id":"$squatId"}}},
               "days":[{"key":"A","name":"a","exercises":[]}]}""",
        )
        assertEquals(listOf("/days/0/exercises"), e.paths())
        val e2 = errors(
            """{"schemaVersion":1,"name":"P","lifts":{},"days":[]}""",
        ).paths()
        assertEquals(setOf("/lifts", "/days"), e2.toSet())
    }

    @Test
    fun load_variants_oneof() {
        fun withLoad(l: String) = base.replace("""{"type":"WORKING"}""", l)
        assertIs<Load.PercentTm>(valid(withLoad("""{"type":"PERCENT_TM","value":0.9,"of":"bench"}""")).days[0].exercises[0].sets[0].load)
        assertIs<Load.Fixed>(valid(withLoad("""{"type":"FIXED","kg":20}""")).days[0].exercises[0].sets[0].load)
        assertIs<Load.Bodyweight>(valid(withLoad("""{"type":"BODYWEIGHT"}""")).days[0].exercises[0].sets[0].load)
        assertIs<Load.NoLoad>(valid(withLoad("""{"type":"NONE"}""")).days[0].exercises[0].sets[0].load)
        assertEquals(listOf("/days/0/exercises/0/sets/0/load"), errors(withLoad("""{"type":"PERCENT_TM"}""")).paths())
        assertEquals(listOf("/days/0/exercises/0/sets/0/load/value"), errors(withLoad("""{"type":"FIXED","kg":1,"value":1}""")).paths())
        assertEquals(listOf("/days/0/exercises/0/sets/0/load/value"), errors(withLoad("""{"type":"NONE","value":1}""")).paths())
        assertEquals(listOf("/days/0/exercises/0/sets/0/load/type"), errors(withLoad("""{"type":"MAGIC"}""")).paths())
        assertEquals(listOf("/days/0/exercises/0/sets/0/load/value"), errors(withLoad("""{"type":"PERCENT_TM","value":1.6}""")).paths())
    }

    @Test
    fun load_of_and_tmFrom_must_reference_lifts() {
        val e = errors(
            base.replace("""{"type":"WORKING"}""", """{"type":"PERCENT_TM","value":1,"of":"ghost"}""")
                .replace("""{"exercise":{"id":"$squatId"}}""", """{"exercise":{"id":"$squatId"},"tmFrom":"ghost2"}"""),
        ).paths().toSet()
        assertEquals(setOf("/days/0/exercises/0/sets/0/load/of", "/lifts/squat/tmFrom"), e)
    }

    @Test
    fun rule_variants_and_unknown_keys() {
        fun withRule(r: String) = base.replace("""{"type":"LINEAR","incrementKg":2.5}""", r)
        assertIs<Rule.Cycle>(valid(withRule("""{"type":"CYCLE","incrementKg":5}""")).progression["squat"])
        assertIs<Rule.NoRule>(valid(withRule("""{"type":"NONE"}""")).progression["squat"])
        assertEquals(listOf("/progression/squat/stages"), errors(withRule("""{"type":"STAGES","incrementKg":5,"stages":[]}""")).paths())
        assertEquals(listOf("/progression/squat"), errors(withRule("""{"type":"LINEAR"}""")).paths())
        assertEquals(listOf("/progression/squat/type"), errors(withRule("""{"type":"WEIRD"}""")).paths())
        assertEquals(listOf("/progression/squat/table"), errors(withRule("""{"type":"LINEAR","incrementKg":1,"table":[]}""")).paths())
    }

    @Test
    fun duplicate_day_keys() {
        val d = """{"key":"A","name":"a","exercises":[{"lift":"squat","sets":[{"reps":5,"load":{"type":"NONE"}}]}]}"""
        val e = errors("""{"schemaVersion":1,"name":"P","lifts":{"squat":{"exercise":{"id":"$squatId"}}},"days":[$d,$d]}""")
        assertEquals(listOf("/days/1/key"), e.paths())
    }

    @Test
    fun amrap_set_must_be_within_expanded_sets() {
        // 5 + 1 = 6 세트 → 인덱스 0..5
        fun prog(i: Int) = base.replace(
            """{"lift":"squat","sets":[{"count":5,"reps":5,"load":{"type":"WORKING"}}]}""",
            """{"lift":"squat","amrapSet":$i,"sets":[{"count":5,"reps":5,"load":{"type":"WORKING"}},{"reps":1,"amrap":true,"load":{"type":"WORKING"}}]}""",
        )
        assertEquals(5, valid(prog(5)).days[0].exercises[0].amrapSet)
        assertEquals(listOf("/days/0/exercises/0/amrapSet"), errors(prog(6)).paths())
    }

    @Test
    fun amrap_table_requires_an_amrap_set() {
        val table = """{"type":"AMRAP_TABLE","table":[{"minReps":0,"incrementKg":2.5}]}"""
        val noAmrap = base.replace("""{"type":"LINEAR","incrementKg":2.5}""", table)
        assertEquals(listOf("/progression/squat"), errors(noAmrap).paths())
        val withAmrap = noAmrap.replace("\"count\":5,\"reps\":5", "\"count\":1,\"reps\":5,\"amrap\":true")
        assertIs<Rule.AmrapTable>(valid(withAmrap).progression["squat"])
        // weekly 의 amrap 도 인정
        val weeklyAmrap = noAmrap.replace("\"count\":5,\"reps\":5", "\"count\":1,\"reps\":5,\"weekly\":[{\"amrap\":true}]")
        valid(weeklyAmrap)
    }

    @Test
    fun amrap_table_row_max_must_not_be_below_min() {
        val bad = base.replace(
            """{"type":"LINEAR","incrementKg":2.5}""",
            """{"type":"AMRAP_TABLE","table":[{"minReps":5,"maxReps":2,"incrementKg":2.5}]}""",
        ).replace("\"count\":5,\"reps\":5", "\"count\":1,\"reps\":5,\"amrap\":true")
        assertEquals(listOf("/progression/squat/table/0/maxReps"), errors(bad).paths())
    }

    @Test
    fun stages_lift_sets_must_use_working_load() {
        val stages = """{"type":"STAGES","incrementKg":5,"stages":[{"sets":5,"reps":3}]}"""
        val ok = base.replace("""{"type":"LINEAR","incrementKg":2.5}""", stages)
        valid(ok)
        val bad = ok.replace("""{"type":"WORKING"}""", """{"type":"PERCENT_TM","value":0.8}""")
        assertEquals(listOf("/days/0/exercises/0/sets/0/load"), errors(bad).paths())
    }

    @Test
    fun weekly_length_must_not_exceed_cycle_weeks() {
        fun prog(weeks: Int, n: Int) = base.replace("\"name\":\"P\"", "\"name\":\"P\",\"cycleWeeks\":$weeks").replace(
            "\"count\":5,\"reps\":5",
            "\"count\":1,\"reps\":5,\"weekly\":[" + List(n) { "{\"reps\":3}" }.joinToString(",") + "]",
        )
        valid(prog(4, 4))
        assertEquals(listOf("/days/0/exercises/0/sets/0/weekly"), errors(prog(4, 5)).paths())
        // cycleWeeks 가 없으면 길이 제한 없음
        valid(base.replace("\"count\":5,\"reps\":5", "\"count\":1,\"reps\":5,\"weekly\":[{},{},{},{},{},{}]"))
    }

    @Test
    fun weekday_enum_and_day_key_pattern() {
        val e = errors(base.replace("\"key\":\"A\"", "\"key\":\"A-1\",\"weekday\":\"FUNDAY\""))
        assertEquals(setOf("/days/0/key", "/days/0/weekday"), e.paths().toSet())
        valid(base.replace("\"key\":\"A\"", "\"key\":\"A\",\"weekday\":\"MON\""))
    }

    @Test
    fun json_pointer_escapes_special_characters_in_keys() {
        val e = errors(base.replace("\"progression\"", "\"progression\":{\"a/b\":{\"type\":\"NONE\"}},\"x\""))
        assertTrue("/progression/a~1b" in e.paths(), e.toString())
    }

    @Test
    fun integer_values_accept_whole_floats_only() {
        valid(base.replace("\"count\":5", "\"count\":5.0"))
        assertEquals(listOf("/days/0/exercises/0/sets/0/count"), errors(base.replace("\"count\":5", "\"count\":5.5")).paths())
        assertEquals(listOf("/days/0/exercises/0/sets/0/count"), errors(base.replace("\"count\":5", "\"count\":\"5\"")).paths())
    }

    @Test
    fun orThrow_produces_the_api_error() {
        val r = ProgramValidator.validate(parse("{}"), resolver)
        val ex = runCatching { r.orThrow() }.exceptionOrNull() as com.fitlog.core.ApiException
        assertEquals(com.fitlog.core.ErrorCode.VALIDATION_FAILED, ex.code)
        assertEquals("program definition is invalid", ex.message)
        assertTrue(ex.details!!.isNotEmpty())
    }
}
