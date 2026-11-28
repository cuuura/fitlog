package com.fitlog.program.instance

import com.fitlog.core.AppJson
import com.fitlog.core.Exercises
import com.fitlog.core.Ids
import com.fitlog.core.ProgramAdjustments
import com.fitlog.core.ProgramInstances
import com.fitlog.core.ProgramSkips
import com.fitlog.core.SessionExercises
import com.fitlog.core.Times
import com.fitlog.core.UserSettingsTable
import com.fitlog.core.WorkoutSessions
import com.fitlog.core.WorkoutSets
import com.fitlog.engine.E1rmFormula
import com.fitlog.engine.EngineSettings
import com.fitlog.engine.PerformedExercise
import com.fitlog.engine.PerformedSet
import com.fitlog.engine.ProgramCalculator
import com.fitlog.engine.ProgramDefinition
import com.fitlog.engine.ProgramEvent
import com.fitlog.engine.ProgramState
import com.fitlog.engine.SkipPolicy
import org.jetbrains.exposed.sql.ResultRow
import org.jetbrains.exposed.sql.SortOrder
import org.jetbrains.exposed.sql.SqlExpressionBuilder.eq
import org.jetbrains.exposed.sql.SqlExpressionBuilder.inList
import org.jetbrains.exposed.sql.SqlExpressionBuilder.isNotNull
import org.jetbrains.exposed.sql.SqlExpressionBuilder.isNull
import org.jetbrains.exposed.sql.Transaction
import org.jetbrains.exposed.sql.and
import org.jetbrains.exposed.sql.deleteWhere
import org.jetbrains.exposed.sql.insert
import org.jetbrains.exposed.sql.selectAll
import org.jetbrains.exposed.sql.update
import java.time.Clock
import java.time.DayOfWeek
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.util.UUID

/** "오늘" 을 정하는 시계. 테스트에서 고정 시계로 바꾼다 */
object InstanceClock {
    @Volatile
    var clock: Clock = Clock.systemUTC()

    fun today(tz: String): LocalDate = LocalDate.now(clock.withZone(ZoneId.of(tz)))
}

/** 인스턴스 행에서 꺼낸 값 */
internal class InstanceCtx(val row: ResultRow) {
    val id: UUID = row[ProgramInstances.id]
    val userId: UUID = row[ProgramInstances.userId]
    val definition: ProgramDefinition = AppJson.decodeFromString(row[ProgramInstances.definition])
    val initial: ProgramState = AppJson.decodeFromString(row[ProgramInstances.initialState])
    val state: ProgramState = AppJson.decodeFromString(row[ProgramInstances.state])
    val policy: SkipPolicy = SkipPolicy.valueOf(row[ProgramInstances.skipPolicy])
    val status: String = row[ProgramInstances.status]
    val tz: String = row[ProgramInstances.tz]
    val startDate: LocalDate = row[ProgramInstances.startDate]
}

internal fun Transaction.loadInstanceRow(userId: UUID, id: UUID): ResultRow? =
    ProgramInstances.selectAll()
        .where { (ProgramInstances.id eq id) and (ProgramInstances.userId eq userId) and ProgramInstances.deletedAt.isNull() }
        .singleOrNull()

/** 엔진 설정: 사용자 e1RM 식 + 정의에 나오는 종목 중 BARBELL 종목 id */
internal fun Transaction.engineSettings(userId: UUID, def: ProgramDefinition): EngineSettings {
    val formula = UserSettingsTable.selectAll().where { UserSettingsTable.userId eq userId }.singleOrNull()
        ?.get(UserSettingsTable.e1rmFormula)?.let { runCatching { E1rmFormula.valueOf(it) }.getOrNull() } ?: E1rmFormula.EPLEY
    val ids = def.lifts.values.mapNotNull { it.exercise.id }.mapNotNull { runCatching { UUID.fromString(it) }.getOrNull() }.toSet()
    val barbells = if (ids.isEmpty()) emptySet() else Exercises.selectAll()
        .where { (Exercises.id inList ids) and (Exercises.type eq "BARBELL") }
        .map { it[Exercises.id].toString() }.toSet()
    return EngineSettings(formula, barbells)
}

private class SessionEv(val planSeq: Int, val date: LocalDate, val event: ProgramEvent.Completed)
private class SkipEv(val id: UUID, val planSeq: Int, val dayIndex: Int, val date: LocalDate, val auto: Boolean)
private class AdjEv(val afterSeq: Int, val createdAt: Instant, val event: ProgramEvent.Adjusted)

