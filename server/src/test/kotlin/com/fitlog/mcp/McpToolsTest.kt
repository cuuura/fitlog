package com.fitlog.mcp

import com.fitlog.core.DeletionRequests
import com.fitlog.core.Ids
import com.fitlog.core.Times
import com.fitlog.importing.Conflict
import com.fitlog.importing.ImportChannel
import com.fitlog.importing.ImportOutcome
import com.fitlog.importing.ImportPreview
import com.fitlog.oauth.Connected
import com.fitlog.oauth.FakeImporter
import com.fitlog.oauth.a2Config
import com.fitlog.oauth.a2Test
import com.fitlog.oauth.connect
import com.fitlog.oauth.mcpCall
import com.fitlog.oauth.mcpInit
import com.fitlog.oauth.plainClient
import com.fitlog.oauth.result
import com.fitlog.program.catalog.ProgramTemplates
import com.fitlog.session.exJson
import com.fitlog.session.insertExercise
import com.fitlog.session.newId
import com.fitlog.session.putSession
import com.fitlog.session.sessionJson
import com.fitlog.session.setJson
import com.fitlog.support.auth
import com.fitlog.support.jsonBody
import io.ktor.client.HttpClient
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.HttpStatusCode
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.jetbrains.exposed.sql.SqlExpressionBuilder.eq
import org.jetbrains.exposed.sql.selectAll
import org.jetbrains.exposed.sql.transactions.transaction
import org.jetbrains.exposed.sql.update
import java.time.Duration
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

class McpToolsTest {
    private class Ctx(val c: HttpClient, val conn: Connected, val sid: String) {
        suspend fun call(tool: String, args: String = "{}") = c.mcpCall(conn.access, sid, tool, args).result()
    }

    private suspend fun HttpClient.ctx(write: Boolean = true): Ctx {
        val conn = connect(write = write)
        return Ctx(this, conn, mcpInit(conn.access))
    }

    private fun JsonObject.isError() = this["isError"]!!.jsonPrimitive.boolean
    private fun JsonObject.sc() = this["structuredContent"]!!.jsonObject
    private fun JsonObject.text() = this["content"]!!.jsonArray[0].jsonObject["text"]!!.jsonPrimitive.content

    private suspend fun HttpClient.startStronglifts(uid: UUID): String {
        val id = newId()
        val res = post("/v1/program-instances") {
            auth(uid); jsonBody()
            setBody(
                """{"id":"$id","programId":"${ProgramTemplates.idOf("stronglifts-5x5")}","startDate":"2026-11-02","tz":"Asia/Seoul",""" +
                    """"tm":{},"working":{"squat":100,"bench":60,"row":50,"ohp":40,"deadlift":120}}""",
            )
        }
        assertEquals(HttpStatusCode.Created, res.status, res.bodyAsText())
        return id
    }

    // ---------------------------------------------------------------- 조회

