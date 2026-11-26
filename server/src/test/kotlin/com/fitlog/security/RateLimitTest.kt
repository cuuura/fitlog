package com.fitlog.security

import com.fitlog.core.AppJson
import com.fitlog.core.RateLimitConfig
import com.fitlog.module
import com.fitlog.support.TestEnv
import com.fitlog.support.auth
import com.fitlog.support.createUser
import com.fitlog.support.jsonBody
import io.ktor.client.request.HttpRequestBuilder
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.HttpResponse
import io.ktor.client.statement.bodyAsText
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.server.testing.testApplication
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

class RateLimitTest {
    private fun cfg(rl: RateLimitConfig, trustProxy: Boolean = false) =
        TestEnv.config.copy(rateLimits = rl, trustProxy = trustProxy)

    private suspend fun HttpResponse.assertLimited() {
        assertEquals(HttpStatusCode.TooManyRequests, status)
        val retry = headers[HttpHeaders.RetryAfter]
        assertNotNull(retry, "Retry-After missing")
        assertTrue(retry.toLong() >= 1, "Retry-After=$retry")
        val err = AppJson.parseToJsonElement(bodyAsText()).jsonObject["error"]!!.jsonObject
        assertEquals("RATE_LIMITED", err["code"]!!.jsonPrimitive.content)
    }

    private fun HttpRequestBuilder.badLogin(forwarded: String? = null) {
        jsonBody()
        forwarded?.let { header("X-Forwarded-For", it) }
        setBody("""{"idToken":"bad"}""")
    }

    @Test
    fun authBucketLimitsByIp() = testApplication {
        application { module(cfg(RateLimitConfig(enabled = true, authPerMinute = 3))) }
        repeat(3) { assertEquals(HttpStatusCode.Unauthorized, client.post("/v1/auth/google") { badLogin() }.status) }
        client.post("/v1/auth/google") { badLogin() }.assertLimited()
    }

    @Test
    fun forwardedForIgnoredWithoutTrustProxy() = testApplication {
        application { module(cfg(RateLimitConfig(enabled = true, authPerMinute = 2))) }
        repeat(2) { i -> client.post("/v1/auth/google") { badLogin("9.9.9.$i") } }
        client.post("/v1/auth/google") { badLogin("9.9.9.77") }.assertLimited()
    }

    @Test
    fun forwardedForSeparatesClientsWithTrustProxy() = testApplication {
        application { module(cfg(RateLimitConfig(enabled = true, authPerMinute = 2), trustProxy = true)) }
        repeat(2) { assertEquals(HttpStatusCode.Unauthorized, client.post("/v1/auth/google") { badLogin("9.9.9.1") }.status) }
        client.post("/v1/auth/google") { badLogin("9.9.9.1") }.assertLimited()
        assertEquals(HttpStatusCode.Unauthorized, client.post("/v1/auth/google") { badLogin("9.9.9.2") }.status)
    }

    @Test
    fun apiBucketSeparatesUsers() = testApplication {
        application { module(cfg(RateLimitConfig(enabled = true, apiPerMinute = 3))) }
        startApplication()
        val a = createUser()
        val b = createUser()
        repeat(3) { assertEquals(HttpStatusCode.OK, client.get("/v1/me") { auth(a) }.status) }
        client.get("/v1/me") { auth(a) }.assertLimited()
        assertEquals(HttpStatusCode.OK, client.get("/v1/me") { auth(b) }.status)
    }

    @Test
    fun exportBucketLimitsByUser() = testApplication {
        application { module(cfg(RateLimitConfig(enabled = true, exportPer10Minutes = 2))) }
        startApplication()
        val u = createUser()
        val other = createUser()
        repeat(2) { assertEquals(HttpStatusCode.OK, client.get("/v1/export.json") { auth(u) }.status) }
        client.get("/v1/export.json") { auth(u) }.assertLimited()
        assertEquals(HttpStatusCode.OK, client.get("/v1/me") { auth(u) }.status)
        assertEquals(HttpStatusCode.OK, client.get("/v1/export.json") { auth(other) }.status)
    }

    @Test
    fun mcpBucketLimitsByAuthorizationHash() = testApplication {
        application { module(cfg(RateLimitConfig(enabled = true, mcpPerMinute = 2))) }
        fun HttpRequestBuilder.tok(t: String) {
            jsonBody()
            header(HttpHeaders.Authorization, "Bearer $t")
            setBody("{}")
        }
        repeat(2) { client.post("/mcp") { tok("one") } }
        val limited = client.post("/mcp") { tok("one") }
        assertEquals(HttpStatusCode.TooManyRequests, limited.status)
        assertNotNull(limited.headers[HttpHeaders.RetryAfter])
        assertNotEquals(HttpStatusCode.TooManyRequests, client.post("/mcp") { tok("two") }.status)
    }

    @Test
    fun disabledNeverLimits() = testApplication {
        application {
            module(cfg(RateLimitConfig(enabled = false, authPerMinute = 1, apiPerMinute = 1, exportPer10Minutes = 1, mcpPerMinute = 1)))
        }
        startApplication()
        val u = createUser()
        repeat(5) {
            assertEquals(HttpStatusCode.Unauthorized, client.post("/v1/auth/google") { badLogin() }.status)
            assertEquals(HttpStatusCode.OK, client.get("/v1/me") { auth(u) }.status)
            assertEquals(HttpStatusCode.OK, client.get("/v1/export.json") { auth(u) }.status)
        }
    }
}
