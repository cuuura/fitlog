package com.fitlog.program.instance

import com.fitlog.core.Exercises
import com.fitlog.core.SessionExercises
import com.fitlog.core.WorkoutSessions
import com.fitlog.core.WorkoutSets
import com.fitlog.core.lockUser
import com.fitlog.engine.ProgramCalculator
import com.fitlog.engine.ProgramEvent
import com.fitlog.engine.ProgramState
import com.fitlog.engine.Rule
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.jetbrains.exposed.sql.SortOrder
import org.jetbrains.exposed.sql.SqlExpressionBuilder.eq
import org.jetbrains.exposed.sql.SqlExpressionBuilder.inList
import org.jetbrains.exposed.sql.SqlExpressionBuilder.isNotNull
import org.jetbrains.exposed.sql.SqlExpressionBuilder.isNull
import org.jetbrains.exposed.sql.ResultRow
import org.jetbrains.exposed.sql.Transaction
import org.jetbrains.exposed.sql.and
import org.jetbrains.exposed.sql.selectAll
import java.time.LocalDate
import java.util.UUID

private class Step(val seq: Int, val date: LocalDate?, val event: ProgramEvent, val before: ProgramState, val after: ProgramState)

private fun ProgramState.valueOf(key: String): Double? = tm[key] ?: working[key]

/** 이 회차에 그 종목 키의 본운동 세트가 하나라도 기록됐는가 */
private fun ProgramEvent.touches(key: String): Boolean =
    this is ProgramEvent.Completed && exercises.any { it.liftKey == key && !it.accessory && it.sets.isNotEmpty() }

/**
 * 판정 결과(SUCCESS·FAIL·HOLD·NONE). 엔진은 결과를 따로 내놓지 않아 상태 변화로 읽는다:
 * 실패 연속이 늘거나 값이 내려가면 FAIL, 값·단계가 오르면 SUCCESS, 그대로면 HOLD, 그 키를 안 했으면 NONE.
 * (WEEK_END 규칙은 주 끝 회차에 값이 반영되므로 그 회차에 몰려 보인다.)
 */
private fun resultOf(step: Step, key: String): String {
    if (!step.event.touches(key)) return "NONE"
    val b = step.before.valueOf(key)
    val a = step.after.valueOf(key)
    val failUp = (step.after.failStreak[key] ?: 0) > (step.before.failStreak[key] ?: 0)
    return when {
        failUp || (a != null && b != null && a < b) -> "FAIL"
        (a != null && b != null && a > b) || (step.after.stage[key] ?: 0) > (step.before.stage[key] ?: 0) -> "SUCCESS"
        else -> "HOLD"
    }
}

private fun ruleTypeOf(rule: Rule?): String {
    if (rule == null) return "NONE"
    return (com.fitlog.core.AppJson.encodeToJsonElement(Rule.serializer(), rule) as? JsonObject)?.get("type")?.jsonPrimitive?.content ?: "NONE"
}

private fun JsonObjectBuilderNum(b: kotlinx.serialization.json.JsonObjectBuilder, k: String, v: Number?) {
    if (v == null) b.put(k, JsonNull) else b.put(k, v)
}

