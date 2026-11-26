package com.fitlog.security

import com.fitlog.core.ApiException
import com.fitlog.core.AppConfig
import com.fitlog.core.ErrorCode
import com.fitlog.core.IntegrityConfig
import com.fitlog.core.IntegrityMode
import com.google.auth.oauth2.GoogleCredentials
import io.ktor.server.application.ApplicationCall
import io.ktor.server.request.header
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import org.slf4j.LoggerFactory
import java.io.FileInputStream
import java.net.URI
import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse
import java.security.MessageDigest
import java.time.Duration
import java.util.Base64
import java.util.concurrent.ConcurrentHashMap
import kotlin.math.abs

private val log = LoggerFactory.getLogger("com.fitlog.Integrity")

const val INTEGRITY_HEADER = "X-Integrity-Token"
private const val VERIFY_TIMEOUT_MS = 3000L

/** decodeIntegrityToken 결과 중 판정에 쓰는 값 */
data class IntegrityVerdict(
    val requestHash: String?,
    val requestPackageName: String?,
    val timestampMillis: Long?,
    val appRecognitionVerdict: String?,
    val packageName: String?,
    val deviceRecognitionVerdict: List<String>,
)

/** 실제 구현은 Google decodeIntegrityToken. 호출 자체 실패(네트워크·5xx)는 예외 */
fun interface IntegrityVerifier {
    suspend fun decode(token: String): IntegrityVerdict
}

/** decodeIntegrityToken 응답 JSON(tokenPayloadExternal)을 판정 값으로 바꾼다 */
fun parseIntegrityResponse(body: String): IntegrityVerdict {
    val payload = Json.parseToJsonElement(body).jsonObject["tokenPayloadExternal"]?.jsonObject
        ?: error("tokenPayloadExternal missing")
    fun obj(name: String): JsonObject? = payload[name] as? JsonObject
    fun JsonObject.str(name: String): String? = (this[name] as? JsonPrimitive)?.contentOrNull
    val details = obj("requestDetails")
    val app = obj("appIntegrity")
    val device = obj("deviceIntegrity")
    return IntegrityVerdict(
        requestHash = details?.str("requestHash"),
        requestPackageName = details?.str("requestPackageName"),
        // int64 는 문자열로 온다
        timestampMillis = (details?.get("timestampMillis") as? JsonPrimitive)?.let { it.longOrNull },
        appRecognitionVerdict = app?.str("appRecognitionVerdict"),
        packageName = app?.str("packageName"),
        deviceRecognitionVerdict = (device?.get("deviceRecognitionVerdict") as? JsonArray)
            ?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull } ?: emptyList(),
    )
}

/** 서비스 계정으로 Google Play Integrity API 를 호출하는 실제 검증기 */
class GoogleIntegrityVerifier(private val cfg: IntegrityConfig) : IntegrityVerifier {
    private val http = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(2)).build()
    private val credentials: GoogleCredentials by lazy {
        val path = cfg.credentialsPath ?: error("PLAY_INTEGRITY_CREDENTIALS not configured")
        FileInputStream(path).use { GoogleCredentials.fromStream(it) }
            .createScoped("https://www.googleapis.com/auth/playintegrity")
    }

    override suspend fun decode(token: String): IntegrityVerdict = withContext(Dispatchers.IO) {
        val pkg = cfg.packageNames.first()
        val creds = credentials
        creds.refreshIfExpired()
        val bearer = creds.accessToken.tokenValue
        val reqBody = JsonObject(mapOf("integrity_token" to JsonPrimitive(token))).toString()
        val req = HttpRequest.newBuilder(URI.create("https://playintegrity.googleapis.com/v1/$pkg:decodeIntegrityToken"))
            .timeout(Duration.ofSeconds(3))
            .header("Authorization", "Bearer $bearer")
            .header("Content-Type", "application/json")
            .POST(HttpRequest.BodyPublishers.ofString(reqBody))
            .build()
        val res = http.send(req, HttpResponse.BodyHandlers.ofString())
        // 400 = 토큰 자체가 잘못됨(위조·손상) → 판정 실패. 그 밖의 오류(인증 설정·5xx)는 호출 실패로 보고 fail-open
        if (res.statusCode() == 400) throw InvalidIntegrityTokenException("decodeIntegrityToken HTTP 400")
        check(res.statusCode() == 200) { "decodeIntegrityToken HTTP ${res.statusCode()}" }
        parseIntegrityResponse(res.body())
    }
}

