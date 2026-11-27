package com.fitlog.session

import com.fitlog.core.ChangeSeq
import com.fitlog.engine.ProgramCalculator
import com.fitlog.program.instance.replayInstances
import com.fitlog.core.SessionExercises
import com.fitlog.core.Times
import com.fitlog.core.WorkoutSessions
import com.fitlog.core.WorkoutSets
import com.fitlog.core.notFound
import com.fitlog.core.validation
import org.jetbrains.exposed.sql.SortOrder
import org.jetbrains.exposed.sql.SqlExpressionBuilder.eq
import org.jetbrains.exposed.sql.SqlExpressionBuilder.inList
import org.jetbrains.exposed.sql.SqlExpressionBuilder.less
import org.jetbrains.exposed.sql.SqlExpressionBuilder.neq
import org.jetbrains.exposed.sql.SqlExpressionBuilder.inSubQuery
import org.jetbrains.exposed.sql.SqlExpressionBuilder.isNull
import org.jetbrains.exposed.sql.SqlExpressionBuilder.notInList
import org.jetbrains.exposed.sql.Transaction
import org.jetbrains.exposed.sql.and
import org.jetbrains.exposed.sql.SqlExpressionBuilder.isNull
import org.jetbrains.exposed.sql.select
import org.jetbrains.exposed.sql.selectAll
import org.jetbrains.exposed.sql.update
import java.math.BigDecimal
import java.time.Instant
import java.util.UUID

/** PUT /sessions/{id}: 전체 업서트. 호출자는 lockUser 를 먼저 호출해야 한다 */
internal fun Transaction.putSession(userId: UUID, id: UUID, body: Session, engine: ProgramCalculator): Session {
    // ---- 검증 (쓰기 전에 모두) ----
    checkTz(body.tz)
    if (body.endedAt != null && body.endedAt < body.startedAt) validation("endedAt must be >= startedAt", "endedAt")

    val refs = exerciseRefs(body.exercises.map { it.exerciseId })
    val seIds = HashSet<UUID>()
    val setIds = HashSet<UUID>()
    val checkedSets = HashMap<UUID, List<WorkoutSet>>()
    body.exercises.forEachIndexed { i, ex ->
        if (!seIds.add(ex.id)) validation("duplicate id", "exercises[$i].id")
        if (ex.position < 0) validation("position must be >= 0", "exercises[$i].position")
        val ref = refs[ex.exerciseId]
        if (ref == null || ref.deleted || (ref.ownerId != null && ref.ownerId != userId)) {
            validation("unknown exercise", "exercises[$i].exerciseId")
        }
        checkedSets[ex.id] = ex.sets.mapIndexed { j, s ->
            if (!setIds.add(s.id)) validation("duplicate id", "exercises[$i].sets[$j].id")
            checkSet(s, ref.type, "exercises[$i].sets[$j]")
        }
    }

    // ---- 소유권: 남의 세션이거나 다른 세션/사용자의 하위 행 ID 와 충돌하면 거절 ----
    val existing = WorkoutSessions.selectAll().where { WorkoutSessions.id eq id }.singleOrNull()
    if (existing != null && existing[WorkoutSessions.userId] != userId) notFound("session not found")
    if (seIds.isNotEmpty()) {
        val clash = SessionExercises.select(SessionExercises.id)
            .where { (SessionExercises.id inList seIds) and (SessionExercises.sessionId neq id) }
            .firstOrNull()
        if (clash != null) {
            val idx = body.exercises.indexOfFirst { it.id == clash[SessionExercises.id] }
            validation("id is used by another session", "exercises[$idx].id")
        }
    }
    if (setIds.isNotEmpty()) {
        val clash = setsWithExercise().select(WorkoutSets.id)
            .where { (WorkoutSets.id inList setIds) and (SessionExercises.sessionId neq id) }
            .firstOrNull()
        if (clash != null) {
            val clashId = clash[WorkoutSets.id]
            body.exercises.forEachIndexed { i, ex ->
                val j = ex.sets.indexOfFirst { it.id == clashId }
                if (j >= 0) validation("id is used by another session", "exercises[$i].sets[$j].id")
            }
        }
    }

    checkProgramLink(userId, id, body.programInstanceId, body.planSeq)
    body.scheduledWorkoutId?.let {
        if (!scheduledExists(userId, it)) validation("unknown scheduled workout", "scheduledWorkoutId")
        if (scheduledLinkTaken(id, it)) {
            throw com.fitlog.core.ApiException(
                com.fitlog.core.ErrorCode.CONFLICT, "another session is already linked to this scheduled workout", "scheduledWorkoutId",
            )
        }
    }
    val previousInstance = if (existing != null) existing[WorkoutSessions.programInstanceId] else null

    // ---- 쓰기 ----
    val now = Times.now()
    upsertSessionRow(
        userId, id, body.startedAt, body.endedAt, body.tz, body.note, now,
        body.programInstanceId, body.planSeq, body.planDayKey, body.scheduledWorkoutId,
    )
    body.exercises.forEach { ex ->
        upsertSessionExerciseRow(ex.id, id, ex.exerciseId, ex.position, ex.note, now, ex.liftKey, ex.accessory)
        checkedSets.getValue(ex.id).forEach { upsertSetRow(ex.id, it, now) }
    }
    // 본문에 없는 기존 종목·세트는 소프트 삭제
    val sessionSeSub = SessionExercises.select(SessionExercises.id).where { SessionExercises.sessionId eq id }
    val staleSets = WorkoutSets.deletedAt.isNull() and
        (WorkoutSets.sessionExerciseId inSubQuery sessionSeSub) and
        (if (setIds.isEmpty()) org.jetbrains.exposed.sql.Op.TRUE else WorkoutSets.id notInList setIds)
    WorkoutSets.update({ staleSets }) {
        it[deletedAt] = now
        it[updatedAt] = now
        it[serverSeq] = ChangeSeq.next
    }
    val staleSe = (SessionExercises.sessionId eq id) and SessionExercises.deletedAt.isNull() and
        (if (seIds.isEmpty()) org.jetbrains.exposed.sql.Op.TRUE else SessionExercises.id notInList seIds)
    SessionExercises.update({ staleSe }) {
        it[deletedAt] = now
        it[updatedAt] = now
        it[serverSeq] = ChangeSeq.next
    }
    // 연결된 인스턴스(이전·새 인스턴스 모두)를 같은 트랜잭션 끝에서 다시 계산한다
    replayInstances(engine, userId, setOfNotNull(previousInstance, body.programInstanceId))
    return loadSession(userId, id)!!
}

