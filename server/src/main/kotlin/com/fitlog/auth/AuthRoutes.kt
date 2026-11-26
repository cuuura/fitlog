package com.fitlog.auth

import com.fitlog.account.ensureSettings
import com.fitlog.core.AccessTokens
import com.fitlog.core.AppConfig
import com.fitlog.core.AppUsers
import com.fitlog.core.GoogleIdTokenVerifier
import com.fitlog.core.Ids
import com.fitlog.core.RefreshTokens
import com.fitlog.core.Times
import com.fitlog.core.dbQuery
import com.fitlog.core.unauthenticated
import com.fitlog.security.checkIntegrity
import io.ktor.http.HttpStatusCode
import io.ktor.server.request.receive
import io.ktor.server.response.respond
import io.ktor.server.routing.Route
import io.ktor.server.routing.post
import io.ktor.server.routing.route
import kotlinx.serialization.Serializable
import org.jetbrains.exposed.sql.Transaction
import org.jetbrains.exposed.sql.and
import org.jetbrains.exposed.sql.insert
import org.jetbrains.exposed.sql.insertIgnore
import org.jetbrains.exposed.sql.selectAll
import org.jetbrains.exposed.sql.update
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64
import java.util.UUID

@Serializable data class GoogleLoginRequest(val idToken: String)
@Serializable data class RefreshRequest(val refreshToken: String)

@Serializable
data class AuthTokens(val accessToken: String, val refreshToken: String, val expiresIn: Long, val isNewUser: Boolean)

/** 리프레시 토큰 발급·폐기. 불투명 문자열은 DB에 SHA-256 hex 로만 저장한다 */
object RefreshTokenService {
    private val random = SecureRandom()

    fun newOpaque(): String =
        ByteArray(32).also { random.nextBytes(it) }.let { Base64.getUrlEncoder().withoutPadding().encodeToString(it) }

    fun hash(token: String): String =
        MessageDigest.getInstance("SHA-256").digest(token.toByteArray()).joinToString("") { "%02x".format(it) }

    /** 트랜잭션 안에서 새 리프레시 토큰을 만들고 평문을 돌려준다 */
    fun issue(tx: Transaction, userId: UUID, ttlSec: Long): String {
        val raw = newOpaque()
        val now = Times.now()
        tx.run {
            RefreshTokens.insert {
                it[id] = Ids.newId()
                it[RefreshTokens.userId] = userId
                it[tokenHash] = hash(raw)
                it[expiresAt] = now.plusSeconds(ttlSec)
                it[createdAt] = now
            }
        }
        return raw
    }

    /** 자기 토큰만 폐기한다. 남의 토큰·없는 토큰은 조용히 무시 */
    suspend fun revokeOwn(userId: UUID, refreshToken: String) {
        dbQuery {
            RefreshTokens.update({
                (RefreshTokens.tokenHash eq hash(refreshToken)) and
                    (RefreshTokens.userId eq userId) and RefreshTokens.revokedAt.isNull()
            }) { it[revokedAt] = Times.now() }
        }
    }
}

private sealed interface RotateResult {
    data class Ok(val userId: UUID, val refresh: String) : RotateResult
    data object Invalid : RotateResult
}

private val verifierCache = java.util.concurrent.ConcurrentHashMap<List<String>, GoogleIdTokenVerifier>()

/** A1 소유. 경로는 /v1 아래 상대 경로로 등록한다 (인증 없이) */
fun Route.authRoutes(config: AppConfig) {
    val access = AccessTokens(config.jwt)
    val verifier: GoogleIdTokenVerifier = config.googleVerifier
        ?: verifierCache.getOrPut(config.googleClientIds) { GoogleIdTokenVerifierImpl(config.googleClientIds) }

    fun tokens(userId: UUID, refresh: String, isNew: Boolean) =
        AuthTokens(access.issue(userId), refresh, access.ttlSec, isNew)

    route("/auth") {
        post("/google") {
            val req = call.receive<GoogleLoginRequest>()
            checkIntegrity(call, config, req.idToken)
            val identity = verifier.verify(req.idToken) ?: unauthenticated("invalid google id token")
            val (uid, refresh, isNew) = dbQuery {
                val now = Times.now()
                var user = AppUsers.selectAll().where { AppUsers.googleSub eq identity.sub }.singleOrNull()
                var isNew = false
                if (user == null) {
                    val newId = Ids.newId()
                    AppUsers.insertIgnore {
                        it[id] = newId
                        it[googleSub] = identity.sub
                        it[email] = identity.email
                        it[displayName] = identity.name
                        it[role] = "MEMBER"
                        it[createdAt] = now
                        it[updatedAt] = now
                    }
                    user = AppUsers.selectAll().where { AppUsers.googleSub eq identity.sub }.single()
                    isNew = user[AppUsers.id] == newId
                }
                val id = user[AppUsers.id]
                if (!isNew) {
                    AppUsers.update({ AppUsers.id eq id }) {
                        it[email] = identity.email
                        it[displayName] = identity.name
                        it[updatedAt] = now
                    }
                }
                ensureSettings(id)
                Triple(id, RefreshTokenService.issue(this, id, config.jwt.refreshTtlSec), isNew)
            }
            call.respond(tokens(uid, refresh, isNew))
        }

        post("/refresh") {
            val req = call.receive<RefreshRequest>()
            checkIntegrity(call, config, req.refreshToken)
            val result: RotateResult = dbQuery {
                val now = Times.now()
                val row = RefreshTokens.selectAll()
                    .where { RefreshTokens.tokenHash eq RefreshTokenService.hash(req.refreshToken) }
                    .forUpdate().singleOrNull() ?: return@dbQuery RotateResult.Invalid
                val uid = row[RefreshTokens.userId]
                if (row[RefreshTokens.revokedAt] != null) {
                    // 이미 회전/폐기된 토큰의 재사용 = 탈취 의심. 사용자의 모든 리프레시 토큰을 폐기한다
                    RefreshTokens.update({ (RefreshTokens.userId eq uid) and RefreshTokens.revokedAt.isNull() }) {
                        it[revokedAt] = now
                    }
                    return@dbQuery RotateResult.Invalid
                }
                if (!row[RefreshTokens.expiresAt].isAfter(now)) return@dbQuery RotateResult.Invalid
                RefreshTokens.update({ RefreshTokens.id eq row[RefreshTokens.id] }) { it[revokedAt] = now }
                RotateResult.Ok(uid, RefreshTokenService.issue(this, uid, config.jwt.refreshTtlSec))
            }
            when (result) {
                is RotateResult.Ok -> call.respond(HttpStatusCode.OK, tokens(result.userId, result.refresh, false))
                RotateResult.Invalid -> unauthenticated("invalid refresh token")
            }
        }
    }
}
