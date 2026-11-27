package com.fitlog.mcp

import com.fitlog.core.Ids
import com.fitlog.core.PasswordLoginConfig
import com.fitlog.core.Exercises
import com.fitlog.oauth.TEST_BASE
import com.fitlog.oauth.a2Config
import com.fitlog.oauth.a2Test
import com.fitlog.oauth.connect
import com.fitlog.oauth.json
import com.fitlog.oauth.mcpCall
import com.fitlog.oauth.mcpInit
import com.fitlog.oauth.mcpPost
import com.fitlog.oauth.plainClient
import com.fitlog.oauth.result
import com.fitlog.session.exJson
import com.fitlog.session.insertExercise
import com.fitlog.session.newId
import com.fitlog.session.putSession
import com.fitlog.session.sessionJson
import com.fitlog.session.setJson
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.statement.bodyAsText
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.jetbrains.exposed.sql.SqlExpressionBuilder.eq
import org.jetbrains.exposed.sql.transactions.transaction
import org.jetbrains.exposed.sql.update
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** ChatGPT 호환(search/fetch), 스키마 점검, /health/mcp-trace */
class McpCompatTest {
    private fun JsonObject.isError() = this["isError"]!!.jsonPrimitive.boolean
    private fun JsonObject.sc() = this["structuredContent"]!!.jsonObject
    private fun JsonObject.text() = this["content"]!!.jsonArray[0].jsonObject["text"]!!.jsonPrimitive.content

    @Test
    fun all_tool_schemas_are_structurally_valid() = a2Test {
        val c = plainClient()
        val conn = c.connect()
        val sid = c.mcpInit(conn.access)
        val tools = c.mcpPost(conn.access, sid, """{"jsonrpc":"2.0","id":2,"method":"tools/list"}""").json().result()["tools"]!!.jsonArray
        val nameRe = Regex("^[a-zA-Z0-9_-]{1,64}$")
        val allowedTypes = setOf("object", "string", "integer", "number", "boolean", "array", "null")
        // 검증기(networknt 등)가 클래스패스에 없어 구조 점검만 한다
        fun check(where: String, n: kotlinx.serialization.json.JsonElement) {
            val o = n as? JsonObject ?: return
            o["type"]?.let { t ->
                val ts = (t as? kotlinx.serialization.json.JsonPrimitive)?.let { listOf(it.content) } ?: t.jsonArray.map { it.jsonPrimitive.content }
                assertTrue(ts.all { it in allowedTypes }, "$where type $t")
                if ("object" in ts && o.containsKey("properties")) assertTrue(o["properties"] is JsonObject, "$where properties")
                if ("array" in ts) assertNotNull(o["items"], "$where array needs items")
            }
            o["required"]?.let { r -> r.jsonArray.forEach { k -> assertTrue(o["properties"]!!.jsonObject.containsKey(k.jsonPrimitive.content), "$where required ${k} not in properties") } }
            assertFalse(o.containsKey("\$ref"), "$where \$ref unsupported")
            o["properties"]?.jsonObject?.forEach { (k, v) -> check("$where.$k", v) }
            o["items"]?.let { check("$where[]", it) }
            (o["additionalProperties"] as? JsonObject)?.let { check("$where{}", it) }
        }
        val names = mutableSetOf<String>()
        for (t in tools.map { it.jsonObject }) {
            val name = t["name"]!!.jsonPrimitive.content
            assertTrue(nameRe.matches(name), name)
            assertTrue(names.add(name), "duplicate $name")
            for (key in listOf("inputSchema", "outputSchema")) {
                val sch = t[key]!!.jsonObject
                assertEquals("object", sch["type"]!!.jsonPrimitive.content, "$name.$key")
                assertTrue(sch["properties"] is JsonObject, "$name.$key must declare properties (even empty)")
                check("$name.$key", sch)
            }
        }
        assertTrue("search" in names && "fetch" in names)
    }

