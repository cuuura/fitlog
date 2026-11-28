package com.fitlog.engine

import com.fitlog.core.AppJson
import com.fitlog.program.catalog.ProgramTemplates
import com.fitlog.program.schema.ExerciseResolver
import com.fitlog.program.schema.ProgramValidator
import com.fitlog.program.schema.ResolveResult
import com.fitlog.program.schema.ValidationResult
import kotlinx.serialization.builtins.ListSerializer
import java.io.File
import java.security.MessageDigest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** C17: 기존 템플릿 전체의 계획·상태 전이가 v1.2 이전과 같다(골든 해시) */
class TemplateRegressionTest {
    private val seedIds: Set<String> by lazy {
        val text = javaClass.getResourceAsStream("/db/SEED_EXERCISES.md")!!.readBytes().toString(Charsets.UTF_8)
        Regex("`(019b76da-4000-7000-8000-[0-9a-f]{12})`").findAll(text).map { it.groupValues[1] }.toSet()
    }
    private val resolver: ExerciseResolver = { ref ->
        val id = ref.id
        if (id != null && id in seedIds) ResolveResult.Found(id) else ResolveResult.Failed("unknown exercise $id")
    }

    private fun fingerprint(key: String): String {
        val p = (ProgramValidator.validate(ProgramTemplates.readJson(key), resolver) as ValidationResult.Valid).definition
        val e = ProgramEngine
        val inputs = e.requiredInputs(p)
        val tm = inputs.filter { it.value == Needs.TM }.keys.associateWith { 100.0 }
        val wk = inputs.filter { it.value == Needs.WORKING }.keys.associateWith { 60.0 }
        var s = e.initialState(p, tm, wk)
        val sb = StringBuilder()
        for (i in 0 until 40) {
            val plan = e.plan(p, s, 6)
            sb.append(AppJson.encodeToString(ListSerializer(PlannedDay.serializer()), plan)).append('\n')
            val day = plan.first()
            val ev = EngineTestUtil.performed(day, repsFor = { ex, set, si ->
                when {
                    i % 4 == 3 -> 0
                    i % 7 == 5 && si == ex.sets.lastIndex -> maxOf(0, set.targetReps - 1)
                    else -> set.targetReps + (if (set.isAmrap) i % 5 else 0)
                }
            })
            s = e.apply(p, s, ev)
            sb.append(s.tm).append(s.working).append(s.stage).append(s.failStreak).append(s.pendingTmDelta)
                .append(s.week).append(s.cycle).append(s.nextDayIndex).append(s.seq).append('\n')
        }
        return MessageDigest.getInstance("SHA-256").digest(sb.toString().toByteArray()).joinToString("") { "%02x".format(it) }
    }

    @Test
    fun all_existing_templates_replay_and_plan_identically() {
        val golden = File("src/test/resources/template-regression.golden")
        val actual = ProgramTemplates.all.sortedBy { it.key }.joinToString("\n") { "${it.key} ${fingerprint(it.key)}" }
        if (System.getenv("UPDATE_GOLDEN") == "1") golden.writeText(actual + "\n")
        assertTrue(golden.exists(), "golden missing")
        assertEquals(golden.readText().trim(), actual)
    }
}
