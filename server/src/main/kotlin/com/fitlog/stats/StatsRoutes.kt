package com.fitlog.stats

import com.fitlog.core.AppConfig
import com.fitlog.core.Ids
import com.fitlog.core.InstantSerializer
import com.fitlog.core.SessionExercises
import com.fitlog.core.Times
import com.fitlog.core.UUIDSerializer
import com.fitlog.core.WorkoutSessions
import com.fitlog.core.WorkoutSets
import com.fitlog.core.dbQuery
import com.fitlog.core.notFound
import com.fitlog.core.userId
import com.fitlog.core.validation
import com.fitlog.engine.E1rmFormula
import com.fitlog.engine.ProgramEngine
import com.fitlog.records.DoneSet
import com.fitlog.records.RecordPoint
import com.fitlog.records.bestEstimated
import com.fitlog.records.heavier
import com.fitlog.records.point
import com.fitlog.records.requireVisibleExercise
import com.fitlog.records.userFormula
import io.ktor.server.response.respond
import io.ktor.server.routing.Route
import io.ktor.server.routing.get
import kotlinx.serialization.Serializable
import org.jetbrains.exposed.sql.JoinType
import org.jetbrains.exposed.sql.SqlExpressionBuilder.eq
import org.jetbrains.exposed.sql.SqlExpressionBuilder.greater
import org.jetbrains.exposed.sql.SqlExpressionBuilder.greaterEq
import org.jetbrains.exposed.sql.SqlExpressionBuilder.inList
import org.jetbrains.exposed.sql.SqlExpressionBuilder.isNotNull
import org.jetbrains.exposed.sql.SqlExpressionBuilder.isNull
import org.jetbrains.exposed.sql.SqlExpressionBuilder.lessEq
import org.jetbrains.exposed.sql.and
import org.jetbrains.exposed.sql.selectAll
import java.math.BigDecimal
import java.math.RoundingMode
import java.time.Instant
import java.time.temporal.ChronoUnit
import java.util.UUID

// ---------------------------------------------------------------- DTO (contracts/v1.0/openapi.yaml)

@Serializable
data class ProgressPoint(
    @Serializable(with = UUIDSerializer::class) val sessionId: UUID,
    @Serializable(with = InstantSerializer::class) val startedAt: Instant,
    val topWeightKg: Double,
    val topReps: Int,
    val bestE1rmKg: Double? = null,
    val volumeKg: Double,
    val workSetCount: Int,
    val isWeightPr: Boolean,
    val isE1rmPr: Boolean,
)

@Serializable
data class ExerciseProgress(
    @Serializable(with = UUIDSerializer::class) val exerciseId: UUID,
    val formula: String,
    val points: List<ProgressPoint>,
    val bestWeight: RecordPoint? = null,
    val bestE1rm: RecordPoint? = null,
)

@Serializable
data class SnapSet(val weightKg: Double, val reps: Int)

@Serializable
data class Snap(
    @Serializable(with = UUIDSerializer::class) val sessionId: UUID,
    @Serializable(with = InstantSerializer::class) val startedAt: Instant,
    val sets: List<SnapSet>,
    val setCount: Int,
    val topWeightKg: Double? = null,
    val bestE1rmKg: Double? = null,
    val volumeKg: Double,
)

@Serializable
data class ComparisonExercise(
    @Serializable(with = UUIDSerializer::class) val exerciseId: UUID,
    val current: Snap,
    val previous: Snap? = null,
    val bestWeight: RecordPoint? = null,
    val bestE1rm: RecordPoint? = null,
)

@Serializable
data class SessionComparison(
    @Serializable(with = UUIDSerializer::class) val sessionId: UUID,
    val formula: String,
    val exercises: List<ComparisonExercise>,
)

// ---------------------------------------------------------------- 내부 도구

const val PROGRESS_DEFAULT_DAYS = 180L
const val PROGRESS_DEFAULT_LIMIT = 100
const val PROGRESS_MAX_LIMIT = 500

/** 세션 시작 시각과 함께 읽은 판정 대상 세트 */
private class StatSet(
    val set: DoneSet,
    val startedAt: Instant,
    val exPosition: Int,
    val setPosition: Int,
)

/** 세션 앞뒤 순서: 시작 시각, 같으면 세션 id (결정적 순서) */
private val sessionOrder = compareBy<Pair<Instant, UUID>>({ it.first }, { it.second })

private fun StatSet.key() = startedAt to set.sessionId

/**
 * 끝낸 작업 세트(records와 같은 필터: 워밍업·삭제(세트·종목·세션)·무게/횟수 없음 제외).
 * 세션 시작 시각이 [until] 이하인 것만(null이면 전부). 종목은 여러 개를 한 번에 읽는다.
 */
