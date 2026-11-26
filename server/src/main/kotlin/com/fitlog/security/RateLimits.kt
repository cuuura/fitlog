package com.fitlog.security

import com.fitlog.core.AppConfig
import io.ktor.server.application.Application
import io.ktor.server.routing.Route

/** contracts/v1.0/security.md 호출 제한 범위 */
enum class Bucket { AUTH, API, EXPORT, MCP }

/** A2 소유. config.rateLimits.enabled 일 때 RateLimit 플러그인 설치(429 + Retry-After + RATE_LIMITED 본문) */
fun Application.installRateLimits(config: AppConfig) {
    // A2 구현
}

/** A2 소유. 이 블록 안 경로에 bucket 한도를 건다. 꺼져 있으면 그대로 body 만 등록 */
fun Route.withRateLimit(config: AppConfig, bucket: Bucket, body: Route.() -> Unit) {
    body()
}
