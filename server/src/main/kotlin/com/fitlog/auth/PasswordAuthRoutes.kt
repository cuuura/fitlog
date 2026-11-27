package com.fitlog.auth

import com.fitlog.account.ensureSettings
import com.fitlog.core.AccessTokens
import com.fitlog.core.ApiException
import com.fitlog.core.AppConfig
import com.fitlog.core.AppUsers
import com.fitlog.core.ErrorCode
import com.fitlog.core.Ids
import com.fitlog.core.PasswordCredentials
import com.fitlog.core.Times
import com.fitlog.core.dbQuery
import com.fitlog.core.forbidden
import com.fitlog.core.notFound
import com.fitlog.core.unauthenticated
import com.fitlog.core.validation
import com.fitlog.security.checkIntegrity
import io.ktor.http.HttpHeaders
import io.ktor.server.request.receive
import io.ktor.server.response.header
import io.ktor.server.response.respond
import io.ktor.server.routing.Route
import io.ktor.server.routing.get
import io.ktor.server.routing.post
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import org.jetbrains.exposed.exceptions.ExposedSQLException
import org.jetbrains.exposed.sql.insert
import org.jetbrains.exposed.sql.selectAll
import org.jetbrains.exposed.sql.update
import java.security.MessageDigest
import java.security.SecureRandom
import java.time.Duration
import java.util.Base64
import java.util.UUID
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.PBEKeySpec

@Serializable
data class AuthMethods(val google: Boolean, val password: Boolean, val passwordSignup: Boolean)

@Serializable
data class PasswordRegisterRequest(
    val username: String,
    val password: String,
    val signupCode: String? = null,
    val displayName: String? = null,
)

@Serializable
data class PasswordLoginRequest(val username: String, val password: String)

/** PBKDF2-HMAC-SHA256 비밀번호 해시. 저장 형식: pbkdf2_sha256$<반복>$<salt b64>$<hash b64> */
object PasswordHasher {
    const val ITERATIONS = 210_000
    private const val SALT_BYTES = 16
    private const val KEY_BYTES = 32
    private const val PREFIX = "pbkdf2_sha256"
    private val random = SecureRandom()

    private fun derive(password: String, salt: ByteArray, iterations: Int): ByteArray {
        val spec = PBEKeySpec(password.toCharArray(), salt, iterations, KEY_BYTES * 8)
        try {
            return SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256").generateSecret(spec).encoded
        } finally {
            spec.clearPassword()
        }
    }

    fun hash(password: String): String {
        val salt = ByteArray(SALT_BYTES).also { random.nextBytes(it) }
        val key = derive(password, salt, ITERATIONS)
        val b64 = Base64.getEncoder()
        return "$PREFIX$$ITERATIONS$${b64.encodeToString(salt)}$${b64.encodeToString(key)}"
    }

    fun verify(password: String, stored: String): Boolean {
        val parts = stored.split('$')
        if (parts.size != 4 || parts[0] != PREFIX) return false
        val iterations = parts[1].toIntOrNull()?.takeIf { it > 0 } ?: return false
        val dec = Base64.getDecoder()
        val salt: ByteArray
        val expected: ByteArray
        try {
            salt = dec.decode(parts[2])
            expected = dec.decode(parts[3])
        } catch (e: IllegalArgumentException) {
            return false
        }
        return MessageDigest.isEqual(derive(password, salt, iterations), expected)
    }
}

private const val MAX_FAILURES = 5
private val LOCK_DURATION: Duration = Duration.ofMinutes(15)
private val USERNAME_RE = Regex("^[a-z0-9._-]{3,32}$")

/** 존재하지 않는 아이디도 같은 시간이 걸리도록 비교할 더미 해시(지연 생성) */
private val dummyHash: String by lazy { PasswordHasher.hash("dummy-password-for-timing") }

private fun normalizeUsername(raw: String) = raw.trim().lowercase()

private fun constantTimeEquals(a: String, b: String): Boolean =
    MessageDigest.isEqual(a.toByteArray(Charsets.UTF_8), b.toByteArray(Charsets.UTF_8))

private sealed interface LoginOutcome {
    data class Ok(val userId: UUID, val refresh: String) : LoginOutcome
    data class Locked(val retryAfterSec: Long) : LoginOutcome
    data object Invalid : LoginOutcome
}

/** Retry-After 헤더는 호출 쪽에서 먼저 붙인다 */
private fun tooManyAttempts(): Nothing =
    throw ApiException(ErrorCode.RATE_LIMITED, "too many failed attempts, retry later")