    @Test
    fun read_tools_profile_exercises_programs() = a2Test {
        val ctx = plainClient().ctx()
        val uid = ctx.conn.userId
        val ex = insertExercise(uid, "BARBELL")
        // 테스트 DB 에 같은 이름의 기본 종목이 쌓여도 limit 안에 들도록 고유 이름으로 바꾼다
        val uniqueName = "테스트 종목 ${ex.toString().takeLast(8)}"
        org.jetbrains.exposed.sql.transactions.transaction {
            com.fitlog.core.Exercises.update({ com.fitlog.core.Exercises.id eq ex }) { it[com.fitlog.core.Exercises.nameKo] = uniqueName }
        }

        val profile = ctx.call("get_profile")
        assertFalse(profile.isError())
        assertEquals("KG", profile.sc()["weightUnit"]!!.jsonPrimitive.content)
        assertEquals("Asia/Seoul", profile.sc()["timezone"]!!.jsonPrimitive.content)
        assertEquals("EPLEY", profile.sc()["e1rmFormula"]!!.jsonPrimitive.content)
        assertTrue(profile.text().isNotBlank() && !profile.text().contains("\n"))

        val found = ctx.call("search_exercises", """{"query":"$uniqueName","limit":5}""")
        assertTrue(found.sc()["exercises"]!!.jsonArray.any { it.jsonObject["id"]!!.jsonPrimitive.content == ex.toString() })
        assertEquals(0, ctx.call("search_exercises", """{"query":"zzzz없는종목"}""").sc()["count"]!!.jsonPrimitive.int)
        assertTrue(ctx.call("search_exercises", """{"type":"NOPE"}""").isError())

        val templates = ctx.call("list_programs", """{"source":"TEMPLATE"}""")
        assertTrue(templates.sc()["count"]!!.jsonPrimitive.int >= 5)
        assertEquals(0, ctx.call("list_programs", """{"source":"MINE"}""").sc()["count"]!!.jsonPrimitive.int)
        val nsuns4 = templates.sc()["programs"]!!.jsonArray.map { it.jsonObject }.first { it["templateKey"]?.jsonPrimitive?.content == "nsuns-4day" }
        assertEquals("INTERMEDIATE", nsuns4["level"]!!.jsonPrimitive.content)
        assertEquals("nsuns-amrap-wave", nsuns4["family"]!!.jsonPrimitive.content)
        assertEquals("주 4일", nsuns4["variantLabel"]!!.jsonPrimitive.content)
        assertEquals(1, nsuns4["aka"]!!.jsonArray.size)
        assertEquals(setOf("progress", "failure", "deload"), nsuns4["rules"]!!.jsonObject.keys)

        val program = ctx.call("get_program", """{"templateKey":"stronglifts-5x5"}""")
        val p = program.sc()["program"]!!.jsonObject
        assertEquals("stronglifts-5x5", p["templateKey"]!!.jsonPrimitive.content)
        assertTrue(p["definition"]!!.jsonObject["days"]!!.jsonArray.isNotEmpty())
        val byId = ctx.call("get_program", """{"id":"${p["id"]!!.jsonPrimitive.content}"}""")
        assertEquals(p["id"], byId.sc()["program"]!!.jsonObject["id"])
        assertTrue(ctx.call("get_program").isError())
        assertTrue(ctx.call("get_program", """{"templateKey":"nope"}""").isError())

        // 검증: 유효한 정의는 통과, 잘못된 정의는 경로가 있는 에러
        val valid = ctx.call("validate_program", """{"definition":${p["definition"]}}""")
        assertTrue(valid.sc()["valid"]!!.jsonPrimitive.boolean, valid.toString())
        val invalid = ctx.call("validate_program", """{"definition":{"schemaVersion":1,"name":"x"}}""")
        assertFalse(invalid.isError())
        assertFalse(invalid.sc()["valid"]!!.jsonPrimitive.boolean)
        assertTrue(invalid.sc()["errors"]!!.jsonArray.isNotEmpty())
        assertTrue(invalid.sc()["errors"]!!.jsonArray[0].jsonObject.containsKey("path"))
    }

