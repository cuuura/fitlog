package com.fitlog.security

import com.fitlog.core.AppConfig
import com.fitlog.core.ErrorBody
import com.fitlog.core.ErrorCode
import com.fitlog.core.ErrorResponse
import io.ktor.http.HttpStatusCode
import io.ktor.server.application.Application
import io.ktor.server.application.ApplicationCall
import io.ktor.server.application.install
import io.ktor.server.auth.jwt.JWTPrincipal
import io.ktor.server.auth.principal
import io.ktor.server.plugins.forwardedheaders.XForwardedHeaders
import io.ktor.server.plugins.origin
import io.ktor.server.plugins.ratelimit.RateLimit
import io.ktor.server.plugins.ratelimit.RateLimitName
import io.ktor.server.plugins.ratelimit.rateLimit
import io.ktor.server.request.header
import io.ktor.server.response.ApplicationSendPipeline
import io.ktor.server.application.call
import io.ktor.server.routing.Route
import java.security.MessageDigest
import kotlin.time.Duration.Companion.minutes

/** contracts/v1.0/security.md 호출 제한 범위 */
enum class Bucket { AUTH, API, EXPORT, MCP }

private fun Bucket.limitName() = RateLimitName(name.lowercase())

private fun clientIp(call: ApplicationCall): String = call.request.origin.remoteAddress

/** 인증된 요청은 JWT subject, 아니면 IP */
private fun userKey(call: ApplicationCall): String =
    call.principal<JWTPrincipal>()?.subject?.let { "u:$it" } ?: "ip:${clientIp(call)}"

/** Authorization 값의 SHA-256(토큰별 한도). 없으면 IP */
private fun mcpKey(call: ApplicationCall): String {
    val auth = call.request.header("Authorization") ?: return "ip:${clientIp(call)}"
    val digest = MessageDigest.getInstance("SHA-256").digest(auth.toByteArray(Charsets.UTF_8))
    return "t:" + digest.joinToString("") { "%02x".format(it) }
}

/** config.rateLimits.enabled 일 때 RateLimit 플러그인 설치(429 + Retry-After + RATE_LIMITED 본문) */
fun Application.installRateLimits(config: AppConfig) {
    val rl = config.rateLimits
    if (!rl.enabled) return

    if (config.trustProxy) install(XForwardedHeaders)

    install(RateLimit) {
        register(Bucket.AUTH.limitName()) {
            rateLimiter(limit = rl.authPerMinute, refillPeriod = 1.minutes)
            requestKey { call -> clientIp(call) }
        }
        register(Bucket.API.limitName()) {
            rateLimiter(limit = rl.apiPerMinute, refillPeriod = 1.minutes)
            requestKey { call -> userKey(call) }
        }
        register(Bucket.EXPORT.limitName()) {
            rateLimiter(limit = rl.exportPer10Minutes, refillPeriod = 10.minutes)
            requestKey { call -> userKey(call) }
        }
        register(Bucket.MCP.limitName()) {
            rateLimiter(limit = rl.mcpPerMinute, refillPeriod = 1.minutes)
            requestKey { call -> mcpKey(call) }
        }
    }

    // 플러그인은 상태 코드만 응답하므로(Retry-After 헤더는 이미 설정됨) 본문을 기존 에러 형식으로 바꾼다
    sendPipeline.intercept(ApplicationSendPipeline.Before) { subject ->
        if (subject is HttpStatusCode && subject == HttpStatusCode.TooManyRequests) {
            call.response.status(HttpStatusCode.TooManyRequests)
            proceedWith(ErrorResponse(ErrorBody(ErrorCode.RATE_LIMITED.name, "too many requests, retry later")))
        }
    }
}

/** 이 블록 안 경로에 bucket 한도를 건다. 꺼져 있으면 그대로 body 만 등록 */
fun Route.withRateLimit(config: AppConfig, bucket: Bucket, body: Route.() -> Unit) {
    if (!config.rateLimits.enabled) {
        body()
        return
    }
    rateLimit(bucket.limitName()) { body() }
}