/** 검증기가 토큰 자체를 거부했을 때(Google 400). fail-open 대상이 아니다 */
class InvalidIntegrityTokenException(message: String) : RuntimeException(message)

private val realVerifiers = ConcurrentHashMap<IntegrityConfig, IntegrityVerifier>()

/** 본문 토큰의 SHA-256 을 base64url(패딩 없음)로 인코딩한 값 */
fun expectedRequestHash(bodyToken: String): String =
    Base64.getUrlEncoder().withoutPadding()
        .encodeToString(MessageDigest.getInstance("SHA-256").digest(bodyToken.toByteArray(Charsets.UTF_8)))

/** 판정이 나쁘면 사유, 좋으면 null */
fun evaluateIntegrity(v: IntegrityVerdict, bodyToken: String, cfg: IntegrityConfig, nowMs: Long): String? = when {
    v.requestHash != expectedRequestHash(bodyToken) -> "request hash mismatch"
    v.requestPackageName !in cfg.packageNames -> "request package not allowed"
    v.packageName !in cfg.packageNames -> "app package not allowed"
    v.appRecognitionVerdict != "PLAY_RECOGNIZED" -> "app not recognized"
    "MEETS_DEVICE_INTEGRITY" !in v.deviceRecognitionVerdict -> "device integrity not met"
    v.timestampMillis == null || abs(nowMs - v.timestampMillis) > cfg.maxAgeSec * 1000 -> "token too old"
    else -> null
}

/**
 * /v1/auth/google·/v1/auth/refresh 에서 본문 토큰 값(idToken·refreshToken)을 넘겨 호출한다.
 * 모드 off: 무시, report: 검증·로그만, enforce: 실패 시 ApiException(INTEGRITY_FAILED).
 * Google 호출 자체가 실패하면(네트워크·5xx·3초 초과) 막지 않고 경고만 남긴다(fail-open)
 */
suspend fun checkIntegrity(call: ApplicationCall, config: AppConfig, bodyToken: String) {
    val cfg = config.integrity
    if (cfg.mode == IntegrityMode.OFF) return
    val enforce = cfg.mode == IntegrityMode.ENFORCE
    val path = call.request.local.uri

    fun fail(reason: String) {
        log.warn("integrity check failed ({}) path={} mode={}", reason, path, cfg.mode)
        if (enforce) throw ApiException(ErrorCode.INTEGRITY_FAILED, "integrity check failed")
    }

    val header = call.request.header(INTEGRITY_HEADER)
    if (header.isNullOrBlank()) return fail("missing header")

    val verifier = config.integrityVerifierOverride ?: realVerifiers.getOrPut(cfg) { GoogleIntegrityVerifier(cfg) }
    val verdict = try {
        withTimeout(VERIFY_TIMEOUT_MS) { verifier.decode(header) }
    } catch (e: InvalidIntegrityTokenException) {
        return fail("invalid token")
    } catch (e: TimeoutCancellationException) {
        log.warn("integrity verifier timed out; allowing (fail-open) path={}", path)
        return
    } catch (e: kotlinx.coroutines.CancellationException) {
        throw e
    } catch (e: Exception) {
        log.warn("integrity verifier unavailable; allowing (fail-open) path={}: {}", path, e.toString())
        return
    }
    val reason = evaluateIntegrity(verdict, bodyToken, cfg, System.currentTimeMillis())
    if (reason != null) fail(reason) else log.info("integrity ok path={}", path)
}
