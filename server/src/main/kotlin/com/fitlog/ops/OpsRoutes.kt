package com.fitlog.ops

import com.fitlog.core.AppConfig
import io.ktor.server.application.Application
import io.ktor.server.routing.Route

/** A3 소유. 루트(인증 없음): GET /health/ready, /privacy, /account-deletion */
fun Route.opsRoutes(config: AppConfig) {
    // A3 구현
}

/** A3 소유. CallId(X-Request-Id)·로그, 본문 크기 제한, 공개 페이지 보안 헤더, 종료 정리 */
fun Application.installOps(config: AppConfig) {
    // A3 구현
}
