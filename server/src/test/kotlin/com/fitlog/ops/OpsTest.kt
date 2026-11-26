package com.fitlog.ops

import com.fitlog.module
import com.fitlog.support.TestEnv
import com.fitlog.core.SiteConfig
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.contentType
import io.ktor.server.testing.ApplicationTestBuilder
import io.ktor.server.testing.testApplication
import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

class OpsTest {
    private val config = TestEnv.config.copy(
        site = SiteConfig(contactEmail = "help@fitlog.test", effectiveDate = "2026-12-24", backupRetentionDays = 21),
        publicBaseUrl = "https://fit.example.com",
        maxBodyBytes = 1000,
    )

    private fun opsApp(block: suspend ApplicationTestBuilder.() -> Unit) = testApplication {
        application { module(config) }
        block()
    }

    @Test
    fun `ready returns ok when database is reachable`() = opsApp {
        val res = client.get("/health/ready")
        assertEquals(HttpStatusCode.OK, res.status)
        assertEquals("ok", res.bodyAsText())
    }

    @Test
    fun `privacy page substitutes placeholders and sets security headers`() = opsApp {
        val res = client.get("/privacy")
        assertEquals(HttpStatusCode.OK, res.status)
        val html = res.bodyAsText()
        assertContains(html, "help@fitlog.test")
        assertContains(html, "2026-12-24")
        assertContains(html, "21일")
        assertContains(html, "https://fit.example.com/account-deletion")
        assertFalse(html.contains("{{"), "placeholders must be replaced")
        assertContains(html, "<table>")
        assertContains(html, "<h2>1. 처리하는 정보</h2>")
        assertContains(res.headers[HttpHeaders.ContentType]!!, "text/html")
        assertEquals("default-src 'none'; style-src 'unsafe-inline'", res.headers["Content-Security-Policy"])
        assertEquals("nosniff", res.headers["X-Content-Type-Options"])
        assertEquals("no-referrer", res.headers["Referrer-Policy"])
        assertEquals("public, max-age=3600", res.headers[HttpHeaders.CacheControl])
    }

    @Test
    fun `account deletion page lists contact email and retention`() = opsApp {
        val res = client.get("/account-deletion")
        assertEquals(HttpStatusCode.OK, res.status)
        val html = res.bodyAsText()
        assertContains(html, "mailto:help@fitlog.test")
        assertContains(html, "설정 → 계정 → 계정 삭제")
        assertContains(html, "21일")
        assertContains(html, "href=\"/privacy\"")
        assertEquals("nosniff", res.headers["X-Content-Type-Options"])
    }

    @Test
    fun `request id is generated when missing and echoed when sane`() = opsApp {
        val generated = client.get("/health").headers["X-Request-Id"]
        assertTrue(!generated.isNullOrBlank())
        val echoed = client.get("/health") { header("X-Request-Id", "abc-123_DEF.4") }
        assertEquals("abc-123_DEF.4", echoed.headers["X-Request-Id"])
        val bad = client.get("/health") { header("X-Request-Id", "bad id with spaces <script>") }
        assertNotEquals("bad id with spaces <script>", bad.headers["X-Request-Id"])
        assertTrue(!bad.headers["X-Request-Id"].isNullOrBlank())
    }

    @Test
    fun `oversized content length gets 413 with standard error body`() = opsApp {
        val res = client.post("/v1/auth/google") {
            contentType(ContentType.Application.Json)
            setBody("x".repeat(2000))
        }
        assertEquals(HttpStatusCode.PayloadTooLarge, res.status)
        val body = res.bodyAsText()
        assertContains(body, "\"code\":\"VALIDATION_FAILED\"")
        assertContains(body, "request body too large")
    }

    @Test
    fun `small body is not rejected by the limit`() = opsApp {
        val res = client.post("/v1/auth/google") {
            contentType(ContentType.Application.Json)
            setBody("{}")
        }
        assertNotEquals(HttpStatusCode.PayloadTooLarge, res.status)
    }

    @Test
    fun `markdown renderer escapes html and blocks unsafe links`() {
        val html = Markdown.render("# 제목 <b>\n\n본문 **굵게** [나쁨](javascript:alert(1)) <script>x</script>\n\n- 하나\n- 둘")
        assertContains(html, "<h1>제목 &lt;b&gt;</h1>")
        assertContains(html, "<strong>굵게</strong>")
        assertFalse(html.contains("<a href=\"javascript"))
        assertFalse(html.contains("<script>"))
        assertContains(html, "<ul>")
    }
}
