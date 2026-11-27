package com.fitlog.program.schema

import com.fitlog.program.catalog.ProgramTemplates
import kotlinx.serialization.json.Json
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue
import com.fitlog.engine.Rule

class TemplatesValidTest {
    /** SEED_EXERCISES.md 의 고정 id 를 그대로 읽어 "존재하는 종목"으로 쓴다 */
    private val seedIds: Set<String> by lazy {
        val text = javaClass.getResourceAsStream("/db/SEED_EXERCISES.md")!!.readBytes().toString(Charsets.UTF_8)
        Regex("`(019b76da-4000-7000-8000-[0-9a-f]{12})`").findAll(text).map { it.groupValues[1] }.toSet()
    }

    private val resolver: ExerciseResolver = { ref ->
        val id = ref.id
        if (id != null && id in seedIds) ResolveResult.Found(id) else ResolveResult.Failed("unknown exercise $id")
    }

    private fun validate(key: String) = ProgramValidator.validate(ProgramTemplates.readJson(key), resolver)

    @Test
    fun seed_list_has_77_ids() {
        assertEquals(77, seedIds.size)
    }

    @Test
    fun all_templates_pass_validation() {
        assertEquals(20, ProgramTemplates.all.size)
        for (t in ProgramTemplates.all) {
            val r = validate(t.key)
            assertTrue(r is ValidationResult.Valid, "${t.key}: ${(r as? ValidationResult.Invalid)?.errors}")
        }
    }

    @Test
    fun template_ids_are_fixed() {
        val ids = ProgramTemplates.all.map { it.id.toString() }
        assertEquals(
            (1..20).map { "019b76da-5000-7000-8000-%012x".format(it) },
            ids,
        )
        assertEquals(
            listOf(
                "stronglifts-5x5", "nsuns-4day", "wendler-531-bbb", "gzclp", "texas-method",
                "nsuns-5day", "nsuns-6day", "wendler-531-bbs", "wendler-531-fsl", "wendler-531-beginners",
                "novice-3x5-ab", "greyskull-lp", "madcow-5x5",
                "reddit-ppl-6day", "ppl-3day", "upper-lower-4day", "phul-4day", "fullbody-3day-beginner", "dumbbell-home-3day", "rippler-12week",
            ),
            ProgramTemplates.all.map { it.key },
        )
    }

    @Test
    fun contract_templates_are_identical_copies() {
        // 계약의 두 템플릿과 같은 JSON 인지 (서버 쪽 사본이 바뀌지 않았는지)
        val repoRoot = generateSequence(java.io.File("").absoluteFile) { it.parentFile }
            .firstOrNull { java.io.File(it, "contracts/v0.2/templates").isDirectory } ?: return
        for (k in listOf("stronglifts-5x5", "nsuns-4day")) {
            val contract = Json.parseToJsonElement(java.io.File(repoRoot, "contracts/v0.2/templates/$k.json").readText())
            assertEquals(contract, ProgramTemplates.readJson(k), k)
        }
    }

    @Test
    fun wendler_has_four_week_cycle_and_cycle_rules() {
        val d = (validate("wendler-531-bbb") as ValidationResult.Valid).definition
        assertEquals(4, d.cycleWeeks)
        assertEquals(4, d.days.size)
        assertEquals(5.0, (d.progression["squat"] as Rule.Cycle).incrementKg)
        assertEquals(5.0, (d.progression["deadlift"] as Rule.Cycle).incrementKg)
        assertEquals(2.5, (d.progression["bench"] as Rule.Cycle).incrementKg)
        assertEquals(2.5, (d.progression["ohp"] as Rule.Cycle).incrementKg)
        val main = d.days[0].exercises[0].sets
        assertEquals(3, main.size)
        assertTrue(main.all { it.weekly!!.size == 4 })
        val bbb = d.days[0].exercises[1]
        assertEquals(5, bbb.sets[0].count)
        assertEquals(10, bbb.sets[0].reps)
    }

    @Test
    fun gzclp_has_stages_and_amrap_table() {
        val d = (validate("gzclp") as ValidationResult.Valid).definition
        assertEquals(listOf("A1", "B1", "A2", "B2"), d.days.map { it.key })
        val t1 = d.progression["squat_t1"] as Rule.Stages
        assertEquals(listOf(5 to 3, 6 to 2, 10 to 1), t1.stages.map { it.sets to it.reps })
        val t2 = d.progression["bench_t2"] as Rule.Stages
        assertEquals(listOf(3 to 10, 3 to 8, 3 to 6), t2.stages.map { it.sets to it.reps })
        val t3 = d.progression["pulldown"]
        assertIs<Rule.AmrapTable>(t3)
        assertEquals(25, t3.table.last().minReps)
    }

    @Test
    fun texas_has_three_days_with_progression_only_on_intensity_day() {
        val d = (validate("texas-method") as ValidationResult.Valid).definition
        assertEquals(3, d.days.size)
        val vol = d.days[0].exercises
        assertTrue(vol.all { !it.countsForProgression })
        assertTrue(d.days[2].exercises.all { it.countsForProgression })
        assertTrue(d.progression.values.all { it is Rule.Linear })
    }
}