    @Test
    fun search_and_fetch_return_json_text_and_structured_content() = a2Test {
        val c = plainClient()
        val conn = c.connect()
        val sid = c.mcpInit(conn.access)
        val uid = conn.userId
        val ex = insertExercise(uid, "BARBELL")
        val unique = "검색종목${ex.toString().takeLast(8)}"
        transaction { Exercises.update({ Exercises.id eq ex }) { it[Exercises.nameKo] = unique } }
        val sid1 = newId()
        c.putSession(uid, sid1, sessionJson(sid1, "2026-11-10T01:00:00Z", "2026-11-10T02:00:00Z", exercises = listOf(
            exJson(exerciseId = ex, sets = listOf(setJson(weightKg = "100", reps = "5"), setJson(position = 1, weightKg = "110", reps = "3"))),
        )))

        val s = c.mcpCall(conn.access, sid, "search", """{"query":"$unique"}""").result()
        assertFalse(s.isError())
        // content 텍스트가 곧 {"results":[...]} JSON
        val parsed = Json.parseToJsonElement(s.text()).jsonObject
        assertEquals(s.sc(), parsed)
        val results = parsed["results"]!!.jsonArray.map { it.jsonObject }
        val ids = results.map { it["id"]!!.jsonPrimitive.content }
        assertTrue("exercise:$ex" in ids, ids.toString())
        assertTrue("session:$sid1" in ids, ids.toString())
        results.forEach {
            assertTrue(it["title"]!!.jsonPrimitive.content.isNotBlank())
            assertEquals("$TEST_BASE/r/${it["id"]!!.jsonPrimitive.content}", it["url"]!!.jsonPrimitive.content)
        }
        // 날짜로도 찾는다
        val byDate = c.mcpCall(conn.access, sid, "search", """{"query":"2026-11-10"}""").result()
        assertTrue(byDate.sc()["results"]!!.jsonArray.any { it.jsonObject["id"]!!.jsonPrimitive.content == "session:$sid1" })
        assertTrue(c.mcpCall(conn.access, sid, "search", """{"query":"zzz없는것zzz"}""").result().sc()["results"]!!.jsonArray.isEmpty())
        assertTrue(c.mcpCall(conn.access, sid, "search", "{}").result().isError())
        // 프로그램 템플릿
        val prog = c.mcpCall(conn.access, sid, "search", """{"query":"stronglifts"}""").result().sc()["results"]!!.jsonArray
        val progId = prog.map { it.jsonObject["id"]!!.jsonPrimitive.content }.firstOrNull { it.startsWith("program:") }
        assertNotNull(progId)

        for ((id, needle) in listOf("session:$sid1" to "100×5", "exercise:$ex" to unique, progId!! to "구성")) {
            val f = c.mcpCall(conn.access, sid, "fetch", """{"id":"$id"}""").result()
            assertFalse(f.isError(), "$id ${f.text()}")
            val o = Json.parseToJsonElement(f.text()).jsonObject
            assertEquals(f.sc(), o)
            assertEquals(id, o["id"]!!.jsonPrimitive.content)
            assertEquals("$TEST_BASE/r/$id", o["url"]!!.jsonPrimitive.content)
            assertTrue(o["title"]!!.jsonPrimitive.content.isNotBlank())
            assertTrue(o["text"]!!.jsonPrimitive.content.contains(needle), "$id: ${o["text"]}")
            assertNotNull(o["metadata"]!!.jsonObject)
        }
        val sessionText = Json.parseToJsonElement(c.mcpCall(conn.access, sid, "fetch", """{"id":"session:$sid1"}""").result().text())
            .jsonObject["text"]!!.jsonPrimitive.content
        assertTrue(sessionText.contains("110×3") && sessionText.contains(unique), sessionText)

        // 알 수 없는 id 는 도구 오류(500 아님)
        for (bad in listOf("session:${UUID.randomUUID()}", "exercise:${UUID.randomUUID()}", "program:${UUID.randomUUID()}", "instance:${UUID.randomUUID()}", "nonsense", "foo:${UUID.randomUUID()}", "session:not-a-uuid")) {
            val r = c.mcpCall(conn.access, sid, "fetch", """{"id":"$bad"}""").result()
            assertTrue(r.isError(), bad)
        }
        // 다른 사용자의 세션은 보이지 않는다
        val other = c.connect()
        val otherSid = c.mcpInit(other.access)
        assertTrue(c.mcpCall(other.access, otherSid, "fetch", """{"id":"session:$sid1"}""").result().isError())
        assertFalse(Ids.newId().toString().isEmpty())
    }

