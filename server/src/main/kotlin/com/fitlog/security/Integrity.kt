package com.fitlog.security

import com.fitlog.core.AppConfig
import io.ktor.server.application.ApplicationCall

/** decodeIntegrityToken 결과 중 판정에 쓰는 값 */
data class IntegrityVerdict(
    val requestHash: String?,
    val requestPackageName: String?,
    val timestampMillis: Long?,
    val appRecognitionVerdict: String?,
    val packageName: String?,
    val deviceRecognitionVerdict: List<String>,
)

/** A2 소유. 실제 구현은 Google decodeIntegrityToken. 호출 자체 실패(네트워크·5xx)는 예외 */
fun interface IntegrityVerifier {
    suspend fun decode(token: String): IntegrityVerdict
}

/**
 * A2 소유. /v1/auth/google·/v1/auth/refresh 에서 본문 토큰 값(idToken·refreshToken)을 넘겨 호출한다.
 * 모드 off: 무시, report: 검증·로그만, enforce: 실패 시 ApiException(INTEGRITY_FAILED)
 */
suspend fun checkIntegrity(call: ApplicationCall, config: AppConfig, bodyToken: String) {
    // A2 구현
}
