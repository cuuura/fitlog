package com.fitlog.mcp

import com.fitlog.core.AppJson
import com.fitlog.core.Exercises
import com.fitlog.core.Ids
import com.fitlog.core.OneRmMeasurements
import com.fitlog.core.ProgramAccessories
import com.fitlog.core.ProgramAdjustments
import com.fitlog.core.ProgramInstances
import com.fitlog.core.SessionExercises
import com.fitlog.core.Times
import com.fitlog.core.UserSettingsTable
import com.fitlog.core.WorkoutSessions
import com.fitlog.core.WorkoutSets
import com.fitlog.core.lockUser
import com.fitlog.core.notFound
import com.fitlog.core.validation
import com.fitlog.engine.E1rmFormula
import com.fitlog.engine.PlannedExercise
import com.fitlog.engine.PlannedSet
import com.fitlog.engine.ProgramCalculator
import com.fitlog.engine.ProgramEngine
import com.fitlog.engine.ProgramState
import com.fitlog.engine.SkipPolicy
import com.fitlog.program.instance.AdjustInput
import com.fitlog.program.instance.PatchInstance
import com.fitlog.program.instance.instanceView
import com.fitlog.program.instance.patchInstance
import com.fitlog.program.instance.plannedWorkouts
import com.fitlog.program.instance.Instance
import com.fitlog.program.instance.InstanceCtx
import com.fitlog.program.instance.InstanceState
import com.fitlog.program.instance.PlannedWorkout
import com.fitlog.program.instance.engineSettings
import com.fitlog.program.instance.loadInstanceRow
import com.fitlog.program.instance.nextOnOrAfter
import com.fitlog.program.instance.replayInstance
import com.fitlog.program.instance.weekdayOf
import com.fitlog.records.OneRmMeasurement
import com.fitlog.records.ExerciseRecords
import com.fitlog.records.RecordPoint
import com.fitlog.records.RepsRecord
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.jetbrains.exposed.sql.JoinType
import org.jetbrains.exposed.sql.ResultRow
import org.jetbrains.exposed.sql.SortOrder
import org.jetbrains.exposed.sql.SqlExpressionBuilder.eq
import org.jetbrains.exposed.sql.SqlExpressionBuilder.greater
import org.jetbrains.exposed.sql.SqlExpressionBuilder.greaterEq
import org.jetbrains.exposed.sql.SqlExpressionBuilder.inList
import org.jetbrains.exposed.sql.SqlExpressionBuilder.isNotNull
import org.jetbrains.exposed.sql.SqlExpressionBuilder.isNull
import org.jetbrains.exposed.sql.SqlExpressionBuilder.less
import org.jetbrains.exposed.sql.Transaction
import org.jetbrains.exposed.sql.and
import org.jetbrains.exposed.sql.or
import org.jetbrains.exposed.sql.insert
import org.jetbrains.exposed.sql.selectAll
import org.jetbrains.exposed.sql.update
import java.math.BigDecimal
import java.time.DayOfWeek
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.temporal.TemporalAdjusters
import java.util.UUID

/*
 * MCP 조회·조정 도구가 쓰는 질의. 같은 일을 하는 REST 핸들러(records, program.instance)의 함수가 private 이라
 * 같은 규칙으로 여기서 다시 구현했다(내부 함수 internal 로 열리면 이 복사본을 지울 수 있다).
 */

internal const val DEFAULT_TZ = "Asia/Seoul"

/** 사용자 시간대: 가장 최근 세션의 tz, 없으면 Asia/Seoul */
internal fun Transaction.userTz(userId: UUID): String =
    WorkoutSessions.select(WorkoutSessions.tz)
        .where { (WorkoutSessions.userId eq userId) and WorkoutSessions.deletedAt.isNull() }
        .orderBy(WorkoutSessions.startedAt to SortOrder.DESC)
        .limit(1).firstOrNull()?.get(WorkoutSessions.tz)
        ?.takeIf { runCatching { ZoneId.of(it) }.isSuccess } ?: DEFAULT_TZ

