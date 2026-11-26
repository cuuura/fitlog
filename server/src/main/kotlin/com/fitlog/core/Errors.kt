package com.fitlog.core

import io.ktor.http.HttpStatusCode
import kotlinx.serialization.Serializable

enum class ErrorCode(val status: HttpStatusCode) {
    VALIDATION_FAILED(HttpStatusCode.BadRequest),
    UNAUTHENTICATED(HttpStatusCode.Unauthorized),
    FORBIDDEN(HttpStatusCode.Forbidden),
    NOT_FOUND(HttpStatusCode.NotFound),
    CONFLICT(HttpStatusCode.Conflict),
    RATE_LIMITED(HttpStatusCode.TooManyRequests),
    PARENT_MISSING(HttpStatusCode.Conflict),
}

/** 핸들러에서 던지면 StatusPages가 계약의 에러 형식으로 바꾼다 */
class ApiException(
    val code: ErrorCode,
    override val message: String,
    val field: String? = null,
    /** 프로그램 검증 등 여러 에러를 JSON 포인터 경로별로 줄 때 */
    val details: List<ErrorDetail>? = null,
) :
    RuntimeException(message)

fun validation(message: String, field: String? = null): Nothing =
    throw ApiException(ErrorCode.VALIDATION_FAILED, message, field)

fun notFound(message: String = "not found"): Nothing = throw ApiException(ErrorCode.NOT_FOUND, message)
fun forbidden(message: String = "forbidden"): Nothing = throw ApiException(ErrorCode.FORBIDDEN, message)
fun unauthenticated(message: String = "unauthenticated"): Nothing =
    throw ApiException(ErrorCode.UNAUTHENTICATED, message)

@Serializable
data class ErrorBody(
    val code: String,
    val message: String,
    val field: String? = null,
    val details: List<ErrorDetail>? = null,
)

/** path = JSON 포인터(예: /days/0/exercises/1/lift) */
@Serializable
data class ErrorDetail(val path: String, val message: String)

@Serializable
data class ErrorResponse(val error: ErrorBody)
