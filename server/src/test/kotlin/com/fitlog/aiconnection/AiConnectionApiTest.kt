package com.fitlog.aiconnection

import com.fitlog.core.AiConnections
import com.fitlog.core.Ids
import com.fitlog.core.OAuthClients
import com.fitlog.core.OAuthTokens
import com.fitlog.core.Times
import com.fitlog.session.arr
import com.fitlog.session.get
import com.fitlog.session.obj
import com.fitlog.session.str
import com.fitlog.support.TestEnv
import com.fitlog.support.auth
import com.fitlog.support.createUser
import com.fitlog.support.fitlogTest
import com.fitlog.support.jsonClient
import io.ktor.client.request.delete
import io.ktor.client.request.get
import io.ktor.http.HttpStatusCode
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.jetbrains.exposed.sql.SqlExpressionBuilder.eq
import org.jetbrains.exposed.sql.insert
import org.jetbrains.exposed.sql.selectAll
import org.jetbrains.exposed.sql.transactions.transaction
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class AiConnectionApiTest {
    private fun insertClient(name: String): UUID {
        val cid = Ids.newId()
        transaction {
            OAuthClients.insert {
                it[id] = cid
                it[clientId] = "client-$cid"
                it[clientName] = name
                it[redirectUris] = listOf("https://example.com/cb")
                it[createdAt] = Times.now()
            }
        }
        return cid
    }

    private fun insertConnection(uid: UUID, name: String, revoked: Boolean = false, scopes: List<String> = listOf("fitlog.read", "fitlog.write")): UUID {
        val client = insertClient(name)
        val conn = Ids.newId()
        transaction {
            AiConnections.insert {
                it[id] = conn
                it[userId] = uid
                it[clientId] = client
                it[AiConnections.scopes] = scopes
                it[createdAt] = Times.now()
                it[lastUsedAt] = Times.now()
                if (revoked) it[revokedAt] = Times.now()
            }
        }
        return conn
    }

    private fun insertToken(conn: UUID, kind: String): UUID {
        val tid = Ids.newId()
        transaction {
            OAuthTokens.insert {
                it[id] = tid
                it[connectionId] = conn
                it[OAuthTokens.kind] = kind
                it[tokenHash] = "hash-$tid"
                it[familyId] = Ids.newId()
                it[expiresAt] = Times.now().plusSeconds(3600)
                it[createdAt] = Times.now()
            }
        }
        return tid
    }

    @Test
    fun list_shows_own_active_connections_with_client_name() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val other = createUser()
        val mine = insertConnection(uid, "Claude")
        insertConnection(uid, "Revoked AI", revoked = true)
        insertConnection(other, "Other AI")
        val list = c.get("/v1/me/ai-connections") { auth(uid) }.arr()
        assertEquals(1, list.size)
        assertEquals(mine.toString(), list[0].str("id"))
        assertEquals("Claude", list[0].str("clientName"))
        assertEquals(listOf("fitlog.read", "fitlog.write"), list[0]["scopes"]!!.jsonArray.map { it.jsonPrimitive.content })
        assertNotNull(list[0].str("createdAt")); assertNotNull(list[0].str("lastUsedAt"))
        assertEquals(HttpStatusCode.Unauthorized, c.get("/v1/me/ai-connections").status)
    }

    @Test
    fun delete_revokes_connection_and_all_its_tokens() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val conn = insertConnection(uid, "ChatGPT")
        val keep = insertConnection(uid, "Gemini")
        val t1 = insertToken(conn, "ACCESS")
        val t2 = insertToken(conn, "REFRESH")
        val t3 = insertToken(keep, "ACCESS")

        assertEquals(HttpStatusCode.NoContent, c.delete("/v1/me/ai-connections/$conn") { auth(uid) }.status)
        transaction {
            assertNotNull(AiConnections.selectAll().where { AiConnections.id eq conn }.single()[AiConnections.revokedAt])
            for (t in listOf(t1, t2)) assertNotNull(OAuthTokens.selectAll().where { OAuthTokens.id eq t }.single()[OAuthTokens.revokedAt])
            assertNull(OAuthTokens.selectAll().where { OAuthTokens.id eq t3 }.single()[OAuthTokens.revokedAt])
            assertNull(AiConnections.selectAll().where { AiConnections.id eq keep }.single()[AiConnections.revokedAt])
        }
        val after = c.get("/v1/me/ai-connections") { auth(uid) }.arr()
        assertEquals(listOf(keep.toString()), after.map { it.str("id")!! })
        // 다시 지워도, 없는 연결도 204
        assertEquals(HttpStatusCode.NoContent, c.delete("/v1/me/ai-connections/$conn") { auth(uid) }.status)
        assertEquals(HttpStatusCode.NoContent, c.delete("/v1/me/ai-connections/${UUID.randomUUID()}") { auth(uid) }.status)
    }

    @Test
    fun delete_of_someone_elses_connection_is_404_and_changes_nothing() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val other = createUser()
        val conn = insertConnection(other, "Claude")
        val tok = insertToken(conn, "ACCESS")
        assertEquals(HttpStatusCode.NotFound, c.delete("/v1/me/ai-connections/$conn") { auth(uid) }.status)
        transaction {
            assertNull(AiConnections.selectAll().where { AiConnections.id eq conn }.single()[AiConnections.revokedAt])
            assertNull(OAuthTokens.selectAll().where { OAuthTokens.id eq tok }.single()[OAuthTokens.revokedAt])
        }
    }

    @Test
    fun mcp_info_has_url_and_three_clients() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val b = c.get("/v1/mcp-info") { auth(uid) }.obj()
        assertEquals(TestEnv.config.publicBaseUrl + "/mcp", b.str("mcpUrl"))
        val clients = b["clients"]!!.jsonArray
        assertEquals(listOf("claude", "chatgpt", "gemini"), clients.map { it.str("key")!! })
        for (cl in clients) {
            assertTrue(cl.str("name")!!.isNotEmpty())
            assertTrue(cl.jsonObject["steps"]!!.jsonArray.size in 2..4)
        }
        assertEquals(HttpStatusCode.Unauthorized, c.get("/v1/mcp-info").status)
    }
}
