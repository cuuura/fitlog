package com.fitlog.ops

import com.fitlog.core.AppConfig
import com.fitlog.core.ErrorBody
import com.fitlog.core.ErrorResponse
import com.fitlog.core.dbQuery
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpMethod
import io.ktor.http.HttpStatusCode
import io.ktor.http.withCharset
import io.ktor.server.application.Application
import io.ktor.server.application.ApplicationCall
import io.ktor.server.application.createApplicationPlugin
import io.ktor.server.application.install
import com.fitlog.mcp.mcpTraceBuffer
import io.ktor.server.application.hooks.ResponseSent
import io.ktor.server.request.httpMethod
import io.ktor.server.request.path
import io.ktor.server.plugins.callid.CallId
import io.ktor.server.plugins.callid.callIdMdc
import io.ktor.server.plugins.calllogging.CallLogging
import io.ktor.server.request.contentLength
import io.ktor.server.request.header
import io.ktor.server.response.header
import io.ktor.server.response.respond
import io.ktor.server.response.respondText
import io.ktor.server.routing.Route
import io.ktor.server.routing.get
import org.slf4j.LoggerFactory
import java.util.UUID

private val log = LoggerFactory.getLogger("com.fitlog.ops")

/** 요청 ID 로 받아들일 형식: 영숫자·._- 1~64자 */
private val SANE_REQUEST_ID = Regex("^[A-Za-z0-9._-]{1,64}$")

/** A3 소유. 루트(인증 없음): GET /health/ready, /privacy, /account-deletion */
fun Route.opsRoutes(config: AppConfig) {
    // 배포 버전: 이미지 빌드 커밋(FITLOG_VERSION). 배포가 최신 main 인지 확인하는 용도, 비밀 아님
    get("/health/version") {
        call.response.header(HttpHeaders.CacheControl, "no-store")
        call.respondText(System.getenv("FITLOG_VERSION")?.ifBlank { null } ?: "dev")
    }
    // 준비 상태: DB 에 SELECT 1 이 되면 200, 아니면 503 (업타임 모니터·컨테이너 HEALTHCHECK 용)
    get("/health/ready") {
        call.response.header(HttpHeaders.CacheControl, "no-store")
        val ok = try {
            dbQuery { exec("SELECT 1") { it.next() } } == true
        } catch (e: Exception) {
            log.warn("readiness check failed: {}", e.message)
            false
        }
        if (ok) call.respondText("ok") else call.respondText("unavailable", status = HttpStatusCode.ServiceUnavailable)
    }

    // 공개 페이지는 처음 요청 때 한 번만 만든다
    val privacyHtml by lazy { SitePages.privacy(config) }
    val deletionHtml by lazy { SitePages.accountDeletion(config) }
    get("/privacy") { call.respondPage(privacyHtml) }
    get("/account-deletion") { call.respondPage(deletionHtml) }
}

private suspend fun ApplicationCall.respondPage(html: String) {
    response.header("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'")
    response.header("X-Content-Type-Options", "nosniff")
    response.header("Referrer-Policy", "no-referrer")
    response.header(HttpHeaders.CacheControl, "public, max-age=3600")
    respondText(html, ContentType.Text.Html.withCharset(Charsets.UTF_8))
}

private class BodyLimitConfig { var maxBytes: Long = 5L * 1024 * 1024 }

/** Content-Length 가 한도를 넘으면 본문을 읽기 전에 413 으로 거절한다 */
private val BodyLimit = createApplicationPlugin("BodyLimit", ::BodyLimitConfig) {
    val max = pluginConfig.maxBytes
    onCall { call ->
        val len = call.request.contentLength()
        if (len != null && len > max) {
            call.respond(
                HttpStatusCode.PayloadTooLarge,
                ErrorResponse(ErrorBody("VALIDATION_FAILED", "request body too large")),
            )
        }
    }
}

/** 브라우저 기반 MCP 클라이언트(Inspector 등)가 직접 호출하는 경로. 쿠키를 쓰지 않는 Bearer 방식이라 와일드카드 허용 */
internal fun isCrossOriginPath(path: String): Boolean =
    path == "/mcp" || path.startsWith("/mcp/") || path.startsWith("/.well-known/") ||
        path == "/oauth/token" || path == "/oauth/register"

