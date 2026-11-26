package com.fitlog.core

data class DbConfig(val url: String, val user: String, val password: String, val maxPool: Int = 10)

data class JwtConfig(
    val secret: String,
    val issuer: String = "fitlog",
    val audience: String = "fitlog-app",
    val accessTtlSec: Long = 15 * 60,
    val refreshTtlSec: Long = 30L * 24 * 60 * 60,
)

data class AppConfig(
    val port: Int,
    val db: DbConfig,
    val jwt: JwtConfig,
    /** Google OAuth 클라이언트 ID 목록(Android/Web). ID 토큰 audience 검증에 쓴다 */
    val googleClientIds: List<String>,
    /** null 이면 auth 패키지가 googleClientIds 로 실제 검증기를 만든다. 테스트에서 가짜 주입용 */
    val googleVerifier: GoogleIdTokenVerifier? = null,
    /** null 이면 com.fitlog.engine.ProgramEngine. 테스트에서 가짜 엔진 주입용 */
    val calculator: com.fitlog.engine.ProgramCalculator? = null,
) {
    val engine: com.fitlog.engine.ProgramCalculator get() = calculator ?: com.fitlog.engine.ProgramEngine

    companion object {
        fun fromEnv(env: Map<String, String> = System.getenv()): AppConfig = AppConfig(
            port = env["PORT"]?.toInt() ?: 8080,
            db = DbConfig(
                url = env["DB_URL"] ?: "jdbc:postgresql://localhost:5432/fitlog",
                user = env["DB_USER"] ?: "fitlog",
                password = env["DB_PASSWORD"] ?: "fitlog",
            ),
            jwt = JwtConfig(secret = env["JWT_SECRET"] ?: error("JWT_SECRET is required")),
            googleClientIds = env["GOOGLE_CLIENT_IDS"]?.split(',')?.map { it.trim() }?.filter { it.isNotEmpty() }
                ?: emptyList(),
        )
    }
}
