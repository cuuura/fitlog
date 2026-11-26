package com.fitlog.auth

import com.fitlog.core.AppJson
import com.fitlog.core.RefreshTokens
import com.fitlog.core.Times
import com.fitlog.support.fitlogTest
import com.fitlog.support.jsonBody
import com.fitlog.support.jsonClient
import io.ktor.client.HttpClient
import io.ktor.client.request.HttpRequestBuilder
import io.ktor.client.request.header
import io.ktor.client.request.get
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.HttpResponse
import io.ktor.client.statement.bodyAsText
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.jetbrains.exposed.sql.SqlExpressionBuilder.eq
import org.jetbrains.exposed.sql.selectAll
import org.jetbrains.exposed.sql.transactions.transaction
import org.jetbrains.exposed.sql.update
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

class AuthFlowTest {
    private suspend fun HttpResponse.obj(): JsonObject = AppJson.parseToJsonElement(bodyAsText()).jsonObject

    private suspend fun HttpClient.google(token: String) =
        post("/v1/auth/google") { jsonBody(); setBody("""{"idToken":"$token"}""") }

    private suspend fun HttpClient.refresh(rt: String) =
        post("/v1/auth/refresh") { jsonBody(); setBody("""{"refreshToken":"$rt"}""") }

    private suspend fun HttpClient.logout(access: String, rt: String) =
        post("/v1/auth/logout") {
            jsonBody()
            header(HttpHeaders.Authorization, "Bearer $access")
            setBody("""{"refreshToken":"$rt"}""")
        }

    private fun HttpRequestBuilder.bearer(access: String) = header(HttpHeaders.Authorization, "Bearer $access")

    private fun sub() = "s-${UUID.randomUUID()}"

    @Test
    fun loginCreatesUserThenReloginIsNotNew() = fitlogTest {
        val c = jsonClient()
        val s = sub()
        val first = c.google("test:$s:a@x.com")
        assertEquals(HttpStatusCode.OK, first.status)
        val f = first.obj()
        assertTrue(f.getValue("isNewUser").jsonPrimitive.boolean)
        assertEquals(900L, f.getValue("expiresIn").jsonPrimitive.long)

        val me1 = c.get("/v1/me") { bearer(f.getValue("accessToken").jsonPrimitive.content) }.obj()

        val second = c.google("test:$s:new@x.com").obj()
        assertEquals(false, second.getValue("isNewUser").jsonPrimitive.boolean)
        val me2 = c.get("/v1/me") { bearer(second.getValue("accessToken").jsonPrimitive.content) }.obj()
        assertEquals(me1.getValue("id"), me2.getValue("id"))
        assertEquals("new@x.com", me2.getValue("email").jsonPrimitive.content)
    }

    @Test
    fun invalidGoogleTokenIs401() = fitlogTest {
        val c = jsonClient()
        val res = c.google("garbage")
        assertEquals(HttpStatusCode.Unauthorized, res.status)
        assertEquals("UNAUTHENTICATED", res.obj().getValue("error").jsonObject.getValue("code").jsonPrimitive.content)
    }

    @Test
    fun refreshTokenIsStoredHashedOnly() = fitlogTest {
        val c = jsonClient()
        val t = c.google("test:${sub()}:h@x.com").obj()
        val rt = t.getValue("refreshToken").jsonPrimitive.content
        val hash = RefreshTokenService.hash(rt)
        val stored = transaction {
            RefreshTokens.selectAll().where { RefreshTokens.tokenHash eq hash }.count()
        }
        assertEquals(1, stored)
        assertEquals(43, rt.length) // 32 bytes base64url without padding
    }

    @Test
    fun refreshRotatesAndOldTokenReuseRevokesEverything() = fitlogTest {
        val c = jsonClient()
        val t0 = c.google("test:${sub()}:r@x.com").obj()
        val rt0 = t0.getValue("refreshToken").jsonPrimitive.content

        val r1 = c.refresh(rt0)
        assertEquals(HttpStatusCode.OK, r1.status)
        val t1 = r1.obj()
        val rt1 = t1.getValue("refreshToken").jsonPrimitive.content
        assertNotEquals(rt0, rt1)
        assertEquals(false, t1.getValue("isNewUser").jsonPrimitive.boolean)

        val r2 = c.refresh(rt1)
        assertEquals(HttpStatusCode.OK, r2.status)
        val rt2 = r2.obj().getValue("refreshToken").jsonPrimitive.content

        // old (already rotated) token reused -> theft detection
        assertEquals(HttpStatusCode.Unauthorized, c.refresh(rt0).status)
        // the whole family is dead now, including the newest token
        assertEquals(HttpStatusCode.Unauthorized, c.refresh(rt2).status)
    }

    @Test
    fun unknownAndExpiredRefreshTokensAre401() = fitlogTest {
        val c = jsonClient()
        assertEquals(HttpStatusCode.Unauthorized, c.refresh("nope").status)

        val t = c.google("test:${sub()}:e@x.com").obj()
        val rt = t.getValue("refreshToken").jsonPrimitive.content
        transaction {
            RefreshTokens.update({ RefreshTokens.tokenHash eq RefreshTokenService.hash(rt) }) {
                it[expiresAt] = Times.now().minusSeconds(5)
            }
        }
        assertEquals(HttpStatusCode.Unauthorized, c.refresh(rt).status)
    }

    @Test
    fun logoutRevokesOwnTokenAndRequiresBearer() = fitlogTest {
        val c = jsonClient()
        val t = c.google("test:${sub()}:l@x.com").obj()
        val access = t.getValue("accessToken").jsonPrimitive.content
        val rt = t.getValue("refreshToken").jsonPrimitive.content

        val noAuth = c.post("/v1/auth/logout") { jsonBody(); setBody("""{"refreshToken":"$rt"}""") }
        assertEquals(HttpStatusCode.Unauthorized, noAuth.status)

        assertEquals(HttpStatusCode.NoContent, c.logout(access, rt).status)
        assertEquals(HttpStatusCode.Unauthorized, c.refresh(rt).status)
    }

    @Test
    fun logoutWithOthersOrUnknownTokenIs204AndDoesNotRevoke() = fitlogTest {
        val c = jsonClient()
        val a = c.google("test:${sub()}:a@x.com").obj()
        val b = c.google("test:${sub()}:b@x.com").obj()
        val accessA = a.getValue("accessToken").jsonPrimitive.content
        val rtB = b.getValue("refreshToken").jsonPrimitive.content

        assertEquals(HttpStatusCode.NoContent, c.logout(accessA, rtB).status)
        assertEquals(HttpStatusCode.NoContent, c.logout(accessA, "does-not-exist").status)
        // B's token still works
        assertEquals(HttpStatusCode.OK, c.refresh(rtB).status)
    }
}