private fun loadStatSets(uid: UUID, exerciseIds: Collection<UUID>, until: Instant? = null): List<StatSet> {
    if (exerciseIds.isEmpty()) return emptyList()
    val join = WorkoutSets
        .join(SessionExercises, JoinType.INNER, WorkoutSets.sessionExerciseId, SessionExercises.id)
        .join(WorkoutSessions, JoinType.INNER, SessionExercises.sessionId, WorkoutSessions.id)
    return join.selectAll().where {
        var c = (WorkoutSessions.userId eq uid) and WorkoutSessions.deletedAt.isNull() and
            SessionExercises.deletedAt.isNull() and WorkoutSets.deletedAt.isNull() and
            (SessionExercises.exerciseId inList exerciseIds.toList()) and
            (WorkoutSets.isWarmup eq false) and WorkoutSets.completedAt.isNotNull() and
            WorkoutSets.weightKg.isNotNull() and (WorkoutSets.weightKg greater BigDecimal.ZERO) and
            WorkoutSets.reps.isNotNull() and (WorkoutSets.reps greaterEq 1)
        if (until != null) c = c and (WorkoutSessions.startedAt lessEq until)
        c
    }.map {
        StatSet(
            set = DoneSet(
                setId = it[WorkoutSets.id],
                sessionId = it[SessionExercises.sessionId],
                exerciseId = it[SessionExercises.exerciseId],
                weightKg = it[WorkoutSets.weightKg]!!.toDouble(),
                reps = it[WorkoutSets.reps]!!,
                at = it[WorkoutSets.completedAt]!!,
            ),
            startedAt = it[WorkoutSessions.startedAt],
            exPosition = it[SessionExercises.position],
            setPosition = it[WorkoutSets.position],
        )
    }
}

private fun parseTime(s: String?, field: String): Instant? = s?.trim()?.takeIf { it.isNotEmpty() }?.let { Times.parse(it, field) }

private fun bestWeightOf(sets: List<DoneSet>, formula: E1rmFormula): RecordPoint? =
    sets.minWithOrNull(heavier)?.let { point(it, formula) }

private fun bestE1rmOf(sets: List<DoneSet>, formula: E1rmFormula): RecordPoint? =
    bestEstimated(sets, formula)?.let { point(it.first, formula) }

private fun e1rmOf(formula: E1rmFormula, s: DoneSet): Double? = ProgramEngine.estimateOneRm(formula, s.weightKg, s.reps)

private fun volume(sets: List<DoneSet>): Double =
    sets.fold(BigDecimal.ZERO) { acc, s -> acc + BigDecimal.valueOf(s.weightKg).multiply(BigDecimal(s.reps)) }
        .setScale(2, RoundingMode.HALF_UP).toDouble()

// ---------------------------------------------------------------- 종목 추이

/** STA-4 종목 추이. REST와 MCP가 함께 쓴다. 트랜잭션 안에서 호출한다 */
fun statsProgress(uid: UUID, exerciseId: UUID, fromArg: String?, toArg: String?, limitArg: Int?): ExerciseProgress {
    val limit = limitArg ?: PROGRESS_DEFAULT_LIMIT
    if (limit !in 1..PROGRESS_MAX_LIMIT) validation("limit must be between 1 and $PROGRESS_MAX_LIMIT", "limit")
    val to = parseTime(toArg, "to") ?: Times.now()
    val from = parseTime(fromArg, "from") ?: to.minus(PROGRESS_DEFAULT_DAYS, ChronoUnit.DAYS)
    if (from > to) validation("from must not be after to", "from")

    requireVisibleExercise(uid, exerciseId)
    val formula = userFormula(uid)
    val all = loadStatSets(uid, listOf(exerciseId))

    // 세션 단위로 묶어 (startedAt, id) 오름차순으로 훑으며 누적 최대를 갱신한다(기간 밖 세션도 누적에 포함)
    val sessions = all.groupBy { it.key() }.toSortedMap(sessionOrder)
    var maxWeight = Double.NEGATIVE_INFINITY
    var maxE1rm = Double.NEGATIVE_INFINITY
    val points = ArrayList<ProgressPoint>()
    for ((key, rows) in sessions) {
        val sets = rows.map { it.set }
        val top = sets.maxOf { it.weightKg }
        val topReps = sets.filter { it.weightKg == top }.maxOf { it.reps }
        val e1rm = sets.mapNotNull { e1rmOf(formula, it) }.maxOrNull()
        if (key.first in from..to) {
            points += ProgressPoint(
                sessionId = key.second,
                startedAt = key.first,
                topWeightKg = top,
                topReps = topReps,
                bestE1rmKg = e1rm,
                volumeKg = volume(sets),
                workSetCount = sets.size,
                isWeightPr = top > maxWeight,
                isE1rmPr = e1rm != null && e1rm > maxE1rm,
            )
        }
        if (top > maxWeight) maxWeight = top
        if (e1rm != null && e1rm > maxE1rm) maxE1rm = e1rm
    }
    val allSets = all.map { it.set }
    return ExerciseProgress(
        exerciseId = exerciseId,
        formula = formula.name,
        points = points.takeLast(limit),
        bestWeight = bestWeightOf(allSets, formula),
        bestE1rm = bestE1rmOf(allSets, formula),
    )
}

// ---------------------------------------------------------------- 회차 비교

