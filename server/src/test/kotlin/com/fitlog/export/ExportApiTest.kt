package com.fitlog.export

import com.fitlog.core.AppJson
import com.fitlog.core.BodyMeasurements
import com.fitlog.core.ChangeSeq
import com.fitlog.core.Exercises
import com.fitlog.core.WorkoutSessions
import com.fitlog.session.arr
import com.fitlog.session.get
import com.fitlog.session.obj
import com.fitlog.support.auth
import com.fitlog.support.createUser
import com.fitlog.support.fitlogTest
import com.fitlog.support.jsonClient
import io.ktor.client.request.get
import io.ktor.client.statement.bodyAsBytes
import io.ktor.client.statement.bodyAsText
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.jetbrains.exposed.sql.SqlExpressionBuilder.eq
import org.jetbrains.exposed.sql.transactions.transaction
import org.jetbrains.exposed.sql.selectAll
import org.jetbrains.exposed.sql.update
import java.io.File
import java.math.BigDecimal
import java.time.Instant
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** import.schema.json 을 읽어 필요한 부분(타입·필수·additionalProperties·enum·범위·$ref·oneOf)만 대조하는 간이 검사기 */
class MiniSchema(private val root: JsonObject) {
    private val uuidRe = Regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")

    fun validate(value: JsonElement): List<String> = mutableListOf<String>().also { check(root, value, "", it) }

    private fun resolve(ref: String): JsonObject? {
        if (!ref.startsWith("#/")) return null // 외부(program.schema.json)는 대조하지 않는다
        var cur: JsonElement = root
        for (p in ref.removePrefix("#/").split('/')) cur = cur.jsonObject[p]!!
        return cur.jsonObject
    }

    private fun check(schema: JsonObject, v: JsonElement, path: String, errs: MutableList<String>) {
        schema["\$ref"]?.jsonPrimitive?.content?.let { ref ->
            val target = resolve(ref) ?: return
            return check(target, v, path, errs)
        }
        schema["const"]?.let { if (it != v) errs += "$path: expected const $it" }
        schema["enum"]?.jsonArray?.let { if (v !in it) errs += "$path: $v not in enum" }
        schema["oneOf"]?.jsonArray?.let { alts ->
            val ok = alts.count { a -> mutableListOf<String>().also { check(a.jsonObject, v, path, it) }.isEmpty() }
            if (ok != 1) errs += "$path: matches $ok of oneOf"
        }
        when (schema["type"]?.jsonPrimitive?.content) {
            "object" -> {
                val o = v as? JsonObject ?: return run { errs += "$path: not an object" }
                val props = schema["properties"]?.jsonObject ?: JsonObject(emptyMap())
                schema["required"]?.jsonArray?.forEach { if (it.jsonPrimitive.content !in o) errs += "$path: missing ${it.jsonPrimitive.content}" }
                val addl = schema["additionalProperties"]
                for ((k, child) in o) {
                    val ps = props[k]
                    if (ps != null) check(ps.jsonObject, child, "$path/$k", errs)
                    else if (addl is JsonPrimitive && addl.content == "false") errs += "$path: unknown key $k"
                    else if (addl is JsonObject) check(addl, child, "$path/$k", errs)
                }
            }
            "array" -> {
                val a = v as? JsonArray ?: return run { errs += "$path: not an array" }
                schema["minItems"]?.jsonPrimitive?.content?.toInt()?.let { if (a.size < it) errs += "$path: minItems" }
                schema["maxItems"]?.jsonPrimitive?.content?.toInt()?.let { if (a.size > it) errs += "$path: maxItems" }
                schema["items"]?.jsonObject?.let { items -> a.forEachIndexed { i, e -> check(items, e, "$path/$i", errs) } }
            }
            "string" -> {
                val p = v as? JsonPrimitive ?: return run { errs += "$path: not a string" }
                if (!p.isString) errs += "$path: not a string"
                val s = p.content
                schema["minLength"]?.jsonPrimitive?.content?.toInt()?.let { if (s.length < it) errs += "$path: minLength" }
                schema["maxLength"]?.jsonPrimitive?.content?.toInt()?.let { if (s.length > it) errs += "$path: maxLength" }
                when (schema["format"]?.jsonPrimitive?.content) {
                    "uuid" -> if (!uuidRe.matches(s)) errs += "$path: not uuid"
                    "date-time" -> runCatching { Instant.parse(s) }.onFailure { errs += "$path: not date-time" }
                    "date" -> runCatching { java.time.LocalDate.parse(s) }.onFailure { errs += "$path: not date" }
                }
            }
            "integer" -> {
                val p = v as? JsonPrimitive ?: return run { errs += "$path: not integer" }
                if (p.isString || p.content.toBigDecimalOrNull()?.let { it.stripTrailingZeros().scale() <= 0 } != true) errs += "$path: not integer"
                range(schema, p, path, errs)
            }
            "number" -> {
                val p = v as? JsonPrimitive ?: return run { errs += "$path: not number" }
                if (p.isString || p.content.toBigDecimalOrNull() == null) errs += "$path: not number"
                range(schema, p, path, errs)
            }
            "boolean" -> if ((v as? JsonPrimitive)?.let { !it.isString && (it.content == "true" || it.content == "false") } != true) errs += "$path: not boolean"
        }
    }

