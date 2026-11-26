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
    // ---------------------------------------------------------------- v1.0
    /** 호출 제한(contracts/v1.0/security.md). 테스트 기본은 꺼짐 */
    val rateLimits: RateLimitConfig = RateLimitConfig(),
    /** true 일 때만 X-Forwarded-For 를 믿는다(리버스 프록시 뒤) */
    val trustProxy: Boolean = false,
    val integrity: IntegrityConfig = IntegrityConfig(),
    /** null 이면 security 패키지의 실제 Google decodeIntegrityToken 구현. 테스트에서 가짜 주입용 */
    val integrityVerifierOverride: com.fitlog.security.IntegrityVerifier? = null,
    /** 공개 페이지(/privacy, /account-deletion) 값 */
    val site: SiteConfig = SiteConfig(),
    /** 요청 본문 최대 바이트(Content-Length 기준) */
    val maxBodyBytes: Long = 5L * 1024 * 1024,
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
            rateLimits = RateLimitConfig.fromEnv(env),
            trustProxy = env["TRUST_PROXY"]?.toBoolean() ?: false,
            integrity = IntegrityConfig.fromEnv(env),
            site = SiteConfig(
                contactEmail = env["CONTACT_EMAIL"] ?: "privacy@example.invalid",
                effectiveDate = env["POLICY_EFFECTIVE_DATE"] ?: "2026-12-01",
                backupRetentionDays = env["BACKUP_RETENTION_DAYS"]?.toInt() ?: 30,
            ),
            maxBodyBytes = env["MAX_BODY_BYTES"]?.toLong() ?: (5L * 1024 * 1024),
        ).also { require(it.jwt.secret.length >= 32) { "JWT_SECRET must be at least 32 characters" } }
    }
}

/** contracts/v1.0/security.md 호출 제한. enabled=false 면 설치하지 않는다 */
data class RateLimitConfig(
    val enabled: Boolean = false,
    val authPerMinute: Int = 20,
    val apiPerMinute: Int = 300,
    val exportPer10Minutes: Int = 5,
    val mcpPerMinute: Int = 120,
) {
    companion object {
        fun fromEnv(env: Map<String, String>) = RateLimitConfig(
            enabled = env["RATE_LIMIT_ENABLED"]?.toBoolean() ?: true,
            authPerMinute = env["RATE_LIMIT_AUTH_PER_MIN"]?.toInt() ?: 20,
            apiPerMinute = env["RATE_LIMIT_API_PER_MIN"]?.toInt() ?: 300,
            exportPer10Minutes = env["RATE_LIMIT_EXPORT_PER_10MIN"]?.toInt() ?: 5,
            mcpPerMinute = env["RATE_LIMIT_MCP_PER_MIN"]?.toInt() ?: 120,
        )
    }
}

enum class IntegrityMode { OFF, REPORT, ENFORCE }

data class IntegrityConfig(
    val mode: IntegrityMode = IntegrityMode.OFF,
    /** 허용 패키지 이름 */
    val packageNames: List<String> = listOf("com.fitlog.fitlog"),
    /** 서비스 계정 JSON 파일 경로(decodeIntegrityToken 호출용) */
    val credentialsPath: String? = null,
    /** 토큰 발급 시각 허용 오차 */
    val maxAgeSec: Long = 600,
) {
    companion object {
        fun fromEnv(env: Map<String, String>) = IntegrityConfig(
            mode = env["INTEGRITY_MODE"]?.let { IntegrityMode.valueOf(it.uppercase()) } ?: IntegrityMode.OFF,
            packageNames = env["INTEGRITY_PACKAGE_NAMES"]?.split(',')?.map { it.trim() }?.filter { it.isNotEmpty() }
                ?: listOf("com.fitlog.fitlog"),
            credentialsPath = env["PLAY_INTEGRITY_CREDENTIALS"],
        )
    }
}

data class SiteConfig(
    val contactEmail: String = "privacy@example.invalid",
    val effectiveDate: String = "2026-12-01",
    val backupRetentionDays: Int = 30,
)
