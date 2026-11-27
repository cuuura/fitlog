package com.fitlog.oauth

import com.fitlog.core.AiConnections
import com.fitlog.core.OAuthTokens
import com.fitlog.core.Times
import io.ktor.client.HttpClient
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.request.options
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.contentType
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

/** 실사용에서 깨졌던 부류(재시도·CORS·디스커버리 경로·에러 형식) 회귀 테스트 */
class OAuthRobustnessTest {
    @Test
    fun refresh_retry_right_after_rotation_keeps_connection_alive() = a2Test {
        val c = plainClient()
        val conn = c.connect()
        suspend fun refresh(t: String) = c.post("/oauth/token") { setBody(form("grant_type" to "refresh_token", "refresh_token" to t)) }

        val r1 = refresh(conn.refresh)
        assertEquals(HttpStatusCode.OK, r1.status)
        val refresh1 = r1.json()["refresh_token"]!!.jsonPrimitive.content
        // 응답이 유실돼 클라이언트가 같은 옛 리프레시로 곧바로 재시도 → 연결이 끊기면 안 된다
        val retry = refresh(conn.refresh)
        assertEquals(HttpStatusCode.OK, retry.status)
        val access2 = retry.json()["access_token"]!!.jsonPrimitive.content
        assertNotNull(OAuthTokenService.authenticate(access2))
        assertEquals(HttpStatusCode.OK, refresh(refresh1).status)
        val revoked = transaction { AiConnections.selectAll().where { AiConnections.id eq conn.connectionId }.single()[AiConnections.revokedAt] }
        assertNull(revoked)

        // 후속 토큰이 모두 폐기된 뒤에는 유예 안이어도 옛 토큰 재사용은 거절
        transaction { OAuthTokens.update({ OAuthTokens.connectionId eq conn.connectionId }) { it[revokedAt] = Times.now() } }
        assertEquals("invalid_grant", refresh(conn.refresh).json()["error"]!!.jsonPrimitive.content)
    }

    @Test
    fun resource_parameter_accepts_mcp_url_and_server_root_but_not_others() = a2Test {
        val c = plainClient()
        val cid = c.registerClient()
        val ch = challengeOf(pkceVerifier())
        suspend fun target(resource: String) = c.get(authorizeUrl(cid, ch, resource = resource)).location()
        assertEquals("accounts.google.com", target("$TEST_BASE/mcp").host)
        assertEquals("accounts.google.com", target("$TEST_BASE/mcp/").host)
        assertEquals("accounts.google.com", target(TEST_BASE).host)
        assertEquals("invalid_target", target("https://evil.test/mcp").parameters["error"])
    }

    @Test
    fun openid_configuration_probe_returns_authorization_server_metadata() = a2Test {
        val c = plainClient()
        for (p in listOf("/.well-known/openid-configuration", "/.well-known/openid-configuration/mcp", "/mcp/.well-known/openid-configuration")) {
            val res = c.get(p)
            assertEquals(HttpStatusCode.OK, res.status, p)
            assertEquals("$TEST_BASE/oauth/token", res.json()["token_endpoint"]!!.jsonPrimitive.content)
        }
    }

    @Test
    fun cors_preflight_and_headers_for_browser_mcp_clients() = a2Test {
        val c = plainClient()
        val pre = c.options("/mcp") {
            header(HttpHeaders.Origin, "https://inspector.test")
            header("Access-Control-Request-Method", "POST")
            header("Access-Control-Request-Headers", "authorization,content-type,mcp-session-id")
        }
        assertEquals(HttpStatusCode.NoContent, pre.status)
        assertEquals("*", pre.headers["Access-Control-Allow-Origin"])
        assertTrue(pre.headers["Access-Control-Allow-Headers"]!!.contains("mcp-session-id"))
        assertTrue(pre.headers["Access-Control-Allow-Methods"]!!.contains("POST"))
        assertEquals(HttpStatusCode.NoContent, c.options("/oauth/token").status)
        // 실제 응답에도 붙고, 세션 ID·WWW-Authenticate 는 브라우저에 노출한다
        assertEquals("*", c.get("/.well-known/oauth-authorization-server").headers["Access-Control-Allow-Origin"])
        val unauth = c.mcpPost(null, null, "{}")
        assertEquals("*", unauth.headers["Access-Control-Allow-Origin"])
        assertTrue(unauth.headers["Access-Control-Expose-Headers"]!!.contains("Mcp-Session-Id"))
        // 인가 페이지(브라우저 이동)에는 붙이지 않는다
        assertNull(c.get("/oauth/authorize").headers["Access-Control-Allow-Origin"])
    }

    @Test
    fun rejected_token_gets_invalid_token_challenge_and_missing_token_does_not() = a2Test {
        val c = plainClient()
        val missing = c.mcpPost(null, null, "{}")
        assertEquals(HttpStatusCode.Unauthorized, missing.status)
        val h = missing.headers[HttpHeaders.WWWAuthenticate]!!
        assertTrue(!h.contains("invalid_token"))
        assertTrue(h.contains("resource_metadata=\"$TEST_BASE/.well-known/oauth-protected-resource\""))
        val bad = c.mcpPost("fla_expired", null, "{}")
        assertEquals(HttpStatusCode.Unauthorized, bad.status)
        assertTrue(bad.headers[HttpHeaders.WWWAuthenticate]!!.contains("error=\"invalid_token\""))
    }

    @Test
    fun unknown_session_gets_404_and_valid_one_works() = a2Test {
        val c = plainClient()
        val conn = c.connect()
        val sid = c.mcpInit(conn.access)
        assertEquals(HttpStatusCode.OK, c.mcpPost(conn.access, sid, """{"jsonrpc":"2.0","id":2,"method":"tools/list"}""").status)
        val res = c.mcpPost(conn.access, "garbage", """{"jsonrpc":"2.0","id":2,"method":"tools/list"}""")
        assertEquals(HttpStatusCode.NotFound, res.status)
    }

    @Test
    fun unknown_route_and_wrong_content_type_use_error_json_not_500() = a2Test {
        val c: HttpClient = plainClient()
        val nf = c.get("/v1/does-not-exist")
        assertEquals(HttpStatusCode.NotFound, nf.status)
        assertEquals("NOT_FOUND", nf.json()["error"]!!.jsonObject["code"]!!.jsonPrimitive.content)
        val bad = c.post("/v1/auth/google") {
            contentType(ContentType.Text.Plain)
            setBody("hello")
        }
        assertEquals(HttpStatusCode.UnsupportedMediaType, bad.status)
        assertEquals("VALIDATION_FAILED", bad.json()["error"]!!.jsonObject["code"]!!.jsonPrimitive.content)
        // 본문을 직접 보낸 405 는 그대로 둔다
        val get = c.get("/mcp")
        assertEquals(HttpStatusCode.MethodNotAllowed, get.status)
        assertEquals("", get.bodyAsText())
    }
}
