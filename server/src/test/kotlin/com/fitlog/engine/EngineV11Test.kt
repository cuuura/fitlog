package com.fitlog.engine

import com.fitlog.core.AppJson
import com.fitlog.core.ErrorDetail
import com.fitlog.engine.EngineTestUtil.E
import com.fitlog.engine.EngineTestUtil.performed
import com.fitlog.support.fitlogTest
import com.fitlog.program.instance.insertProgram
import com.fitlog.program.instance.startInstance
import com.fitlog.program.schema.ExerciseResolver
import com.fitlog.program.schema.ProgramValidator
import com.fitlog.program.schema.ResolveResult
import com.fitlog.program.schema.ValidationResult
import com.fitlog.records.SuggestItem
import com.fitlog.session.insertExercise
import com.fitlog.session.newId
import com.fitlog.support.createUser
import com.fitlog.support.jsonClient
import io.ktor.http.HttpStatusCode
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import java.io.File
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** contracts/v1.1/program-ext.md 6절 테스트 벡터 */
class EngineV11Test {
    private val exId = "019b76da-4000-7000-8000-000000000001"

    private fun def(
        sets: String,
        rule: String = """{"type":"DOUBLE","incrementKg":2.5}""",
        extra: String = "",
        days: String? = null,
    ): ProgramDefinition = AppJson.decodeFromString(
        """{"schemaVersion":1,"name":"P","roundingKg":2.5,"barKg":0,$extra
          "lifts":{"squat":{"exercise":{"id":"$exId"}}},
          "progression":{"squat":$rule},
          "days":${days ?: """[{"key":"A","name":"A","exercises":[{"lift":"squat","sets":[$sets]}]}]"""}}""",
    )

    private val double3x8to12 = """{"count":3,"reps":8,"repsMax":12,"load":{"type":"WORKING"}}"""

    /** 계획대로 무게, 세트마다 reps 를 [reps] 로 수행해 한 회차 진행 */
    private fun doStep(p: ProgramDefinition, s: ProgramState, reps: List<Int>, weights: List<Double?>? = null): ProgramState {
        val day = E.plan(p, s, 1).single()
        val ev = performed(
            day,
            repsFor = { _, _, i -> reps[i] },
            weightFor = { _, set, i -> if (weights != null) weights[i] else set.targetWeightKg },
        )
        return E.apply(p, s, ev)
    }

    // 1
    @Test
    fun double_hits_upper_bound_and_adds_increment() {
        val p = def(double3x8to12)
        val s = doStep(p, E.initialState(p, emptyMap(), mapOf("squat" to 40.0)), listOf(12, 12, 12))
        assertEquals(42.5, s.working["squat"])
        assertEquals(0, s.failStreak["squat"] ?: 0)
    }

    // 2
    @Test
    fun double_in_range_keeps_weight_and_resets_streak() {
        val p = def(double3x8to12)
        var s = E.initialState(p, emptyMap(), mapOf("squat" to 40.0)).copy(failStreak = mapOf("squat" to 2))
        s = doStep(p, s, listOf(12, 11, 10))
        assertEquals(40.0, s.working["squat"])
        assertEquals(0, s.failStreak["squat"])
    }

    // 3
    @Test
    fun double_three_failures_deload() {
        val p = def(double3x8to12)
        var s = E.initialState(p, emptyMap(), mapOf("squat" to 40.0))
        s = doStep(p, s, listOf(7, 8, 8))
        assertEquals(1, s.failStreak["squat"])
        s = doStep(p, s, listOf(7, 8, 8))
        assertEquals(2, s.failStreak["squat"])
        assertEquals(40.0, s.working["squat"])
        s = doStep(p, s, listOf(7, 8, 8))
        assertEquals(36.0, s.working["squat"])
        assertEquals(0, s.failStreak["squat"])
    }

