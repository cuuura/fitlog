package com.fitlog

import com.fitlog.account.accountRoutes
import com.fitlog.auth.authRoutes
import com.fitlog.body.bodyRoutes
import com.fitlog.core.AppConfig
import com.fitlog.core.Database
import com.fitlog.core.installCore
import com.fitlog.exercise.exerciseRoutes
import com.fitlog.session.sessionRoutes
import com.fitlog.sync.syncRoutes
import io.ktor.server.application.Application
import io.ktor.server.auth.authenticate
import io.ktor.server.engine.embeddedServer
import io.ktor.server.netty.Netty
import io.ktor.server.response.respondText
import io.ktor.server.routing.get
import io.ktor.server.routing.route
import io.ktor.server.routing.routing

fun main() {
    val config = AppConfig.fromEnv()
    embeddedServer(Netty, port = config.port) { module(config) }.start(wait = true)
}

/**
 * 앱 조립. 각 WP는 자기 패키지의 `xxxRoutes(config)` 함수만 채운다.
 * - 인증이 필요 없는 경로: authRoutes (A1)
 * - 나머지는 authenticate(AUTH_BEARER) 안에 등록된다
 */
fun Application.module(config: AppConfig) {
    Database.init(config.db)
    installCore(config)
    routing {
        get("/health") { call.respondText("ok") }
        route("/v1") {
            authRoutes(config)
            authenticate(com.fitlog.core.AUTH_BEARER) {
                accountRoutes(config)
                exerciseRoutes(config)
                sessionRoutes(config)
                bodyRoutes(config)
                syncRoutes(config)
            }
        }
    }
}