    @Test
    fun read_tools_sessions_records_summary_body() = a2Test {
        val ctx = plainClient().ctx()
        val uid = ctx.conn.userId
        val ex = insertExercise(uid, "BARBELL")
        val sid1 = newId()
        val sid2 = newId()
        val c = ctx.c
        assertEquals(
            HttpStatusCode.OK,
            c.putSession(uid, sid1, sessionJson(sid1, "2026-11-10T01:00:00Z", "2026-11-10T02:00:00Z", exercises = listOf(
                exJson(exerciseId = ex, sets = listOf(setJson(weightKg = "100", reps = "5"), setJson(position = 1, weightKg = "110", reps = "3"))),
            ))).status,
        )
        assertEquals(
            HttpStatusCode.OK,
            c.putSession(uid, sid2, sessionJson(sid2, "2026-11-12T01:00:00Z", "2026-11-12T02:00:00Z", exercises = listOf(
                exJson(exerciseId = ex, sets = listOf(setJson(weightKg = "105", reps = "5"))),
            ))).status,
        )

        val list = ctx.call("list_sessions", """{"from":"2026-11-01","to":"2026-11-30"}""")
        assertEquals(2, list.sc()["count"]!!.jsonPrimitive.int)
        val first = list.sc()["sessions"]!!.jsonArray[0].jsonObject
        assertEquals(sid2, first["id"]!!.jsonPrimitive.content) // 최신순
        assertEquals("2026-11-12", first["date"]!!.jsonPrimitive.content)
        assertEquals(1, first["setCount"]!!.jsonPrimitive.int)
        assertEquals(525.0, first["totalVolumeKg"]!!.jsonPrimitive.double)
        assertEquals(1, ctx.call("list_sessions", """{"from":"2026-11-11","to":"2026-11-30"}""").sc()["count"]!!.jsonPrimitive.int)
        assertEquals(0, ctx.call("list_sessions", """{"from":"2026-12-01"}""").sc()["count"]!!.jsonPrimitive.int)
        assertTrue(ctx.call("list_sessions", """{"from":"2026/11/01"}""").isError())

        val detail = ctx.call("get_session", """{"id":"$sid1"}""")
        assertFalse(detail.isError())
        val s = detail.sc()["session"]!!.jsonObject
        assertEquals(1, s["exercises"]!!.jsonArray.size)
        assertEquals(2, s["exercises"]!!.jsonArray[0].jsonObject["sets"]!!.jsonArray.size)
        assertTrue(detail.sc()["exerciseNames"]!!.jsonObject.containsKey(ex.toString()))
        assertTrue(ctx.call("get_session", """{"id":"${UUID.randomUUID()}"}""").isError())

        val rec = ctx.call("get_exercise_records", """{"exerciseId":"$ex"}""").sc()["records"]!!.jsonObject
        assertEquals(110.0, rec["bestWeight"]!!.jsonObject["weightKg"]!!.jsonPrimitive.double)
        assertNotNull(rec["bestE1rm"])
        assertTrue(rec["byReps"]!!.jsonArray.any { it.jsonObject["reps"]!!.jsonPrimitive.int == 5 })
        assertTrue(ctx.call("get_exercise_records", """{"exerciseId":"${UUID.randomUUID()}"}""").isError())

        // v1.0 종목 추이: REST와 같은 출력
        val prog = ctx.call("get_exercise_progress", """{"exerciseId":"$ex","from":"2026-01-01T00:00:00Z","to":"2026-12-31T00:00:00Z"}""").sc()["progress"]!!.jsonObject
        assertEquals(2, prog["points"]!!.jsonArray.size)
        assertEquals(110.0, prog["bestWeight"]!!.jsonObject["weightKg"]!!.jsonPrimitive.double)
        assertTrue(ctx.call("get_exercise_progress", """{"exerciseId":"$ex","limit":501}""").isError())
        assertTrue(ctx.call("get_exercise_progress", """{"exerciseId":"${UUID.randomUUID()}"}""").isError())

        val sum = ctx.call("get_training_summary", """{"from":"2026-11-01","to":"2026-11-30"}""").sc()
        assertEquals(2, sum["sessionCount"]!!.jsonPrimitive.int)
        val e = sum["exercises"]!!.jsonArray[0].jsonObject
        assertEquals(ex.toString(), e["exerciseId"]!!.jsonPrimitive.content)
        assertEquals(3, e["sets"]!!.jsonPrimitive.int)
        assertEquals(500.0 + 330.0 + 525.0, e["volumeKg"]!!.jsonPrimitive.double)
        assertEquals(110.0, e["maxWeightKg"]!!.jsonPrimitive.double)
        assertNotNull(e["bestE1rmKg"])
        val weeks = sum["weeks"]!!.jsonArray.map { it.jsonObject }
        assertEquals(listOf("2026-11-09"), weeks.map { it["weekStart"]!!.jsonPrimitive.content }) // 월요일 시작
        assertEquals(2, weeks[0]["sessions"]!!.jsonPrimitive.int)
        assertTrue(ctx.call("get_training_summary", """{"from":"2026-11-30","to":"2026-11-01"}""").isError())
        assertTrue(ctx.call("get_training_summary", """{"from":"2020-01-01","to":"2026-11-01"}""").isError())

        // 체중
        c.post("/v1/body/measurements") {
            auth(uid); jsonBody()
            setBody("""{"id":"${newId()}","measuredAt":"2026-11-11T00:00:00Z","weightKg":80.5}""")
        }
        c.post("/v1/body/measurements") {
            auth(uid); jsonBody()
            setBody("""{"id":"${newId()}","measuredAt":"2026-11-20T00:00:00Z","weightKg":79.5}""")
        }
        val body = ctx.call("get_body_measurements", """{"from":"2026-11-01","to":"2026-11-30"}""")
        assertEquals(2, body.sc()["count"]!!.jsonPrimitive.int)
        assertEquals(79.5, body.sc()["measurements"]!!.jsonArray[0].jsonObject["weightKg"]!!.jsonPrimitive.double)
        assertEquals(1, ctx.call("get_body_measurements", """{"from":"2026-11-15"}""").sc()["count"]!!.jsonPrimitive.int)
        assertEquals(79.5, ctx.call("get_profile").sc()["latestBodyWeight"]!!.jsonObject["weightKg"]!!.jsonPrimitive.double)
    }

