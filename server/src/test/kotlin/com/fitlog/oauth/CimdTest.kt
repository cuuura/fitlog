package com.fitlog.oauth

import com.fitlog.core.CimdFetchException
import com.fitlog.core.ClientMetadataFetcher
import io.ktor.client.request.get
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.HttpStatusCode
import kotlinx.serialization.json.jsonPrimitive
import java.net.InetAddress
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

private const val CIMD_URL = "https://chatgpt.test/oauth/client.json"

private fun doc(
    clientId: String = CIMD_URL,
    redirects: String = """["$TEST_REDIRECT","https://chatgpt.test/cb"]""",
    extra: String = "",
) = """{"client_id":"$clientId","client_name":"ChatGPT CIMD","redirect_uris":$redirects$extra}"""

private class FakeCimd(val docs: MutableMap<String, String>) : ClientMetadataFetcher {
    val calls = AtomicInteger()
    override fun fetch(url: String): String {
        calls.incrementAndGet()
        return docs[url] ?: throw CimdFetchException("client metadata fetch failed with HTTP 404")
    }
}

class CimdTest {
    private fun cfg(f: FakeCimd) = a2Config().copy(cimdFetcher = f)

    @Test
    fun cimd_full_flow_with_pkce_and_mcp() {
        val fake = FakeCimd(mutableMapOf(CIMD_URL to doc()))
        a2Test(cfg(fake)) {
            val c = plainClient()
            val conn = c.connect(clientId = CIMD_URL)
            assertEquals(CIMD_URL, conn.clientId)
            assertTrue(conn.access.isNotEmpty())
            val sid = c.mcpInit(conn.access)
            val list = c.mcpPost(conn.access, sid, """{"jsonrpc":"2.0","id":3,"method":"tools/list"}""")
            assertEquals(HttpStatusCode.OK, list.status)
            assertTrue(list.bodyAsText().contains("tools"))
            // 리프레시도 동일하게 동작한다
            val r = c.post("/oauth/token") {
                setBody(form("grant_type" to "refresh_token", "refresh_token" to conn.refresh, "client_id" to CIMD_URL))
            }
            assertEquals(HttpStatusCode.OK, r.status)
            // 1시간 캐시: 여러 번 호출해도 문서는 한 번만 가져온다
            assertEquals(1, fake.calls.get())
        }
    }

    @Test
    fun document_client_id_mismatch_is_rejected() {
        val fake = FakeCimd(mutableMapOf(CIMD_URL to doc(clientId = "https://other.test/client.json")))
        a2Test(cfg(fake)) {
            val c = plainClient()
            val res = c.get(authorizeUrl(CIMD_URL, challengeOf(pkceVerifier())))
            assertEquals(HttpStatusCode.BadRequest, res.status)
            val tok = c.post("/oauth/token") {
                setBody(form("grant_type" to "authorization_code", "code" to "x", "redirect_uri" to TEST_REDIRECT, "code_verifier" to "y", "client_id" to CIMD_URL))
            }
            assertEquals(HttpStatusCode.BadRequest, tok.status)
            assertEquals("invalid_client", tok.json()["error"]!!.jsonPrimitive.content)
        }
    }

    @Test
    fun redirect_uri_not_in_document_is_rejected() {
        val fake = FakeCimd(mutableMapOf(CIMD_URL to doc()))
        a2Test(cfg(fake)) {
            val c = plainClient()
            val res = c.get(authorizeUrl(CIMD_URL, challengeOf(pkceVerifier()), redirect = "https://evil.test/cb"))
            assertEquals(HttpStatusCode.BadRequest, res.status)
        }
    }

    @Test
    fun unsupported_auth_method_and_bad_documents_are_rejected() {
        val bad = mapOf(
            "https://a.test/c.json" to doc("https://a.test/c.json", extra = ""","token_endpoint_auth_method":"private_key_jwt""""),
            "https://b.test/c.json" to doc("https://b.test/c.json", redirects = "[]"),
            "https://c.test/c.json" to "not json",
        )
        a2Test(cfg(FakeCimd(bad.toMutableMap()))) {
            val c = plainClient()
            for (u in bad.keys) {
                assertEquals(HttpStatusCode.BadRequest, c.get(authorizeUrl(u, challengeOf(pkceVerifier()))).status, u)
            }
            // 알 수 없는 URL(가져오기 실패)도 오류
            assertEquals(HttpStatusCode.BadRequest, c.get(authorizeUrl("https://none.test/c.json", challengeOf(pkceVerifier()))).status)
        }
        // auth method none 명시는 허용
        a2Test(cfg(FakeCimd(mutableMapOf(CIMD_URL to doc(extra = ""","token_endpoint_auth_method":"none"""")))) ) {
            assertEquals(HttpStatusCode.Found, plainClient().get(authorizeUrl(CIMD_URL, challengeOf(pkceVerifier()))).status)
        }
    }

    @Test
    fun dcr_client_still_works_alongside() = a2Test(cfg(FakeCimd(mutableMapOf()))) {
        val c = plainClient()
        val conn = c.connect()
        assertEquals(HttpStatusCode.OK, c.mcpPost(conn.access, c.mcpInit(conn.access), """{"jsonrpc":"2.0","id":3,"method":"tools/list"}""").status)
    }

    @Test
    fun client_id_shape() {
        assertTrue(isCimdClientId("https://chatgpt.com/oauth/client.json"))
        assertFalse(isCimdClientId("https://chatgpt.com"))
        assertFalse(isCimdClientId("http://chatgpt.com/a"))
        assertFalse(isCimdClientId("https://u:p@chatgpt.com/a"))
        assertFalse(isCimdClientId("https://chatgpt.com/a#frag"))
        assertFalse(isCimdClientId("fitlog_abc123"))
        assertFalse(isCimdClientId(null))
    }

    @Test
    fun ssrf_guard_rejects_non_public_addresses() {
        for (ip in listOf("127.0.0.1", "10.1.2.3", "172.16.0.5", "192.168.1.1", "169.254.169.254", "0.0.0.0", "100.64.0.1", "::1", "fe80::1", "fd00::1")) {
            assertFalse(isPublicAddress(InetAddress.getByName(ip)), ip)
        }
        for (ip in listOf("8.8.8.8", "1.1.1.1", "2606:4700:4700::1111")) {
            assertTrue(isPublicAddress(InetAddress.getByName(ip)), ip)
        }
        // 하나라도 사설 주소로 풀리면 거부(DNS 리바인딩 완화)
        assertFailsWith<CimdFetchException> {
            checkCimdHost("evil.test") { listOf(InetAddress.getByName("8.8.8.8"), InetAddress.getByName("127.0.0.1")) }
        }
        assertFailsWith<CimdFetchException> { checkCimdHost("localhost") }
        assertFailsWith<CimdFetchException> { HttpCimdFetcher().fetch("https://127.0.0.1/client.json") }
        assertFailsWith<CimdFetchException> { HttpCimdFetcher().fetch("http://example.com/client.json") }
        checkCimdHost("ok.test") { listOf(InetAddress.getByName("8.8.8.8")) }
    }
}