/** 테스트용 아이디·비밀번호 로그인(contracts/v1.0/auth-password.md). authRoutes 의 /auth 아래에 붙는다 */
fun Route.passwordAuthRoutes(config: AppConfig) {
    val access = AccessTokens(config.jwt)
    val pw = config.passwordLogin

    fun tokens(userId: UUID, refresh: String, isNew: Boolean) =
        AuthTokens(access.issue(userId), refresh, access.ttlSec, isNew)

    get("/methods") {
        call.respond(
            AuthMethods(
                google = true,
                password = pw.enabled,
                passwordSignup = pw.enabled && pw.signupCode != null,
            ),
        )
    }

    post("/password/register") {
        if (!pw.enabled) notFound()
        val req = call.receive<PasswordRegisterRequest>()
        checkIntegrity(call, config, req.username)
        val code = pw.signupCode
        if (code == null) forbidden("signup is disabled")
        if (req.signupCode == null || !constantTimeEquals(req.signupCode, code)) forbidden("invalid signup code")
        val username = normalizeUsername(req.username)
        if (!USERNAME_RE.matches(username)) {
            validation("username must be 3-32 characters of a-z, 0-9, '.', '_', '-'", "username")
        }
        if (req.password.length !in 8..128) validation("password must be 8-128 characters", "password")

        // 해시 계산은 DB 트랜잭션 밖, 기본 디스패처에서
        val hash = withContext(Dispatchers.Default) { PasswordHasher.hash(req.password) }
        val display = req.displayName?.trim()?.takeIf { it.isNotEmpty() } ?: username
        val userId = Ids.newId()
        val refresh = try {
            dbQuery {
                val now = Times.now()
                if (PasswordCredentials.selectAll().where { PasswordCredentials.username eq username }.any()) {
                    throw ApiException(ErrorCode.CONFLICT, "username already taken", "username")
                }
                AppUsers.insert {
                    it[id] = userId
                    it[googleSub] = "pw:$userId"
                    it[email] = "$username@password.local"
                    it[displayName] = display
                    it[role] = "MEMBER"
                    it[createdAt] = now
                    it[updatedAt] = now
                }
                PasswordCredentials.insert {
                    it[PasswordCredentials.userId] = userId
                    it[PasswordCredentials.username] = username
                    it[passwordHash] = hash
                    it[failedCount] = 0
                    it[createdAt] = now
                    it[updatedAt] = now
                }
                ensureSettings(userId)
                RefreshTokenService.issue(this, userId, config.jwt.refreshTtlSec)
            }
        } catch (e: ExposedSQLException) {
            // 동시 가입 경합: 유니크 위반
            if (e.sqlState == "23505") throw ApiException(ErrorCode.CONFLICT, "username already taken", "username")
            throw e
        }
        call.respond(tokens(userId, refresh, true))
    }

    post("/password/login") {
        if (!pw.enabled) notFound()
        val req = call.receive<PasswordLoginRequest>()
        checkIntegrity(call, config, req.username)
        val username = normalizeUsername(req.username)

        val row = dbQuery {
            PasswordCredentials.selectAll().where { PasswordCredentials.username eq username }.singleOrNull()
        }
        if (row == null) {
            withContext(Dispatchers.Default) { PasswordHasher.verify(req.password, dummyHash) }
            unauthenticated("invalid username or password")
        }
        val uid = row[PasswordCredentials.userId]
        val lockedAt = row[PasswordCredentials.lockedUntil]
        val now0 = Times.now()
        if (lockedAt != null && lockedAt.isAfter(now0)) {
            // 잠금 중에는 비밀번호가 맞아도 429
            val sec = Duration.between(now0, lockedAt).seconds.coerceAtLeast(1)
            call.response.header(HttpHeaders.RetryAfter, sec.toString())
            tooManyAttempts()
        }
        val ok = withContext(Dispatchers.Default) { PasswordHasher.verify(req.password, row[PasswordCredentials.passwordHash]) }

        val outcome: LoginOutcome = dbQuery {
            val now = Times.now()
            // 동시 시도에서 실패 횟수가 유실되지 않도록 행을 잠근다
            val cur = PasswordCredentials.selectAll().where { PasswordCredentials.userId eq uid }.forUpdate().single()
            val locked = cur[PasswordCredentials.lockedUntil]
            if (locked != null && locked.isAfter(now)) {
                return@dbQuery LoginOutcome.Locked(Duration.between(now, locked).seconds.coerceAtLeast(1))
            }
            if (ok) {
                PasswordCredentials.update({ PasswordCredentials.userId eq uid }) {
                    it[failedCount] = 0
                    it[lockedUntil] = null
                    it[updatedAt] = now
                }
                LoginOutcome.Ok(uid, RefreshTokenService.issue(this, uid, config.jwt.refreshTtlSec))
            } else {
                val failures = cur[PasswordCredentials.failedCount] + 1
                val lock = failures >= MAX_FAILURES
                PasswordCredentials.update({ PasswordCredentials.userId eq uid }) {
                    // 잠금이 걸리면 횟수를 0으로 되돌려 해제 후 다시 5번의 기회를 준다
                    it[failedCount] = if (lock) 0 else failures
                    it[lockedUntil] = if (lock) now.plus(LOCK_DURATION) else null
                    it[updatedAt] = now
                }
                LoginOutcome.Invalid
            }
        }
        when (outcome) {
            is LoginOutcome.Ok -> call.respond(tokens(outcome.userId, outcome.refresh, false))
            is LoginOutcome.Locked -> {
                call.response.header(HttpHeaders.RetryAfter, outcome.retryAfterSec.toString())
                tooManyAttempts()
            }
            LoginOutcome.Invalid -> unauthenticated("invalid username or password")
        }
    }
}
