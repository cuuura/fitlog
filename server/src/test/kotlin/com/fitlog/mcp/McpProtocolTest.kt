package com.fitlog.mcp

import com.fitlog.core.AiConnections
import com.fitlog.core.AiToolCalls
import com.fitlog.core.Times
import com.fitlog.oauth.a2Test
import com.fitlog.oauth.connect
import com.fitlog.oauth.json
import com.fitlog.oauth.mcpCall
import com.fitlog.oauth.mcpInit
import com.fitlog.oauth.mcpPost
import com.fitlog.oauth.plainClient
import com.fitlog.oauth.result
import com.fitlog.oauth.TEST_BASE
import io.ktor.client.request.delete
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.statement.bodyAsText
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.jetbrains.exposed.sql.SqlExpressionBuilder.eq
import org.jetbrains.exposed.sql.selectAll
import org.jetbrains.exposed.sql.transactions.transaction
import org.jetbrains.exposed.sql.update
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class McpProtocolTest {
    private val readTools = listOf(
        "get_profile", "search_exercises", "list_programs", "get_program", "validate_program", "list_program_instances",
        "get_plan", "list_sessions", "get_session", "get_exercise_records", "get_training_summary", "get_body_measurements",
        "list_deletion_requests",
    )
    private val writeTools = listOf(
        "import_bundle", "create_program", "start_program", "log_session", "log_body_weight", "create_exercise",
        "adjust_program_instance", "request_deletion",
    )

    @Test
    fun missing_or_invalid_token_gets_401_with_resource_metadata_header() = a2Test {
        val c = plainClient()
        val expected = "Bearer resource_metadata=\"$TEST_BASE/.well-known/oauth-protected-resource\""
        val none = c.mcpPost(null, null, """{"jsonrpc":"2.0","id":1,"method":"ping"}""")
        assertEquals(HttpStatusCode.Unauthorized, none.status)
        assertEquals(expected, none.headers[HttpHeaders.WWWAuthenticate])
        val bad = c.mcpPost("fla_not-a-token", null, """{"jsonrpc":"2.0","id":1,"method":"ping"}""")
        assertEquals(HttpStatusCode.Unauthorized, bad.status)
        assertEquals(expected, bad.headers[HttpHeaders.WWWAuthenticate])
        val wrongScheme = c.mcpPost(null, null, "{}") // 헤더 없이
        assertEquals(HttpStatusCode.Unauthorized, wrongScheme.status)
    }

    @Test
    fun initialize_negotiates_version_and_issues_session() = a2Test {
        val c = plainClient()
        val conn = c.connect()
        val res = c.mcpPost(
            conn.access, null,
            """{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}""",
        )
        assertEquals(HttpStatusCode.OK, res.status)
        assertTrue(res.headers[HttpHeaders.ContentType]!!.startsWith("application/json"))
        assertTrue(res.headers["Mcp-Session-Id"]!!.isNotEmpty())
        val j = res.json()
        assertEquals("2.0", j["jsonrpc"]!!.jsonPrimitive.content)
        assertEquals("a", j["id"]!!.jsonPrimitive.content)
        val r = j.result()
        assertEquals("2025-06-18", r["protocolVersion"]!!.jsonPrimitive.content)
        assertTrue(r["capabilities"]!!.jsonObject.containsKey("tools"))
        assertEquals("fitlog", r["serverInfo"]!!.jsonObject["name"]!!.jsonPrimitive.content)
        val instr = r["instructions"]!!.jsonPrimitive.content
        assertTrue("kg" in instr && "NEEDS_RESOLUTION" in instr && "request_deletion" in instr)

        // 모르는 버전을 요구하면 서버가 지원하는 최신 버전으로
        val other = c.mcpPost(
            conn.access, null,
            """{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}""",
        ).json().result()
        assertEquals("2025-06-18", other["protocolVersion"]!!.jsonPrimitive.content)
        val older = c.mcpPost(
            conn.access, null,
            """{"jsonrpc":"2.0","id":3,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}""",
        ).json().result()
        assertEquals("2025-03-26", older["protocolVersion"]!!.jsonPrimitive.content)
    }

    @Test
    fun session_header_is_required_and_checked() = a2Test {
        val c = plainClient()
        val conn = c.connect()
        val sid = c.mcpInit(conn.access)
        val ping = """{"jsonrpc":"2.0","id":5,"method":"ping"}"""
        assertEquals(HttpStatusCode.OK, c.mcpPost(conn.access, sid, ping).status)
        assertEquals(HttpStatusCode.BadRequest, c.mcpPost(conn.access, null, ping).status)
        assertEquals(HttpStatusCode.NotFound, c.mcpPost(conn.access, "no-such-session", ping).status)
        // 다른 연결의 세션은 쓸 수 없다
        val other = c.connect()
        assertEquals(HttpStatusCode.NotFound, c.mcpPost(other.access, sid, ping).status)
        // 종료
        val del = c.delete("/mcp") { header(HttpHeaders.Authorization, "Bearer ${conn.access}"); header("Mcp-Session-Id", sid) }
        assertEquals(HttpStatusCode.OK, del.status)
        assertEquals(HttpStatusCode.NotFound, c.mcpPost(conn.access, sid, ping).status)
    }

    @Test
    fun transport_edge_cases() = a2Test {
        val c = plainClient()
        val conn = c.connect()
        val sid = c.mcpInit(conn.access)
        // GET 은 405 (SSE 스트림 없음)
        val get = c.get("/mcp") { header(HttpHeaders.Authorization, "Bearer ${conn.access}") }
        assertEquals(HttpStatusCode.MethodNotAllowed, get.status)
        // 배치는 거절
        val batch = c.mcpPost(conn.access, sid, """[{"jsonrpc":"2.0","id":1,"method":"ping"}]""")
        assertEquals(HttpStatusCode.BadRequest, batch.status)
        assertEquals(-32600, batch.json()["error"]!!.jsonObject["code"]!!.jsonPrimitive.int)
        // 파싱 오류
        val broken = c.mcpPost(conn.access, sid, "{not json")
        assertEquals(HttpStatusCode.BadRequest, broken.status)
        assertEquals(-32700, broken.json()["error"]!!.jsonObject["code"]!!.jsonPrimitive.int)
        // 알림은 202, 본문 없음
        val note = c.mcpPost(conn.access, sid, """{"jsonrpc":"2.0","method":"notifications/initialized"}""")
        assertEquals(HttpStatusCode.Accepted, note.status)
        assertEquals("", note.bodyAsText())
        // 클라이언트가 보낸 응답도 202
        assertEquals(HttpStatusCode.Accepted, c.mcpPost(conn.access, sid, """{"jsonrpc":"2.0","id":9,"result":{}}""").status)
        // ping, 모르는 메서드
        assertEquals(JsonObject(emptyMap()), c.mcpPost(conn.access, sid, """{"jsonrpc":"2.0","id":5,"method":"ping"}""").json().result())
        val unknown = c.mcpPost(conn.access, sid, """{"jsonrpc":"2.0","id":6,"method":"resources/list"}""").json()
        assertEquals(-32601, unknown["error"]!!.jsonObject["code"]!!.jsonPrimitive.int)
        // 모르는 도구는 프로토콜 오류
        val tool = c.mcpCall(conn.access, sid, "no_such_tool")
        assertEquals(-32602, tool["error"]!!.jsonObject["code"]!!.jsonPrimitive.int)
    }

    @Test
    fun tools_list_has_21_tools_with_schemas_and_annotations() = a2Test {
        val c = plainClient()
        val conn = c.connect()
        val sid = c.mcpInit(conn.access)
        val tools = c.mcpPost(conn.access, sid, """{"jsonrpc":"2.0","id":2,"method":"tools/list"}""").json().result()["tools"]!!.jsonArray
        assertEquals(21, tools.size)
        assertEquals((readTools + writeTools).toSet(), tools.map { it.jsonObject["name"]!!.jsonPrimitive.content }.toSet())
        for (t in tools.map { it.jsonObject }) {
            val name = t["name"]!!.jsonPrimitive.content
            val desc = t["description"]!!.jsonPrimitive.content
            assertTrue(desc.contains("fitlog.read") || desc.contains("fitlog.write"), "$name permission note")
            assertTrue(Regex("[가-힣]").containsMatchIn(desc) && Regex("[A-Za-z]{4}").containsMatchIn(desc), "$name ko+en description")
            assertEquals("object", t["inputSchema"]!!.jsonObject["type"]!!.jsonPrimitive.content, name)
            assertEquals("object", t["outputSchema"]!!.jsonObject["type"]!!.jsonPrimitive.content, name)
            val ann = t["annotations"]!!.jsonObject
            val isWrite = name in writeTools
            assertEquals(!isWrite, ann["readOnlyHint"]!!.jsonPrimitive.boolean, name)
            assertEquals(false, ann["destructiveHint"]!!.jsonPrimitive.boolean, name)
            assertTrue(desc.contains(if (isWrite) "fitlog.write" else "fitlog.read"), name)
        }
        // read 전용 연결에도 쓰기 도구가 목록에 보인다
        val ro = c.connect(write = false)
        val roSid = c.mcpInit(ro.access)
        val roTools = c.mcpPost(ro.access, roSid, """{"jsonrpc":"2.0","id":2,"method":"tools/list"}""").json().result()["tools"]!!.jsonArray
        assertEquals(21, roTools.size)
    }

    @Test
    fun rate_limit_is_60_calls_per_minute_per_token() = a2Test {
        val c = plainClient()
        val conn = c.connect()
        val sid = c.mcpInit(conn.access)
        repeat(60) { i ->
            val r = c.mcpCall(conn.access, sid, "get_profile")
            assertNotNull(r["result"], "call $i should pass: $r")
        }
        val over = c.mcpCall(conn.access, sid, "get_profile")
        val err = over["error"]!!.jsonObject
        assertEquals(-32029, err["code"]!!.jsonPrimitive.int)
        assertEquals("RATE_LIMITED", err["message"]!!.jsonPrimitive.content)
        // 다른 토큰(다른 연결)은 영향 없음
        val other = c.connect()
        val otherSid = c.mcpInit(other.access)
        assertNotNull(c.mcpCall(other.access, otherSid, "get_profile")["result"])
        // 호출 로그에 RATE_LIMITED 가 남는다
        transaction {
            val codes = AiToolCalls.selectAll().where { AiToolCalls.connectionId eq conn.connectionId }.map { it[AiToolCalls.resultCode] }
            assertEquals(60, codes.count { it == "OK" })
            assertEquals(1, codes.count { it == "RATE_LIMITED" })
        }
    }

    @Test
    fun revoked_connection_gets_401_and_last_used_is_tracked() = a2Test {
        val c = plainClient()
        val conn = c.connect()
        transaction { assertNull(AiConnections.selectAll().where { AiConnections.id eq conn.connectionId }.single()[AiConnections.lastUsedAt]) }
        val sid = c.mcpInit(conn.access)
        assertNotNull(c.mcpCall(conn.access, sid, "get_profile")["result"])
        transaction { assertNotNull(AiConnections.selectAll().where { AiConnections.id eq conn.connectionId }.single()[AiConnections.lastUsedAt]) }

        transaction { AiConnections.update({ AiConnections.id eq conn.connectionId }) { it[revokedAt] = Times.now() } }
        val after = c.mcpPost(conn.access, sid, """{"jsonrpc":"2.0","id":1,"method":"ping"}""")
        assertEquals(HttpStatusCode.Unauthorized, after.status)
        assertTrue(after.headers[HttpHeaders.WWWAuthenticate]!!.contains("resource_metadata"))
    }

    @Test
    fun tool_calls_are_logged_without_input_bodies() = a2Test {
        val c = plainClient()
        val conn = c.connect()
        val sid = c.mcpInit(conn.access)
        c.mcpCall(conn.access, sid, "search_exercises", """{"query":"비밀검색어"}""")
        c.mcpCall(conn.access, sid, "get_session", """{"id":"not-a-uuid"}""")
        transaction {
            val rows = AiToolCalls.selectAll().where { AiToolCalls.connectionId eq conn.connectionId }.orderBy(AiToolCalls.id).toList()
            assertEquals(listOf("search_exercises", "get_session"), rows.map { it[AiToolCalls.tool] })
            assertEquals(listOf("OK", "VALIDATION_FAILED"), rows.map { it[AiToolCalls.resultCode] })
            assertTrue(rows.all { it[AiToolCalls.durationMs] >= 0 })
            // 테이블에는 입력 본문을 담을 컬럼이 없다
            assertEquals(setOf("id", "connection_id", "tool", "result_code", "duration_ms", "created_at"), AiToolCalls.columns.map { it.name }.toSet())
        }
    }
}
