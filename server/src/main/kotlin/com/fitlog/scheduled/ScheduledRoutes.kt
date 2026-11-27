package com.fitlog.scheduled

import com.fitlog.core.AppConfig
import com.fitlog.core.Exercises
import com.fitlog.core.Ids
import com.fitlog.core.ScheduledWorkouts
import com.fitlog.core.Times
import com.fitlog.core.WorkoutSessions
import com.fitlog.core.dbQuery
import com.fitlog.core.lockUser
import com.fitlog.core.notFound
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
import kotlinx.serialization.Serializable
import org.jetbrains.exposed.sql.SortOrder
import org.jetbrains.exposed.sql.SqlExpressionBuilder.eq
import org.jetbrains.exposed.sql.SqlExpressionBuilder.inList
import org.jetbrains.exposed.sql.SqlExpressionBuilder.isNull
import org.jetbrains.exposed.sql.Transaction
import org.jetbrains.exposed.sql.and
import org.jetbrains.exposed.sql.select
import org.jetbrains.exposed.sql.selectAll
import java.time.LocalDate
import java.time.ZoneId
import java.time.temporal.ChronoUnit
import java.util.UUID

/** contracts/v1.0/scheduled-workout.md §6 */

@Serializable
data class ScheduledList(val items: List<ScheduledWorkout>)

@Serializable
data class SkipBody(val skipped: Boolean)

private const val DEFAULT_TZ = "Asia/Seoul"
private const val MAX_RANGE_DAYS = 92L

/** 사용자 시간대: 가장 최근 세션의 tz, 없으면 Asia/Seoul */
internal fun Transaction.scheduledUserTz(userId: UUID): ZoneId {
    val tz = WorkoutSessions.select(WorkoutSessions.tz)
        .where { (WorkoutSessions.userId eq userId) and WorkoutSessions.deletedAt.isNull() }
        .orderBy(WorkoutSessions.startedAt to SortOrder.DESC)
        .limit(1).firstOrNull()?.get(WorkoutSessions.tz)
    return runCatching { ZoneId.of(tz ?: DEFAULT_TZ) }.getOrElse { ZoneId.of(DEFAULT_TZ) }
}

/** 예정 운동 검증: 모양(validateScheduled) + 종목이 내 종목이거나 기본 종목인지. 실패하면 VALIDATION_FAILED */
internal fun Transaction.checkScheduledWorkout(userId: UUID, w: ScheduledWorkout, base: String = "") {
    validateScheduled(w, base).firstOrNull()?.let { (path, msg) -> validation(msg, path) }
    val ids = w.items.map { it.exerciseId }.toSet()
    val owners = Exercises.select(Exercises.id, Exercises.ownerId).where { Exercises.id inList ids }
        .associate { it[Exercises.id] to it[Exercises.ownerId] }
    w.items.forEachIndexed { i, item ->
        if (item.exerciseId !in owners || (owners[item.exerciseId] != null && owners[item.exerciseId] != userId)) {
            validation("unknown exercise", "$base/items/$i/exerciseId")
        }
    }
}

private fun parseDate(s: String, field: String): LocalDate =
    runCatching { LocalDate.parse(s) }.getOrElse { validation("$field must be YYYY-MM-DD", field) }

fun Route.scheduledRoutes(config: AppConfig) {
    get("/scheduled-workouts") {
        val uid = call.userId
        val q = call.request.queryParameters
        val list = dbQuery {
            val today = LocalDate.now(scheduledUserTz(uid))
            val from = q["from"]?.let { parseDate(it, "from") }
            val to = q["to"]?.let { parseDate(it, "to") }
            val f = from ?: (to?.minusDays(7) ?: today.minusDays(7))
            val t = to ?: (from?.plusDays(30) ?: today.plusDays(30))
            if (t < f) validation("to must be >= from", "to")
            if (ChronoUnit.DAYS.between(f, t) + 1 > MAX_RANGE_DAYS) validation("range must be at most $MAX_RANGE_DAYS days", "to")
            listScheduled(uid, f, t)
        }
        call.respond(ScheduledList(list))
    }

    put("/scheduled-workouts/{id}") {
        val uid = call.userId
        val id = Ids.parse(call.parameters["id"])
        val body = call.receive<ScheduledWorkout>()
        if (body.id != id) validation("path id and body id differ", "id")
        val saved = dbQuery {
            lockUser(uid)
            val existing = ScheduledWorkouts.selectAll().where { ScheduledWorkouts.id eq id }.singleOrNull()
            if (existing != null && existing[ScheduledWorkouts.userId] != uid) notFound("scheduled workout not found")
            checkScheduledWorkout(uid, body)
            upsertScheduledRow(
                uid, body, Times.now(),
                source = existing?.get(ScheduledWorkouts.sourceCol) ?: "APP",
                importBatchId = existing?.get(ScheduledWorkouts.importBatchId),
            )
            withStatus(listOf(findScheduled(uid, id)!!)).single()
        }
        call.respond(HttpStatusCode.OK, saved)
    }

    delete("/scheduled-workouts/{id}") {
        val uid = call.userId
        val id = Ids.parse(call.parameters["id"])
        dbQuery {
            lockUser(uid)
            val row = ScheduledWorkouts.selectAll().where { ScheduledWorkouts.id eq id }.singleOrNull()
            if (row == null || row[ScheduledWorkouts.userId] != uid) notFound("scheduled workout not found")
            if (row[ScheduledWorkouts.deletedAt] == null) softDeleteScheduledRow(uid, id, Times.now())
        }
        call.respond(HttpStatusCode.NoContent)
    }

    post("/scheduled-workouts/{id}/skip") {
        val uid = call.userId
        val id = Ids.parse(call.parameters["id"])
        val body = call.receive<SkipBody>()
        val saved = dbQuery {
            lockUser(uid)
            setScheduledSkipped(uid, id, body.skipped, Times.now()) ?: notFound("scheduled workout not found")
        }
        call.respond(HttpStatusCode.OK, saved)
    }
}
