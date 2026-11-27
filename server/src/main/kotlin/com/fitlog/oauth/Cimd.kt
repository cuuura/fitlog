package com.fitlog.oauth

import com.fitlog.core.AppConfig
import com.fitlog.core.CimdFetchException
import com.fitlog.core.ClientMetadataFetcher
import com.fitlog.core.Ids
import com.fitlog.core.OAuthClients
import com.fitlog.core.Times
import com.fitlog.core.dbQuery
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.jetbrains.exposed.sql.SqlExpressionBuilder.eq
import org.jetbrains.exposed.sql.insertIgnore
import org.jetbrains.exposed.sql.update
import java.net.Inet4Address
import java.net.Inet6Address
import java.net.InetAddress
import java.net.URI
import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse
import java.time.Duration
import java.util.concurrent.ConcurrentHashMap

// OAuth Client ID Metadata Documents (draft-ietf-oauth-client-id-metadata-document)
// client_id 가 https URL 이면 그 URL 의 JSON 문서가 클라이언트 메타데이터다.

const val CIMD_MAX_BODY = 64 * 1024
const val CIMD_CACHE_TTL_SEC = 3600L
private const val CIMD_MAX_URL_LEN = 2048

/** CIMD 검증·가져오기 실패. [message] 는 사용자·클라이언트에게 보여도 되는 문구 */
class CimdException(message: String) : Exception(message)

/** client_id 가 CIMD 형식(https 스킴, 호스트, 경로 있음, fragment·userinfo 없음)인지 */
fun isCimdClientId(s: String?): Boolean {
    if (s.isNullOrEmpty() || s.length > CIMD_MAX_URL_LEN || s.contains('#')) return false
    val u = runCatching { URI(s) }.getOrNull() ?: return false
    return u.scheme == "https" && !u.host.isNullOrEmpty() && u.userInfo == null && u.fragment == null && !u.rawPath.isNullOrEmpty()
}

/** SSRF 방어: 공인 주소가 아니면(사설·루프백·링크로컬·CGNAT 등) false */
internal fun isPublicAddress(a: InetAddress): Boolean {
    if (a.isAnyLocalAddress || a.isLoopbackAddress || a.isLinkLocalAddress || a.isSiteLocalAddress || a.isMulticastAddress) return false
    val b = a.address
    when (a) {
        is Inet4Address -> {
            val b0 = b[0].toInt() and 0xff
            val b1 = b[1].toInt() and 0xff
            if (b0 == 0) return false // 0.0.0.0/8
            if (b0 == 100 && b1 in 64..127) return false // CGNAT 100.64/10
            if (b0 == 192 && b1 == 0 && (b[2].toInt() and 0xff) == 0) return false // 192.0.0.0/24
            if (b0 == 198 && (b1 == 18 || b1 == 19)) return false // 벤치마크 198.18/15
            if (b0 >= 240) return false // 예약·브로드캐스트
        }
        is Inet6Address -> {
            if ((b[0].toInt() and 0xfe) == 0xfc) return false // ULA fc00::/7
        }
    }
    return true
}

/** 호스트가 가리키는 모든 주소가 공인 주소여야 통과. 아니면 [CimdFetchException] */
internal fun checkCimdHost(host: String, resolve: (String) -> List<InetAddress> = { InetAddress.getAllByName(it).toList() }) {
    val addrs = try {
        resolve(host)
    } catch (e: Exception) {
        throw CimdFetchException("client metadata host could not be resolved")
    }
    if (addrs.isEmpty() || addrs.any { !isPublicAddress(it) }) {
        throw CimdFetchException("client metadata host resolves to a non-public address")
    }
}

/** 실제 CIMD 가져오기 (JDK HttpClient). 리다이렉트는 따르지 않는다 */
internal class HttpCimdFetcher(
    private val resolve: (String) -> List<InetAddress> = { InetAddress.getAllByName(it).toList() },
) : ClientMetadataFetcher {
    private val http = HttpClient.newBuilder()
        .connectTimeout(Duration.ofSeconds(5))
        .followRedirects(HttpClient.Redirect.NEVER)
        .build()

    override fun fetch(url: String): String {
        val uri = URI(url)
        if (uri.scheme != "https") throw CimdFetchException("client_id must be an https URL")
        checkCimdHost(uri.host, resolve)
        val req = HttpRequest.newBuilder(uri)
            .timeout(Duration.ofSeconds(5))
            .header("Accept", "application/json")
            .GET()
            .build()
        try {
            val res = http.send(req, HttpResponse.BodyHandlers.ofInputStream())
            res.body().use { body ->
                if (res.statusCode() != 200) throw CimdFetchException("client metadata fetch failed with HTTP ${res.statusCode()}")
                val bytes = body.readNBytes(CIMD_MAX_BODY + 1)
                if (bytes.size > CIMD_MAX_BODY) throw CimdFetchException("client metadata document exceeds $CIMD_MAX_BODY bytes")
                return String(bytes, Charsets.UTF_8)
            }
        } catch (e: CimdFetchException) {
            throw e
        } catch (e: Exception) {
            throw CimdFetchException("client metadata could not be fetched")
        }
    }
}