/** replay 입력 모음(메모리). 건너뛰기를 더하면 events() 도 갱신된다 */
private class ReplayData(
    val sessions: List<SessionEv>,
    val skips: MutableList<SkipEv>,
    val adjustments: List<AdjEv>,
    val policy: SkipPolicy,
) {
    private val sessionSeqs get() = sessions.mapTo(HashSet()) { it.planSeq }

    /** 세션이 있는 회차의 건너뛰기는 무시한다(실제로 한 운동이 우선) */
    private fun effectiveSkips() = skips.filter { it.planSeq !in sessionSeqs }

    fun events(): List<ProgramEvent> {
        class Keyed(val seq: Int, val kind: Int, val at: Instant, val event: ProgramEvent)
        val all = sessions.map { Keyed(it.planSeq, 0, Instant.EPOCH, it.event) } +
            effectiveSkips().map { Keyed(it.planSeq, 0, Instant.EPOCH, ProgramEvent.Skipped(it.planSeq, policy)) } +
            adjustments.map { Keyed(it.afterSeq, 1, it.createdAt, it.event) }
        return all.sortedWith(compareBy<Keyed> { it.seq }.thenBy { it.kind }.thenBy { it.at }).map { it.event }
    }

    /** 가장 큰 회차 이벤트의 날짜(예정일 계산의 기준). 없으면 null */
    fun lastDate(): LocalDate? {
        val s = sessions.map { it.planSeq to it.date } + effectiveSkips().map { it.planSeq to it.date }
        return s.maxByOrNull { it.first }?.second
    }
}

internal class ReplayResult(val state: ProgramState, val lastEventDate: LocalDate?)

private fun Transaction.loadReplayData(ctx: InstanceCtx): ReplayData {
    val zone = ZoneId.of(ctx.tz)
    val rows = WorkoutSessions.selectAll()
        .where {
            (WorkoutSessions.programInstanceId eq ctx.id) and WorkoutSessions.endedAt.isNotNull() and
                WorkoutSessions.deletedAt.isNull() and WorkoutSessions.planSeq.isNotNull()
        }.toList()
    // 같은 planSeq 에 둘 이상이면 먼저 끝난 것만(부분 유니크 인덱스가 보통 막지만 방어한다)
    val chosen = rows.groupBy { it[WorkoutSessions.planSeq]!! }.map { (_, list) ->
        list.minWith(compareBy<ResultRow> { it[WorkoutSessions.endedAt] }.thenBy { it[WorkoutSessions.id] })
    }
    val sessionIds = chosen.map { it[WorkoutSessions.id] }
    val exRows = if (sessionIds.isEmpty()) emptyList() else SessionExercises.selectAll()
        .where { (SessionExercises.sessionId inList sessionIds) and SessionExercises.deletedAt.isNull() }
        .orderBy(SessionExercises.position to SortOrder.ASC, SessionExercises.id to SortOrder.ASC).toList()
    val setRows = if (exRows.isEmpty()) emptyList() else WorkoutSets.selectAll()
        .where { (WorkoutSets.sessionExerciseId inList exRows.map { it[SessionExercises.id] }) and WorkoutSets.deletedAt.isNull() }
        .orderBy(WorkoutSets.position to SortOrder.ASC, WorkoutSets.id to SortOrder.ASC).toList()
    val setsByEx = setRows.groupBy { it[WorkoutSets.sessionExerciseId] }
    val exBySession = exRows.groupBy { it[SessionExercises.sessionId] }
    val sessions = chosen.map { s ->
        val exercises = exBySession[s[WorkoutSessions.id]].orEmpty().map { ex ->
            PerformedExercise(
                ex[SessionExercises.liftKey], ex[SessionExercises.accessory],
                // 완료 표시(completedAt)가 없는 세트는 기록하지 않은 것으로 본다
                setsByEx[ex[SessionExercises.id]].orEmpty().filter { it[WorkoutSets.completedAt] != null }.map {
                    PerformedSet(
                        it[WorkoutSets.plannedSetKey], it[WorkoutSets.reps], it[WorkoutSets.weightKg]?.toDouble(),
                        it[WorkoutSets.isWarmup], it[WorkoutSets.setType],
                    )
                },
            )
        }
        val seq = s[WorkoutSessions.planSeq]!!
        SessionEv(seq, s[WorkoutSessions.startedAt].atZone(zone).toLocalDate(), ProgramEvent.Completed(seq, exercises))
    }
    val skips = ProgramSkips.selectAll().where { ProgramSkips.instanceId eq ctx.id }.map {
        SkipEv(it[ProgramSkips.id], it[ProgramSkips.planSeq], it[ProgramSkips.dayIndex], it[ProgramSkips.skippedOn], it[ProgramSkips.auto])
    }.toMutableList()
    val adj = ProgramAdjustments.selectAll().where { ProgramAdjustments.instanceId eq ctx.id }.map {
        AdjEv(
            it[ProgramAdjustments.afterSeq], it[ProgramAdjustments.createdAt],
            ProgramEvent.Adjusted(
                AppJson.decodeFromString(it[ProgramAdjustments.tm]), AppJson.decodeFromString(it[ProgramAdjustments.working]),
            ),
        )
    }
    return ReplayData(sessions, skips, adj, ctx.policy)
}

