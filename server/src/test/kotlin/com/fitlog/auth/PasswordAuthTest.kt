package com.fitlog.auth

import com.fitlog.core.AppConfig
import com.fitlog.core.AppJson
import com.fitlog.core.PasswordCredentials
import com.fitlog.core.PasswordLoginConfig
import com.fitlog.module
import com.fitlog.support.TestEnv
import com.fitlog.support.jsonBody
import com.fitlog.support.jsonClient
import io.ktor.client.HttpClient
import io.ktor.client.request.get
import io.ktor.client.request.delete
import io.ktor.client.request.header
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.HttpResponse
import io.ktor.client.statement.bodyAsText
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.server.testing.ApplicationTestBuilder
import io.ktor.server.testing.testApplication
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.jetbrains.exposed.sql.selectAll
import org.jetbrains.exposed.sql.transactions.transaction
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

class PasswordAuthTest {
    private val code = "letmein"
    private val on = TestEnv.config.copy(passwordLogin = PasswordLoginConfig(enabled = true, signupCode = code))

    private fun pwTest(cfg: AppConfig = on, block: suspend ApplicationTestBuilder.() -> Unit) = testApplication {
        application { module(cfg) }
        block()
    }

    private suspend fun HttpResponse.obj(): JsonObject = AppJson.parseToJsonElement(bodyAsText()).jsonObject
    private fun uname() = "u" + UUID.randomUUID().toString().replace("-", "").take(12)

