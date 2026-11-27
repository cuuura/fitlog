package com.fitlog.deletion

import com.fitlog.program.instance.deleteInstance
import com.fitlog.core.AppConfig
import com.fitlog.core.BodyMeasurements
import com.fitlog.core.ChangeSeq
import com.fitlog.core.DeletionRequests
import com.fitlog.core.ErrorBody
import com.fitlog.core.ErrorCode
import com.fitlog.core.ErrorResponse
import com.fitlog.core.Exercises
import com.fitlog.core.Ids
import com.fitlog.core.InstantSerializer
import com.fitlog.core.ApiException
import com.fitlog.core.ProgramInstances
import com.fitlog.core.Programs
import com.fitlog.core.ScheduledWorkouts
import com.fitlog.scheduled.softDeleteScheduledRow
import com.fitlog.core.Times
import com.fitlog.core.UUIDSerializer
import com.fitlog.core.WorkoutSessions
import com.fitlog.core.dbQuery
import com.fitlog.core.forbidden
import com.fitlog.core.lockUser
import com.fitlog.core.notFound
import com.fitlog.core.userId
import com.fitlog.core.validation
import com.fitlog.body.softDeleteMeasurementRow
import com.fitlog.session.deleteSessionRest
import io.ktor.http.HttpStatusCode
import io.ktor.server.response.respond
import io.ktor.server.routing.Route
import io.ktor.server.routing.get
import io.ktor.server.routing.post
import kotlinx.serialization.Serializable
import org.jetbrains.exposed.sql.SortOrder
import org.jetbrains.exposed.sql.SqlExpressionBuilder.eq
import org.jetbrains.exposed.sql.SqlExpressionBuilder.isNull
import org.jetbrains.exposed.sql.SqlExpressionBuilder.less
import org.jetbrains.exposed.sql.Transaction
import org.jetbrains.exposed.sql.and
import org.jetbrains.exposed.sql.deleteWhere
import org.jetbrains.exposed.sql.selectAll
import org.jetbrains.exposed.sql.update
import java.time.Instant
import java.util.UUID

/** openapi DeletionRequest */
@Serializable
data class DeletionRequest(
    @Serializable(with = UUIDSerializer::class) val id: UUID,
    val entity: String,
    @Serializable(with = UUIDSerializer::class) val entityId: UUID,
    val label: String? = null,
    val reason: String? = null,
    val clientName: String? = null,
    val status: String,
    val note: String? = null,
    @Serializable(with = InstantSerializer::class) val createdAt: Instant,
    @Serializable(with = InstantSerializer::class) val expiresAt: Instant,
    @Serializable(with = InstantSerializer::class) val decidedAt: Instant? = null,
)

@Serializable
data class PendingCount(val pending: Int)

private val STATUSES = setOf("PENDING", "APPROVED", "REJECTED", "EXPIRED")

private fun org.jetbrains.exposed.sql.ResultRow.toDto() = DeletionRequest(
    id = this[DeletionRequests.id],
    entity = this[DeletionRequests.entity],
    entityId = this[DeletionRequests.entityId],
    label = this[DeletionRequests.label],
    reason = this[DeletionRequests.reason],
    clientName = this[DeletionRequests.clientName],
    status = this[DeletionRequests.status],
    note = this[DeletionRequests.note],
    createdAt = this[DeletionRequests.createdAt],
    expiresAt = this[DeletionRequests.expiresAt],
    decidedAt = this[DeletionRequests.decidedAt],
)

/** expires_at 이 지난 PENDING 을 EXPIRED 로 바꾼다 */
private fun Transaction.expirePending(uid: UUID) {
    DeletionRequests.update({
        (DeletionRequests.userId eq uid) and (DeletionRequests.status eq "PENDING") and
            (DeletionRequests.expiresAt less Times.now())
    }) { it[status] = "EXPIRED" }
}

/** v0.1 에러 형식의 410 GONE (ErrorCode.GONE 과 같은 본문) */
private suspend fun io.ktor.server.application.ApplicationCall.respondGone(message: String) =
    respond(HttpStatusCode.Gone, ErrorResponse(ErrorBody("GONE", message)))

