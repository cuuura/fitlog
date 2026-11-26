package com.fitlog.importing

import com.fitlog.session.arr
import com.fitlog.session.getSession
import com.fitlog.session.newId
import com.fitlog.session.obj
import com.fitlog.session.str
import com.fitlog.support.auth
import com.fitlog.support.createUser
import com.fitlog.support.fitlogTest
import com.fitlog.support.jsonBody
import com.fitlog.support.jsonClient
import io.ktor.client.HttpClient
import io.ktor.client.request.get
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.HttpResponse
import io.ktor.client.statement.bodyAsText
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.File
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

private const val SQUAT = "019b76da-4000-7000-8000-000000000001"
private const val BENCH = "019b76da-4000-7000-8000-000000000003"
private const val ROW = "019b76da-4000-7000-8000-00000000000a"

private suspend fun HttpClient.imp(uid: UUID, bundle: String, extra: String = "", path: String = "/v1/imports"): HttpResponse =
    post(path) {
        auth(uid); jsonBody()
        setBody("""{"bundle":$bundle${if (extra.isEmpty()) "" else ",$extra"}}""")
    }

private suspend fun HttpClient.revert(uid: UUID, id: String): HttpResponse = post("/v1/imports/$id/revert") { auth(uid) }
private suspend fun HttpClient.detail(uid: UUID, id: String): HttpResponse = get("/v1/imports/$id") { auth(uid) }

private fun sets(n: Int = 3, w: Int = 100, reps: Int = 5) = (1..n).joinToString(",") { """{"weightKg":$w,"reps":$reps}""" }

private fun session(start: String, name: String = "스쿼트", id: String? = null, extra: String = "", w: Int = 100): String {
    val idPart = if (id != null) """"id":"$id",""" else ""
    return """{$idPart"startedAt":"$start","tz":"Asia/Seoul"$extra,"exercises":[{"exercise":{"name":"$name"},"sets":[${sets(3, w)}]}]}"""
}

private fun bundle(vararg parts: String) = "{" + (listOf(""""schemaVersion":1""") + parts).joinToString(",") + "}"
private fun sessions(vararg s: String) = """"sessions":[${s.joinToString(",")}]"""
private fun bodies(vararg s: String) = """"bodyMeasurements":[${s.joinToString(",")}]"""

private fun programDef(name: String = "My Program") = """{"schemaVersion":1,"name":"$name","lifts":{"squat":{"exercise":{"name":"스쿼트"}}},
 "progression":{"squat":{"type":"LINEAR","incrementKg":2.5}},
 "days":[{"key":"A","name":"A","exercises":[{"lift":"squat","sets":[{"count":3,"reps":5,"load":{"type":"WORKING"}}]}]}]}"""

private fun programs(vararg p: String) = """"programs":[${p.joinToString(",")}]"""

private fun JsonObject.itemIds(entity: String, action: String = "CREATED"): List<String> =
    this["items"]!!.jsonArray.map { it.jsonObject }.filter { it.str("entity") == entity && it.str("action") == action }.map { it.str("entityId")!! }

private fun JsonObject.conflictIds(): List<String> = this["conflicts"]!!.jsonArray.map { it.str("conflictId")!! }

private fun resolutions(vararg pairs: Pair<String, String>) =
    """"resolutions":{${pairs.joinToString(",") { """"${it.first}":${it.second}""" }}}"""

