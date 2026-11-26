package com.fitlog.account

import com.fitlog.auth.RefreshRequest
import com.fitlog.auth.RefreshTokenService
import com.fitlog.core.AppConfig
import com.fitlog.core.AppUsers
import com.fitlog.core.Consents
import com.fitlog.core.Ids
import com.fitlog.core.InstantSerializer
import com.fitlog.core.Times
import com.fitlog.core.UUIDSerializer
import com.fitlog.core.WorkoutSessions
import com.fitlog.core.dbQuery
import com.fitlog.core.lockUser
import com.fitlog.core.unauthenticated
import com.fitlog.core.userId
import com.fitlog.core.validation
import io.ktor.http.HttpStatusCode
import io.ktor.server.request.receive
import io.ktor.server.response.respond
import io.ktor.server.routing.Route
import io.ktor.server.routing.delete
import io.ktor.server.routing.get
import io.ktor.server.routing.post
import io.ktor.server.routing.put
import io.ktor.server.routing.route
import kotlinx.serialization.Serializable
import org.jetbrains.exposed.sql.SortOrder
import org.jetbrains.exposed.sql.Transaction
import org.jetbrains.exposed.sql.and
import org.jetbrains.exposed.sql.SqlExpressionBuilder.eq
import org.jetbrains.exposed.sql.deleteWhere
import org.jetbrains.exposed.sql.insert
import org.jetbrains.exposed.sql.selectAll
import java.time.Instant
import java.util.UUID

/** 필수 동의 종류와 현재 버전 */
val REQUIRED_CONSENT_KINDS = listOf("TERMS", "PRIVACY", "HEALTH_DATA")
const val CURRENT_CONSENT_VERSION = "2026-11-01"
val CURRENT_CONSENT_VERSIONS: Map<String, String> = REQUIRED_CONSENT_KINDS.associateWith { CURRENT_CONSENT_VERSION }

@Serializable
data class Me(
    @Serializable(with = UUIDSerializer::class) val id: UUID,
    val email: String,
    val displayName: String? = null,
    val role: String,
    val consentsRequired: List<String>,
)

@Serializable
data class ConsentInput(val kind: String, val version: String, val granted: Boolean)

@Serializable
data class Consent(
    val kind: String,
    val version: String,
    val granted: Boolean,
    @Serializable(with = InstantSerializer::class) val createdAt: Instant? = null,
)

private fun Transaction.latestConsents(userId: UUID): List<Consent> =
    Consents.selectAll().where { Consents.userId eq userId }
        .orderBy(Consents.createdAt to SortOrder.DESC, Consents.id to SortOrder.DESC)
        .toList()
        .distinctBy { it[Consents.kind] }
        .map { Consent(it[Consents.kind], it[Consents.version], it[Consents.granted], it[Consents.createdAt]) }
        .sortedBy { REQUIRED_CONSENT_KINDS.indexOf(it.kind) }

private fun validateSettings(s: Settings) {
    s.weightUnit?.let { if (it !in setOf("KG", "LB")) validation("weightUnit must be KG or LB", "weightUnit") }
    s.sex?.let { if (it !in setOf("MALE", "FEMALE", "OTHER")) validation("sex must be MALE, FEMALE or OTHER", "sex") }
    s.defaultRestSec?.let { if (it !in 0..3600) validation("defaultRestSec must be 0..3600", "defaultRestSec") }
    s.birthYear?.let { if (it !in 1900..2100) validation("birthYear must be 1900..2100", "birthYear") }
    s.heightCm?.let { if (!it.isFinite() || it < 50.0 || it > 300.0) validation("heightCm must be 50..300", "heightCm") }
}

/** A1 소유. 경로는 /v1 아래 상대 경로로 등록한다 (authenticate 블록 안) */
fun Route.accountRoutes(config: AppConfig) {
    // 계약상 logout 은 Bearer 가 필요하므로 여기(authenticate 블록)에 등록한다
    post("/auth/logout") {
        val uid = call.userId
        val req = call.receive<RefreshRequest>()
        RefreshTokenService.revokeOwn(uid, req.refreshToken)
        call.respond(HttpStatusCode.NoContent)
    }

    route("/me") {
        get {
            val uid = call.userId
            val me = dbQuery {
                val u = AppUsers.selectAll().where { AppUsers.id eq uid }.singleOrNull() ?: return@dbQuery null
                val latest = latestConsents(uid).associateBy { it.kind }
                val required = REQUIRED_CONSENT_KINDS.filter { kind ->
                    val c = latest[kind]
                    !(c != null && c.granted && c.version == CURRENT_CONSENT_VERSIONS.getValue(kind))
                }
                Me(uid, u[AppUsers.email], u[AppUsers.displayName], u[AppUsers.role], required)
            } ?: unauthenticated("user no longer exists")
            call.respond(me)
        }

        delete {
            val uid = call.userId
            dbQuery {
                lockUser(uid)
                // session_exercise.exercise_id -> exercise 는 CASCADE 가 아니라서 user 삭제 시 cascade 순서에 따라
                // FK 위반이 날 수 있다. 세션(→종목·세트 cascade)을 먼저 지워 순서를 고정한다.
                WorkoutSessions.deleteWhere { userId eq uid }
                AppUsers.deleteWhere { id eq uid } // ON DELETE CASCADE 로 모든 데이터 삭제
            }
            call.respond(HttpStatusCode.NoContent)
        }

        route("/settings") {
            get { call.respond(dbQuery { loadSettings(call.userId) }) }
            put {
                val uid = call.userId
                val body = call.receive<Settings>()
                validateSettings(body)
                call.respond(dbQuery { patchSettings(uid, body); loadSettings(uid) })
            }
        }

        route("/consents") {
            get { call.respond(dbQuery { latestConsents(call.userId) }) }
            post {
                val uid = call.userId
                val body = call.receive<ConsentInput>()
                if (body.kind !in REQUIRED_CONSENT_KINDS) validation("kind must be one of $REQUIRED_CONSENT_KINDS", "kind")
                if (body.version.isBlank() || body.version.length > 50) validation("version is required", "version")
                val created = dbQuery {
                    // 같은 밀리초에 쌓여도 "최신"이 모호하지 않도록 직전 기록보다 항상 늦게 둔다
                    val prev = Consents.selectAll()
                        .where { (Consents.userId eq uid) and (Consents.kind eq body.kind) }
                        .orderBy(Consents.createdAt to SortOrder.DESC).limit(1)
                        .singleOrNull()?.get(Consents.createdAt)
                    var at = Times.now()
                    if (prev != null && !at.isAfter(prev)) at = Instant.ofEpochMilli(prev.toEpochMilli() + 1)
                    Consents.insert {
                        it[id] = Ids.newId()
                        it[userId] = uid
                        it[kind] = body.kind
                        it[version] = body.version
                        it[granted] = body.granted
                        it[createdAt] = at
                    }
                    Consent(body.kind, body.version, body.granted, at)
                }
                call.respond(HttpStatusCode.Created, created)
            }
        }
    }
}
