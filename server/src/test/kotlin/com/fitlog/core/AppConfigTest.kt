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
}