    private fun range(schema: JsonObject, p: JsonPrimitive, path: String, errs: MutableList<String>) {
        val n = p.content.toBigDecimalOrNull() ?: return
        schema["minimum"]?.jsonPrimitive?.content?.toBigDecimal()?.let { if (n < it) errs += "$path: below minimum" }
        schema["maximum"]?.jsonPrimitive?.content?.toBigDecimal()?.let { if (n > it) errs += "$path: above maximum" }
        schema["exclusiveMinimum"]?.jsonPrimitive?.content?.toBigDecimal()?.let { if (n <= it) errs += "$path: not above exclusiveMinimum" }
        schema["multipleOf"]?.jsonPrimitive?.content?.toBigDecimal()?.let {
            if (n.remainder(it).compareTo(BigDecimal.ZERO) != 0) errs += "$path: not multipleOf"
        }
    }

    companion object {
        fun load(): MiniSchema {
            val f = listOf("../contracts/v0.3/import.schema.json", "contracts/v0.3/import.schema.json").map(::File).first { it.exists() }
            return MiniSchema(AppJson.parseToJsonElement(f.readText()).jsonObject)
        }
    }
}

class ExportApiTest {
    private val t0 = Instant.parse("2026-11-20T01:00:00Z")

    private fun JsonElement.o() = jsonObject
    private fun JsonElement.s(k: String) = jsonObject[k]?.jsonPrimitive?.content
    private fun JsonElement.dec(k: String) = jsonObject[k]?.jsonPrimitive?.content?.let(::BigDecimal)

    @Test
    fun json_export_matches_import_schema_and_db_content() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val other = createUser()
        val bench = insertOwnExercise(uid, "벤치", "Bench", "BARBELL", "CHEST", listOf("TRICEPS", "SHOULDERS"))
        val dead = insertOwnExercise(uid, "삭제될 종목", null, "MACHINE", "BACK", emptyList())
        transaction { Exercises.update({ Exercises.id eq dead }) { it[deletedAt] = Instant.now(); it[serverSeq] = ChangeSeq.next } }
        insertOwnExercise(other, "남의 종목")
        val prog = insertProgramRow(uid, "내 5x5")
        val tmpl = transaction { com.fitlog.core.Programs.selectAll().where { com.fitlog.core.Programs.templateKey eq "stronglifts-5x5" }.first()[com.fitlog.core.Programs.id] }
        val deadProg = insertProgramRow(uid, "지운 프로그램")
        transaction { com.fitlog.core.Programs.update({ com.fitlog.core.Programs.id eq deadProg }) { it[deletedAt] = Instant.now() } }
        val instOwn = insertInstanceRow(uid, prog, "ACTIVE", """{"squat":100.5}""", """{"squat":80.0}""")
        val instTmpl = insertInstanceRow(uid, tmpl, "PAUSED")
        val instDone = insertInstanceRow(uid, prog, "FINISHED")
        val s1 = insertSessionRow(
            uid, t0, "Asia/Seoul", note = "첫 세션", instanceId = instOwn, planSeq = 3, planDayKey = "A",
            exercises = listOf(
                bench to listOf(
                    SetSeed("60", 8, warmup = true),
                    SetSeed("100.5", 5, note = "쉬움", rpe = "8.5", rir = 2, rest = 120, targetReps = 5, targetWeight = "100", amrap = true),
                ),
                bench to listOf(SetSeed(null, null, duration = 600, distance = "1500.5", added = "10")),
            ),
        )
        // 비어 있는 세션과 삭제된 세션은 나가지 않는다
        insertSessionRow(uid, t0.plusSeconds(100))
        val gone = insertSessionRow(uid, t0.plusSeconds(200), exercises = listOf(bench to listOf(SetSeed())))
        transaction { WorkoutSessions.update({ WorkoutSessions.id eq gone }) { it[deletedAt] = Instant.now() } }
        insertSessionRow(other, t0, exercises = listOf(bench to listOf(SetSeed())))
        val s2 = insertSessionRow(uid, t0.plusSeconds(86400), instanceId = instDone, planSeq = 0, ended = false,
            exercises = listOf(dead to listOf(SetSeed("50", 10))))
        val b1 = insertBodyRow(uid, t0, "72.5")
        val b2 = insertBodyRow(uid, t0.plusSeconds(86400), "72")
        val bGone = insertBodyRow(uid, t0.plusSeconds(1), "99")
        transaction { BodyMeasurements.update({ BodyMeasurements.id eq bGone }) { it[deletedAt] = Instant.now() } }

