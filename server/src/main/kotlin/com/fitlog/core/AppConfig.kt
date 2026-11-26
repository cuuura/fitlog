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
    /** 외부에서 보이는 서버 주소(끝 슬래시 없음). MCP 리소스 URL·OAuth 메타데이터·리다이렉트에 쓴다 */
    val publicBaseUrl: String = "http://localhost:8080",
    /** MCP 로그인 페이지용 Google 웹 OAuth 클라이언트(인가 코드 흐름) */
    val googleWebClientId: String? = null,
    val googleWebClientSecret: String? = null,
    /** null 이면 oauth 패키지의 실제 구현(Google 토큰 엔드포인트). 테스트에서 가짜 주입용 */
    val googleCodeExchanger: GoogleCodeExchanger? = null,
    /** null 이면 com.fitlog.importing.ImportPipeline. 테스트에서 가짜 주입용 */
    val importerOverride: com.fitlog.importing.Importer? = null,
) {
    val engine: com.fitlog.engine.ProgramCalculator get() = calculator ?: com.fitlog.engine.ProgramEngine
    val importer: com.fitlog.importing.Importer get() = importerOverride ?: com.fitlog.importing.ImportPipeline

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
            publicBaseUrl = (env["PUBLIC_BASE_URL"] ?: "http://localhost:8080").trimEnd('/'),
            googleWebClientId = env["GOOGLE_WEB_CLIENT_ID"],
            googleWebClientSecret = env["GOOGLE_WEB_CLIENT_SECRET"],
        )
    }
}