    @Test
    fun read_tools_instances_and_plan_and_adjust() = a2Test {
        val ctx = plainClient().ctx()
        val uid = ctx.conn.userId
        val instanceId = ctx.c.startStronglifts(uid)

        val list = ctx.call("list_program_instances", """{"status":"ACTIVE"}""")
        assertEquals(1, list.sc()["count"]!!.jsonPrimitive.int)
        val inst = list.sc()["instances"]!!.jsonArray[0].jsonObject
        assertEquals(instanceId, inst["id"]!!.jsonPrimitive.content)
        assertEquals(100.0, inst["state"]!!.jsonObject["working"]!!.jsonObject["squat"]!!.jsonPrimitive.double)
        assertNotNull(inst["next"])
        assertEquals(0, ctx.call("list_program_instances", """{"status":"PAUSED"}""").sc()["count"]!!.jsonPrimitive.int)

        val plan = ctx.call("get_plan", """{"instanceId":"$instanceId","count":2}""")
        assertEquals(2, plan.sc()["count"]!!.jsonPrimitive.int)
        val day = plan.sc()["plan"]!!.jsonArray[0].jsonObject
        assertEquals(1, day["planSeq"]!!.jsonPrimitive.int)
        assertTrue(day["exercises"]!!.jsonArray.isNotEmpty())
        assertTrue(ctx.call("get_plan", """{"instanceId":"${UUID.randomUUID()}"}""").isError())
        assertTrue(ctx.call("get_plan", """{"instanceId":"$instanceId","count":99}""").isError())

        // 조정: 작업 무게 변경, 일시중지
        val adj = ctx.call("adjust_program_instance", """{"instanceId":"$instanceId","working":{"squat":110},"status":"PAUSED"}""")
        assertFalse(adj.isError(), adj.toString())
        val after = adj.sc()["instance"]!!.jsonObject
        assertEquals("PAUSED", after["status"]!!.jsonPrimitive.content)
        assertEquals(110.0, after["state"]!!.jsonObject["working"]!!.jsonObject["squat"]!!.jsonPrimitive.double)
        val resumed = ctx.call("adjust_program_instance", """{"instanceId":"$instanceId","status":"ACTIVE"}""")
        assertEquals("ACTIVE", resumed.sc()["instance"]!!.jsonObject["status"]!!.jsonPrimitive.content)
        // 종료·삭제·모르는 키·빈 요청은 안 된다
        assertTrue(ctx.call("adjust_program_instance", """{"instanceId":"$instanceId","status":"FINISHED"}""").isError())
        assertTrue(ctx.call("adjust_program_instance", """{"instanceId":"$instanceId","working":{"nope":1}}""").isError())
        assertTrue(ctx.call("adjust_program_instance", """{"instanceId":"$instanceId"}""").isError())
        assertTrue(ctx.call("adjust_program_instance", """{"instanceId":"${UUID.randomUUID()}","status":"PAUSED"}""").isError())

        // 다른 사용자의 인스턴스는 보이지도 만지지도 못한다
        val other = plainClient().ctx()
        assertEquals(0, other.call("list_program_instances").sc()["count"]!!.jsonPrimitive.int)
        assertTrue(other.call("get_plan", """{"instanceId":"$instanceId"}""").isError())
        assertTrue(other.call("adjust_program_instance", """{"instanceId":"$instanceId","status":"PAUSED"}""").isError())
    }