internal fun Transaction.deleteSessionRest(userId: UUID, id: UUID, engine: ProgramCalculator) {
    val row = WorkoutSessions.selectAll().where { WorkoutSessions.id eq id }.singleOrNull() ?: return
    if (row[WorkoutSessions.userId] != userId) notFound("session not found")
    if (row[WorkoutSessions.deletedAt] != null) return
    softDeleteSession(id, Times.now())
    row[WorkoutSessions.programInstanceId]?.let { replayInstances(engine, userId, setOf(it)) }
}

internal fun Transaction.listSummaries(userId: UUID, before: Instant?, limit: Int): List<SessionSummary> {
    val sessions = WorkoutSessions.selectAll()
        .where {
            val base = (WorkoutSessions.userId eq userId) and WorkoutSessions.deletedAt.isNull()
            if (before != null) base and (WorkoutSessions.startedAt less before) else base
        }
        .orderBy(WorkoutSessions.startedAt to SortOrder.DESC, WorkoutSessions.id to SortOrder.DESC)
        .limit(limit)
        .toList()
    if (sessions.isEmpty()) return emptyList()
    val ids = sessions.map { it[WorkoutSessions.id] }

    val exerciseCount = SessionExercises.select(SessionExercises.id, SessionExercises.sessionId)
        .where { (SessionExercises.sessionId inList ids) and SessionExercises.deletedAt.isNull() }
        .groupingBy { it[SessionExercises.sessionId] }.eachCount()

    val setCount = HashMap<UUID, Int>()
    val volume = HashMap<UUID, BigDecimal>()
    setsWithExercise()
        .select(SessionExercises.sessionId, WorkoutSets.weightKg, WorkoutSets.reps)
        .where {
            (SessionExercises.sessionId inList ids) and SessionExercises.deletedAt.isNull() and
                WorkoutSets.deletedAt.isNull() and (WorkoutSets.isWarmup eq false)
        }
        .forEach {
            val sid = it[SessionExercises.sessionId]
            setCount.merge(sid, 1, Int::plus)
            val w = it[WorkoutSets.weightKg]
            val r = it[WorkoutSets.reps]
            if (w != null && r != null) volume.merge(sid, w.multiply(BigDecimal(r)), BigDecimal::add)
        }

    return sessions.map {
        val sid = it[WorkoutSessions.id]
        SessionSummary(
            id = sid,
            startedAt = it[WorkoutSessions.startedAt],
            endedAt = it[WorkoutSessions.endedAt],
            tz = it[WorkoutSessions.tz],
            exerciseCount = exerciseCount[sid] ?: 0,
            setCount = setCount[sid] ?: 0,
            totalVolumeKg = (volume[sid] ?: BigDecimal.ZERO).setScale(2, java.math.RoundingMode.HALF_UP).toDouble(),
            source = it[WorkoutSessions.sourceCol],
            importBatchId = it[WorkoutSessions.importBatchId],
        )
    }
}

/** 이 종목이 들어간 가장 최근 세션의 세트들. 없으면 null */
internal fun Transaction.lastSetsFor(userId: UUID, exerciseId: UUID): LastSets? {
    val row = sessionsWithExercise()
        .select(WorkoutSessions.id, WorkoutSessions.startedAt)
        .where {
            (WorkoutSessions.userId eq userId) and WorkoutSessions.deletedAt.isNull() and
                SessionExercises.deletedAt.isNull() and (SessionExercises.exerciseId eq exerciseId)
        }
        .orderBy(WorkoutSessions.startedAt to SortOrder.DESC, WorkoutSessions.id to SortOrder.DESC)
        .limit(1)
        .firstOrNull() ?: return null
    val sid = row[WorkoutSessions.id]
    val ses = SessionExercises.select(SessionExercises.id)
        .where { (SessionExercises.sessionId eq sid) and (SessionExercises.exerciseId eq exerciseId) and SessionExercises.deletedAt.isNull() }
        .orderBy(SessionExercises.position to SortOrder.ASC, SessionExercises.id to SortOrder.ASC)
        .map { it[SessionExercises.id] }
    val sets = ses.flatMap { seId ->
        WorkoutSets.selectAll()
            .where { (WorkoutSets.sessionExerciseId eq seId) and WorkoutSets.deletedAt.isNull() }
            .orderBy(WorkoutSets.position to SortOrder.ASC, WorkoutSets.id to SortOrder.ASC)
            .map { it.toWorkoutSet() }
    }
    return LastSets(sid, row[WorkoutSessions.startedAt], sets)
}