internal fun Transaction.userFormula(uid: UUID): E1rmFormula =
    UserSettingsTable.selectAll().where { UserSettingsTable.userId eq uid }.singleOrNull()
        ?.get(UserSettingsTable.e1rmFormula)
        ?.let { s -> E1rmFormula.entries.firstOrNull { it.name == s } } ?: E1rmFormula.EPLEY

// ---------------------------------------------------------------- 인스턴스 (program.instance 의 private 함수와 같은 규칙)


internal fun Transaction.mcpPlannedWorkouts(
    engine: ProgramCalculator, ctx: InstanceCtx, state: ProgramState, count: Int, anchor: LocalDate?,
): List<PlannedWorkout> = plannedWorkouts(engine, ctx, state, count, anchor)

/** 호출자는 lockUser 를 먼저 호출한다(FIXED_DATE 는 조회 중 replay 가 쓴다) */
internal fun Transaction.mcpInstanceView(engine: ProgramCalculator, row: ResultRow, withNext: Boolean = true): Instance =
    instanceView(engine, row, withNext)

internal fun Transaction.mcpPlan(engine: ProgramCalculator, uid: UUID, id: UUID, count: Int): List<PlannedWorkout> {
    lockUser(uid)
    var row = loadInstanceRow(uid, id) ?: notFound("program instance not found")
    var anchor: LocalDate? = null
    val state: ProgramState
    if (row[ProgramInstances.skipPolicy] == "FIXED_DATE") {
        val res = replayInstance(engine, row)
        state = res.state
        anchor = res.lastEventDate
        row = loadInstanceRow(uid, id)!!
    } else {
        state = AppJson.decodeFromString(row[ProgramInstances.state])
    }
    return mcpPlannedWorkouts(engine, InstanceCtx(row), state, count, anchor)
}

/** v0.2 PATCH /program-instances/{id} 를 그대로 쓴다. MCP 는 status ACTIVE|PAUSED 만(호출자가 검사) */
internal fun Transaction.mcpAdjustInstance(
    engine: ProgramCalculator, uid: UUID, id: UUID,
    status: String?, tm: Map<String, Double>, working: Map<String, Double>,
): Instance {
    if (status != null && status != "ACTIVE" && status != "PAUSED") validation("status must be ACTIVE or PAUSED", "status")
    val adjust = if (tm.isEmpty() && working.isEmpty()) null else AdjustInput(tm, working)
    return patchInstance(engine, uid, id, PatchInstance(status = status, adjust = adjust))
}

// ---------------------------------------------------------------- 기록(records) — RecordsRoutes 와 같은 판정

private class DoneSet(val setId: UUID, val sessionId: UUID, val exerciseId: UUID, val weightKg: Double, val reps: Int, val at: Instant)

private fun Transaction.loadDoneSets(uid: UUID, exerciseId: UUID): List<DoneSet> {
    val join = WorkoutSets
        .join(SessionExercises, JoinType.INNER, WorkoutSets.sessionExerciseId, SessionExercises.id)
        .join(WorkoutSessions, JoinType.INNER, SessionExercises.sessionId, WorkoutSessions.id)
    return join.selectAll().where {
        (WorkoutSessions.userId eq uid) and WorkoutSessions.deletedAt.isNull() and
            SessionExercises.deletedAt.isNull() and WorkoutSets.deletedAt.isNull() and
            (SessionExercises.exerciseId eq exerciseId) and
            (WorkoutSets.isWarmup eq false) and WorkoutSets.completedAt.isNotNull() and
            WorkoutSets.weightKg.isNotNull() and (WorkoutSets.weightKg greater BigDecimal.ZERO) and
            WorkoutSets.reps.isNotNull() and (WorkoutSets.reps greaterEq 1)
    }.map {
        DoneSet(
            it[WorkoutSets.id], it[SessionExercises.sessionId], it[SessionExercises.exerciseId],
            it[WorkoutSets.weightKg]!!.toDouble(), it[WorkoutSets.reps]!!, it[WorkoutSets.completedAt]!!,
        )
    }
}

