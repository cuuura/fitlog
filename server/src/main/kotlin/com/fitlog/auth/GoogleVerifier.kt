package com.fitlog.auth

import com.fitlog.core.GoogleIdentity
import com.google.api.client.googleapis.auth.oauth2.GoogleIdTokenVerifier as GoogleLibVerifier
import com.google.api.client.http.javanet.NetHttpTransport
import com.google.api.client.json.gson.GsonFactory
import org.slf4j.LoggerFactory
import com.fitlog.core.GoogleIdTokenVerifier as FitlogVerifier

/** 실제 Google ID 토큰 검증기 (audience = Google OAuth 클라이언트 ID 목록) */
class GoogleIdTokenVerifierImpl(clientIds: List<String>) : FitlogVerifier {
    private val log = LoggerFactory.getLogger(javaClass)

    private val lib: GoogleLibVerifier = GoogleLibVerifier.Builder(NetHttpTransport(), GsonFactory.getDefaultInstance())
        .setAudience(clientIds)
        .setIssuers(listOf("accounts.google.com", "https://accounts.google.com"))
        .build()

    override fun verify(idToken: String): GoogleIdentity? {
        val token = try {
            lib.verify(idToken)
        } catch (e: Exception) {
            log.warn("google id token verification failed: {}", e.toString())
            null
        } ?: return null
        val p = token.payload
        val email = p.email ?: return null
        if (p.emailVerified != true) return null
        return GoogleIdentity(sub = p.subject, email = email, name = p["name"] as? String)
    }
}