    // ---------------------------------------------------------------- 쓰기 (가짜 importer)

    @Test
    fun write_tools_call_importer_with_mcp_context_and_bundle_shapes() {
        val importer = FakeImporter()
        a2Test(a2Config(importer)) {
            val ctx = plainClient().ctx()
            val conn = ctx.conn

            val bundle = """{"schemaVersion":1,"sessions":[{"startedAt":"2026-11-01T10:00:00+09:00","exercises":[{"exercise":{"name":"스쿼트"},"sets":[{"weightKg":100,"reps":5}]}]}]}"""
            val r = ctx.call("import_bundle", """{"bundle":$bundle,"onConflict":"SKIP_ALL","resolutions":{"c1":{"action":"SKIP"}}}""")
            assertFalse(r.isError(), r.toString())
            assertEquals("SAVED", r.sc()["status"]!!.jsonPrimitive.content)
            assertTrue(r.sc()["created"]!!.jsonPrimitive.boolean)
            val batchId = r.sc()["importBatchId"]!!.jsonPrimitive.content
            assertEquals(batchId, r.sc()["batch"]!!.jsonObject["id"]!!.jsonPrimitive.content)
            assertTrue(r.text().contains("앱의 AI 기록에서 되돌릴 수 있습니다"), r.text())
            assertTrue(r.sc()["message"]!!.jsonPrimitive.content.contains("되돌릴 수 있습니다"))

            val (ictx, req) = importer.calls.single()
            assertEquals(conn.userId, ictx.userId)
            assertEquals(ImportChannel.MCP, ictx.channel)
            assertEquals("Claude Test", ictx.clientName)
            assertEquals(conn.connectionId, ictx.aiConnectionId)
            assertEquals("MCP", req.channel)
            assertEquals("Claude Test", req.clientName)
            assertEquals("SKIP_ALL", req.onConflict)
            assertEquals("SKIP", req.resolutions["c1"]!!.action)
            assertEquals(1, (req.bundle as JsonObject)["sessions"]!!.jsonArray.size)
            importer.calls.clear()

            ctx.call("create_program", """{"definition":{"schemaVersion":1,"name":"P"},"note":"내가 만든 것"}""")
            var b = importer.calls.single().second.bundle.jsonObject
            assertEquals(1, b["schemaVersion"]!!.jsonPrimitive.int)
            assertEquals("내가 만든 것", b["note"]!!.jsonPrimitive.content)
            assertEquals("P", b["programs"]!!.jsonArray[0].jsonObject["definition"]!!.jsonObject["name"]!!.jsonPrimitive.content)
            importer.calls.clear()

            ctx.call("start_program", """{"program":{"templateKey":"stronglifts-5x5"},"startDate":"2026-11-02","working":{"squat":100},"skipPolicy":"SHIFT","tz":"Asia/Seoul"}""")
            val (_, startReq) = importer.calls.single()
            val sp = startReq.bundle.jsonObject["startPrograms"]!!.jsonArray[0].jsonObject
            assertEquals("stronglifts-5x5", sp["program"]!!.jsonObject["templateKey"]!!.jsonPrimitive.content)
            assertEquals("2026-11-02", sp["startDate"]!!.jsonPrimitive.content)
            assertEquals(100.0, sp["working"]!!.jsonObject["squat"]!!.jsonPrimitive.double)
            assertEquals("SHIFT", sp["skipPolicy"]!!.jsonPrimitive.content)
            assertEquals("Asia/Seoul", startReq.tz)
            importer.calls.clear()

            ctx.call("start_program", """{"program":{"templateKey":"stronglifts-5x5"},"startDate":"2026-11-02","working":{"squat":100},"skipPolicy":"FIXED_DATE","weekdays":{"A":"MON","B":"THU"}}""")
            val wsp = importer.calls.single().second.bundle.jsonObject["startPrograms"]!!.jsonArray[0].jsonObject
            assertEquals("THU", wsp["weekdays"]!!.jsonObject["B"]!!.jsonPrimitive.content)
            assertTrue(ctx.call("start_program", """{"program":{"templateKey":"x"},"startDate":"2026-11-02","weekdays":"MON"}""").isError())
            importer.calls.clear()

            ctx.call("log_session", """{"session":{"startedAt":"2026-11-01T10:00:00+09:00","exercises":[]}}""")
            assertEquals("2026-11-01T10:00:00+09:00", importer.calls.single().second.bundle.jsonObject["sessions"]!!.jsonArray[0].jsonObject["startedAt"]!!.jsonPrimitive.content)
            importer.calls.clear()

            ctx.call("log_body_weight", """{"measuredAt":"2026-11-01T07:00:00+09:00","weightKg":80.5}""")
            val bm = importer.calls.single().second.bundle.jsonObject["bodyMeasurements"]!!.jsonArray[0].jsonObject
            assertEquals(80.5, bm["weightKg"]!!.jsonPrimitive.double)
            importer.calls.clear()

            ctx.call("create_exercise", """{"nameKo":"케이블 컬","type":"MACHINE","primaryMuscle":"BICEPS","onConflict":"ASK"}""")
            val exb = importer.calls.single().second
            val exj = exb.bundle.jsonObject["exercises"]!!.jsonArray[0].jsonObject
            assertEquals("케이블 컬", exj["nameKo"]!!.jsonPrimitive.content)
            assertFalse(exj.containsKey("onConflict"))
            assertEquals("ASK", exb.onConflict)
            importer.calls.clear()

            // 입력 검증은 importer 를 부르기 전에
            assertTrue(ctx.call("log_body_weight", """{"measuredAt":"yesterday","weightKg":80}""").isError())
            assertTrue(ctx.call("log_body_weight", """{"measuredAt":"2026-11-01T07:00:00Z"}""").isError())
            assertTrue(ctx.call("import_bundle", """{"bundle":"not an object"}""").isError())
            assertTrue(ctx.call("start_program", """{"program":{"templateKey":"x"},"startDate":"11/02"}""").isError())
            assertTrue(importer.calls.isEmpty())
        }
    }

