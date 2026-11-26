package com.fitlog.oauth

import com.fitlog.core.AiConnections
import com.fitlog.core.OAuthTokens
import com.fitlog.core.Times
import io.ktor.client.request.get
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.contentType
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive
import org.jetbrains.exposed.sql.SqlExpressionBuilder.eq
import org.jetbrains.exposed.sql.selectAll
import org.jetbrains.exposed.sql.transactions.transaction
import org.jetbrains.exposed.sql.update
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class OAuthFlowTest {
    @Test
    fun metadata_documents_are_served_on_all_paths() = a2Test {
        val c = plainClient()
        for (p in listOf("/.well-known/oauth-protected-resource", "/.well-known/oauth-protected-resource/mcp")) {
            val j = c.get(p).json()
            assertEquals("$TEST_BASE/mcp", j["resource"]!!.jsonPrimitive.content, p)
            assertEquals(listOf(TEST_BASE), j["authorization_servers"]!!.jsonArray.map { it.jsonPrimitive.content })
            assertEquals(listOf("fitlog.read", "fitlog.write"), j["scopes_supported"]!!.jsonArray.map { it.jsonPrimitive.content })
        }
        for (p in listOf("/.well-known/oauth-authorization-server", "/.well-known/oauth-authorization-server/mcp")) {
            val j = c.get(p).json()
            assertEquals(TEST_BASE, j["issuer"]!!.jsonPrimitive.content)
            assertEquals("$TEST_BASE/oauth/authorize", j["authorization_endpoint"]!!.jsonPrimitive.content)
            assertEquals("$TEST_BASE/oauth/token", j["token_endpoint"]!!.jsonPrimitive.content)
            assertEquals("$TEST_BASE/oauth/register", j["registration_endpoint"]!!.jsonPrimitive.content)
            assertEquals(listOf("code"), j["response_types_supported"]!!.jsonArray.map { it.jsonPrimitive.content })
            assertEquals(listOf("authorization_code", "refresh_token"), j["grant_types_supported"]!!.jsonArray.map { it.jsonPrimitive.content })
            assertEquals(listOf("S256"), j["code_challenge_methods_supported"]!!.jsonArray.map { it.jsonPrimitive.content })
            assertEquals(listOf("none"), j["token_endpoint_auth_methods_supported"]!!.jsonArray.map { it.jsonPrimitive.content })
            assertEquals(listOf("fitlog.read", "fitlog.write"), j["scopes_supported"]!!.jsonArray.map { it.jsonPrimitive.content })
        }
    }

    @Test
    fun registration_validates_and_returns_public_client() = a2Test {
        val c = plainClient()
        suspend fun reg(body: String) = c.post("/oauth/register") { contentType(ContentType.Application.Json); setBody(body) }

        val ok = reg("""{"client_name":"Claude","redirect_uris":["https://claude.ai/api/mcp/auth_callback","http://127.0.0.1:3000/cb"]}""")
        assertEquals(HttpStatusCode.Created, ok.status)
        val j = ok.json()
        assertTrue(j["client_id"]!!.jsonPrimitive.content.isNotEmpty())
        assertEquals("Claude", j["client_name"]!!.jsonPrimitive.content)
        assertEquals("none", j["token_endpoint_auth_method"]!!.jsonPrimitive.content)
        assertEquals(2, j["redirect_uris"]!!.jsonArray.size)
        assertEquals(listOf("authorization_code", "refresh_token"), j["grant_types"]!!.jsonArray.map { it.jsonPrimitive.content })
        assertEquals(listOf("code"), j["response_types"]!!.jsonArray.map { it.jsonPrimitive.content })

        assertEquals(HttpStatusCode.BadRequest, reg("""{"redirect_uris":["https://a.test/cb"]}""").status)
        assertEquals(HttpStatusCode.BadRequest, reg("""{"client_name":"x"}""").status)
        assertEquals(HttpStatusCode.BadRequest, reg("""{"client_name":"x","redirect_uris":[]}""").status)
        val http = reg("""{"client_name":"x","redirect_uris":["http://evil.example/cb"]}""")
        assertEquals(HttpStatusCode.BadRequest, http.status)
        assertEquals("invalid_redirect_uri", http.json()["error"]!!.jsonPrimitive.content)
        assertEquals(HttpStatusCode.BadRequest, reg("""{"client_name":"x","redirect_uris":["myapp://cb"]}""").status)
        val confidential = reg("""{"client_name":"x","redirect_uris":["https://a.test/cb"],"token_endpoint_auth_method":"client_secret_basic"}""")
        assertEquals(HttpStatusCode.BadRequest, confidential.status)
        assertEquals("invalid_client_metadata", confidential.json()["error"]!!.jsonPrimitive.content)
        assertEquals(HttpStatusCode.BadRequest, reg("not json").status)
    }

    @Test
    fun authorize_never_redirects_for_bad_client_or_redirect_uri() = a2Test {
        val c = plainClient()
        val cid = c.registerClient()
        val ch = challengeOf(pkceVerifier())
        val unknown = c.get(authorizeUrl("nope", ch))
        assertEquals(HttpStatusCode.BadRequest, unknown.status)
        assertNull(unknown.headers[HttpHeaders.Location])
        assertTrue(unknown.headers[HttpHeaders.ContentType]!!.startsWith("text/html"))
        val badRedirect = c.get(authorizeUrl(cid, ch, redirect = "http://localhost:7777/other"))
        assertEquals(HttpStatusCode.BadRequest, badRedirect.status)
        assertNull(badRedirect.headers[HttpHeaders.Location])
    }

    @Test
    fun authorize_requires_pkce_and_redirects_other_errors_with_state() = a2Test {
        val c = plainClient()
        val cid = c.registerClient()
        val ch = challengeOf(pkceVerifier())
        suspend fun err(url: String): Pair<String?, String?> {
            val r = c.get(url)
            assertEquals(HttpStatusCode.Found, r.status)
            val loc = r.location()
            assertEquals("localhost", loc.host)
            return loc.parameters["error"] to loc.parameters["state"]
        }
        assertEquals("invalid_request" to "xyz", err(authorizeUrl(cid, "")))
        assertEquals("invalid_request" to "xyz", err(authorizeUrl(cid, ch, method = "plain")))
        assertEquals("invalid_request" to "xyz", err(authorizeUrl(cid, ch, method = null)))
        assertEquals("invalid_target" to "xyz", err(authorizeUrl(cid, ch, resource = "https://other.test/mcp")))
        assertEquals("invalid_scope" to "xyz", err(authorizeUrl(cid, ch, scope = "admin")))
        assertEquals("unsupported_response_type" to "xyz", err(authorizeUrl(cid, ch).replace("response_type=code", "response_type=token")))
        // resource 가 맞으면 Google 로 간다
        val good = c.get(authorizeUrl(cid, ch, resource = "$TEST_BASE/mcp"))
        assertEquals("accounts.google.com", good.location().host)
        val loc = good.location()
        assertEquals("web-client-id", loc.parameters["client_id"])
        assertEquals("$TEST_BASE/oauth/google/callback", loc.parameters["redirect_uri"])
        assertEquals("openid email profile", loc.parameters["scope"])
        assertEquals("code", loc.parameters["response_type"])
    }

    @Test
    fun full_flow_register_authorize_google_consent_token() = a2Test {
        val c = plainClient()
        val conn = c.connect(clientName = "Claude Test")
        assertEquals("fitlog.read fitlog.write", conn.scope)
        assertTrue(conn.access.isNotEmpty() && conn.refresh.isNotEmpty() && conn.access != conn.refresh)

        // 토큰은 해시로만 저장된다
        transaction {
            assertTrue(OAuthTokens.selectAll().where { OAuthTokens.tokenHash eq conn.access }.empty())
            assertTrue(OAuthTokens.selectAll().where { OAuthTokens.tokenHash eq sha256Hex(conn.access) }.count() == 1L)
            assertTrue(OAuthTokens.selectAll().where { OAuthTokens.tokenHash eq sha256Hex(conn.refresh) }.count() == 1L)
            val row = AiConnections.selectAll().where { AiConnections.id eq conn.connectionId }.single()
            assertEquals(listOf("fitlog.read", "fitlog.write"), row[AiConnections.scopes])
            assertNull(row[AiConnections.revokedAt])
        }
        // 토큰 응답 형식
        val tok = c.post("/oauth/token") {
            setBody(form("grant_type" to "refresh_token", "refresh_token" to conn.refresh))
        }
        assertEquals(HttpStatusCode.OK, tok.status)
        assertEquals("no-store", tok.headers[HttpHeaders.CacheControl])
        val j = tok.json()
        assertEquals("Bearer", j["token_type"]!!.jsonPrimitive.content)
        assertEquals("3600", j["expires_in"]!!.jsonPrimitive.content)
        assertEquals("fitlog.read fitlog.write", j["scope"]!!.jsonPrimitive.content)
    }

    @Test
    fun consent_page_shows_client_and_write_checkbox() = a2Test {
        val c = plainClient()
        val cid = c.registerClient("내 AI <b>")
        val verifier = pkceVerifier()
        val auth = c.get(authorizeUrl(cid, challengeOf(verifier)))
        val st = auth.location().parameters["state"]!!
        val page = c.get("/oauth/google/callback?code=test:pg-${System.nanoTime()}:a@b.c&state=${urlEnc(st)}").bodyAsText()
        assertTrue(page.contains("내 AI &lt;b&gt;이(가) 내 운동 기록을 읽고/추가합니다"), page)
        assertTrue(page.contains("name=\"write\""))
        assertTrue(page.contains("name=\"decision\" value=\"allow\""))
        // 읽기만 요청하면 쓰기 체크박스가 없다
        val auth2 = c.get(authorizeUrl(cid, challengeOf(verifier), scope = "fitlog.read"))
        val page2 = c.get("/oauth/google/callback?code=test:pg-${System.nanoTime()}:a@b.c&state=${urlEnc(auth2.location().parameters["state"]!!)}").bodyAsText()
        assertFalse(page2.contains("name=\"write\""))
    }

    @Test
    fun consent_without_write_checkbox_grants_read_only() = a2Test {
        val c = plainClient()
        val conn = c.connect(write = false)
        assertEquals("fitlog.read", conn.scope)
        transaction {
            assertEquals(listOf("fitlog.read"), AiConnections.selectAll().where { AiConnections.id eq conn.connectionId }.single()[AiConnections.scopes])
        }
    }

    @Test
    fun consent_deny_redirects_with_access_denied_and_creates_no_connection() = a2Test {
        val c = plainClient()
        val cid = c.registerClient()
        val sub = "deny-${System.nanoTime()}"
        val formToken = c.loginUntilConsent(cid, sub, challengeOf(pkceVerifier()), state = "s1")
        val r = c.post("/oauth/consent") { setBody(form("form" to formToken, "decision" to "deny")) }
        assertEquals(HttpStatusCode.Found, r.status)
        val loc = r.location()
        assertEquals("access_denied", loc.parameters["error"])
        assertEquals("s1", loc.parameters["state"])
        assertNull(loc.parameters["code"])
        transaction {
            val uid = com.fitlog.core.AppUsers.selectAll().where { com.fitlog.core.AppUsers.googleSub eq sub }.single()[com.fitlog.core.AppUsers.id]
            assertTrue(AiConnections.selectAll().where { AiConnections.userId eq uid }.empty())
        }
    }

    @Test
    fun consent_and_callback_reject_forged_or_expired_values() = a2Test {
        val c = plainClient()
        val cid = c.registerClient()
        val formToken = c.loginUntilConsent(cid, "forge-${System.nanoTime()}", challengeOf(pkceVerifier()))
        val tampered = formToken.dropLast(2) + (if (formToken.endsWith("AA")) "BB" else "AA")
        assertEquals(HttpStatusCode.BadRequest, c.post("/oauth/consent") { setBody(form("form" to tampered, "decision" to "allow")) }.status)
        assertEquals(HttpStatusCode.BadRequest, c.post("/oauth/consent") { setBody(form("decision" to "allow")) }.status)
        // authz 용 서명을 consent 용으로 쓸 수 없다
        val authzState = c.get(authorizeUrl(cid, challengeOf(pkceVerifier()))).location().parameters["state"]!!
        assertEquals(HttpStatusCode.BadRequest, c.post("/oauth/consent") { setBody(form("form" to authzState, "decision" to "allow")) }.status)
        assertEquals(HttpStatusCode.BadRequest, c.get("/oauth/google/callback?code=test:a:b&state=garbage").status)
        // Google 로그인 실패
        assertEquals(HttpStatusCode.BadRequest, c.get("/oauth/google/callback?code=bad-code&state=${urlEnc(authzState)}").status)
        // 사용자가 Google 에서 취소
        val cancelled = c.get("/oauth/google/callback?error=access_denied&state=${urlEnc(authzState)}")
        assertEquals(HttpStatusCode.Found, cancelled.status)
        assertEquals("access_denied", cancelled.location().parameters["error"])
    }

    @Test
    fun token_rejects_pkce_mismatch_and_other_bad_requests() = a2Test {
        val c = plainClient()
        val cid = c.registerClient()
        val verifier = pkceVerifier()
        val formToken = c.loginUntilConsent(cid, "pk-${System.nanoTime()}", challengeOf(verifier))
        val code = c.post("/oauth/consent") { setBody(form("form" to formToken, "decision" to "allow")) }.location().parameters["code"]!!

        suspend fun exchange(vararg extra: Pair<String, String>) = c.post("/oauth/token") {
            val base = mutableMapOf("grant_type" to "authorization_code", "code" to code, "redirect_uri" to TEST_REDIRECT, "code_verifier" to verifier)
            extra.forEach { base[it.first] = it.second }
            setBody(form(*base.map { it.key to it.value }.toTypedArray()))
        }
        val wrongVerifier = exchange("code_verifier" to pkceVerifier())
        assertEquals(HttpStatusCode.BadRequest, wrongVerifier.status)
        assertEquals("invalid_grant", wrongVerifier.json()["error"]!!.jsonPrimitive.content)
        assertEquals("invalid_grant", exchange("redirect_uri" to "http://localhost:7777/other").json()["error"]!!.jsonPrimitive.content)
        assertEquals("invalid_target", exchange("resource" to "https://other.test/mcp").json()["error"]!!.jsonPrimitive.content)
        assertEquals("invalid_grant", exchange("code" to "unknown").json()["error"]!!.jsonPrimitive.content)
        assertEquals("invalid_request", exchange("code_verifier" to "").json()["error"]!!.jsonPrimitive.content)
        val badGrant = c.post("/oauth/token") { setBody(form("grant_type" to "password")) }
        assertEquals("unsupported_grant_type", badGrant.json()["error"]!!.jsonPrimitive.content)
        // 실패한 시도 뒤에도 올바른 검증자로는 교환할 수 있다. resource 가 맞으면 통과
        val ok = exchange("resource" to "$TEST_BASE/mcp")
        assertEquals(HttpStatusCode.OK, ok.status)
    }

    @Test
    fun authorization_code_is_single_use_and_reuse_revokes_connection_tokens() = a2Test {
        val c = plainClient()
        val cid = c.registerClient()
        val verifier = pkceVerifier()
        val formToken = c.loginUntilConsent(cid, "reuse-${System.nanoTime()}", challengeOf(verifier))
        val code = c.post("/oauth/consent") { setBody(form("form" to formToken, "decision" to "allow")) }.location().parameters["code"]!!
        suspend fun exchange() = c.post("/oauth/token") {
            setBody(form("grant_type" to "authorization_code", "code" to code, "redirect_uri" to TEST_REDIRECT, "code_verifier" to verifier))
        }
        val first = exchange()
        assertEquals(HttpStatusCode.OK, first.status)
        val access = first.json()["access_token"]!!.jsonPrimitive.content
        assertNotNull(OAuthTokenService.authenticate(access))

        val second = exchange()
        assertEquals(HttpStatusCode.BadRequest, second.status)
        assertEquals("invalid_grant", second.json()["error"]!!.jsonPrimitive.content)
        // 재사용 감지: 이 연결의 토큰이 모두 폐기된다
        assertNull(OAuthTokenService.authenticate(access))
        val refresh = first.json()["refresh_token"]!!.jsonPrimitive.content
        val r = c.post("/oauth/token") { setBody(form("grant_type" to "refresh_token", "refresh_token" to refresh)) }
        assertEquals("invalid_grant", r.json()["error"]!!.jsonPrimitive.content)
    }

    @Test
    fun auth_code_expires_after_ten_minutes() = a2Test {
        val c = plainClient()
        val cid = c.registerClient()
        val verifier = pkceVerifier()
        val formToken = c.loginUntilConsent(cid, "exp-${System.nanoTime()}", challengeOf(verifier))
        val code = c.post("/oauth/consent") { setBody(form("form" to formToken, "decision" to "allow")) }.location().parameters["code"]!!
        transaction {
            com.fitlog.core.OAuthAuthCodes.update({ com.fitlog.core.OAuthAuthCodes.codeHash eq sha256Hex(code) }) {
                it[expiresAt] = Times.now().minusSeconds(1)
            }
        }
        val r = c.post("/oauth/token") {
            setBody(form("grant_type" to "authorization_code", "code" to code, "redirect_uri" to TEST_REDIRECT, "code_verifier" to verifier))
        }
        assertEquals("invalid_grant", r.json()["error"]!!.jsonPrimitive.content)
    }

    @Test
    fun refresh_rotates_and_reuse_of_old_refresh_revokes_family() = a2Test {
        val c = plainClient()
        val conn = c.connect()
        suspend fun refresh(t: String) = c.post("/oauth/token") { setBody(form("grant_type" to "refresh_token", "refresh_token" to t)) }

        val r1 = refresh(conn.refresh)
        assertEquals(HttpStatusCode.OK, r1.status)
        val j1 = r1.json()
        val access1 = j1["access_token"]!!.jsonPrimitive.content
        val refresh1 = j1["refresh_token"]!!.jsonPrimitive.content
        assertNotEquals(conn.refresh, refresh1)
        assertNotEquals(conn.access, access1)
        assertNotNull(OAuthTokenService.authenticate(access1))
        val familyIds = transaction {
            OAuthTokens.selectAll().where { OAuthTokens.connectionId eq conn.connectionId }.map { it[OAuthTokens.familyId] }.toSet()
        }
        assertEquals(1, familyIds.size)

        // 새 리프레시로 또 회전
        val r2 = refresh(refresh1)
        assertEquals(HttpStatusCode.OK, r2.status)
        val refresh2 = r2.json()["refresh_token"]!!.jsonPrimitive.content
        val access2 = r2.json()["access_token"]!!.jsonPrimitive.content

        // 이미 회전된 리프레시를 다시 쓰면 거절 + 계열 전체 폐기
        val reuse = refresh(refresh1)
        assertEquals(HttpStatusCode.BadRequest, reuse.status)
        assertEquals("invalid_grant", reuse.json()["error"]!!.jsonPrimitive.content)
        assertEquals("invalid_grant", refresh(refresh2).json()["error"]!!.jsonPrimitive.content)
        assertNull(OAuthTokenService.authenticate(access2))
        assertNull(OAuthTokenService.authenticate(access1))
        assertEquals("invalid_grant", refresh("unknown-token").json()["error"]!!.jsonPrimitive.content)
    }

    @Test
    fun reconnect_after_revoke_reuses_connection_and_dead_tokens_stay_dead() = a2Test {
        val c = plainClient()
        val first = c.connect(write = true)
        transaction {
            AiConnections.update({ AiConnections.id eq first.connectionId }) { it[revokedAt] = Times.now() }
        }
        assertNull(OAuthTokenService.authenticate(first.access))
        val refreshDenied = c.post("/oauth/token") { setBody(form("grant_type" to "refresh_token", "refresh_token" to first.refresh)) }
        assertEquals("invalid_grant", refreshDenied.json()["error"]!!.jsonPrimitive.content)

        // 같은 사용자·같은 클라이언트가 읽기 전용으로 다시 연결
        val second = c.connect(write = false, sub = first.sub, clientId = first.clientId)
        assertEquals(first.connectionId, second.connectionId)
        assertEquals("fitlog.read", second.scope)
        transaction {
            val row = AiConnections.selectAll().where { AiConnections.id eq first.connectionId }.single()
            assertNull(row[AiConnections.revokedAt])
            assertEquals(listOf("fitlog.read"), row[AiConnections.scopes])
        }
        assertNull(OAuthTokenService.authenticate(first.access), "old token must not come back to life")
        assertNotNull(OAuthTokenService.authenticate(second.access))
    }
}