    @Test
    fun mcp_trace_is_404_when_disabled_and_records_rows_when_enabled() {
        // 꺼짐: 비밀번호 로그인도 꺼진 기본 설정
        a2Test(a2Config().copy(mcpTrace = false)) {
            val c = plainClient()
            assertEquals(HttpStatusCode.NotFound, c.get("/health/mcp-trace").status)
        }
        a2Test(a2Config().copy(mcpTrace = true)) {
            val c = plainClient()
            // 인증 실패 호출도 남는다
            c.mcpPost(null, null, """{"jsonrpc":"2.0","id":1,"method":"ping"}""")
            val conn = c.connect()
            val sid = c.mcpInit(conn.access)
            c.mcpPost(conn.access, null, """{"jsonrpc":"2.0","id":2,"method":"tools/list"}""")
            c.mcpPost(conn.access, "stale-sid", """{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_profile","arguments":{"secret":"zzz-arg"}}}""")
            c.mcpCall(conn.access, sid, "no_such_tool")
            val res = c.get("/health/mcp-trace")
            assertEquals(HttpStatusCode.OK, res.status)
            val body = res.bodyAsText()
            val entries = Json.parseToJsonElement(body).jsonObject["entries"]!!.jsonArray.map { it.jsonObject }.reversed() // 오래된 것부터
            assertTrue(entries.size >= 6, body)
            assertEquals(false, entries[0]["authenticated"]!!.jsonPrimitive.boolean)
            assertEquals("401", entries[0]["status"]!!.jsonPrimitive.content)
            val init = entries.first { it["rpcMethod"]!!.jsonPrimitive.content == "initialize" }
            assertEquals("test/1", init["client"]!!.jsonPrimitive.content)
            assertEquals(true, init["authenticated"]!!.jsonPrimitive.boolean)
            assertTrue(entries.any { it["rpcMethod"]!!.jsonPrimitive.content == "tools/list" && !it["sessionPresent"]!!.jsonPrimitive.boolean })
            val stale = entries.first { it["sessionPresent"]!!.jsonPrimitive.boolean && it["sessionVerified"]?.jsonPrimitive?.boolean == false }
            assertEquals("get_profile", stale["tool"]!!.jsonPrimitive.content)
            assertEquals("200", stale["status"]!!.jsonPrimitive.content)
            assertNull(stale["rpcError"])
            val unknownTool = entries.last { it["tool"]?.jsonPrimitive?.content == "no_such_tool" }
            assertEquals("-32602", unknownTool["rpcError"]!!.jsonPrimitive.content)
            // 후속 요청에는 세션 기준 클라이언트 이름이 붙는다
            assertEquals("test/1", unknownTool["client"]!!.jsonPrimitive.content)
            // 토큰·인자는 기록하지 않는다
            assertFalse(body.contains(conn.access) || body.contains("zzz-arg") || body.contains(conn.connectionId.toString()) || body.contains(conn.userId.toString()))
        }
    }

    @Test
    fun mcp_trace_defaults_to_password_login_flag_and_ring_is_bounded() {
        assertTrue(a2Config().copy(passwordLogin = PasswordLoginConfig(enabled = true), mcpTrace = null).mcpTraceEnabled)
        assertFalse(a2Config().copy(passwordLogin = PasswordLoginConfig(enabled = true), mcpTrace = false).mcpTraceEnabled)
        assertFalse(a2Config().copy(passwordLogin = PasswordLoginConfig(enabled = false), mcpTrace = null).mcpTraceEnabled)
        val buf = McpTraceBuffer(100)
        repeat(130) { buf.add(McpTraceRow("POST")) }
        assertEquals(100, buf.json()["count"]!!.jsonPrimitive.content.toInt())
        assertEquals(120, truncateUa("x".repeat(500))!!.length)
    }
}