    @Test
    fun needs_resolution_is_reported_without_saving_and_importer_errors_become_tool_errors() {
        val importer = FakeImporter { _, _ ->
            ImportOutcome.NeedsResolution(
                ImportPreview(
                    valid = true,
                    counts = mapOf("exercises" to mapOf("create" to 1)),
                    conflicts = listOf(
                        Conflict("c1", "EXERCISE_NAME_AMBIGUOUS", "/sessions/0/exercises/0", "이름이 여러 종목과 맞습니다", listOf("MAP_TO", "CREATE", "SKIP")),
                    ),
                    unresolved = listOf("c1"),
                ),
            )
        }
        a2Test(a2Config(importer)) {
            val ctx = plainClient().ctx()
            val r = ctx.call("log_session", """{"session":{"startedAt":"2026-11-01T10:00:00+09:00","exercises":[]}}""")
            assertFalse(r.isError())
            assertEquals("NEEDS_RESOLUTION", r.sc()["status"]!!.jsonPrimitive.content)
            val conflicts = r.sc()["conflicts"]!!.jsonArray
            assertEquals(1, conflicts.size)
            assertEquals("c1", conflicts[0].jsonObject["conflictId"]!!.jsonPrimitive.content)
            assertEquals(listOf("MAP_TO", "CREATE", "SKIP"), conflicts[0].jsonObject["allowed"]!!.jsonArray.map { it.jsonPrimitive.content })
            assertTrue(r.sc()["importBatchId"] == null)
            assertFalse(r.text().contains("되돌릴 수 있습니다"))

            importer.outcome = { _, _ ->
                throw com.fitlog.core.ApiException(
                    com.fitlog.core.ErrorCode.VALIDATION_FAILED, "bundle is invalid",
                    details = listOf(com.fitlog.core.ErrorDetail("/sessions/0/startedAt", "must be date-time")),
                )
            }
            val bad = ctx.call("log_session", """{"session":{"exercises":[]}}""")
            assertTrue(bad.isError())
            assertTrue(bad.text().contains("/sessions/0/startedAt"), bad.text())

            // 구현 전(TODO) 이어도 서버가 죽지 않고 도구 오류로
            importer.outcome = { _, _ -> TODO("not yet") }
            assertTrue(ctx.call("log_body_weight", """{"measuredAt":"2026-11-01T07:00:00Z","weightKg":80}""").isError())
            assertFalse(ctx.call("get_profile").isError())
        }
    }

