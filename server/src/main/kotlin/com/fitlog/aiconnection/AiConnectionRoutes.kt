package com.fitlog.aiconnection

import com.fitlog.core.AiConnections
import com.fitlog.core.AppConfig
import com.fitlog.core.Ids
import com.fitlog.core.InstantSerializer
import com.fitlog.core.OAuthAuthCodes
import com.fitlog.core.OAuthClients
import com.fitlog.core.OAuthTokens
import com.fitlog.core.Times
import com.fitlog.core.UUIDSerializer
import com.fitlog.core.dbQuery
import com.fitlog.core.notFound
import com.fitlog.core.userId
import io.ktor.http.HttpStatusCode
import io.ktor.server.response.respond
import io.ktor.server.routing.Route
import io.ktor.server.routing.delete
import io.ktor.server.routing.get
import kotlinx.serialization.Serializable
import org.jetbrains.exposed.sql.SortOrder
import org.jetbrains.exposed.sql.SqlExpressionBuilder.eq
import org.jetbrains.exposed.sql.SqlExpressionBuilder.isNull
import org.jetbrains.exposed.sql.and
import org.jetbrains.exposed.sql.selectAll
import org.jetbrains.exposed.sql.update
import java.time.Instant
import java.util.UUID

/** openapi AiConnection */
@Serializable
data class AiConnection(
    @Serializable(with = UUIDSerializer::class) val id: UUID,
    val clientName: String,
    val scopes: List<String>,
    @Serializable(with = InstantSerializer::class) val createdAt: Instant,
    @Serializable(with = InstantSerializer::class) val lastUsedAt: Instant? = null,
)

@Serializable
data class McpClientInfo(val key: String, val name: String, val steps: List<String>, val docUrl: String? = null)

@Serializable
data class McpInfo(val mcpUrl: String, val clients: List<McpClientInfo>)

/** A3 소유 (v0.3). 등록 위치: /v1 아래, 인증 필요 */
fun Route.aiConnectionRoutes(config: AppConfig) {
    get("/me/ai-connections") {
        val uid = call.userId
        val list = dbQuery {
            AiConnections.join(OAuthClients, org.jetbrains.exposed.sql.JoinType.INNER, AiConnections.clientId, OAuthClients.id).selectAll()
                .where { (AiConnections.userId eq uid) and AiConnections.revokedAt.isNull() }
                .orderBy(AiConnections.createdAt, SortOrder.DESC)
                .map {
                    AiConnection(
                        id = it[AiConnections.id],
                        clientName = it[OAuthClients.clientName],
                        scopes = it[AiConnections.scopes],
                        createdAt = it[AiConnections.createdAt],
                        lastUsedAt = it[AiConnections.lastUsedAt],
                    )
                }
        }
        call.respond(list)
    }

    delete("/me/ai-connections/{id}") {
        val uid = call.userId
        val id = Ids.parse(call.parameters["id"])
        dbQuery {
            val row = AiConnections.selectAll().where { AiConnections.id eq id }.singleOrNull()
            if (row != null) {
                if (row[AiConnections.userId] != uid) notFound("connection not found")
                val now = Times.now()
                if (row[AiConnections.revokedAt] == null) {
                    AiConnections.update({ AiConnections.id eq id }) { it[revokedAt] = now }
                }
                OAuthTokens.update({ (OAuthTokens.connectionId eq id) and OAuthTokens.revokedAt.isNull() }) {
                    it[revokedAt] = now
                }
                // 아직 쓰지 않은 인가 코드도 못 쓰게 한다
                OAuthAuthCodes.update({ (OAuthAuthCodes.connectionId eq id) and OAuthAuthCodes.usedAt.isNull() }) {
                    it[usedAt] = now
                }
            }
        }
        call.respond(HttpStatusCode.NoContent)
    }

    get("/mcp-info") {
        call.respond(
            McpInfo(
                mcpUrl = config.publicBaseUrl + "/mcp",
                clients = listOf(
                    McpClientInfo(
                        "claude", "Claude",
                        listOf(
                            "Claude 설정의 커넥터(Connectors) 메뉴에서 '커스텀 커넥터 추가'를 고릅니다.",
                            "위 MCP 주소를 붙여넣고 추가합니다.",
                            "Google 로그인 화면이 열리면 fitlog 계정으로 로그인하고 접근을 허용합니다.",
                        ),
                    ),
                    McpClientInfo(
                        "chatgpt", "ChatGPT",
                        listOf(
                            "ChatGPT 설정에서 커넥터(앱) 메뉴를 열고 개발자 모드를 켭니다.",
                            "새 커넥터를 만들고 위 MCP 주소를 입력합니다. 인증은 OAuth 로 선택합니다.",
                            "Google 로그인 화면에서 fitlog 계정으로 로그인하고 접근을 허용합니다.",
                        ),
                    ),
                    McpClientInfo(
                        "gemini", "Gemini",
                        listOf(
                            "Gemini 에서 MCP 서버(원격 커넥터)를 추가하는 메뉴를 엽니다.",
                            "위 MCP 주소를 입력하고 추가합니다.",
                            "Google 로그인 화면에서 fitlog 계정으로 로그인하고 접근을 허용합니다.",
                        ),
                    ),
                ),
            ),
        )
    }
}