/** 일반 삭제 경로로 실행한다. 대상이 이미 없으면 false */
private fun Transaction.execute(uid: UUID, entity: String, id: UUID, config: AppConfig): Boolean = when (entity) {
    "workout_session" -> {
        val row = WorkoutSessions.selectAll().where { WorkoutSessions.id eq id }.singleOrNull()
        if (row == null || row[WorkoutSessions.userId] != uid || row[WorkoutSessions.deletedAt] != null) false
        else {
            deleteSessionRest(uid, id, config.engine)
            true
        }
    }
    "program" -> {
        val row = Programs.selectAll().where { Programs.id eq id }.singleOrNull()
        if (row == null) false
        else if (row[Programs.ownerId] == null) forbidden("built-in templates cannot be deleted")
        else if (row[Programs.ownerId] != uid || row[Programs.deletedAt] != null) false
        else {
            val now = Times.now()
            Programs.update({ Programs.id eq id }) {
                it[deletedAt] = now
                it[updatedAt] = now
            }
            true
        }
    }
    "program_instance" -> {
        val row = ProgramInstances.selectAll().where { ProgramInstances.id eq id }.singleOrNull()
        if (row == null || row[ProgramInstances.userId] != uid) false
        else {
            // v0.2 DELETE 경로 그대로: 하드 삭제, 연결된 세션은 남기고 연결만 끊는다
            deleteInstance(uid, id)
            true
        }
    }
    "exercise" -> {
        val row = Exercises.selectAll().where { Exercises.id eq id }.singleOrNull()
        if (row == null) false
        else if (row[Exercises.ownerId] == null) forbidden("built-in exercises cannot be deleted")
        else if (row[Exercises.ownerId] != uid || row[Exercises.deletedAt] != null) false
        else {
            val now = Times.now()
            Exercises.update({ Exercises.id eq id }) {
                it[deletedAt] = now
                it[updatedAt] = now
                it[serverSeq] = ChangeSeq.next
            }
            true
        }
    }
    "body_measurement" -> {
        val row = BodyMeasurements.selectAll().where { BodyMeasurements.id eq id }.singleOrNull()
        if (row == null || row[BodyMeasurements.userId] != uid || row[BodyMeasurements.deletedAt] != null) false
        else {
            softDeleteMeasurementRow(id, Times.now())
            true
        }
    }
    "scheduled_workout" -> {
        val row = ScheduledWorkouts.selectAll().where { ScheduledWorkouts.id eq id }.singleOrNull()
        if (row == null || row[ScheduledWorkouts.userId] != uid || row[ScheduledWorkouts.deletedAt] != null) false
        else softDeleteScheduledRow(uid, id, Times.now())
    }
    else -> validation("unknown entity '$entity'", "entity")
}

/** A3 소유 (v0.3). 등록 위치: /v1 아래, 인증 필요 */
fun Route.deletionRoutes(config: AppConfig) {
    get("/deletion-requests") {
        val uid = call.userId
        val status = call.request.queryParameters["status"]
        if (status != null && status !in STATUSES) validation("status must be one of $STATUSES", "status")
        val list = dbQuery {
            lockUser(uid)
            expirePending(uid)
            DeletionRequests.selectAll()
                .where {
                    val base = DeletionRequests.userId eq uid
                    if (status != null) base and (DeletionRequests.status eq status) else base
                }
                .orderBy(DeletionRequests.createdAt, SortOrder.DESC)
                .map { it.toDto() }
        }
        call.respond(list)
    }

    get("/deletion-requests/count") {
        val uid = call.userId
        val n = dbQuery {
            lockUser(uid)
            expirePending(uid)
            DeletionRequests.selectAll()
                .where { (DeletionRequests.userId eq uid) and (DeletionRequests.status eq "PENDING") }
                .count().toInt()
        }
        call.respond(PendingCount(n))
    }

    for (action in listOf("approve", "reject")) {
        post("/deletion-requests/{id}/$action") {
            val uid = call.userId
            val id = Ids.parse(call.parameters["id"])
            val result: DeletionRequest? = run {
                dbQuery {
                    lockUser(uid)
                    expirePending(uid)
                    val row = DeletionRequests.selectAll()
                        .where { (DeletionRequests.id eq id) and (DeletionRequests.userId eq uid) }
                        .singleOrNull() ?: notFound("deletion request not found")
                    when (row[DeletionRequests.status]) {
                        "PENDING" -> {}
                        "EXPIRED" -> return@dbQuery null
                        else -> throw ApiException(ErrorCode.CONFLICT, "deletion request is already decided")
                    }
                    val now = Times.now()
                    var note: String? = null
                    val status = if (action == "approve") {
                        val done = execute(uid, row[DeletionRequests.entity], row[DeletionRequests.entityId], config)
                        if (!done) note = "already deleted"
                        "APPROVED"
                    } else "REJECTED"
                    DeletionRequests.update({ DeletionRequests.id eq id }) {
                        it[DeletionRequests.status] = status
                        it[decidedAt] = now
                        if (note != null) it[DeletionRequests.note] = note
                    }
                    DeletionRequests.selectAll().where { DeletionRequests.id eq id }.single().toDto()
                }
            }
            if (result == null) call.respondGone("deletion request has expired") else call.respond(result)
        }
    }
}
