package com.fitlog

import com.fitlog.core.AUTH_BEARER
import com.fitlog.core.userId
import com.fitlog.support.TestEnv
import com.fitlog.support.auth
import com.fitlog.support.createUser
import io.ktor.client.request.get
import io.ktor.client.statement.bodyAsText
import io.ktor.http.HttpStatusCode
import io.ktor.server.auth.authenticate
import io.ktor.server.response.respondText
import io.ktor.server.routing.get
import io.ktor.server.routing.routing
import io.ktor.server.testing.testApplication
import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertEquals

class HealthTest {
    private fun probeApp(block: suspend io.ktor.server.testing.ApplicationTestBuilder.() -> Unit) = testApplication {
        application {
            module(TestEnv.config)
            routing { authenticate(AUTH_BEARER) { get("/_probe") { call.respondText(call.userId.toString()) } } }
        }
        block()
    }

    @Test
    fun `health is ok and migrations ran`() = probeApp {
        assertEquals("ok", client.get("/health").bodyAsText())
    }

    @Test
    fun `missing token returns contract 401`() = probeApp {
        val res = client.get("/_probe")
        assertEquals(HttpStatusCode.Unauthorized, res.status)
        assertContains(res.bodyAsText(), "\"code\":\"UNAUTHENTICATED\"")
    }

    @Test
    fun `valid token resolves userId`() = probeApp {
        startApplication()
        val uid = createUser()
        val res = client.get("/_probe") { auth(uid) }
        assertEquals(uid.toString(), res.bodyAsText())
    }
}