/** AI-4 get_program_analysis. 호출자는 dbQuery 안에서 부른다 */
internal fun Transaction.programAnalysis(engine: ProgramCalculator, uid: UUID, id: UUID, sessionCount: Int): JsonObject {
    lockUser(uid)
    val row0 = ownInstance(uid, id)
    replayInstance(engine, row0) // 최신 상태(FIXED_DATE 자동 건너뛰기 포함)
    val ctx = InstanceCtx(loadInstanceRow(uid, id)!!)
    val def = ctx.definition
    val settings = engineSettings(uid, def)
    val data = loadReplayData(ctx)

    // 회차 이벤트를 하나씩 엔진에 통과시켜 회차 뒤 상태 값을 얻는다
    var state = ctx.initial
    val steps = ArrayList<Step>()
    for (k in data.keyedEvents()) {
        val after = engine.apply(def, state, k.event, settings)
        if (k.event !is ProgramEvent.Adjusted) steps += Step(k.seq, k.date, k.event, state, after)
        state = after
    }
    val completed = steps.filter { it.event is ProgramEvent.Completed }
    val recent = completed.takeLast(sessionCount)
    val recentSeqs = recent.map { it.seq }

    // 종목 키별
    val exNames = def.lifts.values.mapNotNull { it.exercise.id }.mapNotNull { runCatching { UUID.fromString(it) }.getOrNull() }
        .let { ids ->
            if (ids.isEmpty()) emptyMap() else Exercises.selectAll().where { Exercises.id inList ids }
                .associate { it[Exercises.id].toString() to it[Exercises.nameKo] }
        }
    val lifts = buildJsonArray {
        for ((key, lift) in def.lifts) {
            val judged = steps.filter { it.event is ProgramEvent.Completed && resultOf(it, key) != "NONE" }
            val last3 = judged.takeLast(3)
            val stalled = last3.size == 3 && (last3.last().after.valueOf(key) ?: 0.0) <= (last3.first().before.valueOf(key) ?: 0.0)
            add(buildJsonObject {
                put("key", key)
                put("exerciseId", lift.exercise.id ?: "")
                put("exerciseName", exNames[lift.exercise.id] ?: "")
                put("ruleType", ruleTypeOf(def.progression[key]))
                JsonObjectBuilderNum(this, "tm", state.tm[key])
                JsonObjectBuilderNum(this, "working", state.working[key])
                put("failStreak", state.failStreak[key] ?: 0)
                put("stalled", stalled)
                put("history", buildJsonArray {
                    for (s in recent) add(buildJsonObject {
                        put("planSeq", s.seq)
                        put("date", s.date?.toString() ?: "")
                        JsonObjectBuilderNum(this, "value", s.after.valueOf(key))
                        put("result", resultOf(s, key))
                    })
                })
            })
        }
    }

    // 최근 회차: 계획 대비 실제
    val sessionRows: Map<Int, ResultRow> = if (recentSeqs.isEmpty()) emptyMap() else WorkoutSessions.selectAll().where {
        (WorkoutSessions.programInstanceId eq id) and WorkoutSessions.planSeq.isNotNull() and
            (WorkoutSessions.planSeq inList recentSeqs) and WorkoutSessions.endedAt.isNotNull() and WorkoutSessions.deletedAt.isNull()
    }.toList().groupBy { it[WorkoutSessions.planSeq]!! }.mapValues { (_, l) -> l.minWith(compareBy<ResultRow>({ it[WorkoutSessions.endedAt] }, { it[WorkoutSessions.id] })) }
    val sessionIds = sessionRows.values.map { it[WorkoutSessions.id] }
    val exRows: List<ResultRow> = if (sessionIds.isEmpty()) emptyList() else SessionExercises.selectAll()
        .where { (SessionExercises.sessionId inList sessionIds) and SessionExercises.deletedAt.isNull() and SessionExercises.liftKey.isNotNull() }
        .orderBy(SessionExercises.position to SortOrder.ASC, SessionExercises.id to SortOrder.ASC).toList()
    val setRows: Map<UUID, List<ResultRow>> = if (exRows.isEmpty()) emptyMap() else WorkoutSets.selectAll()
        .where { (WorkoutSets.sessionExerciseId inList exRows.map { it[SessionExercises.id] }) and WorkoutSets.deletedAt.isNull() }
        .orderBy(WorkoutSets.position to SortOrder.ASC, WorkoutSets.id to SortOrder.ASC).toList()
        .groupBy { it[WorkoutSets.sessionExerciseId] }
    val exBySession = exRows.groupBy { it[SessionExercises.sessionId] }
    val recentSessions = buildJsonArray {
        for (s in recent) {
            val r = sessionRows[s.seq]
            add(buildJsonObject {
                put("planSeq", s.seq)
                put("date", s.date?.toString() ?: "")
                put("dayName", def.days.firstOrNull { it.key == r?.get(WorkoutSessions.planDayKey) }?.name ?: (r?.get(WorkoutSessions.planDayKey) ?: ""))
                put("exercises", buildJsonArray {
                    for (ex in exBySession[r?.get(WorkoutSessions.id)].orEmpty()) {
                        val sets = setRows[ex[SessionExercises.id]].orEmpty().filter { !it[WorkoutSets.isWarmup] }
                        val planned = sets.filter { it[WorkoutSets.targetReps] != null }
                        val done = sets.filter { it[WorkoutSets.completedAt] != null }
                        val hit = planned.isNotEmpty() && planned.all {
                            it[WorkoutSets.completedAt] != null && (it[WorkoutSets.reps] ?: 0) >= it[WorkoutSets.targetReps]!!
                        }
                        add(buildJsonObject {
                            put("liftKey", ex[SessionExercises.liftKey]!!)
                            put("planned", buildJsonArray {
                                for (p in planned) add(buildJsonObject {
                                    put("reps", p[WorkoutSets.targetReps]!!)
                                    JsonObjectBuilderNum(this, "repsMax", p[WorkoutSets.targetRepsMax])
                                    JsonObjectBuilderNum(this, "weightKg", p[WorkoutSets.targetWeightKg]?.toDouble())
                                })
                            })
                            put("actual", buildJsonArray {
                                for (a in done) add(buildJsonObject {
                                    JsonObjectBuilderNum(this, "reps", a[WorkoutSets.reps])
                                    JsonObjectBuilderNum(this, "weightKg", a[WorkoutSets.weightKg]?.toDouble())
                                    JsonObjectBuilderNum(this, "rpe", a[WorkoutSets.rpe]?.toDouble())
                                })
                            })
                            put("hit", hit)
                        })
                    }
                })
            })
        }
    }

    val today = InstanceClock.today(ctx.tz)
    val sessionSeqs = data.sessions.map { it.planSeq }.toSet()
    val adherence = buildJsonObject {
        put("completed", data.sessions.size)
        put("skipped", data.skips.count { it.planSeq !in sessionSeqs })
        put("last28Days", data.sessions.count { !it.date.isBefore(today.minusDays(27)) && !it.date.isAfter(today) })
    }
    return buildJsonObject {
        put("instanceId", id.toString())
        put("name", def.name)
        put("status", ctx.status)
        put("week", state.week)
        put("cycle", state.cycle)
        put("seq", state.seq)
        put("lifts", lifts)
        put("recentSessions", recentSessions)
        put("adherence", adherence)
    }
}
