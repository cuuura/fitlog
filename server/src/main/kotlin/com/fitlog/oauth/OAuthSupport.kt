package com.fitlog.oauth

import com.fitlog.auth.RefreshTokenService
import com.fitlog.core.AiConnections
import com.fitlog.core.AppConfig
import com.fitlog.core.GoogleCodeExchanger
import com.fitlog.core.Ids
import com.fitlog.core.OAuthClients
import com.fitlog.core.OAuthTokens
import com.fitlog.core.Times
import com.fitlog.core.dbQuery
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import org.jetbrains.exposed.sql.JoinType
import org.jetbrains.exposed.sql.SqlExpressionBuilder.eq
import org.jetbrains.exposed.sql.SqlExpressionBuilder.isNull
import org.jetbrains.exposed.sql.Transaction
import org.jetbrains.exposed.sql.and
import org.jetbrains.exposed.sql.insert
import org.jetbrains.exposed.sql.selectAll
import org.jetbrains.exposed.sql.update
import java.net.URI
import java.net.URLEncoder
import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse
import java.security.MessageDigest
import java.time.Duration
import java.time.Instant
import java.util.Base64
import java.util.UUID
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

const val SCOPE_READ = "fitlog.read"
const val SCOPE_WRITE = "fitlog.write"
val SUPPORTED_SCOPES = listOf(SCOPE_READ, SCOPE_WRITE)

const val ACCESS_TTL_SEC = 3600L
const val REFRESH_TTL_SEC = 30L * 24 * 3600
const val AUTH_CODE_TTL_SEC = 600L

internal fun AppConfig.mcpUrl() = "$publicBaseUrl/mcp"

internal fun urlEnc(s: String): String = URLEncoder.encode(s, Charsets.UTF_8)

/** 쿼리 파라미터를 덧붙인 URL (null 값은 뺀다) */
internal fun appendQuery(url: String, params: Map<String, String?>): String {
    val q = params.filterValues { it != null }.entries.joinToString("&") { "${urlEnc(it.key)}=${urlEnc(it.value!!)}" }
    if (q.isEmpty()) return url
    return url + (if (url.contains('?')) "&" else "?") + q
}

/** HMAC-SHA256 으로 서명한 단기 JSON 값 (인가 요청 상태, 동의 폼 CSRF 값) */
internal object Signer {
    private val b64 = Base64.getUrlEncoder().withoutPadding()
    private val unb64 = Base64.getUrlDecoder()

    private fun mac(secret: String, data: ByteArray): ByteArray =
        Mac.getInstance("HmacSHA256").run {
            init(SecretKeySpec(secret.toByteArray(), "HmacSHA256"))
            doFinal(data)
        }

    fun sign(secret: String, typ: String, payload: Map<String, String>, ttlSec: Long): String {
        val obj = JsonObject(
            payload.mapValues { JsonPrimitive(it.value) } +
                mapOf("typ" to JsonPrimitive(typ), "exp" to JsonPrimitive(Instant.now().epochSecond + ttlSec)),
        )
        val body = b64.encodeToString(obj.toString().toByteArray())
        return body + "." + b64.encodeToString(mac(secret, body.toByteArray()))
    }

    /** 서명·종류·만료가 맞으면 값 맵, 아니면 null */
    fun verify(secret: String, typ: String, token: String?): Map<String, String>? {
        if (token == null) return null
        val parts = token.split('.')
        if (parts.size != 2) return null
        val expected = mac(secret, parts[0].toByteArray())
        val given = runCatching { unb64.decode(parts[1]) }.getOrNull() ?: return null
        if (!MessageDigest.isEqual(expected, given)) return null
        val obj = runCatching { Json.parseToJsonElement(String(unb64.decode(parts[0]))).jsonObject }.getOrNull() ?: return null
        if (obj["typ"]?.jsonPrimitive?.contentOrNull != typ) return null
        val exp = obj["exp"]?.jsonPrimitive?.longOrNull ?: return null
        if (exp < Instant.now().epochSecond) return null
        return obj.mapValues { it.value.jsonPrimitive.content }
    }
}

internal fun sha256Hex(s: String): String = RefreshTokenService.hash(s)

internal fun pkceChallenge(verifier: String): String =
    Base64.getUrlEncoder().withoutPadding().encodeToString(MessageDigest.getInstance("SHA-256").digest(verifier.toByteArray()))

internal fun constantTimeEquals(a: String, b: String): Boolean =
    MessageDigest.isEqual(a.toByteArray(), b.toByteArray())

