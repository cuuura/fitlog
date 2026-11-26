package com.fitlog.core

/** Google ID 토큰 검증 결과 */
data class GoogleIdentity(val sub: String, val email: String, val name: String?)

/** Google ID 토큰 검증기. 실제 구현은 auth 패키지(A1), 테스트는 가짜를 주입한다 */
fun interface GoogleIdTokenVerifier {
    /** 유효하지 않으면 null */
    fun verify(idToken: String): GoogleIdentity?
}

/** Google 웹 OAuth 인가 코드 → ID 토큰 교환 (MCP 로그인 페이지). 실패하면 null */
fun interface GoogleCodeExchanger {
    fun exchange(code: String, redirectUri: String): String?
}