        val res = c.get("/v1/export.json") { auth(uid) }
        assertEquals(HttpStatusCode.OK, res.status)
        assertTrue(Regex("""attachment; filename="fitlog-export-\d{8}\.json"""").matches(res.headers[HttpHeaders.ContentDisposition]!!))
        val bundle = AppJson.parseToJsonElement(res.bodyAsText()).o()

        // 1) 스키마 대조(additionalProperties=false 포함)
        val errors = MiniSchema.load().validate(bundle)
        assertTrue(errors.isEmpty(), errors.joinToString("\n"))
        assertEquals("1", bundle.s("schemaVersion"))
        assertTrue(bundle.s("note")!!.contains("fitlog") && bundle.s("note")!!.contains("exportedAt"))

        // 2) DB 내용과 필드 비교
        val exs = bundle["exercises"]!!.jsonArray
        assertEquals(setOf(bench.toString(), dead.toString()), exs.map { it.s("id")!! }.toSet()) // 삭제됐어도 세션이 참조하면 포함
        val benchJ = exs.first { it.s("id") == bench.toString() }
        assertEquals("벤치", benchJ.s("nameKo")); assertEquals("Bench", benchJ.s("nameEn"))
        assertEquals("BARBELL", benchJ.s("type")); assertEquals("CHEST", benchJ.s("primaryMuscle"))
        assertEquals(listOf("TRICEPS", "SHOULDERS"), benchJ["secondaryMuscles"]!!.jsonArray.map { it.jsonPrimitive.content })

        val progs = bundle["programs"]!!.jsonArray
        assertEquals(setOf(prog.toString(), deadProg.toString()).minus(deadProg.toString()), progs.map { it.s("id")!! }.toSet())
        assertEquals("내 5x5", progs[0]["definition"]!!.s("name"))

        val sp = bundle["startPrograms"]!!.jsonArray
        assertEquals(setOf(instOwn.toString(), instTmpl.toString()), sp.map { it.s("id")!! }.toSet())
        val spOwn = sp.first { it.s("id") == instOwn.toString() }
        assertEquals(prog.toString(), spOwn["program"]!!.s("id"))
        assertEquals("2026-11-01", spOwn.s("startDate")); assertEquals("Asia/Seoul", spOwn.s("tz")); assertEquals("SHIFT", spOwn.s("skipPolicy"))
        assertEquals(BigDecimal("100.5"), spOwn["tm"]!!.dec("squat")); assertEquals(0, BigDecimal("80").compareTo(spOwn["working"]!!.dec("squat")))
        val spTmpl = sp.first { it.s("id") == instTmpl.toString() }
        assertEquals("stronglifts-5x5", spTmpl["program"]!!.s("templateKey"))

        val sessions = bundle["sessions"]!!.jsonArray
        assertEquals(listOf(s1.toString(), s2.toString()), sessions.map { it.s("id")!! })
        val j1 = sessions[0]
        assertEquals("2026-11-20T01:00:00Z", j1.s("startedAt").let { Instant.parse(it).toString() })
        assertEquals("Asia/Seoul", j1.s("tz")); assertEquals("첫 세션", j1.s("note"))
        assertEquals(instOwn.toString(), j1["program"]!!.s("instanceId")); assertEquals("3", j1["program"]!!.s("planSeq"))
        val jex = j1["exercises"]!!.jsonArray
        assertEquals(2, jex.size)
        assertEquals(bench.toString(), jex[0]["exercise"]!!.s("id"))
        val jsets = jex[0]["sets"]!!.jsonArray
        assertEquals(2, jsets.size)
        assertEquals("true", jsets[0].s("isWarmup")); assertEquals(0, BigDecimal(60).compareTo(jsets[0].dec("weightKg")))
        assertEquals(8, jsets[0].s("reps")!!.toInt())
        assertEquals(BigDecimal("100.5"), jsets[1].dec("weightKg")); assertEquals(BigDecimal("8.5"), jsets[1].dec("rpe"))
        assertEquals("2", jsets[1].s("rir")); assertEquals("120", jsets[1].s("restSec")); assertEquals("쉬움", jsets[1].s("note"))
        assertTrue("plannedSetKey" !in jsets[1].o() && "targetReps" !in jsets[1].o() && "isAmrap" !in jsets[1].o())
        val cardio = jex[1]["sets"]!!.jsonArray[0]
        assertEquals("600", cardio.s("durationSec")); assertEquals(BigDecimal("1500.5"), cardio.dec("distanceM"))
        assertEquals(0, BigDecimal(10).compareTo(cardio.dec("addedWeightKg"))); assertTrue("weightKg" !in cardio.o())
        // FINISHED 인스턴스 연결은 나가지 않고, 진행 중 세션은 endedAt 이 없다
        assertTrue("program" !in sessions[1].o()); assertTrue("endedAt" !in sessions[1].o())

        val bodies = bundle["bodyMeasurements"]!!.jsonArray
        assertEquals(listOf(b1.toString(), b2.toString()), bodies.map { it.s("id")!! })
        assertEquals(BigDecimal("72.5"), bodies[0].dec("weightKg")); assertEquals(0, BigDecimal(72).compareTo(bodies[1].dec("weightKg")))
        assertEquals(t0, Instant.parse(bodies[0].s("measuredAt")))
    }

    @Test
    fun json_export_of_empty_account_is_valid_and_no_other_users_data() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val bundle = c.get("/v1/export.json") { auth(uid) }.bodyAsText().let { AppJson.parseToJsonElement(it).o() }
        assertTrue(MiniSchema.load().validate(bundle).isEmpty())
        for (k in listOf("exercises", "programs", "startPrograms", "sessions", "bodyMeasurements")) assertEquals(0, bundle[k]!!.jsonArray.size, k)
        assertEquals(HttpStatusCode.Unauthorized, c.get("/v1/export.json").status)
    }

