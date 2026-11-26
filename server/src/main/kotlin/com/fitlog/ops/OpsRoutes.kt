package com.fitlog.ops

import com.fitlog.core.AppConfig
import com.fitlog.core.ErrorBody
import com.fitlog.core.ErrorResponse
import com.fitlog.core.dbQuery
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.withCharset
import io.ktor.server.application.Application
import io.ktor.server.application.ApplicationCall
import io.ktor.server.application.createApplicationPlugin
import io.ktor.server.application.install
import io.ktor.server.plugins.callid.CallId
import io.ktor.server.plugins.callid.callIdMdc
import io.ktor.server.plugins.calllogging.CallLogging
import io.ktor.server.request.contentLength
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
    install(BodyLimit) { maxBytes = config.maxBodyBytes }
}
