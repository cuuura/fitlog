package com.fitlog.session

import com.fitlog.core.ChangeSeq
import com.fitlog.core.Exercises
import com.fitlog.core.SessionExercises
import com.fitlog.core.WorkoutSessions
import com.fitlog.core.WorkoutSets
import org.jetbrains.exposed.sql.Op
import org.jetbrains.exposed.sql.SqlExpressionBuilder.eq
import org.jetbrains.exposed.sql.ResultRow
import org.jetbrains.exposed.sql.SortOrder
import org.jetbrains.exposed.sql.Transaction
import org.jetbrains.exposed.sql.and
import org.jetbrains.exposed.sql.insert
import org.jetbrains.exposed.sql.SqlExpressionBuilder.inList
import org.jetbrains.exposed.sql.SqlExpressionBuilder.isNull
import org.jetbrains.exposed.sql.SqlExpressionBuilder.lessEq
import org.jetbrains.exposed.sql.SqlExpressionBuilder.neq
import com.fitlog.core.validation
import org.jetbrains.exposed.sql.select
import org.jetbrains.exposed.sql.selectAll
import org.jetbrains.exposed.sql.statements.UpdateBuilder
import org.jetbrains.exposed.sql.update
import java.time.Instant
import java.util.UUID

/** 세션 로직과 sync 가 함께 쓰는 DB 헬퍼. 모든 쓰기는 호출자가 lockUser 를 먼저 호출했다고 가정한다 */

internal data class ExerciseRef(val ownerId: UUID?, val type: String, val deleted: Boolean)

internal fun Transaction.exerciseRefs(ids: Collection<UUID>): Map<UUID, ExerciseRef> {
    if (ids.isEmpty()) return emptyMap()
    return Exercises.selectAll().where { Exercises.id inList ids.toSet() }.associate {
        it[Exercises.id] to ExerciseRef(it[Exercises.ownerId], it[Exercises.type], it[Exercises.deletedAt] != null)
    }
}

internal fun ResultRow.toWorkoutSet() = WorkoutSet(
    id = this[WorkoutSets.id],
    position = this[WorkoutSets.position],
    isWarmup = this[WorkoutSets.isWarmup],
    setType = this[WorkoutSets.setType],
    weightKg = this[WorkoutSets.weightKg]?.toDouble(),
    addedWeightKg = this[WorkoutSets.addedWeightKg]?.toDouble(),
    reps = this[WorkoutSets.reps],
    durationSec = this[WorkoutSets.durationSec],
    distanceM = this[WorkoutSets.distanceM]?.toDouble(),
    bandLevel = this[WorkoutSets.bandLevel],
    rpe = this[WorkoutSets.rpe]?.toDouble(),
    rir = this[WorkoutSets.rir],
    restSec = this[WorkoutSets.restSec],
    note = this[WorkoutSets.note],
    completedAt = this[WorkoutSets.completedAt],
    plannedSetKey = this[WorkoutSets.plannedSetKey],
    targetReps = this[WorkoutSets.targetReps],
    targetWeightKg = this[WorkoutSets.targetWeightKg]?.toDouble(),
    isAmrap = this[WorkoutSets.isAmrap],
    targetRepsMax = this[WorkoutSets.targetRepsMax],
    targetRir = this[WorkoutSets.targetRir],
    targetRestSec = this[WorkoutSets.targetRestSec],
)

