package com.fitlog.core

import com.auth0.jwt.JWT
import com.auth0.jwt.algorithms.Algorithm
import io.ktor.server.application.ApplicationCall
import io.ktor.server.auth.jwt.JWTPrincipal
import io.ktor.server.auth.principal
import java.util.Date
import java.util.UUID

const val AUTH_BEARER = "bearer"

/** 액세스 토큰(JWT) 발급·검증. 리프레시 토큰·Google 검증은 auth 패키지(A1) 책임 */
class AccessTokens(private val cfg: JwtConfig) {
    val algorithm: Algorithm = Algorithm.HMAC256(cfg.secret)
    val verifier = JWT.require(algorithm).withIssuer(cfg.issuer).withAudience(cfg.audience).build()

    fun issue(userId: UUID, now: Long = System.currentTimeMillis()): String =
        JWT.create()
            .withIssuer(cfg.issuer)
            .withAudience(cfg.audience)
            .withSubject(userId.toString())
            .withIssuedAt(Date(now))
            .withExpiresAt(Date(now + cfg.accessTtlSec * 1000))
            .sign(algorithm)

    val ttlSec: Long get() = cfg.accessTtlSec
}

/** 인증된 요청의 사용자 ID */
val ApplicationCall.userId: UUID
    get() = principal<JWTPrincipal>()?.subject?.let(UUID::fromString) ?: unauthenticated()