private fun point(s: DoneSet, formula: E1rmFormula) = RecordPoint(
    weightKg = s.weightKg, reps = s.reps, e1rmKg = ProgramEngine.estimateOneRm(formula, s.weightKg, s.reps),
    sessionId = s.sessionId, setId = s.setId, achievedAt = s.at,
)

private val heavier = compareByDescending<DoneSet> { it.weightKg }.thenByDescending { it.reps }.thenBy { it.at }.thenBy { it.setId }

internal fun Transaction.mcpExerciseRecords(uid: UUID, exerciseId: UUID): ExerciseRecords {
    Exercises.selectAll().where {
        (Exercises.id eq exerciseId) and Exercises.deletedAt.isNull() and (Exercises.ownerId.isNull() or (Exercises.ownerId eq uid))
    }.singleOrNull() ?: notFound("exercise not found")
    val formula = userFormula(uid)
    val sets = loadDoneSets(uid, exerciseId)
    val byReps = (1..10).mapNotNull { r ->
        sets.filter { it.reps == r }.minWithOrNull(heavier)?.let { RepsRecord(r, point(it, formula)) }
    }
    val bestE1rm = sets.mapNotNull { s -> ProgramEngine.estimateOneRm(formula, s.weightKg, s.reps)?.let { s to it } }
        .minWithOrNull(compareByDescending<Pair<DoneSet, Double>> { it.second }.thenBy { it.first.at }.thenBy { it.first.setId })
    val measured = OneRmMeasurements.selectAll().where {
        (OneRmMeasurements.userId eq uid) and (OneRmMeasurements.exerciseId eq exerciseId) and OneRmMeasurements.deletedAt.isNull()
    }.orderBy(OneRmMeasurements.measuredAt to SortOrder.DESC, OneRmMeasurements.createdAt to SortOrder.DESC)
        .limit(1).singleOrNull()?.let {
            OneRmMeasurement(
                it[OneRmMeasurements.id], it[OneRmMeasurements.exerciseId], it[OneRmMeasurements.weightKg].toDouble(),
                it[OneRmMeasurements.measuredAt], it[OneRmMeasurements.note],
            )
        }
    return ExerciseRecords(
        exerciseId = exerciseId,
        formula = formula.name,
        bestWeight = sets.minWithOrNull(heavier)?.let { point(it, formula) },
        bestE1rm = bestE1rm?.let { point(it.first, formula) },
        latestMeasured = measured,
        byReps = byReps,
    )
}

// ---------------------------------------------------------------- 훈련 요약

private class Agg(var sets: Int = 0, var volume: BigDecimal = BigDecimal.ZERO, var maxWeight: Double? = null, var bestE1rm: Double? = null)