/** 삭제되지 않은 내 세션 전체(종목·세트 포함). 없으면 null */
internal fun Transaction.loadSession(userId: UUID, id: UUID): Session? {
    val s = WorkoutSessions.selectAll()
        .where { (WorkoutSessions.id eq id) and (WorkoutSessions.userId eq userId) and WorkoutSessions.deletedAt.isNull() }
        .singleOrNull() ?: return null
    val ses = SessionExercises.selectAll()
        .where { (SessionExercises.sessionId eq id) and SessionExercises.deletedAt.isNull() }
        .orderBy(SessionExercises.position to SortOrder.ASC, SessionExercises.id to SortOrder.ASC)
        .toList()
    val setsBySe = if (ses.isEmpty()) emptyMap() else WorkoutSets.selectAll()
        .where { (WorkoutSets.sessionExerciseId inList ses.map { it[SessionExercises.id] }) and WorkoutSets.deletedAt.isNull() }
        .orderBy(WorkoutSets.position to SortOrder.ASC, WorkoutSets.id to SortOrder.ASC)
        .toList()
        .groupBy({ it[WorkoutSets.sessionExerciseId] }, { it.toWorkoutSet() })
    return Session(
        id = s[WorkoutSessions.id],
        startedAt = s[WorkoutSessions.startedAt],
        endedAt = s[WorkoutSessions.endedAt],
        tz = s[WorkoutSessions.tz],
        note = s[WorkoutSessions.note],
        source = s[WorkoutSessions.sourceCol],
        exercises = ses.map {
            SessionExercise(
                id = it[SessionExercises.id],
                exerciseId = it[SessionExercises.exerciseId],
                position = it[SessionExercises.position],
                note = it[SessionExercises.note],
                sets = setsBySe[it[SessionExercises.id]].orEmpty(),
                liftKey = it[SessionExercises.liftKey],
                accessory = it[SessionExercises.accessory],
                supersetGroup = it[SessionExercises.supersetGroup],
            )
        },
        updatedAt = s[WorkoutSessions.updatedAt],
        programInstanceId = s[WorkoutSessions.programInstanceId],
        planSeq = s[WorkoutSessions.planSeq],
        planDayKey = s[WorkoutSessions.planDayKey],
        importBatchId = s[WorkoutSessions.importBatchId],
        scheduledWorkoutId = s[WorkoutSessions.scheduledWorkoutId],
    )
}

// ---- 행 단위 upsert (삭제 상태는 되살린다). updatedAt 은 호출자가 정한다 ----

internal fun Transaction.upsertSessionRow(
    userId: UUID, id: UUID, startedAt: Instant, endedAt: Instant?, tz: String, note: String?, at: Instant,
    programInstanceId: UUID? = null, planSeq: Int? = null, planDayKey: String? = null,
    scheduledWorkoutId: UUID? = null,
) {
    fun fill(b: UpdateBuilder<*>) {
        b[WorkoutSessions.startedAt] = startedAt
        b[WorkoutSessions.endedAt] = endedAt
        b[WorkoutSessions.tz] = tz
        b[WorkoutSessions.note] = note
        b[WorkoutSessions.programInstanceId] = programInstanceId
        b[WorkoutSessions.planSeq] = planSeq
        b[WorkoutSessions.planDayKey] = planDayKey
        b[WorkoutSessions.scheduledWorkoutId] = scheduledWorkoutId
        b[WorkoutSessions.updatedAt] = at
        b[WorkoutSessions.deletedAt] = null
        b[WorkoutSessions.serverSeq] = ChangeSeq.next
    }
    val n = WorkoutSessions.update({ WorkoutSessions.id eq id }) { fill(it) }
    if (n == 0) WorkoutSessions.insert {
        it[WorkoutSessions.id] = id
        it[WorkoutSessions.userId] = userId
        it[sourceCol] = "APP"
        it[createdAt] = at
        fill(it)
    }
}

internal fun Transaction.upsertSessionExerciseRow(
    id: UUID, sessionId: UUID, exerciseId: UUID, position: Int, note: String?, at: Instant,
    liftKey: String? = null, accessory: Boolean = false, supersetGroup: String? = null,
) {
    fun fill(b: UpdateBuilder<*>) {
        b[SessionExercises.sessionId] = sessionId
        b[SessionExercises.exerciseId] = exerciseId
        b[SessionExercises.position] = position
        b[SessionExercises.note] = note
        b[SessionExercises.liftKey] = liftKey
        b[SessionExercises.accessory] = accessory
        b[SessionExercises.supersetGroup] = supersetGroup
        b[SessionExercises.updatedAt] = at
        b[SessionExercises.deletedAt] = null
        b[SessionExercises.serverSeq] = ChangeSeq.next
    }
    val n = SessionExercises.update({ SessionExercises.id eq id }) { fill(it) }
    if (n == 0) SessionExercises.insert {
        it[SessionExercises.id] = id
        fill(it)
    }
}