class ImportApiTest {
    @Test
    fun public_schema_files_match_contracts() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val imp = c.get("/v1/public/schema/import.json")
        assertEquals(HttpStatusCode.OK, imp.status)
        assertTrue(imp.headers[HttpHeaders.ContentType]!!.startsWith("application/schema+json"))
        assertEquals("max-age=86400", imp.headers[HttpHeaders.CacheControl])
        assertEquals(File("../contracts/v0.3/import.schema.json").readText(), imp.bodyAsText())
        val prog = c.get("/v1/public/schema/program.json")
        assertEquals(HttpStatusCode.OK, prog.status)
        assertEquals(File("../contracts/v0.2/program.schema.json").readText(), prog.bodyAsText())
        assertEquals(File("../contracts/v0.3/import.schema.json").readText(), File("src/main/resources/schemas/import.schema.json").readText())
    }

    @Test
    fun clean_import_saves_and_shows_source() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val b = bundle(
            """"exercises":[{"nameKo":"신규운동","type":"MACHINE","primaryMuscle":"BACK"}]""",
            programs("""{"definition":${programDef()}}"""),
            sessions(
                """{"startedAt":"2026-11-20T10:00:00+09:00","tz":"Asia/Seoul","exercises":[
                  {"exercise":{"name":"신규운동"},"sets":[{"weightKg":40,"reps":10}]},
                  {"exercise":{"name":"벤치 프레스"},"sets":[{"weightKg":60,"reps":5}]}]}""",
            ),
            bodies("""{"measuredAt":"2026-11-20T08:00:00+09:00","weightKg":72.5}"""),
        )
        val pv = c.imp(uid, b, path = "/v1/imports/preview")
        assertEquals(HttpStatusCode.OK, pv.status)
        assertEquals(1, pv.obj()["counts"]!!.jsonObject["sessions"]!!.jsonObject["NEW"]!!.jsonPrimitive.int)

        val r = c.imp(uid, b, """"clientName":"Claude"""")
        assertEquals(HttpStatusCode.Created, r.status)
        val batch = r.obj()
        assertEquals("APP_JSON", batch.str("channel"))
        assertEquals("Claude", batch.str("clientName"))
        val sum = batch["summary"]!!.jsonObject
        assertEquals(1, sum["sessions"]!!.jsonPrimitive.int)
        assertEquals(1, sum["programs"]!!.jsonPrimitive.int)
        assertEquals(1, sum["exercises"]!!.jsonPrimitive.int)
        assertEquals(1, sum["bodyMeasurements"]!!.jsonPrimitive.int)

        val det = c.detail(uid, batch.str("id")!!).obj()
        val sid = det.itemIds("workout_session").single()
        val s = c.getSession(uid, sid).obj()
        assertEquals("AI_JSON", s.str("source"))
        assertEquals(batch.str("id"), s.str("importBatchId"))
        assertEquals("2026-11-20T01:00:00Z", s.str("startedAt"))
        assertEquals(2, s["exercises"]!!.jsonArray.size)
        assertTrue(s.str("endedAt") != null)
        val p = c.get("/v1/programs/${det.itemIds("program").single()}") { auth(uid) }.obj()
        assertEquals("AI_JSON", p.str("source"))
        assertEquals(batch.str("id"), p.str("importBatchId"))
        val ex = c.get("/v1/exercises") { auth(uid) }.arr().map { it.jsonObject }.single { it.str("nameKo") == "신규운동" }
        assertEquals("AI_JSON", ex.str("source"))
        assertEquals(batch.str("id"), ex.str("importBatchId"))
        val body = c.get("/v1/body/measurements") { auth(uid) }.arr().single().jsonObject
        assertEquals("AI_JSON", body.str("source"))
        assertEquals(batch.str("id"), body.str("importBatchId"))
        val list = c.get("/v1/imports") { auth(uid) }.arr()
        assertEquals(1, list.size)
    }

    @Test
    fun resend_same_bundle_without_ids_is_idempotent() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val b = bundle(
            sessions(session("2026-11-20T10:00:00+09:00")),
            bodies("""{"measuredAt":"2026-11-20T08:00:00+09:00","weightKg":72.5}"""),
        )
        val first = c.imp(uid, b)
        assertEquals(HttpStatusCode.Created, first.status)
        val again = c.imp(uid, b)
        assertEquals(HttpStatusCode.OK, again.status)
        assertEquals(first.obj().str("id"), again.obj().str("id"))
        assertEquals(1, c.get("/v1/imports") { auth(uid) }.arr().size)
        // 키 순서·숫자 표기가 달라도 같은 묶음
        val reshaped = b.replace("72.5", "72.50")
        assertEquals(HttpStatusCode.OK, c.imp(uid, reshaped).status)
        // 되돌린 뒤에는 다시 저장된다
        assertEquals(HttpStatusCode.OK, c.revert(uid, first.obj().str("id")!!).status)
        val third = c.imp(uid, b)
        assertEquals(HttpStatusCode.Created, third.status)
        assertNotEquals(first.obj().str("id"), third.obj().str("id"))
    }

    @Test
    fun resend_same_bundle_with_ids_is_idempotent() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val sid = newId()
        val b = bundle(
            """"exercises":[{"id":"${newId()}","nameKo":"아이디운동","type":"MACHINE","primaryMuscle":"BACK"}]""",
            sessions(session("2026-11-20T10:00:00+09:00", id = sid)),
            bodies("""{"id":"${newId()}","measuredAt":"2026-11-20T08:00:00+09:00","weightKg":72.5}"""),
        )
        val first = c.imp(uid, b)
        assertEquals(HttpStatusCode.Created, first.status)
        val again = c.imp(uid, b)
        assertEquals(HttpStatusCode.OK, again.status)
        assertEquals(first.obj().str("id"), again.obj().str("id"))
        // 일부만 새것이면 새것만 저장(다른 묶음)
        val more = bundle(sessions(session("2026-11-20T10:00:00+09:00", id = sid), session("2026-11-22T10:00:00+09:00", id = newId())))
        val third = c.imp(uid, more)
        assertEquals(HttpStatusCode.Created, third.status)
        assertEquals(1, third.obj()["summary"]!!.jsonObject["sessions"]!!.jsonPrimitive.int)
    }

    @Test
    fun schema_violations_reject_whole_bundle() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val bad = bundle(
            """"extra":1""",
            """"exercises":[{"nameKo":"좋은운동","type":"MACHINE","primaryMuscle":"BACK"},{"nameKo":"","type":"X","primaryMuscle":"BACK"}]""",
            programs("""{"definition":{"schemaVersion":1,"name":"x","lifts":{},"days":[]}}"""),
            sessions("""{"startedAt":"nope","exercises":[{"exercise":{"name":"스쿼트"},"sets":[{"rpe":11,"reps":-1}]}]}"""),
            bodies("""{"measuredAt":"2026-11-20T08:00:00+09:00","weightKg":5}"""),
        )
        val r = c.imp(uid, bad)
        assertEquals(HttpStatusCode.BadRequest, r.status)
        val e = r.obj()["error"]!!.jsonObject
        assertEquals("VALIDATION_FAILED", e.str("code"))
        val paths = e["details"]!!.jsonArray.map { it.str("path")!! }
        assertTrue("/extra" in paths, paths.toString())
        assertTrue("/exercises/1/nameKo" in paths, paths.toString())
        assertTrue("/exercises/1/type" in paths, paths.toString())
        assertTrue(paths.any { it.startsWith("/programs/0/definition") }, paths.toString())
        assertTrue("/sessions/0/startedAt" in paths, paths.toString())
        assertTrue("/sessions/0/exercises/0/sets/0/rpe" in paths, paths.toString())
        assertTrue("/sessions/0/exercises/0/sets/0/reps" in paths, paths.toString())
        assertTrue("/bodyMeasurements/0/weightKg" in paths, paths.toString())
        assertEquals(0, c.get("/v1/imports") { auth(uid) }.arr().size)
        assertTrue(c.get("/v1/exercises") { auth(uid) }.arr().none { it.str("nameKo") == "좋은운동" })
        // 한도: 세션 201개
        val many = bundle(sessions(*Array(201) { session("2026-11-20T10:00:00+09:00") }))
        assertEquals(HttpStatusCode.BadRequest, c.imp(uid, many).status)
    }

    @Test
    fun unknown_exercise_conflict_and_resolutions() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val b = bundle(sessions(session("2026-11-20T10:00:00+09:00", name = "벤치프레")))
        val pv = c.imp(uid, b, path = "/v1/imports/preview").obj()
        val conflict = pv["conflicts"]!!.jsonArray.single().jsonObject
        assertEquals("UNKNOWN_EXERCISE", conflict.str("code"))
        assertEquals("UNKNOWN_EXERCISE:/sessions/0/exercises/0/exercise", conflict.str("conflictId"))
        assertEquals(listOf("MAP_TO", "CREATE", "SKIP"), conflict["allowed"]!!.jsonArray.map { it.jsonPrimitive.content })
        val cands = conflict["candidates"]!!.jsonArray.map { it.str("nameKo") }
        assertTrue("벤치프레스" in cands && cands.size <= 3, cands.toString())

        val r409 = c.imp(uid, b)
        assertEquals(HttpStatusCode.Conflict, r409.status)
        assertEquals(listOf(conflict.str("conflictId")), r409.obj()["unresolved"]!!.jsonArray.map { it.jsonPrimitive.content })
        val cid = conflict.str("conflictId")!!

        // MAP_TO
        val mapped = c.imp(uid, b, resolutions(cid to """{"action":"MAP_TO","exerciseId":"$BENCH"}"""))
        assertEquals(HttpStatusCode.Created, mapped.status)
        val sid = c.detail(uid, mapped.obj().str("id")!!).obj().itemIds("workout_session").single()
        assertEquals(BENCH, c.getSession(uid, sid).obj()["exercises"]!!.jsonArray[0].str("exerciseId"))

        // CREATE (다른 이름·다른 시각으로 새 묶음)
        val b2 = bundle(sessions(session("2026-11-21T10:00:00+09:00", name = "내맘대로운동")))
        val cid2 = "UNKNOWN_EXERCISE:/sessions/0/exercises/0/exercise"
        val bad = c.imp(uid, b2, resolutions(cid2 to """{"action":"CREATE","exercise":{"type":"MACHINE"}}"""))
        assertEquals(HttpStatusCode.BadRequest, bad.status)
        val created = c.imp(uid, b2, resolutions(cid2 to """{"action":"CREATE","exercise":{"type":"MACHINE","primaryMuscle":"CHEST"}}"""))
        assertEquals(HttpStatusCode.Created, created.status)
        assertEquals(1, created.obj()["summary"]!!.jsonObject["exercises"]!!.jsonPrimitive.int)
        assertTrue(c.get("/v1/exercises") { auth(uid) }.arr().any { it.str("nameKo") == "내맘대로운동" })

        // SKIP: 그 종목 기록만 뺌 → 세션 둘 중 하나만
        val b3 = bundle(
            sessions(
                """{"startedAt":"2026-11-25T10:00:00+09:00","tz":"Asia/Seoul","exercises":[
                  {"exercise":{"name":"없는운동"},"sets":[{"weightKg":10,"reps":5}]},
                  {"exercise":{"name":"스쿼트"},"sets":[{"weightKg":100,"reps":5}]}]}""",
            ),
        )
        val skipped = c.imp(uid, b3, resolutions("UNKNOWN_EXERCISE:/sessions/0/exercises/0/exercise" to """{"action":"SKIP"}"""))
        assertEquals(HttpStatusCode.Created, skipped.status)
        val sid3 = c.detail(uid, skipped.obj().str("id")!!).obj().itemIds("workout_session").single()
        assertEquals(1, c.getSession(uid, sid3).obj()["exercises"]!!.jsonArray.size)
    }

    @Test
    fun session_overlap_skip_keep_both_replace_and_revert_restores() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val old = c.imp(uid, bundle(sessions(session("2026-11-20T10:00:00+09:00")))).obj()
        val oldSid = c.detail(uid, old.str("id")!!).obj().itemIds("workout_session").single()

        val b = bundle(sessions(session("2026-11-20T12:00:00+09:00", w = 110)))
        val pv = c.imp(uid, b, path = "/v1/imports/preview").obj()
        val conflict = pv["conflicts"]!!.jsonArray.single().jsonObject
        assertEquals("SESSION_OVERLAP:/sessions/0", conflict.str("conflictId"))
        assertEquals(oldSid, conflict["existing"]!!.jsonObject.str("id"))
        val cid = "SESSION_OVERLAP:/sessions/0"
        assertEquals(HttpStatusCode.Conflict, c.imp(uid, b).status)

        assertEquals(HttpStatusCode.OK, c.imp(uid, b, resolutions(cid to """{"action":"SKIP"}""")).status)
        assertEquals(HttpStatusCode.OK, c.getSession(uid, oldSid).status)

        // 같은 날이라도 3시간 넘게 떨어지고 안 겹치면 충돌 아님
        val far = c.imp(uid, bundle(sessions(session("2026-11-20T20:00:00+09:00"))))
        assertEquals(HttpStatusCode.Created, far.status)

        val both = c.imp(uid, b, resolutions(cid to """{"action":"KEEP_BOTH"}"""))
        assertEquals(HttpStatusCode.Created, both.status)
        assertEquals(HttpStatusCode.OK, c.getSession(uid, oldSid).status)

        val b2 = bundle(sessions(session("2026-11-20T11:00:00+09:00", w = 120)))
        val rep = c.imp(uid, b2, resolutions(cid to """{"action":"REPLACE"}"""))
        assertEquals(HttpStatusCode.Created, rep.status)
        assertEquals(1, rep.obj()["summary"]!!.jsonObject["replaced"]!!.jsonPrimitive.int.coerceAtMost(1))
        val det = c.detail(uid, rep.obj().str("id")!!).obj()
        val newSid = det.itemIds("workout_session").single()
        val replacedOld = det.itemIds("workout_session", "REPLACED_OLD")
        assertTrue(oldSid in replacedOld)
        assertEquals(HttpStatusCode.NotFound, c.getSession(uid, oldSid).status)

        val rv = c.revert(uid, rep.obj().str("id")!!)
        assertEquals(HttpStatusCode.OK, rv.status)
        assertTrue(rv.obj().str("revertedAt") != null)
        assertEquals(HttpStatusCode.NotFound, c.getSession(uid, newSid).status)
        val restored = c.getSession(uid, oldSid)
        assertEquals(HttpStatusCode.OK, restored.status)
        assertEquals(3, restored.obj()["exercises"]!!.jsonArray[0].jsonObject["sets"]!!.jsonArray.size)
    }

    @Test
    fun body_same_day_conflict() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        c.imp(uid, bundle(bodies("""{"measuredAt":"2026-11-20T08:00:00+09:00","weightKg":72.5}""")))
        val b = bundle(bodies("""{"measuredAt":"2026-11-20T21:00:00+09:00","weightKg":73.0}"""))
        val r = c.imp(uid, b)
        assertEquals(HttpStatusCode.Conflict, r.status)
        val cid = "BODY_SAME_DAY:/bodyMeasurements/0"
        assertEquals(listOf(cid), r.obj().conflictIds())
        assertEquals(HttpStatusCode.OK, c.imp(uid, b, resolutions(cid to """{"action":"SKIP"}""")).status)
        val both = c.imp(uid, b, resolutions(cid to """{"action":"KEEP_BOTH"}"""))
        assertEquals(HttpStatusCode.Created, both.status)
        assertEquals(2, c.get("/v1/body/measurements") { auth(uid) }.arr().size)
        val b2 = bundle(bodies("""{"measuredAt":"2026-11-20T22:00:00+09:00","weightKg":74.0}"""))
        val rep = c.imp(uid, b2, resolutions(cid to """{"action":"REPLACE"}"""))
        assertEquals(HttpStatusCode.Created, rep.status)
        val list = c.get("/v1/body/measurements") { auth(uid) }.arr()
        assertEquals(1, list.size)
        assertEquals(74.0, list[0].jsonObject["weightKg"]!!.jsonPrimitive.content.toDouble())
        c.revert(uid, rep.obj().str("id")!!)
        assertEquals(2, c.get("/v1/body/measurements") { auth(uid) }.arr().size)
    }

    @Test
    fun program_name_exists_conflict_and_replace_revert() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val first = c.imp(uid, bundle(programs("""{"definition":${programDef("Dup")}}""")))
        val oldPid = c.detail(uid, first.obj().str("id")!!).obj().itemIds("program").single()
        val b = bundle(programs("""{"definition":${programDef("Dup").replace("\"count\":3", "\"count\":4")}}"""))
        val cid = "PROGRAM_NAME_EXISTS:/programs/0"
        val r = c.imp(uid, b)
        assertEquals(HttpStatusCode.Conflict, r.status)
        assertEquals(listOf(cid), r.obj().conflictIds())
        assertEquals(HttpStatusCode.OK, c.imp(uid, b, resolutions(cid to """{"action":"SKIP"}""")).status)
        val both = c.imp(uid, b, resolutions(cid to """{"action":"KEEP_BOTH"}"""))
        assertEquals(HttpStatusCode.Created, both.status)
        val pid2 = c.detail(uid, both.obj().str("id")!!).obj().itemIds("program").single()
        assertEquals("Dup (2)", c.get("/v1/programs/$pid2") { auth(uid) }.obj().str("name"))

        val b3 = bundle(programs("""{"definition":${programDef("Dup").replace("\"count\":3", "\"count\":5")}}"""))
        val rep = c.imp(uid, b3, resolutions(cid to """{"action":"REPLACE"}"""))
        assertEquals(HttpStatusCode.Created, rep.status)
        assertEquals(HttpStatusCode.NotFound, c.get("/v1/programs/$oldPid") { auth(uid) }.status)
        c.revert(uid, rep.obj().str("id")!!)
        assertEquals(HttpStatusCode.OK, c.get("/v1/programs/$oldPid") { auth(uid) }.status)
    }

    @Test
    fun id_exists_conflict_skip_keep_both_replace() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val sid = newId()
        c.imp(uid, bundle(sessions(session("2026-11-20T10:00:00+09:00", id = sid))))
        val b = bundle(sessions(session("2026-11-25T10:00:00+09:00", id = sid, w = 130)))
        val cid = "ID_EXISTS:/sessions/0"
        val r = c.imp(uid, b)
        assertEquals(HttpStatusCode.Conflict, r.status)
        assertEquals(listOf(cid), r.obj().conflictIds())
        assertEquals(HttpStatusCode.OK, c.imp(uid, b, resolutions(cid to """{"action":"SKIP"}""")).status)
        val both = c.imp(uid, b, resolutions(cid to """{"action":"KEEP_BOTH"}"""))
        assertEquals(HttpStatusCode.Created, both.status)
        val newSid = c.detail(uid, both.obj().str("id")!!).obj().itemIds("workout_session").single()
        assertNotEquals(sid, newSid)
        // 같은 해결로 재전송하면 멱등
        assertEquals(HttpStatusCode.OK, c.imp(uid, b, resolutions(cid to """{"action":"KEEP_BOTH"}""")).status)
        val rep = c.imp(uid, b, resolutions(cid to """{"action":"REPLACE"}"""))
        assertEquals(HttpStatusCode.Created, rep.status)
        val s = c.getSession(uid, sid).obj()
        assertEquals("2026-11-25T01:00:00Z", s.str("startedAt"))
    }

    @Test
    fun plan_mismatch_and_instance_needs_value() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val iid = newId()
        val start = """{"id":"$iid","program":{"templateKey":"stronglifts-5x5"},"startDate":"2026-11-02"}"""
        val b0 = bundle(""""startPrograms":[$start]""")
        val r0 = c.imp(uid, b0)
        assertEquals(HttpStatusCode.Conflict, r0.status)
        val conflict = r0.obj()["conflicts"]!!.jsonArray.single().jsonObject
        assertEquals("INSTANCE_NEEDS_VALUE:/startPrograms/0", conflict.str("conflictId"))
        assertEquals(listOf("SET", "SKIP"), conflict["allowed"]!!.jsonArray.map { it.jsonPrimitive.content })
        val sug = conflict["suggested"]!!.jsonObject
        assertEquals(0, sug["tm"]!!.jsonObject.size)
        assertEquals(setOf("squat", "bench", "row", "ohp", "deadlift"), sug["working"]!!.jsonObject.keys)
        assertTrue(sug["working"]!!.jsonObject.values.all { it is kotlinx.serialization.json.JsonNull })
        // 모자라게 SET 하면 여전히 미해결
        val partial = c.imp(uid, b0, resolutions("INSTANCE_NEEDS_VALUE:/startPrograms/0" to """{"action":"SET","value":{"working":{"squat":100}}}"""))
        assertEquals(HttpStatusCode.Conflict, partial.status)
        val full = """{"action":"SET","value":{"tm":{},"working":{"squat":100,"bench":60,"row":50,"ohp":40,"deadlift":120}}}"""
        val ok = c.imp(uid, b0, resolutions("INSTANCE_NEEDS_VALUE:/startPrograms/0" to full))
        assertEquals(HttpStatusCode.Created, ok.status)
        assertEquals(1, ok.obj()["summary"]!!.jsonObject["programInstances"]!!.jsonPrimitive.int)
        assertEquals(HttpStatusCode.OK, c.get("/v1/program-instances/$iid") { auth(uid) }.status)

        // PLAN_MISMATCH: 다음 회차는 1 인데 3 을 보냄
        val mism = bundle(sessions(session("2026-11-20T10:00:00+09:00", extra = ""","program":{"instanceId":"$iid","planSeq":3}""")))
        val r = c.imp(uid, mism)
        assertEquals(HttpStatusCode.Conflict, r.status)
        val cid = "PLAN_MISMATCH:/sessions/0"
        assertEquals(listOf(cid), r.obj().conflictIds())
        assertEquals(HttpStatusCode.OK, c.imp(uid, mism, resolutions(cid to """{"action":"SKIP"}""")).status)
        val un = c.imp(uid, mism, resolutions(cid to """{"action":"UNLINK"}"""))
        assertEquals(HttpStatusCode.Created, un.status)
        val sid = c.detail(uid, un.obj().str("id")!!).obj().itemIds("workout_session").single()
        assertEquals(null, c.getSession(uid, sid).obj().str("programInstanceId"))
    }

    @Test
    fun program_session_import_replays_instance_with_real_engine() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val iid = newId()
        fun ex(id: String, w: Int) = """{"exercise":{"id":"$id"},"sets":[${sets(5, w, 5)}]}"""
        val b = bundle(
            """"startPrograms":[{"id":"$iid","program":{"templateKey":"stronglifts-5x5"},"startDate":"2026-11-02","working":{"squat":100,"bench":60,"row":50,"ohp":40,"deadlift":120}}]""",
            sessions(
                """{"startedAt":"2026-11-02T10:00:00+09:00","tz":"Asia/Seoul","program":{"instanceId":"$iid","planSeq":1},
                   "exercises":[${ex(SQUAT, 100)},${ex(BENCH, 60)},${ex(ROW, 50)}]}""",
            ),
        )
        val r = c.imp(uid, b)
        assertEquals(HttpStatusCode.Created, r.status, r.bodyAsText())
        val inst = c.get("/v1/program-instances/$iid") { auth(uid) }.obj()
        assertEquals(1, inst["state"]!!.jsonObject["seq"]!!.jsonPrimitive.int)
        assertEquals(2, inst["next"]!!.jsonObject["planSeq"]!!.jsonPrimitive.int)
        assertEquals(102.5, inst["state"]!!.jsonObject["working"]!!.jsonObject["squat"]!!.jsonPrimitive.content.toDouble())
        val sid = c.detail(uid, r.obj().str("id")!!).obj().itemIds("workout_session").single()
        val s = c.getSession(uid, sid).obj()
        assertEquals(iid, s.str("programInstanceId"))
        assertEquals("A", s.str("planDayKey"))
        val first = s["exercises"]!!.jsonArray[0].jsonObject
        assertEquals("squat", first.str("liftKey"))
        val set0 = first["sets"]!!.jsonArray[0].jsonObject
        assertTrue(set0.str("plannedSetKey") != null)
        assertEquals(5, set0["targetReps"]!!.jsonPrimitive.int)
        // 되돌리면 인스턴스 상태도 처음으로
        c.revert(uid, r.obj().str("id")!!)
        assertEquals(HttpStatusCode.NotFound, c.get("/v1/program-instances/$iid") { auth(uid) }.status)
    }

    @Test
    fun skip_all_resolves_every_conflict_with_skip() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        c.imp(uid, bundle(sessions(session("2026-11-20T10:00:00+09:00")), bodies("""{"measuredAt":"2026-11-20T08:00:00+09:00","weightKg":72.5}""")))
        val b = bundle(
            sessions(session("2026-11-20T11:00:00+09:00"), session("2026-11-27T10:00:00+09:00", name = "없는운동")),
            bodies("""{"measuredAt":"2026-11-20T09:00:00+09:00","weightKg":70}"""),
        )
        assertEquals(HttpStatusCode.Conflict, c.imp(uid, b).status)
        val r = c.imp(uid, b, """"onConflict":"SKIP_ALL"""")
        assertEquals(HttpStatusCode.OK, r.status)
        assertEquals(1, c.get("/v1/body/measurements") { auth(uid) }.arr().size)
        assertEquals(1, c.get("/v1/imports") { auth(uid) }.arr().size)
    }

    @Test
    fun failure_midway_leaves_nothing_behind() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val b = bundle(
            """"exercises":[{"nameKo":"롤백운동","type":"MACHINE","primaryMuscle":"BACK"}]""",
            sessions(session("2026-11-20T10:00:00+09:00")),
            bodies("""{"measuredAt":"2026-11-20T08:00:00+09:00","weightKg":72.5}"""),
        )
        ImportPipeline.afterPhase = { if (it == "sessions") error("boom") }
        try {
            assertEquals(HttpStatusCode.InternalServerError, c.imp(uid, b).status)
        } finally {
            ImportPipeline.afterPhase = null
        }
        assertEquals(0, c.get("/v1/imports") { auth(uid) }.arr().size)
        assertTrue(c.get("/v1/exercises") { auth(uid) }.arr().none { it.str("nameKo") == "롤백운동" })
        assertEquals(0, c.get("/v1/body/measurements") { auth(uid) }.arr().size)
        assertEquals(HttpStatusCode.Created, c.imp(uid, b).status)
    }

    @Test
    fun revert_twice_is_noop_and_other_users_get_404() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val other = createUser()
        val r = c.imp(uid, bundle(sessions(session("2026-11-20T10:00:00+09:00")), bodies("""{"measuredAt":"2026-11-20T08:00:00+09:00","weightKg":72.5}""")))
        val id = r.obj().str("id")!!
        val sid = c.detail(uid, id).obj().itemIds("workout_session").single()
        assertEquals(HttpStatusCode.NotFound, c.revert(other, id).status)
        assertEquals(HttpStatusCode.NotFound, c.detail(other, id).status)
        val first = c.revert(uid, id)
        assertEquals(HttpStatusCode.OK, first.status)
        val at = first.obj().str("revertedAt")
        assertEquals(HttpStatusCode.NotFound, c.getSession(uid, sid).status)
        assertEquals(0, c.get("/v1/body/measurements") { auth(uid) }.arr().size)
        val second = c.revert(uid, id)
        assertEquals(HttpStatusCode.OK, second.status)
        assertEquals(at, second.obj().str("revertedAt"))
        assertFailsWith<IllegalArgumentException> { UUID.fromString("x") }
        assertEquals(HttpStatusCode.NotFound, c.revert(uid, newId()).status)
        assertEquals(JsonPrimitive(id), c.get("/v1/imports?limit=5") { auth(uid) }.arr()[0].jsonObject["id"])
    }
}