    // 4
    @Test
    fun double_without_start_weight_fixes_minimum_logged_weight() {
        val p = def(double3x8to12)
        var s = E.initialState(p, emptyMap(), emptyMap())
        assertNull(s.working["squat"])
        s = doStep(p, s, List(3) { 10 }, listOf(42.5, 40.0, 40.0))
        assertEquals(40.0, s.working["squat"])
        assertEquals(0, s.failStreak["squat"])
        // replay 는 같은 결과
        val day = E.plan(p, E.initialState(p, emptyMap(), emptyMap()), 1).single()
        val ev = performed(day, repsFor = { _, _, _ -> 10 }, weightFor = { _, _, i -> listOf(42.5, 40.0, 40.0)[i] })
        assertEquals(s, E.replay(p, E.initialState(p, emptyMap(), emptyMap()), listOf(ev)))
        // 무게가 하나도 없으면 계속 없음
        val none = doStep(p, E.initialState(p, emptyMap(), emptyMap()), List(3) { 10 }, listOf(null, null, null))
        assertNull(none.working["squat"])
    }

    // 5
    @Test
    fun double_without_start_weight_plans_null_weight_and_instance_starts() {
        val p = def(double3x8to12)
        assertEquals(setOf("squat"), E.optionalInputs(p))
        assertEquals(mapOf("squat" to Needs.WORKING), E.requiredInputs(p))
        val plan = E.plan(p, E.initialState(p, emptyMap(), emptyMap()), 3)
        assertTrue(plan.all { d -> d.exercises.all { e -> e.sets.all { it.targetWeightKg == null } } })
        assertEquals(8, plan[0].exercises[0].sets[0].targetReps)
        assertEquals(12, plan[0].exercises[0].sets[0].targetRepsMax)
    }