internal fun Transaction.upsertSetRow(sessionExerciseId: UUID, s: WorkoutSet, at: Instant) {
    fun fill(b: UpdateBuilder<*>) {
        b[WorkoutSets.sessionExerciseId] = sessionExerciseId
        b[WorkoutSets.position] = s.position
        b[WorkoutSets.isWarmup] = s.isWarmup
        b[WorkoutSets.setType] = s.setType
        b[WorkoutSets.weightKg] = s.weightKg?.let(::bd2)
        b[WorkoutSets.addedWeightKg] = s.addedWeightKg?.let(::bd2)
        b[WorkoutSets.reps] = s.reps
        b[WorkoutSets.durationSec] = s.durationSec
        b[WorkoutSets.distanceM] = s.distanceM?.let(::bd1)
        b[WorkoutSets.bandLevel] = s.bandLevel
        b[WorkoutSets.rpe] = s.rpe?.let { java.math.BigDecimal.valueOf(it).setScale(1) }
        b[WorkoutSets.rir] = s.rir
        b[WorkoutSets.restSec] = s.restSec
        b[WorkoutSets.note] = s.note
        b[WorkoutSets.completedAt] = s.completedAt
        b[WorkoutSets.plannedSetKey] = s.plannedSetKey
        b[WorkoutSets.targetReps] = s.targetReps
        b[WorkoutSets.targetWeightKg] = s.targetWeightKg?.let(::bd2)
        b[WorkoutSets.isAmrap] = s.isAmrap
        b[WorkoutSets.targetRepsMax] = s.targetRepsMax
        b[WorkoutSets.targetRir] = s.targetRir
        b[WorkoutSets.targetRestSec] = s.targetRestSec
        b[WorkoutSets.updatedAt] = at
        b[WorkoutSets.deletedAt] = null
        b[WorkoutSets.serverSeq] = ChangeSeq.next
    }
    val n = WorkoutSets.update({ WorkoutSets.id eq s.id }) { fill(it) }
    if (n == 0) WorkoutSets.insert {
        it[WorkoutSets.id] = s.id
        fill(it)
    }
}

// ---- 소프트 삭제 (하위로 전파. 하위는 updatedAt <= at 인 살아있는 행만) ----

internal fun Transaction.softDeleteSets(where: Op<Boolean>, at: Instant) {
    WorkoutSets.update({ where and WorkoutSets.deletedAt.isNull() and (WorkoutSets.updatedAt lessEq at) }) {
        it[deletedAt] = at
        it[updatedAt] = at
        it[serverSeq] = ChangeSeq.next
    }
}

internal fun Transaction.softDeleteSessionExercises(where: Op<Boolean>, at: Instant) {
    val ids = SessionExercises.select(SessionExercises.id)
        .where { where and SessionExercises.deletedAt.isNull() and (SessionExercises.updatedAt lessEq at) }
        .map { it[SessionExercises.id] }
    if (ids.isEmpty()) return
    softDeleteSets(WorkoutSets.sessionExerciseId inList ids, at)
    SessionExercises.update({ SessionExercises.id inList ids }) {
        it[deletedAt] = at
        it[updatedAt] = at
        it[serverSeq] = ChangeSeq.next
    }
}

internal fun Transaction.softDeleteSession(id: UUID, at: Instant) {
    softDeleteSessionExercises(SessionExercises.sessionId eq id, at)
    WorkoutSessions.update({ WorkoutSessions.id eq id }) {
        it[deletedAt] = at
        it[updatedAt] = at
        it[serverSeq] = ChangeSeq.next
    }
}

internal fun Transaction.softDeleteSessionExercise(id: UUID, at: Instant) {
    softDeleteSessionExercises(SessionExercises.id eq id, at)
    // 이미 삭제된 행이라도 updatedAt/serverSeq 는 갱신해 멱등·전파를 보장한다
    SessionExercises.update({ SessionExercises.id eq id }) {
        it[deletedAt] = at
        it[updatedAt] = at
        it[serverSeq] = ChangeSeq.next
    }
}