/** 확인된 클라이언트 메타데이터 */
class CimdClient(val clientId: String, val name: String, val redirectUris: List<String>)

/** CIMD 문서를 가져와 검증하고 oauth_client 행으로 upsert 한다. 문서는 1시간 메모리 캐시(캐시일 뿐, 재시작하면 다시 받는다) */
internal class CimdResolver(config: AppConfig, private val ttlSec: Long = CIMD_CACHE_TTL_SEC) {
    private val fetcher: ClientMetadataFetcher = config.cimdFetcher ?: HttpCimdFetcher()

    private class Entry(val client: CimdClient, val expiresAt: Long)

    private val cache = ConcurrentHashMap<String, Entry>()

    suspend fun resolve(clientId: String): CimdClient {
        val now = System.currentTimeMillis() / 1000
        cache[clientId]?.takeIf { it.expiresAt > now }?.let { return it.client }
        val body = try {
            withContext(Dispatchers.IO) { fetcher.fetch(clientId) }
        } catch (e: CimdFetchException) {
            throw CimdException(e.message ?: "client metadata could not be fetched")
        }
        val client = parse(clientId, body)
        upsert(client)
        if (cache.size > 1000) cache.clear() // 상한(악의적 client_id 폭주 대비)
        cache[clientId] = Entry(client, now + ttlSec)
        return client
    }

    private fun parse(clientId: String, body: String): CimdClient {
        val doc = try {
            Json.parseToJsonElement(body) as? JsonObject
        } catch (e: Exception) {
            null
        } ?: throw CimdException("client metadata document must be a JSON object")
        if ((doc["client_id"] as? JsonPrimitive)?.takeIf { it.isString }?.content != clientId) {
            throw CimdException("client_id in the metadata document does not match the URL")
        }
        val method = (doc["token_endpoint_auth_method"] as? JsonPrimitive)?.takeIf { it.isString }?.content
        if (doc["token_endpoint_auth_method"] != null && method != "none") {
            throw CimdException("unsupported token_endpoint_auth_method (only none is supported)")
        }
        val uris = (doc["redirect_uris"] as? JsonArray)?.map { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content }
        if (uris.isNullOrEmpty() || uris.size > 10 || uris.any { it == null || !validRedirectUri(it) }) {
            throw CimdException("redirect_uris must be 1..10 URIs: https, or http on localhost/127.0.0.1, without fragment")
        }
        val name = (doc["client_name"] as? JsonPrimitive)?.takeIf { it.isString }?.content?.trim()
            ?.takeIf { it.isNotEmpty() }?.take(100) ?: "AI 앱"
        // 이름은 문서가 마음대로 정하므로, 동의 화면에서 실제 도메인을 함께 보여 준다(사칭 방지)
        val host = URI(clientId).host
        return CimdClient(clientId, "$name ($host)", uris.filterNotNull().distinct())
    }

    private suspend fun upsert(c: CimdClient) = dbQuery {
        val updated = OAuthClients.update({ OAuthClients.clientId eq c.clientId }) {
            it[clientName] = c.name
            it[redirectUris] = c.redirectUris
        }
        if (updated == 0) {
            OAuthClients.insertIgnore {
                it[id] = Ids.newId()
                it[clientId] = c.clientId
                it[clientName] = c.name
                it[redirectUris] = c.redirectUris
                it[createdAt] = Times.now()
            }
            // 동시 요청이 먼저 넣었으면 insertIgnore 가 무시되므로 최신 문서 값으로 한 번 더 맞춘다
            OAuthClients.update({ OAuthClients.clientId eq c.clientId }) {
                it[clientName] = c.name
                it[redirectUris] = c.redirectUris
            }
        }
    }
}
