package com.fitlog.security

import com.fitlog.core.AppConfig
import com.fitlog.core.AppJson
import com.fitlog.core.IntegrityConfig
import com.fitlog.core.IntegrityMode
import com.fitlog.module
import com.fitlog.support.TestEnv
import com.fitlog.support.jsonBody
import io.ktor.client.HttpClient
import io.ktor.client.request.header
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.HttpResponse
import io.ktor.client.statement.bodyAsText
import io.ktor.http.HttpStatusCode
import io.ktor.server.testing.ApplicationTestBuilder
import io.ktor.server.testing.testApplication
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class IntegrityTest {
    private val pkg = "com.fitlog.fitlog"
    private val fixed = "test:fixed-sub:a@x.com"

    private fun good(token: String, hash: String = expectedRequestHash(token)) = IntegrityVerdict(
        requestHash = hash,
        requestPackageName = pkg,
        timestampMillis = System.currentTimeMillis(),
        appRecognitionVerdict = "PLAY_RECOGNIZED",
        packageName = pkg,
        deviceRecognitionVerdict = listOf("MEETS_DEVICE_INTEGRITY"),
    )

    private fun cfg(mode: IntegrityMode, verifier: IntegrityVerifier): AppConfig =
        TestEnv.config.copy(integrity = IntegrityConfig(mode = mode), integrityVerifierOverride = verifier)

    /** X-Integrity-Token 헤더 값으로 판정 종류를 고른다. bodyToken 은 서버가 해시를 기대하는 본문 토큰 */
    private fun verifierFor(bodyToken: String) = IntegrityVerifier { header ->
        when (header) {
            "good" -> good(bodyToken)
            "badverdict" -> good(bodyToken).copy(deviceRecognitionVerdict = emptyList())
            "wronghash" -> good(bodyToken, hash = expectedRequestHash("other"))
            "wrongpkg" -> good(bodyToken).copy(packageName = "evil.app")
            "stale" -> good(bodyToken).copy(timestampMillis = System.currentTimeMillis() - 3_600_000)
            "boom" -> throw java.io.IOException("network down")
            "garbage" -> throw InvalidIntegrityTokenException("decodeIntegrityToken HTTP 400")
            else -> error("unexpected $header")
        }
    }

    private suspend fun HttpClient.google(token: String, integrity: String?) =
        post("/v1/auth/google") {
            jsonBody()
            integrity?.let { header(INTEGRITY_HEADER, it) }
            setBody("""{"idToken":"$token"}""")
        }

    private suspend fun HttpClient.refresh(token: String, integrity: String?) =
        post("/v1/auth/refresh") {
            jsonBody()
            integrity?.let { header(INTEGRITY_HEADER, it) }
            setBody("""{"refreshToken":"$token"}""")
        }

    private suspend fun HttpResponse.code(): String? =
        AppJson.parseToJsonElement(bodyAsText()).jsonObject["error"]?.jsonObject?.get("code")?.jsonPrimitive?.content

    private fun run(mode: IntegrityMode, block: suspend ApplicationTestBuilder.() -> Unit) = testApplication {
        application { module(cfg(mode, verifierFor(fixed))) }
        block()
    }

    @Test
    fun offIgnoresHeaderAndVerdict() = run(IntegrityMode.OFF) {
        assertEquals(HttpStatusCode.OK, client.google(fixed, null).status)
        assertEquals(HttpStatusCode.OK, client.google(fixed, "badverdict").status)
    }

    @Test
    fun reportNeverBlocks() = run(IntegrityMode.REPORT) {
        for (h in listOf(null, "badverdict", "wronghash", "wrongpkg", "stale", "good")) {
            assertEquals(HttpStatusCode.OK, client.google(fixed, h).status, "header=$h")
        }
    }

    @Test
    fun enforceBlocksMissingAndBadVerdictsOnGoogle() = run(IntegrityMode.ENFORCE) {
        for (h in listOf(null, "badverdict", "wronghash", "wrongpkg", "stale")) {
            val r = client.google(fixed, h)
            assertEquals(HttpStatusCode.Forbidden, r.status, "header=$h")
            assertEquals("INTEGRITY_FAILED", r.code())
        }
        assertEquals(HttpStatusCode.OK, client.google(fixed, "good").status)
    }

    @Test
    fun enforceOnRefreshChecksRefreshTokenHash() = testApplication {
        val rt = "rt-${UUID.randomUUID()}"
        application { module(cfg(IntegrityMode.ENFORCE, verifierFor(rt))) }
        assertEquals(HttpStatusCode.Forbidden, client.refresh(rt, null).status)
        assertEquals(HttpStatusCode.Forbidden, client.refresh(rt, "wronghash").status)
        assertEquals(HttpStatusCode.Forbidden, client.refresh(rt, "badverdict").status)
        // 통과하면 일반 인증 흐름(모르는 토큰이라 401)
        assertEquals(HttpStatusCode.Unauthorized, client.refresh(rt, "good").status)
    }

    @Test
    fun enforceOnRefreshBlockedWhenHashIsForDifferentToken() = testApplication {
        application { module(cfg(IntegrityMode.ENFORCE, verifierFor("some-other-token"))) }
        assertEquals(HttpStatusCode.Forbidden, client.refresh("rt-x", "good").status)
    }

    @Test
    fun reportOnRefreshNeverBlocks() = testApplication {
        application { module(cfg(IntegrityMode.REPORT, verifierFor("rt-y"))) }
        for (h in listOf(null, "badverdict", "wronghash", "good")) {
            assertEquals(HttpStatusCode.Unauthorized, client.refresh("rt-y", h).status, "header=$h")
        }
    }

    @Test
    fun verifierExceptionIsFailOpenEvenInEnforce() = run(IntegrityMode.ENFORCE) {
        assertEquals(HttpStatusCode.OK, client.google(fixed, "boom").status)
    }

    @Test
    fun tokenRejectedByGoogleIsBlockedInEnforce() = run(IntegrityMode.ENFORCE) {
        val r = client.google(fixed, "garbage")
        assertEquals(HttpStatusCode.Forbidden, r.status)
        assertEquals("INTEGRITY_FAILED", r.code())
    }

    @Test
    fun parsesDecodeIntegrityTokenResponse() {
        val json = """
        {"tokenPayloadExternal":{
          "requestDetails":{"requestPackageName":"com.fitlog.fitlog","requestHash":"abc","timestampMillis":"1700000000123"},
          "appIntegrity":{"appRecognitionVerdict":"PLAY_RECOGNIZED","packageName":"com.fitlog.fitlog","certificateSha256Digest":["x"],"versionCode":"7"},
          "deviceIntegrity":{"deviceRecognitionVerdict":["MEETS_BASIC_INTEGRITY","MEETS_DEVICE_INTEGRITY"]},
          "accountDetails":{"appLicensingVerdict":"LICENSED"}}}
        """.trimIndent()
        val v = parseIntegrityResponse(json)
        assertEquals("abc", v.requestHash)
        assertEquals("com.fitlog.fitlog", v.requestPackageName)
        assertEquals(1700000000123L, v.timestampMillis)
        assertEquals("PLAY_RECOGNIZED", v.appRecognitionVerdict)
        assertEquals("com.fitlog.fitlog", v.packageName)
        assertEquals(listOf("MEETS_BASIC_INTEGRITY", "MEETS_DEVICE_INTEGRITY"), v.deviceRecognitionVerdict)
    }

    @Test
    fun parsesSparseResponseWithoutCrashing() {
        val v = parseIntegrityResponse("""{"tokenPayloadExternal":{"requestDetails":{}}}""")
        assertNull(v.requestHash)
        assertEquals(emptyList(), v.deviceRecognitionVerdict)
    }

    @Test
    fun requestHashIsBase64UrlSha256WithoutPadding() {
        // sha256("") = e3b0c442... → base64url
        assertEquals("47DEQpj8HBSa-_TImW-5JCeuQeRkm5NMpJWZG3hSuFU", expectedRequestHash(""))
    }
}