    private suspend fun HttpClient.register(
        username: String,
        password: String = "password123",
        signupCode: String? = code,
    ) = post("/v1/auth/password/register") {
        jsonBody()
        val c = signupCode?.let { ""","signupCode":"$it"""" } ?: ""
        setBody("""{"username":"$username","password":"$password"$c}""")
    }

    private suspend fun HttpClient.login(username: String, password: String) =
        post("/v1/auth/password/login") { jsonBody(); setBody("""{"username":"$username","password":"$password"}""") }

    private suspend fun HttpResponse.errCode() = obj().getValue("error").jsonObject.getValue("code").jsonPrimitive.content

    @Test
    fun methodsReflectConfig() {
        pwTest {
            val o = jsonClient().get("/v1/auth/methods").obj()
            assertTrue(o.getValue("google").jsonPrimitive.boolean)
            assertTrue(o.getValue("password").jsonPrimitive.boolean)
            assertTrue(o.getValue("passwordSignup").jsonPrimitive.boolean)
        }
        pwTest(on.copy(passwordLogin = PasswordLoginConfig(enabled = true, signupCode = null))) {
            val o = jsonClient().get("/v1/auth/methods").obj()
            assertTrue(o.getValue("password").jsonPrimitive.boolean)
            assertFalse(o.getValue("passwordSignup").jsonPrimitive.boolean)
        }
        pwTest(TestEnv.config) {
            val o = jsonClient().get("/v1/auth/methods").obj()
            assertTrue(o.getValue("google").jsonPrimitive.boolean)
            assertFalse(o.getValue("password").jsonPrimitive.boolean)
            assertFalse(o.getValue("passwordSignup").jsonPrimitive.boolean)
        }
    }

    @Test
    fun disabledReturns404() = pwTest(TestEnv.config) {
        val c = jsonClient()
        val r = c.register(uname())
        assertEquals(HttpStatusCode.NotFound, r.status)
        assertEquals("NOT_FOUND", r.errCode())
        val l = c.login("someone", "password123")
        assertEquals(HttpStatusCode.NotFound, l.status)
        assertEquals("NOT_FOUND", l.errCode())
    }

    @Test
    fun registerReturnsUsableTokens() = pwTest {
        val c = jsonClient()
        val name = uname()
        val r = c.register("  ${name.uppercase()} ")
        assertEquals(HttpStatusCode.OK, r.status)
        val o = r.obj()
        assertTrue(o.getValue("isNewUser").jsonPrimitive.boolean)
        val me = c.get("/v1/me") { header(HttpHeaders.Authorization, "Bearer ${o.getValue("accessToken").jsonPrimitive.content}") }
        assertEquals(HttpStatusCode.OK, me.status)
        assertEquals("$name@password.local", me.obj().getValue("email").jsonPrimitive.content)
    }

    @Test
    fun signupCodeWrongMissingOrUnsetIs403() {
        pwTest {
            val c = jsonClient()
            val wrong = c.register(uname(), signupCode = "nope")
            assertEquals(HttpStatusCode.Forbidden, wrong.status)
            assertEquals("FORBIDDEN", wrong.errCode())
            assertEquals(HttpStatusCode.Forbidden, c.register(uname(), signupCode = null).status)
        }
        pwTest(on.copy(passwordLogin = PasswordLoginConfig(enabled = true, signupCode = null))) {
            assertEquals(HttpStatusCode.Forbidden, jsonClient().register(uname(), signupCode = "anything").status)
        }
    }

    @Test
    fun validationErrorsCarryField() = pwTest {
        val c = jsonClient()
        for ((u, p, field) in listOf(
            Triple("ab", "password123", "username"),
            Triple("a".repeat(33), "password123", "username"),
            Triple("bad name!", "password123", "username"),
            Triple(uname(), "short", "password"),
            Triple(uname(), "p".repeat(129), "password"),
        )) {
            val r = c.register(u, p)
            assertEquals(HttpStatusCode.BadRequest, r.status, "$u/$p")
            val e = r.obj().getValue("error").jsonObject
            assertEquals("VALIDATION_FAILED", e.getValue("code").jsonPrimitive.content)
            assertEquals(field, e.getValue("field").jsonPrimitive.content)
        }
    }

    @Test
    fun duplicateUsernameIsConflictCaseInsensitive() = pwTest {
        val c = jsonClient()
        val name = uname()
        assertEquals(HttpStatusCode.OK, c.register(name).status)
        val dup = c.register(name.uppercase())
        assertEquals(HttpStatusCode.Conflict, dup.status)
        assertEquals("CONFLICT", dup.errCode())
    }

    @Test
    fun loginSuccessAndFailures() = pwTest {
        val c = jsonClient()
        val name = uname()
        c.register(name)
        val ok = c.login(name.uppercase(), "password123")
        assertEquals(HttpStatusCode.OK, ok.status)
        assertFalse(ok.obj().getValue("isNewUser").jsonPrimitive.boolean)

        val bad = c.login(name, "wrongpassword")
        val unknown = c.login(uname(), "password123")
        assertEquals(HttpStatusCode.Unauthorized, bad.status)
        assertEquals(HttpStatusCode.Unauthorized, unknown.status)
        assertEquals("UNAUTHENTICATED", bad.errCode())
        val m1 = bad.obj().getValue("error").jsonObject.getValue("message").jsonPrimitive.content
        val m2 = unknown.obj().getValue("error").jsonObject.getValue("message").jsonPrimitive.content
        assertEquals("invalid username or password", m1)
        assertEquals(m1, m2)
    }

    @Test
    fun lockoutAfterFiveFailuresEvenWithCorrectPassword() = pwTest {
        val c = jsonClient()
        val name = uname()
        c.register(name)
        repeat(5) { assertEquals(HttpStatusCode.Unauthorized, c.login(name, "wrongpassword").status) }
        val locked = c.login(name, "password123")
        assertEquals(HttpStatusCode.TooManyRequests, locked.status)
        assertEquals("RATE_LIMITED", locked.errCode())
        val retry = locked.headers[HttpHeaders.RetryAfter]?.toLongOrNull()
        assertNotNull(retry)
        assertTrue(retry in 1..900, "retry-after=$retry")
    }

    @Test
    fun successResetsFailureCount() = pwTest {
        val c = jsonClient()
        val name = uname()
        c.register(name)
        repeat(4) { c.login(name, "wrongpassword") }
        assertEquals(HttpStatusCode.OK, c.login(name, "password123").status)
        repeat(4) { assertEquals(HttpStatusCode.Unauthorized, c.login(name, "wrongpassword").status) }
        assertEquals(HttpStatusCode.OK, c.login(name, "password123").status)
    }

    @Test
    fun refreshWorksWithIssuedToken() = pwTest {
        val c = jsonClient()
        val name = uname()
        val rt = c.register(name).obj().getValue("refreshToken").jsonPrimitive.content
        val r = c.post("/v1/auth/refresh") { jsonBody(); setBody("""{"refreshToken":"$rt"}""") }
        assertEquals(HttpStatusCode.OK, r.status)
        assertFalse(r.obj().getValue("isNewUser").jsonPrimitive.boolean)
    }

    @Test
    fun accountDeletionRemovesCredential() = pwTest {
        val c = jsonClient()
        val name = uname()
        val access = c.register(name).obj().getValue("accessToken").jsonPrimitive.content
        assertEquals(1, transaction { PasswordCredentials.selectAll().where { PasswordCredentials.username eq name }.count() }.toInt())
        val del = c.delete("/v1/me") { header(HttpHeaders.Authorization, "Bearer $access") }
        assertEquals(HttpStatusCode.NoContent, del.status)
        assertEquals(0, transaction { PasswordCredentials.selectAll().where { PasswordCredentials.username eq name }.count() }.toInt())
        assertEquals(HttpStatusCode.Unauthorized, c.login(name, "password123").status)
    }

    @Test
    fun hashFormatAndVerify() {
        val h = PasswordHasher.hash("correct horse")
        val p = h.split('$')
        assertEquals(4, p.size)
        assertEquals("pbkdf2_sha256", p[0])
        assertEquals("210000", p[1])
        assertEquals(16, java.util.Base64.getDecoder().decode(p[2]).size)
        assertEquals(32, java.util.Base64.getDecoder().decode(p[3]).size)
        assertTrue(PasswordHasher.verify("correct horse", h))
        assertFalse(PasswordHasher.verify("wrong horse", h))
        assertFalse(PasswordHasher.verify("x", "garbage"))
        assertTrue(PasswordHasher.hash("correct horse") != h)
    }
}
