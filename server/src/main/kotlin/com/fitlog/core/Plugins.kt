package com.fitlog.core

import io.ktor.http.HttpStatusCode
import io.ktor.serialization.kotlinx.json.json
import io.ktor.server.application.Application
import io.ktor.server.application.install
import io.ktor.server.auth.authentication
import io.ktor.server.auth.jwt.JWTPrincipal
import io.ktor.server.auth.jwt.jwt
import io.ktor.server.plugins.BadRequestException
import io.ktor.server.plugins.contentnegotiation.ContentNegotiation
import io.ktor.server.plugins.statuspages.StatusPages
import io.ktor.server.response.respond
import kotlinx.serialization.SerializationException
import org.slf4j.LoggerFactory

private val log = LoggerFactory.getLogger("com.fitlog.Errors")

fun Application.installCore(config: AppConfig) {
    install(ContentNegotiation) { json(AppJson) }

    val tokens = AccessTokens(config.jwt)
    authentication {
        jwt(AUTH_BEARER) {
            verifier(tokens.verifier)
            validate { cred -> cred.payload.subject?.let { JWTPrincipal(cred.payload) } }
            challenge { _, _ ->
                call.respond(
                    HttpStatusCode.Unauthorized,
                    ErrorResponse(ErrorBody(ErrorCode.UNAUTHENTICATED.name, "missing or invalid access token")),
                )
            }
        }
    }

    install(StatusPages) {
        exception<ApiException> { call, e ->
            call.respond(e.code.status, ErrorResponse(ErrorBody(e.code.name, e.message, e.field, e.details)))
        }
        exception<BadRequestException> { call, e ->
            val root = generateSequence<Throwable>(e) { it.cause }.firstOrNull { it is ApiException } as ApiException?
            if (root != null) {
                call.respond(root.code.status, ErrorResponse(ErrorBody(root.code.name, root.message, root.field, root.details)))
            } else {
                val msg = generateSequence<Throwable>(e) { it.cause }
                    .firstOrNull { it is SerializationException }?.message ?: (e.message ?: "bad request")
                call.respond(HttpStatusCode.BadRequest, ErrorResponse(ErrorBody(ErrorCode.VALIDATION_FAILED.name, msg)))
            }
        }
        exception<Throwable> { call, e ->
            log.error("unhandled", e)
            call.respond(HttpStatusCode.InternalServerError, ErrorResponse(ErrorBody("INTERNAL", "internal error")))
        }
    }
}
