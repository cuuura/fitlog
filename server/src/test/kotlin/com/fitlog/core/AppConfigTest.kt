package com.fitlog.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class AppConfigTest {
    private val base = mapOf("JWT_SECRET" to "x".repeat(40))

    @Test
    fun blankValuesBehaveLikeUnset() {
        val cfg = AppConfig.fromEnv(
            base + mapOf(
                "PORT" to "", "HOST" to " ", "DB_URL" to "", "GOOGLE_CLIENT_IDS" to "",
                "GOOGLE_WEB_CLIENT_ID" to "", "PUBLIC_BASE_URL" to "", "CONTACT_EMAIL" to "",
                "BACKUP_RETENTION_DAYS" to "", "INTEGRITY_MODE" to "", "INTEGRITY_PACKAGE_NAMES" to "",
                "PLAY_INTEGRITY_CREDENTIALS" to "", "PLAY_INTEGRITY_CREDENTIALS_JSON" to "",
                "RATE_LIMIT_AUTH_PER_MIN" to "", "TRUST_PROXY" to "", "MAX_BODY_BYTES" to "",
            ),
        )
        assertEquals(8080, cfg.port)
        assertEquals("0.0.0.0", cfg.host)
        assertEquals("jdbc:postgresql://localhost:5432/fitlog", cfg.db.url)
        assertEquals(emptyList(), cfg.googleClientIds)
        assertNull(cfg.googleWebClientId)
        assertEquals("http://localhost:8080", cfg.publicBaseUrl)
        assertEquals(30, cfg.site.backupRetentionDays)
        assertEquals(IntegrityMode.OFF, cfg.integrity.mode)
        assertEquals(listOf("com.fitlog.fitlog"), cfg.integrity.packageNames)
        assertNull(cfg.integrity.credentialsPath)
        assertNull(cfg.integrity.credentialsJson)
        assertEquals(20, cfg.rateLimits.authPerMinute)
        assertEquals(false, cfg.trustProxy)
        assertEquals(5L * 1024 * 1024, cfg.maxBodyBytes)
    }

    @Test
    fun hostPortAndCredentialsJsonAreRead() {
        val cfg = AppConfig.fromEnv(
            base + mapOf("HOST" to "127.0.0.1", "PORT" to "9090", "PLAY_INTEGRITY_CREDENTIALS_JSON" to "{\"a\":1}"),
        )
        assertEquals("127.0.0.1", cfg.host)
        assertEquals(9090, cfg.port)
        assertEquals("{\"a\":1}", cfg.integrity.credentialsJson)
    }

    @Test
    fun parseDatabaseUrlHandlesRenderStyleUrls() {
        val p = parseDatabaseUrl("postgresql://u%40x:p%2Fw%3Ad@dpg-abc.singapore-postgres.render.com/fitlog?sslmode=require")!!
        assertEquals("jdbc:postgresql://dpg-abc.singapore-postgres.render.com:5432/fitlog?sslmode=require", p.jdbcUrl)
        assertEquals("u@x", p.user)
        assertEquals("p/w:d", p.password)
        val q = parseDatabaseUrl("postgres://fitlog:secret@db:6543/app")!!
        assertEquals("jdbc:postgresql://db:6543/app", q.jdbcUrl)
        assertEquals("secret", q.password)
        assertNull(parseDatabaseUrl("mysql://a:b@h/db"))
        assertNull(parseDatabaseUrl("not a url"))
    }

    @Test
    fun databaseUrlIsUsedOnlyWithoutDbUrl() {
        val du = "postgres://ru:rp@host1/rdb"
        val a = AppConfig.fromEnv(base + mapOf("DATABASE_URL" to du))
        assertEquals(DbConfig("jdbc:postgresql://host1:5432/rdb", "ru", "rp"), a.db)
        val b = AppConfig.fromEnv(base + mapOf("DATABASE_URL" to du, "DB_USER" to "o", "DB_PASSWORD" to "op"))
        assertEquals("o", b.db.user)
        assertEquals("op", b.db.password)
        assertEquals("jdbc:postgresql://host1:5432/rdb", b.db.url)
        val c = AppConfig.fromEnv(base + mapOf("DATABASE_URL" to du, "DB_URL" to "jdbc:postgresql://x:1/y"))
        assertEquals(DbConfig("jdbc:postgresql://x:1/y", "fitlog", "fitlog"), c.db)
    }

    @Test
    fun publicBaseUrlFallsBackToRenderExternalUrl() {
        assertEquals("https://r.onrender.com", AppConfig.fromEnv(base + mapOf("RENDER_EXTERNAL_URL" to "https://r.onrender.com/")).publicBaseUrl)
        assertEquals(
            "https://mine.example",
            AppConfig.fromEnv(base + mapOf("PUBLIC_BASE_URL" to "https://mine.example", "RENDER_EXTERNAL_URL" to "https://r.onrender.com")).publicBaseUrl,
        )
    }

    @Test
    fun publicBaseUrlIsNormalizedAndRenderFallbackWorks() {
        assertEquals("https://fitlog.onrender.com", AppConfig.fromEnv(base + ("PUBLIC_BASE_URL" to "fitlog.onrender.com/")).publicBaseUrl)
        assertEquals("https://a.test", AppConfig.fromEnv(base + ("PUBLIC_BASE_URL" to " https://a.test/ ")).publicBaseUrl)
        assertEquals("https://r.onrender.com", AppConfig.fromEnv(base + ("RENDER_EXTERNAL_URL" to "https://r.onrender.com")).publicBaseUrl)
        // PUBLIC_BASE_URL 이 RENDER_EXTERNAL_URL 보다 우선
        assertEquals(
            "https://mine.test",
            AppConfig.fromEnv(base + mapOf("PUBLIC_BASE_URL" to "https://mine.test", "RENDER_EXTERNAL_URL" to "https://r.onrender.com")).publicBaseUrl,
        )
    }

    @Test
    fun dbPoolSizeIsConfigurableAndPoolWaitsForSlowDatabase() {
        assertEquals(5, AppConfig.fromEnv(base + ("DB_MAX_POOL" to "5")).db.maxPool)
        assertEquals(10, AppConfig.fromEnv(base).db.maxPool)
        val hc = hikariConfig(DbConfig("jdbc:postgresql://h/db", "u", "p", maxPool = 5))
        // 부팅 때 DB 가 아직 안 깨어났어도 바로 죽지 않는다
        assertEquals(60_000, hc.initializationFailTimeout)
        assertEquals(2, hc.minimumIdle)
        assertEquals(120_000, hc.keepaliveTime)
    }
}
