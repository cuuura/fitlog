package com.fitlog

import com.fitlog.account.accountRoutes
import com.fitlog.auth.authRoutes
import com.fitlog.aiconnection.aiConnectionRoutes
import com.fitlog.deletion.deletionRoutes
import com.fitlog.export.exportRoutes
import com.fitlog.importing.importRoutes
import com.fitlog.importing.publicSchemaRoutes
import com.fitlog.mcp.mcpRoutes
import com.fitlog.oauth.oauthRoutes
import com.fitlog.body.bodyRoutes
import com.fitlog.scheduled.scheduledRoutes
import com.fitlog.core.AppConfig
import com.fitlog.core.Database
import com.fitlog.core.installCore
import com.fitlog.exercise.exerciseRoutes
import com.fitlog.program.catalog.programRoutes
import com.fitlog.program.instance.instanceRoutes
import com.fitlog.records.recordsRoutes
import com.fitlog.session.sessionRoutes
import com.fitlog.sync.syncRoutes
import com.fitlog.ops.installOps
import com.fitlog.ops.installSelfPing
import com.fitlog.ops.opsRoutes
import com.fitlog.security.Bucket
import com.fitlog.security.installRateLimits
import com.fitlog.security.withRateLimit
import com.fitlog.stats.statsRoutes
import io.ktor.server.application.Application
import io.ktor.server.application.ApplicationStopped
import io.ktor.server.auth.authenticate
import io.ktor.server.engine.applicationEnvironment
import io.ktor.server.engine.connector
import io.ktor.server.engine.embeddedServer
import io.ktor.server.netty.Netty
import io.ktor.server.response.respondText
import io.ktor.server.routing.get
import io.ktor.server.routing.route
import io.ktor.server.routing.routing

fun main() {
    val config = AppConfig.fromEnv()
    // 종료 신호(SIGTERM) 시 진행 중 요청을 최대 10초 기다리고, 30초 안에 강제 종료. 끝나면 DB 풀을 닫는다
    embeddedServer(Netty, environment = applicationEnvironment { }, configure = {
        connector {
            host = config.host
            port = config.port
        }
        shutdownGracePeriod = 10_000
        shutdownTimeout = 30_000
    }) {
        module(config)
        monitor.subscribe(ApplicationStopped) { com.fitlog.core.Database.close() }
    }.start(wait = true)
}

/**
 * 앱 조립. 각 WP는 자기 패키지의 `xxxRoutes(config)` 함수만 채운다.
 * - 인증이 필요 없는 경로: authRoutes (A1)
 * - 나머지는 authenticate(AUTH_BEARER) 안에 등록된다
 */
fun Application.module(config: AppConfig) {
    Database.init(config.db)
    installCore(config)
    // v1.0
    installOps(config)
    installSelfPing(config)
    installRateLimits(config)
    routing {
        get("/health") { call.respondText("ok") }
        opsRoutes(config)
        // v0.3 원격 MCP·OAuth (자체 인증)
        withRateLimit(config, Bucket.AUTH) { oauthRoutes(config) }
        withRateLimit(config, Bucket.MCP) { mcpRoutes(config) }
        route("/v1") {
            withRateLimit(config, Bucket.AUTH) { authRoutes(config) }
            publicSchemaRoutes(config)
            authenticate(com.fitlog.core.AUTH_BEARER) {
                withRateLimit(config, Bucket.API) {
                    accountRoutes(config)
                    exerciseRoutes(config)
                    sessionRoutes(config)
                    bodyRoutes(config)
                    scheduledRoutes(config)
                    syncRoutes(config)
                    // v0.2
                    programRoutes(config)
                    instanceRoutes(config)
                    recordsRoutes(config)
                    // v0.3
                    importRoutes(config)
                    withRateLimit(config, Bucket.EXPORT) { exportRoutes(config) }
                    deletionRoutes(config)
                    aiConnectionRoutes(config)
                    // v1.0
                    statsRoutes(config)
                }
            }
        }
    }
}