internal fun newSecret(prefix: String): String = prefix + RefreshTokenService.newOpaque()

class TokenPair(val access: String, val refresh: String)

/** 한 계열(family)의 액세스·리프레시 토큰 한 쌍을 만든다 */
internal fun Transaction.issueTokenPair(connectionId: UUID, familyId: UUID): TokenPair {
    val now = Times.now()
    val access = newSecret("fla_")
    val refresh = newSecret("flr_")
    OAuthTokens.insert {
        it[id] = Ids.newId()
        it[OAuthTokens.connectionId] = connectionId
        it[kind] = "ACCESS"
        it[tokenHash] = sha256Hex(access)
        it[OAuthTokens.familyId] = familyId
        it[expiresAt] = now.plusSeconds(ACCESS_TTL_SEC)
        it[createdAt] = now
    }
    OAuthTokens.insert {
        it[id] = Ids.newId()
        it[OAuthTokens.connectionId] = connectionId
        it[kind] = "REFRESH"
        it[tokenHash] = sha256Hex(refresh)
        it[OAuthTokens.familyId] = familyId
        it[expiresAt] = now.plusSeconds(REFRESH_TTL_SEC)
        it[createdAt] = now
    }
    return TokenPair(access, refresh)
}

/** 이 연결의 살아 있는 토큰을 모두 폐기 */
internal fun Transaction.revokeConnectionTokens(connectionId: UUID) {
    OAuthTokens.update({ (OAuthTokens.connectionId eq connectionId) and OAuthTokens.revokedAt.isNull() }) {
        it[revokedAt] = Times.now()
    }
}

/** MCP 요청을 보낸 연결 */
data class McpPrincipal(
    val tokenId: UUID,
    val connectionId: UUID,
    val userId: UUID,
    val clientName: String,
    val scopes: Set<String>,
)

object OAuthTokenService {
    /** 불투명 액세스 토큰 → 주체. 없음·만료·폐기·연결 폐기면 null. 성공하면 last_used_at 을 갱신한다 */
    suspend fun authenticate(raw: String): McpPrincipal? = dbQuery {
        val now = Times.now()
        val row = OAuthTokens
            .join(AiConnections, JoinType.INNER, OAuthTokens.connectionId, AiConnections.id)
            .join(OAuthClients, JoinType.INNER, AiConnections.clientId, OAuthClients.id)
            .selectAll()
            .where { (OAuthTokens.tokenHash eq sha256Hex(raw)) and (OAuthTokens.kind eq "ACCESS") }
            .singleOrNull() ?: return@dbQuery null
        if (row[OAuthTokens.revokedAt] != null || !row[OAuthTokens.expiresAt].isAfter(now)) return@dbQuery null
        if (row[AiConnections.revokedAt] != null) return@dbQuery null
        AiConnections.update({ AiConnections.id eq row[AiConnections.id] }) { it[lastUsedAt] = now }
        McpPrincipal(
            tokenId = row[OAuthTokens.id],
            connectionId = row[AiConnections.id],
            userId = row[AiConnections.userId],
            clientName = row[OAuthClients.clientName],
            scopes = row[AiConnections.scopes].toSet(),
        )
    }
}

/** 실제 Google 토큰 엔드포인트 호출 (JDK HttpClient). 실패하면 null */
internal class GoogleCodeExchangerImpl(private val clientId: String, private val clientSecret: String) : GoogleCodeExchanger {
    private val http = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(10)).build()

    override fun exchange(code: String, redirectUri: String): String? = try {
        val form = mapOf(
            "code" to code,
            "client_id" to clientId,
            "client_secret" to clientSecret,
            "redirect_uri" to redirectUri,
            "grant_type" to "authorization_code",
        ).entries.joinToString("&") { "${urlEnc(it.key)}=${urlEnc(it.value)}" }
        val req = HttpRequest.newBuilder(URI.create("https://oauth2.googleapis.com/token"))
            .timeout(Duration.ofSeconds(15))
            .header("Content-Type", "application/x-www-form-urlencoded")
            .POST(HttpRequest.BodyPublishers.ofString(form))
            .build()
        val res = http.send(req, HttpResponse.BodyHandlers.ofString())
        if (res.statusCode() != 200) null
        else Json.parseToJsonElement(res.body()).jsonObject["id_token"]?.jsonPrimitive?.contentOrNull
    } catch (e: Exception) {
        null
    }
}