    @Test
    fun double_instance_creation_without_working_returns_201_and_suggest_marks_optional() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val squat = insertExercise(null, "BARBELL")
        val d = def(double3x8to12).copy(lifts = mapOf("squat" to Lift(ExerciseRef(id = squat.toString()))))
        val pid = insertProgram(uid, d)
        val res = c.startInstance(uid, newId(), pid, tm = "{}", working = "{}")
        assertEquals(HttpStatusCode.Created, res.status)
        val item = SuggestItem("squat", UUID.randomUUID(), "WORKING", optional = true)
        assertTrue(AppJson.encodeToString(SuggestItem.serializer(), item).contains("\"optional\":true"))
        assertFalse(AppJson.encodeToString(SuggestItem.serializer(), item.copy(optional = null)).contains("optional"))
    }

    // 6
    @Test
    fun linear_uses_lower_bound_for_failure() {
        val p = def(
            """{"count":3,"reps":5,"repsMax":8,"load":{"type":"WORKING"}}""",
            rule = """{"type":"LINEAR","incrementKg":2.5}""",
        )
        val s = doStep(p, E.initialState(p, emptyMap(), mapOf("squat" to 100.0)), listOf(6, 6, 6))
        assertEquals(102.5, s.working["squat"])
        assertEquals(0, s.failStreak["squat"] ?: 0)
        val f = doStep(p, E.initialState(p, emptyMap(), mapOf("squat" to 100.0)), listOf(6, 6, 4))
        assertEquals(100.0, f.working["squat"])
        assertEquals(1, f.failStreak["squat"])
    }

    // 7
    @Test
    fun weekly_count_expands_per_week_with_continuous_keys() {
        val p = def(
            """{"count":3,"reps":5,"load":{"type":"WORKING"},"weekly":[{"count":5},{"count":4},{"count":3}]},
               {"reps":10,"load":{"type":"WORKING","value":0.5}}""",
            rule = """{"type":"NONE"}""",
        )
        val base = E.initialState(p, emptyMap(), mapOf("squat" to 100.0))
        val counts = (1..3).map { w -> E.plan(p, base.copy(week = w), 1).single().exercises[0].sets }
        assertEquals(listOf(6, 5, 4), counts.map { it.size })
        assertEquals((0..5).map { "A.0.$it" }, counts[0].map { it.plannedSetKey })
        assertEquals(10, counts[0].last().targetReps)
    }

    // 8
    @Test
    fun weekly_add_kg_applies_before_rounding() {
        val p = def(
            """{"reps":5,"load":{"type":"PERCENT_TM","value":0.7},"weekly":[{"addKg":0},{"addKg":5},{"addKg":10}]}""",
            rule = """{"type":"NONE"}""",
        ).let { it.copy(lifts = it.lifts) }
        val base = E.initialState(p, mapOf("squat" to 100.0), emptyMap())
        val w = (1..3).map { n -> E.plan(p, base.copy(week = n), 1).single().exercises[0].sets[0].targetWeightKg }
        assertEquals(listOf(70.0, 75.0, 80.0), w)
    }

    // 9
    @Test
    fun weekly_skip_removes_set_without_affecting_progression() {
        val p = def(
            """{"reps":5,"load":{"type":"WORKING"}},
               {"reps":10,"load":{"type":"WORKING","value":0.5},"weekly":[{},{},{},{"skip":true}]}""",
            rule = """{"type":"LINEAR","incrementKg":2.5}""",
        )
        val base = E.initialState(p, emptyMap(), mapOf("squat" to 100.0))
        assertEquals(2, E.plan(p, base.copy(week = 3), 1).single().exercises[0].sets.size)
        val w4 = E.plan(p, base.copy(week = 4), 1).single()
        assertEquals(listOf("A.0.0"), w4.exercises[0].sets.map { it.plannedSetKey })
        val after = E.apply(p, base.copy(week = 4), performed(w4))
        assertEquals(102.5, after.working["squat"])
    }

    @Test
    fun weekly_skip_of_every_set_drops_the_exercise_for_that_week() {
        val p = def(
            "",
            rule = """{"type":"NONE"}""",
            days = """[{"key":"A","name":"A","exercises":[
              {"lift":"squat","sets":[{"reps":5,"load":{"type":"WORKING"}}]},
              {"lift":"squat","sets":[{"reps":8,"load":{"type":"WORKING"},"weekly":[{},{"skip":true}]}]}]}]""",
        )
        val base = E.initialState(p, emptyMap(), mapOf("squat" to 100.0))
        val w2 = E.plan(p, base.copy(week = 2), 1).single()
        assertEquals(1, w2.exercises.size)
        assertEquals("A.0.0", w2.exercises[0].sets[0].plannedSetKey)
        assertEquals(2, E.plan(p, base, 1).single().exercises.size)
    }

    // 10
    @Test
    fun rest_sec_set_value_wins_over_exercise_value() {
        val p = def(
            """{"reps":5,"restSec":60,"load":{"type":"WORKING"}},{"reps":5,"load":{"type":"WORKING"}}""",
            rule = """{"type":"NONE"}""",
            days = """[{"key":"A","name":"A","exercises":[{"lift":"squat","restSec":120,"sets":[
               {"reps":5,"restSec":60,"load":{"type":"WORKING"}},{"reps":5,"load":{"type":"WORKING"}}]},
               {"lift":"squat","sets":[{"reps":5,"load":{"type":"WORKING"}}]}]}]""",
        )
        val day = E.plan(p, E.initialState(p, emptyMap(), mapOf("squat" to 100.0)), 1).single()
        assertEquals(listOf(60, 120), day.exercises[0].sets.map { it.restSec })
        assertNull(day.exercises[1].sets[0].restSec)
        assertNull(day.exercises[1].sets[0].targetRepsMax)
    }

    // 11
    @Test
    fun existing_templates_plan_like_before_the_change() {
        val names = listOf(
            "stronglifts-5x5", "nsuns-4day", "wendler-531-bbb", "gzclp", "texas-method", "nsuns-5day", "nsuns-6day",
            "wendler-531-bbs", "wendler-531-fsl", "wendler-531-beginners", "novice-3x5-ab", "greyskull-lp", "madcow-5x5",
        )
        val expected = Json.parseToJsonElement(File("src/test/resources/engine-v11-regression.json").readText()).let { it as kotlinx.serialization.json.JsonObject }
        assertEquals(names.toSet(), expected.keys)
        val ls = ListSerializer(PlannedDay.serializer())
        for (n in names) {
            val p: ProgramDefinition = AppJson.decodeFromString(File("src/main/resources/programs/$n.json").readText())
            val tm = HashMap<String, Double>()
            val wk = HashMap<String, Double>()
            E.requiredInputs(p).forEach { (k, need) -> if (need == Needs.TM) tm[k] = 100.0 else wk[k] = 60.0 }
            var s = E.initialState(p, tm, wk)
            val first = E.plan(p, s, 8)
            for (i in 0 until 12) {
                val day = E.plan(p, s, 1).single()
                s = E.apply(p, s, performed(day, repsFor = { _, set, si ->
                    if ((i % 3 == 2 || i % 5 == 4) && si == 0 && !set.isWarmup) maxOf(set.targetReps - 1, 0)
                    else if (set.isAmrap) set.targetReps + 3 else set.targetReps
                }))
            }
            val after = E.plan(p, s, 8)
            val exp = expected[n] as kotlinx.serialization.json.JsonObject
            assertEquals(exp["first"], Json.parseToJsonElement(AppJson.encodeToString(ls, first)), "$n first")
            assertEquals(exp["state"], Json.parseToJsonElement(AppJson.encodeToString(ProgramState.serializer(), s)), "$n state")
            assertEquals(exp["after"], Json.parseToJsonElement(AppJson.encodeToString(ls, after)), "$n after")
        }
    }

    // 12
    private val resolver: ExerciseResolver = { ref -> ResolveResult.Found(ref.id ?: exId) }

    private fun errorsOf(sets: String, rule: String = """{"type":"NONE"}""", days: String? = null): List<ErrorDetail> {
        val json = """{"schemaVersion":1,"name":"P","lifts":{"squat":{"exercise":{"id":"$exId"}}},
          "progression":{"squat":$rule},
          "days":${days ?: """[{"key":"A","name":"A","exercises":[{"lift":"squat","sets":[$sets]}]}]"""}}"""
        val r = ProgramValidator.validate(Json.parseToJsonElement(json), resolver)
        return if (r is ValidationResult.Invalid) r.errors else emptyList()
    }

    @Test
    fun validation_rejects_bad_ranges_and_double_with_percent_tm() {
        val ok = errorsOf("""{"reps":8,"repsMax":12,"restSec":90,"load":{"type":"WORKING"},"weekly":[{"count":4,"addKg":5,"repsMax":10}]}""")
        assertTrue(ok.isEmpty(), ok.toString())
        assertEquals(listOf("/days/0/exercises/0/sets/0/repsMax"), errorsOf("""{"reps":8,"repsMax":6,"load":{"type":"WORKING"}}""").map { it.path })
        assertEquals(listOf("/days/0/exercises/0/sets/0/repsMax"), errorsOf("""{"reps":8,"repsMax":12,"amrap":true,"load":{"type":"WORKING"}}""").map { it.path })
        assertEquals(
            listOf("/days/0/exercises/0/sets/0/load"),
            errorsOf("""{"reps":8,"repsMax":12,"load":{"type":"PERCENT_TM","value":0.7}}""", rule = """{"type":"DOUBLE","incrementKg":2.5}""").map { it.path },
        )
        // weekly 적용 후 기준
        assertTrue(errorsOf("""{"reps":8,"repsMax":10,"load":{"type":"WORKING"},"weekly":[{},{"reps":12}]}""").isNotEmpty())
        assertTrue(errorsOf("""{"reps":8,"repsMax":10,"load":{"type":"WORKING"},"weekly":[{"amrap":true}]}""").isNotEmpty())
        // 범위 밖 값
        assertTrue(errorsOf("""{"reps":8,"restSec":4000,"load":{"type":"WORKING"},"weekly":[{"count":21}]}""").size == 2)
    }

    @Test
    fun validation_rejects_a_week_where_every_exercise_is_skipped() {
        val days = """[{"key":"A","name":"A","exercises":[
          {"lift":"squat","sets":[{"reps":5,"load":{"type":"WORKING"},"weekly":[{},{"skip":true}]}]},
          {"lift":"squat","sets":[{"reps":5,"load":{"type":"WORKING"},"weekly":[{},{"skip":true}]}]}]}]"""
        val errs = errorsOf("", days = days)
        assertEquals(listOf("/days/0/exercises"), errs.map { it.path })
        val okDays = days.replace("""{"reps":5,"load":{"type":"WORKING"},"weekly":[{},{"skip":true}]}]}]}]""", """{"reps":5,"load":{"type":"WORKING"}}]}]}]""")
        assertTrue(errorsOf("", days = okDays).isEmpty())
        val r = ProgramValidator.validate(Json.parseToJsonElement(
            """{"schemaVersion":1,"name":"P","lifts":{"squat":{"exercise":{"id":"$exId"}}},
               "progression":{"squat":{"type":"DOUBLE","incrementKg":2.5}},
               "days":[{"key":"A","name":"A","exercises":[{"lift":"squat","sets":[{"reps":8,"repsMax":12,"load":{"type":"WORKING"}}]}]}]}"""), resolver)
        assertIs<ValidationResult.Valid>(r)
        assertIs<Rule.Double>((r as ValidationResult.Valid).definition.progression["squat"])
    }
}
