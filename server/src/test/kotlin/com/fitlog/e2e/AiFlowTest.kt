package com.fitlog.e2e

import com.fitlog.oauth.a2Config
import com.fitlog.oauth.a2Test
import com.fitlog.oauth.connect
import com.fitlog.oauth.mcpCall
import com.fitlog.oauth.mcpInit
import com.fitlog.oauth.plainClient
import com.fitlog.oauth.result
import com.fitlog.support.auth
import com.fitlog.support.createUser
import com.fitlog.support.jsonBody
import io.ktor.client.request.get
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.HttpStatusCode
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.double
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * v0.3 완료 기준을 실제 가져오기·엔진으로 확인(트랙 리드 소유):
 * MCP 로 프로그램 시작·회차 기록 → 다음 계획 → 출처 표시 → 내보내기 → 새 계정에 가져오기 → 같은 기록·같은 상태
 */
class AiFlowTest {
    private val squat = "019b76da-4000-7000-8000-000000000001"
    private val bench = "019b76da-4000-7000-8000-000000000003"
    private val row = "019b76da-4000-7000-8000-00000000000a"

    private fun parse(s: String) = Json.parseToJsonElement(s).jsonObject

    private fun sets(kg: Int) = (1..5).joinToString(",") { """{"weightKg":$kg,"reps":5}""" }

    @Test
    fun mcp_program_session_export_and_reimport_into_new_account() = a2Test(a2Config(importer = null)) {
        val c = plainClient()
        val conn = c.connect(clientName = "Claude")
        val sid = c.mcpInit(conn.access)
        suspend fun call(tool: String, args: String): JsonObject {
            val r = c.mcpCall(conn.access, sid, tool, args).result()
            assertFalse(r["isError"]!!.jsonPrimitive.boolean, "$tool: $r")
            return r["structuredContent"]!!.jsonObject
        }

        // 1) MCP 로 StrongLifts 시작
        val started = call(
            "start_program",
            """{"program":{"templateKey":"stronglifts-5x5"},"startDate":"2026-11-02",
               "working":{"squat":100,"bench":60,"row":50,"ohp":40,"deadlift":120}}""",
        )
        assertTrue(started.toString().contains("\"id\""), started.toString())
        val inst = call("list_program_instances", "{}").toString()
        val instanceId = Regex("\"id\":\"([0-9a-f-]{36})\"").find(inst)!!.groupValues[1]

        // 2) 1회차(A) 기록 — 종목은 이름으로
        val logged = call(
            "log_session",
            """{"session":{"startedAt":"2026-11-02T10:00:00+09:00","endedAt":"2026-11-02T11:00:00+09:00","tz":"Asia/Seoul",
               "program":{"instanceId":"$instanceId","planSeq":1},
               "exercises":[{"exercise":{"id":"$squat"},"sets":[${sets(100)}]},
                            {"exercise":{"id":"$bench"},"sets":[${sets(60)}]},
                            {"exercise":{"id":"$row"},"sets":[${sets(50)}]}]}}""",
        )
        assertTrue(logged.toString().contains("importBatchId") || logged.toString().contains("\"id\""), logged.toString())

        // 3) 다음 계획: B, 스쿼트 102.5
        val plan = call("get_plan", """{"instanceId":"$instanceId","count":1}""").toString()
        assertTrue(plan.contains("\"dayKey\":\"B\""), plan)
        assertTrue(plan.contains("102.5"), plan)

        // 4) 출처: REST 세션 목록·가져오기 이력
        val uid = conn.userId
        val sessions = Json.parseToJsonElement(c.get("/v1/sessions") { auth(uid) }.bodyAsText()).jsonArray
        assertEquals(1, sessions.size)
        val s0 = parse(c.get("/v1/sessions/${sessions[0].jsonObject["id"]!!.jsonPrimitive.content}") { auth(uid) }.bodyAsText())
        assertEquals("AI_MCP", s0["source"]?.jsonPrimitive?.content, s0.toString())
        val imports = c.get("/v1/imports") { auth(uid) }.bodyAsText()
        assertTrue(imports.contains("\"channel\":\"MCP\"") && imports.contains("Claude"), imports)

        // 5) 내보내기 → 새 계정에 가져오기
        val exported = c.get("/v1/export.json") { auth(uid) }.bodyAsText()
        val other = createUser()
        val req = buildJsonObject { put("bundle", Json.parseToJsonElement(exported)); put("tz", "Asia/Seoul") }
        val res = c.post("/v1/imports") { auth(other); jsonBody(); setBody(req.toString()) }
        assertEquals(HttpStatusCode.Created, res.status, res.bodyAsText())

        val otherSessions = Json.parseToJsonElement(c.get("/v1/sessions") { auth(other) }.bodyAsText()).jsonArray
        assertEquals(1, otherSessions.size)
        assertEquals(sessions[0].jsonObject["totalVolumeKg"]!!.jsonPrimitive.double, otherSessions[0].jsonObject["totalVolumeKg"]!!.jsonPrimitive.double)
        val otherInst = Json.parseToJsonElement(c.get("/v1/program-instances") { auth(other) }.bodyAsText()).jsonArray
        assertEquals(1, otherInst.size)
        val mine = Json.parseToJsonElement(c.get("/v1/program-instances") { auth(uid) }.bodyAsText()).jsonArray
        assertEquals(mine[0].jsonObject["state"], otherInst[0].jsonObject["state"])
    }
}