    @Test
    fun read_only_connection_cannot_call_write_tools() {
        val importer = FakeImporter()
        a2Test(a2Config(importer)) {
            val ctx = plainClient().ctx(write = false)
            for ((tool, args) in listOf(
                "import_bundle" to """{"bundle":{"schemaVersion":1}}""",
                "create_program" to """{"definition":{}}""",
                "start_program" to """{"program":{"templateKey":"x"},"startDate":"2026-11-02"}""",
                "log_session" to """{"session":{}}""",
                "log_body_weight" to """{"measuredAt":"2026-11-01T07:00:00Z","weightKg":80}""",
                "create_exercise" to """{"nameKo":"a","type":"MACHINE","primaryMuscle":"BICEPS"}""",
                "adjust_program_instance" to """{"instanceId":"${UUID.randomUUID()}","status":"PAUSED"}""",
                "request_deletion" to """{"entity":"session","id":"${UUID.randomUUID()}","reason":"x"}""",
            )) {
                val r = ctx.call(tool, args)
                assertTrue(r.isError(), tool)
                assertTrue(r.text().contains("권한"), "$tool: ${r.text()}")
            }
            assertTrue(importer.calls.isEmpty())
            assertFalse(ctx.call("get_profile").isError())
        }
    }

    @Test
    fun write_rate_limit_is_20_per_minute() {
        val importer = FakeImporter()
        a2Test(a2Config(importer)) {
            val ctx = plainClient().ctx()
            repeat(20) { assertFalse(ctx.call("log_body_weight", """{"measuredAt":"2026-11-01T07:00:00Z","weightKg":80}""").isError()) }
            val over = ctx.c.mcpCall(ctx.conn.access, ctx.sid, "log_body_weight", """{"measuredAt":"2026-11-01T07:00:00Z","weightKg":80}""")
            assertEquals(-32029, over["error"]!!.jsonObject["code"]!!.jsonPrimitive.int)
            assertEquals(20, importer.calls.size)
            // 조회는 아직 가능
            assertFalse(ctx.call("get_profile").isError())
        }
    }

    // ---------------------------------------------------------------- 삭제 요청