private class SessionHead(val id: UUID, val startedAt: Instant, val instanceId: UUID?, val dayKey: String?)

private fun snap(head: SessionHead, rows: List<StatSet>, formula: E1rmFormula): Snap {
    val sets = rows.sortedWith(compareBy({ it.exPosition }, { it.setPosition }, { it.set.at })).map { it.set }
    return Snap(
        sessionId = head.id,
        startedAt = head.startedAt,
        sets = sets.map { SnapSet(it.weightKg, it.reps) },
        setCount = sets.size,
        topWeightKg = sets.maxOfOrNull { it.weightKg },
        bestE1rmKg = sets.mapNotNull { e1rmOf(formula, it) }.maxOrNull(),
        volumeKg = volume(sets),
    )
}

/** STA-4 오늘 vs 지난 같은 세션·PR. 트랜잭션 안에서 호출한다 */
fun statsComparison(uid: UUID, sessionId: UUID): SessionComparison {
    val head = WorkoutSessions.selectAll().where {
        (WorkoutSessions.id eq sessionId) and (WorkoutSessions.userId eq uid) and WorkoutSessions.deletedAt.isNull()
    }.singleOrNull()?.let {
        SessionHead(it[WorkoutSessions.id], it[WorkoutSessions.startedAt], it[WorkoutSessions.programInstanceId], it[WorkoutSessions.planDayKey])
    } ?: notFound("session not found")
    val formula = userFormula(uid)

    val exerciseIds = SessionExercises.selectAll().where {
        (SessionExercises.sessionId eq sessionId) and SessionExercises.deletedAt.isNull()
    }.orderBy(SessionExercises.position).map { it[SessionExercises.exerciseId] }.distinct()
    if (exerciseIds.isEmpty()) return SessionComparison(sessionId, formula.name, emptyList())

    val headKey = head.startedAt to head.id
    // 이 세션 이전 세션 중 각 종목이 들어 있는 것: 세트 유무와 상관없이 삭제되지 않은 종목 행이면 된다
    val candidates = WorkoutSessions
        .join(SessionExercises, JoinType.INNER, WorkoutSessions.id, SessionExercises.sessionId)
        .selectAll().where {
            (WorkoutSessions.userId eq uid) and WorkoutSessions.deletedAt.isNull() and SessionExercises.deletedAt.isNull() and
                (SessionExercises.exerciseId inList exerciseIds) and (WorkoutSessions.startedAt lessEq head.startedAt)
        }.map {
            it[SessionExercises.exerciseId] to SessionHead(
                it[WorkoutSessions.id], it[WorkoutSessions.startedAt], it[WorkoutSessions.programInstanceId], it[WorkoutSessions.planDayKey],
            )
        }.filter { sessionOrder.compare(it.second.startedAt to it.second.id, headKey) < 0 }
        .groupBy({ it.first }, { it.second })

    val byExercise = loadStatSets(uid, exerciseIds, until = head.startedAt).groupBy { it.set.exerciseId }
    val newestFirst = compareByDescending<SessionHead> { it.startedAt }.thenByDescending { it.id }

    val result = exerciseIds.map { exId ->
        val exSets = byExercise[exId].orEmpty()
        val earlier = exSets.filter { sessionOrder.compare(it.key(), headKey) < 0 }.map { it.set }
        val list = candidates[exId].orEmpty().distinctBy { it.id }.sortedWith(newestFirst)
        // 같은 프로그램 인스턴스·같은 day 우선, 없으면 그 종목을 한 직전 세션
        val sameDay = if (head.instanceId != null && head.dayKey != null) {
            list.firstOrNull { it.instanceId == head.instanceId && it.dayKey == head.dayKey }
        } else null
        val prev = sameDay ?: list.firstOrNull()
        ComparisonExercise(
            exerciseId = exId,
            current = snap(head, exSets.filter { it.set.sessionId == head.id }, formula),
            previous = prev?.let { p -> snap(p, exSets.filter { it.set.sessionId == p.id }, formula) },
            bestWeight = bestWeightOf(earlier, formula),
            bestE1rm = bestE1rmOf(earlier, formula),
        )
    }
    return SessionComparison(sessionId, formula.name, result)
}

// ---------------------------------------------------------------- 라우트

/** A1 소유 (v1.0 STA-4). 경로는 /v1 아래 상대 경로로 등록한다 */
fun Route.statsRoutes(config: AppConfig) {
    get("/exercises/{id}/progress") {
        val uid = call.userId
        val exerciseId = Ids.parse(call.parameters["id"])
        val q = call.request.queryParameters
        val limit = q["limit"]?.let { it.trim().toIntOrNull() ?: validation("limit must be an integer", "limit") }
        call.respond(dbQuery { statsProgress(uid, exerciseId, q["from"], q["to"], limit) })
    }

    get("/sessions/{id}/comparison") {
        val uid = call.userId
        val sessionId = Ids.parse(call.parameters["id"])
        call.respond(dbQuery { statsComparison(uid, sessionId) })
    }
}
