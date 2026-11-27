package com.fitlog.core

import io.ktor.http.HttpStatusCode
import io.ktor.serialization.kotlinx.json.json
import io.ktor.server.application.Application
import io.ktor.server.application.install
import io.ktor.server.auth.authentication
import io.ktor.server.auth.jwt.JWTPrincipal
import io.ktor.server.auth.jwt.jwt
import io.ktor.server.plugins.BadRequestException
import io.ktor.server.plugins.UnsupportedMediaTypeException
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
        // Content-Type 이 맞지 않는 본문(예: text/plain 으로 JSON 전송)은 서버 오류가 아니라 클라이언트 오류다
        exception<UnsupportedMediaTypeException> { call, _ ->
            call.respond(
                HttpStatusCode.UnsupportedMediaType,
                ErrorResponse(ErrorBody(ErrorCode.VALIDATION_FAILED.name, "unsupported content type")),
            )
        }
        // ContentNegotiation 이 예외 없이 상태만 보내는 415 도 같은 형식으로
        status(HttpStatusCode.UnsupportedMediaType) { call, _ ->
            call.respond(
                HttpStatusCode.UnsupportedMediaType,
                ErrorResponse(ErrorBody(ErrorCode.VALIDATION_FAILED.name, "unsupported content type")),
            )
        }
        // 없는 경로도 계약의 에러 JSON 으로 답한다(본문 없이 상태만 보낸 404 에만 적용)
        status(HttpStatusCode.NotFound) { call, _ ->
            call.respond(HttpStatusCode.NotFound, ErrorResponse(ErrorBody(ErrorCode.NOT_FOUND.name, "not found")))
        }
        exception<Throwable> { call, e ->
            log.error("unhandled", e)
            call.respond(HttpStatusCode.InternalServerError, ErrorResponse(ErrorBody("INTERNAL", "internal error")))
        }
    }
}