/** /mcp·메타데이터·토큰·등록 엔드포인트에 CORS 헤더를 붙이고 OPTIONS 사전 요청에 204 로 답한다 */
private val McpCors = createApplicationPlugin("McpCors") {
    onCall { call ->
        if (!isCrossOriginPath(call.request.local.uri.substringBefore('?'))) return@onCall
        call.response.header("Access-Control-Allow-Origin", "*")
        call.response.header("Access-Control-Expose-Headers", "Mcp-Session-Id, WWW-Authenticate")
        if (call.request.local.method == HttpMethod.Options) {
            call.response.header("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")
            call.response.header(
                "Access-Control-Allow-Headers",
                call.request.header("Access-Control-Request-Headers") ?: "Authorization, Content-Type, Accept, Mcp-Session-Id, MCP-Protocol-Version",
            )
            call.response.header("Access-Control-Max-Age", "86400")
            call.respond(HttpStatusCode.NoContent)
        }
    }
}

/**
 * OAuth·디스커버리 요청 추적(/health/mcp-trace 에 /mcp 요청과 함께 보인다). ChatGPT 등이 연결 과정 어디서 멈추는지 보려는 용도.
 * 비밀 값(code, code_verifier, client_secret, token, state, 비밀번호)은 남기지 않는다
 */
private val OAuthTrace = createApplicationPlugin("OAuthTrace") {
    on(ResponseSent) { call ->
        val p = call.request.path()
        if (!(p.startsWith("/oauth/") || p.startsWith("/.well-known/") || p.startsWith("/mcp/"))) return@on
        val tr = com.fitlog.mcp.McpTraceRow(call.request.httpMethod.value)
        tr.path = p
        tr.status = call.response.status()?.value
        tr.userAgent = com.fitlog.mcp.truncateUa(call.request.header(HttpHeaders.UserAgent))
        tr.accept = com.fitlog.mcp.truncateUa(call.request.header(HttpHeaders.Accept))
        tr.authPresent = call.request.header(HttpHeaders.Authorization) != null
        val q = call.request.queryParameters
        val parts = mutableListOf<String>()
        if (!q.isEmpty()) parts += "params=" + q.names().sorted().joinToString(",")
        q["redirect_uri"]?.let { parts += "redirect_host=" + runCatching { java.net.URI(it).host }.getOrNull() }
        q["scope"]?.let { parts += "scope=" + it.take(80) }
        q["resource"]?.let { parts += "resource=" + it.take(120) }
        q["client_id"]?.takeIf { com.fitlog.oauth.isCimdClientId(it) }?.let {
            parts += "cimd=1"
            parts += "cimd_host=" + runCatching { java.net.URI(it).host }.getOrNull()
        }
        q["client_id"]?.takeIf { com.fitlog.oauth.isCimdClientId(it) }?.let {
            parts += "cimd=1"
            parts += "cimd_host=" + runCatching { java.net.URI(it).host }.getOrNull()
        }
        q["code_challenge_method"]?.let { parts += "ccm=$it" }
        q["response_type"]?.let { parts += "rt=$it" }
        q["error"]?.let { parts += "error=" + it.take(60) }
        call.request.header(HttpHeaders.ContentType)?.let { parts += "ct=" + it.take(60) }
        if (parts.isNotEmpty()) tr.detail = parts.joinToString(" ")
        call.application.mcpTraceBuffer().add(tr)
    }
}

/** A3 소유. CallId(X-Request-Id)·로그, 본문 크기 제한. DB 풀 종료는 main() 의 ApplicationStopped 에서 한다 */
fun Application.installOps(config: AppConfig) {
    install(CallId) {
        // 들어온 X-Request-Id 가 안전한 형식이면 그대로 쓰고, 아니면 새로 만든다
        retrieveFromHeader("X-Request-Id")
        verify { SANE_REQUEST_ID.matches(it) }
        generate { UUID.randomUUID().toString() }
        replyToHeader("X-Request-Id")
    }
    install(CallLogging) {
        callIdMdc("requestId")
        // 헬스 체크는 로그에서 뺀다(주기 호출이라 잡음)
        filter { call -> !call.request.local.uri.startsWith("/health") }
    }
    install(McpCors)
    if (config.mcpTraceEnabled) install(OAuthTrace)
    install(BodyLimit) { maxBytes = config.maxBodyBytes }
}