    @Test
    fun csv_sets_has_bom_header_local_time_and_escaping() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val ex = insertOwnExercise(uid, "벤치, \"프레스\"", "Bench", "BARBELL")
        val prog = insertProgramRow(uid, "내 프로그램")
        val inst = insertInstanceRow(uid, prog)
        // 2026-11-20T01:00Z = 서울 10:00, 뉴욕 20:00(전날)
        insertSessionRow(uid, t0, "Asia/Seoul", instanceId = inst, planSeq = 0, planDayKey = "A",
            exercises = listOf(ex to listOf(SetSeed("100", 5, note = "줄1\n줄2, \"인용\"", rpe = "8", targetReps = 5, targetWeight = "100", amrap = true), SetSeed("60", 8, warmup = true))))
        insertSessionRow(uid, t0.plusSeconds(86400), "America/New_York", exercises = listOf(ex to listOf(SetSeed(null, null, duration = 60))))

        val res = c.get("/v1/export.csv?kind=sets") { auth(uid) }
        assertEquals(HttpStatusCode.OK, res.status)
        assertTrue(res.headers[HttpHeaders.ContentType]!!.startsWith("text/csv"))
        assertTrue(Regex("""attachment; filename="fitlog-sets-\d{8}\.csv"""").matches(res.headers[HttpHeaders.ContentDisposition]!!))
        val bytes = res.bodyAsBytes()
        assertEquals(listOf<Byte>(0xEF.toByte(), 0xBB.toByte(), 0xBF.toByte()), bytes.take(3))
        val text = String(bytes, Charsets.UTF_8).removePrefix("﻿")
        val lines = text.split("\n")
        assertEquals(
            "date,session_id,program,day,exercise_ko,exercise_en,exercise_type,set_no,is_warmup,weight_kg,added_weight_kg,reps,rpe,rir,rest_sec,duration_sec,distance_m,target_reps,target_weight_kg,is_amrap,note,superset_group,set_type",
            lines[0],
        )
        val first = "2026-11-20 10:00"
        assertTrue(lines[1].startsWith("$first,"), lines[1])
        assertTrue(lines[1].contains(",내 프로그램,A,\"벤치, \"\"프레스\"\"\",Bench,BARBELL,1,false,100,,5,8,,,,,5,100,true,\"줄1"), lines[1])
        assertTrue(text.contains("줄2, \"\"인용\"\"\",,NORMAL\n"), text)
        // 두 번째 세트(줄바꿈을 포함한 첫 행 다음)
        val row2 = lines.first { it.startsWith("$first,") && it.contains(",2,true,60,") }
        assertTrue(row2.contains(",내 프로그램,A,"))
        // 뉴욕 시간대: 2026-11-21T01:00Z = 2026-11-20 20:00
        val ny = lines.first { it.startsWith("2026-11-20 20:00,") }
        assertTrue(ny.contains(",,,\"벤치, \"\"프레스\"\"\",Bench,BARBELL,1,false,,,,,,,60,,,,false,"), ny)
    }

    @Test
    fun csv_body_uses_latest_session_tz_or_seoul_and_validates_kind() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        insertBodyRow(uid, t0, "72.5", "OCR")
        insertBodyRow(uid, t0.plusSeconds(3600), "72")
        val gone = insertBodyRow(uid, t0.plusSeconds(7200), "99")
        transaction { BodyMeasurements.update({ BodyMeasurements.id eq gone }) { it[deletedAt] = Instant.now() } }
        var text = c.get("/v1/export.csv?kind=body") { auth(uid) }.bodyAsText().removePrefix("﻿")
        assertEquals("date,weight_kg,source\n2026-11-20 10:00,72.5,OCR\n2026-11-20 11:00,72,MANUAL\n", text)

        val ex = insertOwnExercise(uid)
        insertSessionRow(uid, t0, "America/New_York", exercises = listOf(ex to listOf(SetSeed())))
        text = c.get("/v1/export.csv?kind=body") { auth(uid) }.bodyAsText().removePrefix("﻿")
        assertEquals("date,weight_kg,source\n2026-11-19 20:00,72.5,OCR\n2026-11-19 21:00,72,MANUAL\n", text)

        for (q in listOf("", "?kind=x", "?kind=")) {
            val r = c.get("/v1/export.csv$q") { auth(uid) }
            assertEquals(HttpStatusCode.BadRequest, r.status, q)
            assertEquals("VALIDATION_FAILED", r.obj()["error"]!!.jsonObject["code"]!!.jsonPrimitive.content)
        }
    }

    @Test
    fun json_export_has_no_bundle_limits() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val ex = insertOwnExercise(uid)
        repeat(205) { i -> insertSessionRow(uid, t0.plusSeconds(i * 60L), exercises = listOf(ex to listOf(SetSeed()))) }
        val bundle = AppJson.parseToJsonElement(c.get("/v1/export.json") { auth(uid) }.bodyAsText()).o()
        assertEquals(205, bundle["sessions"]!!.jsonArray.size)
    }

    @Test
    fun mini_schema_rejects_unknown_keys_so_the_check_is_meaningful() {
        val bad = AppJson.parseToJsonElement(
            """{"schemaVersion":1,"sessions":[{"startedAt":"2026-11-20T01:00:00Z","exercises":[{"exercise":{"id":"${UUID.randomUUID()}"},"sets":[{"plannedSetKey":"x"}]}]}]}""",
        )
        assertTrue(MiniSchema.load().validate(bad).any { it.contains("plannedSetKey") })
    }
}