internal fun weekdayOf(s: String?): DayOfWeek? = s?.let { w -> DayOfWeek.entries.firstOrNull { it.name.startsWith(w) } }

internal fun nextOnOrAfter(from: LocalDate, weekday: DayOfWeek): LocalDate {
    var d = from
    while (d.dayOfWeek != weekday) d = d.plusDays(1)
    return d
}

private const val MAX_AUTO_SKIPS = 200

/**
 * FIXED_DATE: 지난 예정일(오늘 이전)인데 세션도 skip 도 없는 회차를 program_skip(auto=true) 로 채운다.
 * 예정일 = 마지막 이벤트 날짜 다음 날부터(없으면 startDate 부터) 처음 나오는 그 날의 weekday.
 * 그 회차에 연결된 세션이 있으면(진행 중 포함) 건너뛰지 않는다.
 */
private fun Transaction.fillAutoSkips(
    engine: ProgramCalculator, ctx: InstanceCtx, data: ReplayData, settings: EngineSettings,
) {
    val today = InstanceClock.today(ctx.tz)
    repeat(MAX_AUTO_SKIPS) {
        val state = engine.replay(ctx.definition, ctx.initial, data.events(), settings)
        val dayIndex = state.nextDayIndex
        val weekday = weekdayOf(ctx.definition.days.getOrNull(dayIndex)?.weekday) ?: return
        val seq = state.seq + 1
        val from = data.lastDate()?.plusDays(1) ?: ctx.startDate
        val sched = nextOnOrAfter(from, weekday)
        if (!sched.isBefore(today)) return
        val linked = WorkoutSessions.selectAll().where {
            (WorkoutSessions.programInstanceId eq ctx.id) and (WorkoutSessions.planSeq eq seq) and WorkoutSessions.deletedAt.isNull()
        }.any()
        if (linked) return
        val id = Ids.newId()
        ProgramSkips.insert {
            it[ProgramSkips.id] = id
            it[instanceId] = ctx.id
            it[planSeq] = seq
            it[ProgramSkips.dayIndex] = dayIndex
            it[skippedOn] = sched
            it[auto] = true
            it[createdAt] = Times.now()
        }
        data.skips.add(SkipEv(id, seq, dayIndex, sched, true))
    }
}

/** 한 인스턴스를 처음부터 다시 계산해 state·state_seq 를 저장한다 */
internal fun Transaction.replayInstance(engine: ProgramCalculator, row: ResultRow): ReplayResult {
    val ctx = InstanceCtx(row)
    val settings = engineSettings(ctx.userId, ctx.definition)
    val data = loadReplayData(ctx)
    if (ctx.policy == SkipPolicy.FIXED_DATE && ctx.status == "ACTIVE") fillAutoSkips(engine, ctx, data, settings)
    // 세션이 생긴 회차에 남은 자동 건너뛰기는 지운다
    val sessionSeqs = data.sessions.map { it.planSeq }.toSet()
    val stale = data.skips.filter { it.auto && it.planSeq in sessionSeqs }.map { it.id }
    if (stale.isNotEmpty()) ProgramSkips.deleteWhere { ProgramSkips.id inList stale }
    val state = engine.replay(ctx.definition, ctx.initial, data.events(), settings)
    ProgramInstances.update({ ProgramInstances.id eq ctx.id }) {
        it[ProgramInstances.state] = AppJson.encodeToString(ProgramState.serializer(), state)
        it[stateSeq] = state.seq
        it[updatedAt] = Times.now()
    }
    return ReplayResult(state, data.lastDate())
}

/** 세션·하위 변경 후 호출: 내 인스턴스만 골라 replay 한다. 호출자는 lockUser 를 먼저 호출한다 */
fun Transaction.replayInstances(engine: ProgramCalculator, userId: UUID, ids: Collection<UUID>) {
    ids.forEach { id -> loadInstanceRow(userId, id)?.let { replayInstance(engine, it) } }
}