    @Test
    fun request_deletion_creates_pending_request_once_and_lists_it() = a2Test {
        val ctx = plainClient().ctx()
        val uid = ctx.conn.userId
        val ex = insertExercise(uid, "BARBELL")
        val sid = newId()
        ctx.c.putSession(uid, sid, sessionJson(sid, exercises = listOf(exJson(exerciseId = ex, sets = listOf(setJson())))))

        val r = ctx.call("request_deletion", """{"entity":"session","id":"$sid","reason":"중복 기록입니다"}""")
        assertFalse(r.isError(), r.toString())
        assertEquals("PENDING", r.sc()["status"]!!.jsonPrimitive.content)
        assertTrue(r.sc()["created"]!!.jsonPrimitive.boolean)
        val req = r.sc()["request"]!!.jsonObject
        assertEquals("workout_session", req["entity"]!!.jsonPrimitive.content)
        assertTrue(req["label"]!!.jsonPrimitive.content.contains("2026-11-26"))
        val reqId = req["id"]!!.jsonPrimitive.content

        transaction {
            val row = DeletionRequests.selectAll().where { DeletionRequests.id eq UUID.fromString(reqId) }.single()
            assertEquals(uid, row[DeletionRequests.userId])
            assertEquals(ctx.conn.connectionId, row[DeletionRequests.connectionId])
            assertEquals("Claude Test", row[DeletionRequests.clientName])
            assertEquals(UUID.fromString(sid), row[DeletionRequests.entityId])
            assertEquals("PENDING", row[DeletionRequests.status])
            assertEquals("중복 기록입니다", row[DeletionRequests.reason])
            val days = Duration.between(row[DeletionRequests.createdAt], row[DeletionRequests.expiresAt]).toDays()
            assertEquals(7, days)
        }
        // 대상 데이터는 그대로다 (AI 는 직접 지울 수 없다)
        assertFalse(ctx.call("get_session", """{"id":"$sid"}""").isError())

        // 같은 대상에 PENDING 이 있으면 기존 요청을 돌려준다
        val again = ctx.call("request_deletion", """{"entity":"session","id":"$sid","reason":"다시"}""")
        assertFalse(again.sc()["created"]!!.jsonPrimitive.boolean)
        assertEquals(reqId, again.sc()["request"]!!.jsonObject["id"]!!.jsonPrimitive.content)

        val listed = ctx.call("list_deletion_requests", """{"status":"PENDING"}""")
        assertEquals(1, listed.sc()["count"]!!.jsonPrimitive.int)
        assertEquals(0, ctx.call("list_deletion_requests", """{"status":"APPROVED"}""").sc()["count"]!!.jsonPrimitive.int)

        // 기한이 지난 PENDING 은 닫히고 새 요청을 만들 수 있다
        transaction {
            DeletionRequests.update({ DeletionRequests.id eq UUID.fromString(reqId) }) { it[expiresAt] = Times.now().minusSeconds(5) }
        }
        val renewed = ctx.call("request_deletion", """{"entity":"session","id":"$sid","reason":"다시"}""")
        assertTrue(renewed.sc()["created"]!!.jsonPrimitive.boolean)
        transaction {
            assertEquals("EXPIRED", DeletionRequests.selectAll().where { DeletionRequests.id eq UUID.fromString(reqId) }.single()[DeletionRequests.status])
        }

        // 다른 종류 대상
        val exReq = ctx.call("request_deletion", """{"entity":"exercise","id":"$ex","reason":"안 씀"}""")
        assertFalse(exReq.isError(), exReq.toString())
        assertEquals(2, ctx.call("list_deletion_requests", """{"status":"PENDING"}""").sc()["count"]!!.jsonPrimitive.int)
    }

    @Test
    fun request_deletion_rejects_foreign_missing_and_builtin_targets() = a2Test {
        val ctx = plainClient().ctx()
        val other = plainClient().ctx()
        val ex = insertExercise(other.conn.userId, "BARBELL")
        val sid = newId()
        other.c.putSession(other.conn.userId, sid, sessionJson(sid, exercises = listOf(exJson(exerciseId = ex, sets = listOf(setJson())))))
        val builtIn = insertExercise(null, "BARBELL")

        for ((entity, id) in listOf("session" to sid, "exercise" to ex.toString(), "exercise" to builtIn.toString(), "program" to UUID.randomUUID().toString(), "body_measurement" to UUID.randomUUID().toString())) {
            val r = ctx.call("request_deletion", """{"entity":"$entity","id":"$id","reason":"x"}""")
            assertTrue(r.isError(), "$entity $id")
        }
        assertTrue(ctx.call("request_deletion", """{"entity":"account","id":"${UUID.randomUUID()}","reason":"x"}""").isError())
        assertTrue(ctx.call("request_deletion", """{"entity":"session","id":"$sid"}""").isError())
        transaction {
            assertEquals(0L, DeletionRequests.selectAll().where { DeletionRequests.userId eq ctx.conn.userId }.count())
            assertEquals(0L, DeletionRequests.selectAll().where { DeletionRequests.userId eq other.conn.userId }.count())
        }
        // 다른 연결이 만든 요청은 이 연결의 목록에 보이지 않는다
        other.call("request_deletion", """{"entity":"session","id":"$sid","reason":"내 것"}""")
        assertEquals(1, other.call("list_deletion_requests").sc()["count"]!!.jsonPrimitive.int)
        assertEquals(0, ctx.call("list_deletion_requests").sc()["count"]!!.jsonPrimitive.int)
    }
}
