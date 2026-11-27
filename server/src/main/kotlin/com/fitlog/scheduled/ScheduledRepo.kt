package com.fitlog.scheduled

import com.fitlog.core.AppJson
import com.fitlog.core.ChangeSeq
import com.fitlog.core.ScheduledWorkouts
import com.fitlog.core.WorkoutSessions
import kotlinx.serialization.builtins.ListSerializer
import org.jetbrains.exposed.sql.ResultRow
import org.jetbrains.exposed.sql.SortOrder
import org.jetbrains.exposed.sql.SqlExpressionBuilder.eq
import org.jetbrains.exposed.sql.SqlExpressionBuilder.greaterEq
import org.jetbrains.exposed.sql.SqlExpressionBuilder.inList
import org.jetbrains.exposed.sql.SqlExpressionBuilder.isNull
import org.jetbrains.exposed.sql.SqlExpressionBuilder.lessEq
import org.jetbrains.exposed.sql.Transaction
import org.jetbrains.exposed.sql.and
import org.jetbrains.exposed.sql.insert
import org.jetbrains.exposed.sql.selectAll
import org.jetbrains.exposed.sql.statements.UpdateBuilder
import org.jetbrains.exposed.sql.update
import java.time.Instant
import java.time.LocalDate
import java.util.UUID

/*
 * scheduled_workout 공용 저장 함수 (트랙 리드 소유). 모두 호출자 트랜잭션 안에서 쓴다(dbQuery + lockUser 는 호출자 책임).
 * sync(SW-A), REST(SW-A), 가져오기(SW-B), MCP(SW-B)가 함께 쓴다.
 */

private val ITEMS = ListSerializer(ScheduledItem.serializer())

fun encodeItems(items: List<ScheduledItem>): String = AppJson.encodeToString(ITEMS, items)
fun decodeItems(json: String): List<ScheduledItem> = AppJson.decodeFromString(ITEMS, json)

/** sync payload 모양(계산 필드 없음) */
fun ResultRow.toScheduled(): ScheduledWorkout = ScheduledWorkout(
    id = this[ScheduledWorkouts.id],
    plannedDate = this[ScheduledWorkouts.plannedDate].toString(),
    title = this[ScheduledWorkouts.title],
    note = this[ScheduledWorkouts.note],
    items = decodeItems(this[ScheduledWorkouts.items]),
    skippedAt = this[ScheduledWorkouts.skippedAt],
    source = this[ScheduledWorkouts.sourceCol],
    importBatchId = this[ScheduledWorkouts.importBatchId],
    updatedAt = this[ScheduledWorkouts.updatedAt],
    deletedAt = this[ScheduledWorkouts.deletedAt],
)

/** 행 생성·전체 교체. `updatedAt` 은 `at`, deleted_at 은 비운다. 소유자 확인은 호출자 책임(남의 id 면 쓰지 말 것). */
fun Transaction.upsertScheduledRow(
    userId: UUID, w: ScheduledWorkout, at: Instant, source: String = w.source ?: "APP", importBatchId: UUID? = w.importBatchId,
) {
    fun fill(b: UpdateBuilder<*>) {
        b[ScheduledWorkouts.plannedDate] = LocalDate.parse(w.plannedDate)
        b[ScheduledWorkouts.title] = w.title.trim()
        b[ScheduledWorkouts.note] = w.note
        b[ScheduledWorkouts.items] = encodeItems(w.items)
        b[ScheduledWorkouts.skippedAt] = w.skippedAt
        b[ScheduledWorkouts.updatedAt] = at
        b[ScheduledWorkouts.deletedAt] = null
        b[ScheduledWorkouts.serverSeq] = ChangeSeq.next
    }
    val n = ScheduledWorkouts.update({ (ScheduledWorkouts.id eq w.id) and (ScheduledWorkouts.userId eq userId) }) { fill(it) }
    if (n == 0) ScheduledWorkouts.insert {
        it[ScheduledWorkouts.id] = w.id
        it[ScheduledWorkouts.userId] = userId
        it[ScheduledWorkouts.sourceCol] = source
        it[ScheduledWorkouts.importBatchId] = importBatchId
        it[ScheduledWorkouts.createdAt] = at
        fill(it)
    }
}

fun Transaction.softDeleteScheduledRow(userId: UUID, id: UUID, at: Instant): Boolean =
    ScheduledWorkouts.update({ (ScheduledWorkouts.id eq id) and (ScheduledWorkouts.userId eq userId) and ScheduledWorkouts.deletedAt.isNull() }) {
        it[deletedAt] = at
        it[updatedAt] = at
        it[serverSeq] = ChangeSeq.next
    } > 0

/** 살아 있는 내 예정(없거나 삭제·남의 것이면 null) */
fun Transaction.findScheduled(userId: UUID, id: UUID): ScheduledWorkout? =
    ScheduledWorkouts.selectAll().where {
        (ScheduledWorkouts.id eq id) and (ScheduledWorkouts.userId eq userId) and ScheduledWorkouts.deletedAt.isNull()
    }.singleOrNull()?.toScheduled()

/** status·sessionId 를 채운다(계약 §1). */
fun Transaction.withStatus(list: List<ScheduledWorkout>): List<ScheduledWorkout> {
    if (list.isEmpty()) return list
    val sessions = WorkoutSessions.selectAll().where {
        (WorkoutSessions.scheduledWorkoutId inList list.map { it.id }) and WorkoutSessions.deletedAt.isNull()
    }.associate { it[WorkoutSessions.scheduledWorkoutId]!! to (it[WorkoutSessions.id] to it[WorkoutSessions.endedAt]) }
    return list.map { w ->
        val s = sessions[w.id]
        val st = when {
            s != null && s.second != null -> ScheduledStatus.DONE
            s != null -> ScheduledStatus.IN_PROGRESS
            w.skippedAt != null -> ScheduledStatus.SKIPPED
            else -> ScheduledStatus.PLANNED
        }
        w.copy(status = st, sessionId = s?.first)
    }
}

/** 기간(포함) 살아 있는 예정, 날짜·생성 순. status 포함. */
fun Transaction.listScheduled(userId: UUID, from: LocalDate, to: LocalDate): List<ScheduledWorkout> =
    withStatus(
        ScheduledWorkouts.selectAll().where {
            (ScheduledWorkouts.userId eq userId) and ScheduledWorkouts.deletedAt.isNull() and
                (ScheduledWorkouts.plannedDate greaterEq from) and (ScheduledWorkouts.plannedDate lessEq to)
        }.orderBy(ScheduledWorkouts.plannedDate to SortOrder.ASC, ScheduledWorkouts.createdAt to SortOrder.ASC)
            .map { it.toScheduled() },
    )

/** 건너뛰기 설정·해제. 없으면 null. status 포함 결과. */
fun Transaction.setScheduledSkipped(userId: UUID, id: UUID, skipped: Boolean, at: Instant): ScheduledWorkout? {
    findScheduled(userId, id) ?: return null
    ScheduledWorkouts.update({ ScheduledWorkouts.id eq id }) {
        it[skippedAt] = if (skipped) at else null
        it[updatedAt] = at
        it[serverSeq] = ChangeSeq.next
    }
    return withStatus(listOf(findScheduled(userId, id)!!)).single()
}