/** [from, to] (날짜, 포함) 구간의 종목별 합계와 주 단위 운동 횟수 */
internal fun Transaction.mcpTrainingSummary(uid: UUID, from: LocalDate, to: LocalDate): JsonObject {
    val zone = ZoneId.of(userTz(uid))
    val start = from.atStartOfDay(zone).toInstant()
    val end = to.plusDays(1).atStartOfDay(zone).toInstant()
    val formula = userFormula(uid)

    val sessions = WorkoutSessions.selectAll().where {
        (WorkoutSessions.userId eq uid) and WorkoutSessions.deletedAt.isNull() and
            (WorkoutSessions.startedAt greaterEq start) and (WorkoutSessions.startedAt less end)
    }.toList()
    val ids = sessions.map { it[WorkoutSessions.id] }

    val perExercise = LinkedHashMap<UUID, Agg>()
    if (ids.isNotEmpty()) {
        WorkoutSets.join(SessionExercises, JoinType.INNER, WorkoutSets.sessionExerciseId, SessionExercises.id)
            .select(SessionExercises.exerciseId, WorkoutSets.weightKg, WorkoutSets.reps)
            .where {
                (SessionExercises.sessionId inList ids) and SessionExercises.deletedAt.isNull() and
                    WorkoutSets.deletedAt.isNull() and (WorkoutSets.isWarmup eq false)
            }.forEach {
                val a = perExercise.getOrPut(it[SessionExercises.exerciseId]) { Agg() }
                val w = it[WorkoutSets.weightKg]
                val r = it[WorkoutSets.reps]
                a.sets++
                if (w != null && r != null) {
                    a.volume = a.volume.add(w.multiply(BigDecimal(r)))
                    val wd = w.toDouble()
                    if (a.maxWeight == null || wd > a.maxWeight!!) a.maxWeight = wd
                    ProgramEngine.estimateOneRm(formula, wd, r)?.let { e ->
                        if (a.bestE1rm == null || e > a.bestE1rm!!) a.bestE1rm = e
                    }
                }
            }
    }
    val names = if (perExercise.isEmpty()) emptyMap() else
        Exercises.select(Exercises.id, Exercises.nameKo).where { Exercises.id inList perExercise.keys.toList() }
            .associate { it[Exercises.id] to it[Exercises.nameKo] }

    val weeks = sessions.groupingBy {
        val date = it[WorkoutSessions.startedAt].atZone(ZoneId.of(it[WorkoutSessions.tz])).toLocalDate()
        date.with(TemporalAdjusters.previousOrSame(DayOfWeek.MONDAY))
    }.eachCount().toSortedMap()

    return buildJsonObject {
        put("from", from.toString())
        put("to", to.toString())
        put("timezone", zone.id)
        put("sessionCount", sessions.size)
        put("exercises", buildJsonArray {
            perExercise.entries.sortedByDescending { it.value.volume }.forEach { (id, a) ->
                add(buildJsonObject {
                    put("exerciseId", id.toString())
                    put("name", names[id] ?: "")
                    put("sets", a.sets)
                    put("volumeKg", a.volume.setScale(2, java.math.RoundingMode.HALF_UP).toDouble())
                    a.maxWeight?.let { put("maxWeightKg", it) }
                    a.bestE1rm?.let { put("bestE1rmKg", it) }
                })
            }
        })
        put("weeks", buildJsonArray {
            weeks.forEach { (monday, n) ->
                add(buildJsonObject { put("weekStart", monday.toString()); put("sessions", n) })
            }
        })
    }
}

internal fun JsonObject.withText(key: String, value: String?): JsonObject =
    if (value == null) this else JsonObject(this + (key to JsonPrimitive(value)))

// ---------------------------------------------------------------- 예정 운동 (scheduled-workout.md §9)

/** 예정 운동 응답: 계산 필드(status, sessionId)와 종목 이름·종목 수를 더한다 */
internal fun Transaction.scheduledJson(list: List<com.fitlog.scheduled.ScheduledWorkout>): List<kotlinx.serialization.json.JsonObject> {
    val ids = list.flatMap { w -> w.items.map { it.exerciseId } }.distinct()
    val names = if (ids.isEmpty()) emptyMap() else com.fitlog.core.Exercises.select(com.fitlog.core.Exercises.id, com.fitlog.core.Exercises.nameKo)
        .where { com.fitlog.core.Exercises.id inList ids }.associate { it[com.fitlog.core.Exercises.id] to it[com.fitlog.core.Exercises.nameKo] }
    return list.map { w ->
        val base = com.fitlog.core.AppJson.encodeToJsonElement(com.fitlog.scheduled.ScheduledWorkout.serializer(), w) as kotlinx.serialization.json.JsonObject
        val items = kotlinx.serialization.json.JsonArray(
            (base["items"] as kotlinx.serialization.json.JsonArray).mapIndexed { i, el ->
                val n = names[w.items[i].exerciseId]
                kotlinx.serialization.json.JsonObject(
                    (el as kotlinx.serialization.json.JsonObject) + ("exerciseName" to (n?.let { kotlinx.serialization.json.JsonPrimitive(it) } ?: kotlinx.serialization.json.JsonNull)),
                )
            },
        )
        kotlinx.serialization.json.JsonObject(base + ("items" to items) + ("itemCount" to kotlinx.serialization.json.JsonPrimitive(w.items.size)))
    }
}