internal fun Transaction.softDeleteSet(id: UUID, at: Instant) {
    WorkoutSets.update({ WorkoutSets.id eq id }) {
        it[deletedAt] = at
        it[updatedAt] = at
        it[serverSeq] = ChangeSeq.next
    }
}

// Tables.kt 에는 FK 선언이 없어 innerJoin 의 자동 조인을 쓸 수 없다. 조인 조건을 직접 준다
internal fun setsWithExercise() =
    WorkoutSets.join(SessionExercises, org.jetbrains.exposed.sql.JoinType.INNER, WorkoutSets.sessionExerciseId, SessionExercises.id)

internal fun sessionsWithExercise() =
    WorkoutSessions.join(SessionExercises, org.jetbrains.exposed.sql.JoinType.INNER, WorkoutSessions.id, SessionExercises.sessionId)

/** 세션 행이 현재 가리키는 인스턴스(없거나 연결 없음이면 null). 삭제된 세션도 포함한다 */
internal fun Transaction.sessionInstanceId(sessionId: UUID): UUID? =
    WorkoutSessions.select(WorkoutSessions.programInstanceId).where { WorkoutSessions.id eq sessionId }
        .singleOrNull()?.get(WorkoutSessions.programInstanceId)

/**
 * 세션을 인스턴스에 연결해도 되는지 확인한다: 내 인스턴스여야 하고(400), 같은 (인스턴스, planSeq) 에
 * 이미 다른 살아있는 세션이 있으면 부분 유니크 인덱스가 막으므로 미리 409 로 바꾼다.
 */
internal fun Transaction.checkProgramLink(
    userId: UUID, sessionId: UUID, instanceId: UUID?, planSeq: Int?, fieldPrefix: String = "",
) {
    planSeq?.let { if (it < 1) validation("planSeq must be >= 1", fieldPrefix + "planSeq") }
    if (instanceId == null) return
    val owned = com.fitlog.core.ProgramInstances.select(com.fitlog.core.ProgramInstances.id)
        .where {
            (com.fitlog.core.ProgramInstances.id eq instanceId) and (com.fitlog.core.ProgramInstances.userId eq userId) and
                com.fitlog.core.ProgramInstances.deletedAt.isNull()
        }.firstOrNull()
    if (owned == null) validation("unknown program instance", fieldPrefix + "programInstanceId")
    if (planSeq != null) {
        val clash = WorkoutSessions.select(WorkoutSessions.id)
            .where {
                (WorkoutSessions.programInstanceId eq instanceId) and (WorkoutSessions.planSeq eq planSeq) and
                    WorkoutSessions.deletedAt.isNull() and (WorkoutSessions.id neq sessionId)
            }.firstOrNull()
        if (clash != null) {
            throw com.fitlog.core.ApiException(
                com.fitlog.core.ErrorCode.CONFLICT, "another session is already linked to this planSeq", fieldPrefix + "planSeq",
            )
        }
    }
}

/** 내 예정 운동 행이 있는가(삭제된 것도 포함: 예정을 지워도 연결된 세션은 남는다) */
internal fun Transaction.scheduledExists(userId: UUID, id: UUID): Boolean =
    com.fitlog.core.ScheduledWorkouts.select(com.fitlog.core.ScheduledWorkouts.id)
        .where { (com.fitlog.core.ScheduledWorkouts.id eq id) and (com.fitlog.core.ScheduledWorkouts.userId eq userId) }
        .any()

/** 이 예정에 이 세션 말고 살아 있는 세션이 이미 연결돼 있는가 */
internal fun Transaction.scheduledLinkTaken(sessionId: UUID, scheduledId: UUID): Boolean =
    WorkoutSessions.select(WorkoutSessions.id)
        .where {
            (WorkoutSessions.scheduledWorkoutId eq scheduledId) and WorkoutSessions.deletedAt.isNull() and
                (WorkoutSessions.id neq sessionId)
        }.any()
