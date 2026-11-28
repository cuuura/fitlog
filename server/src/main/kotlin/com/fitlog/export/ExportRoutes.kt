package com.fitlog.export

import com.fitlog.core.AppConfig
import com.fitlog.core.AppJson
import com.fitlog.core.BodyMeasurements
import com.fitlog.core.Exercises
import com.fitlog.core.ProgramInstances
import com.fitlog.core.Programs
import com.fitlog.core.ScheduledWorkouts
import com.fitlog.core.SessionExercises
import com.fitlog.scheduled.decodeItems
import com.fitlog.core.Times
import com.fitlog.core.WorkoutSessions
import com.fitlog.core.WorkoutSets
import com.fitlog.core.dbQuery
import com.fitlog.core.userId
import com.fitlog.core.validation
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.withCharset
import io.ktor.server.response.header
import io.ktor.server.response.respondText
import io.ktor.server.routing.Route
import io.ktor.server.routing.get
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.JsonUnquotedLiteral
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import org.jetbrains.exposed.sql.ResultRow
import org.jetbrains.exposed.sql.SortOrder
import org.jetbrains.exposed.sql.SqlExpressionBuilder.eq
import org.jetbrains.exposed.sql.SqlExpressionBuilder.inList
import org.jetbrains.exposed.sql.SqlExpressionBuilder.isNull
import org.jetbrains.exposed.sql.Transaction
import org.jetbrains.exposed.sql.and
import org.jetbrains.exposed.sql.or
import org.jetbrains.exposed.sql.selectAll
import java.math.BigDecimal
import java.time.Instant
import java.time.ZoneId
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.UUID

private const val DEFAULT_TZ = "Asia/Seoul"
private val localFmt = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm")
private val fileDateFmt = DateTimeFormatter.ofPattern("yyyyMMdd").withZone(ZoneOffset.UTC)

private const val SETS_HEADER =
    "date,session_id,program,day,exercise_ko,exercise_en,exercise_type,set_no,is_warmup,weight_kg,added_weight_kg," +
        "reps,rpe,rir,rest_sec,duration_sec,distance_m,target_reps,target_weight_kg,is_amrap,note,superset_group,set_type"
private const val BODY_HEADER = "date,weight_kg,source"

/** A3 소유 (v0.3). 등록 위치: /v1 아래, 인증 필요 */
fun Route.exportRoutes(config: AppConfig) {
    get("/export.json") {
        val uid = call.userId
        val now = Times.now()
        val bundle = dbQuery { buildBundle(uid, now) }
        call.response.header(HttpHeaders.ContentDisposition, "attachment; filename=\"fitlog-export-${fileDateFmt.format(now)}.json\"")
        call.respondText(AppJson.encodeToString(JsonElement.serializer(), bundle), ContentType.Application.Json)
    }

    get("/export.csv") {
        val uid = call.userId
        val kind = call.request.queryParameters["kind"]
        if (kind != "sets" && kind != "body") validation("kind must be 'sets' or 'body'", "kind")
        val now = Times.now()
        val csv = dbQuery { if (kind == "sets") setsCsv(uid) else bodyCsv(uid) }
        call.response.header(
            HttpHeaders.ContentDisposition,
            "attachment; filename=\"fitlog-$kind-${fileDateFmt.format(now)}.csv\"",
        )
        call.respondText("﻿" + csv, ContentType.Text.CSV.withCharset(Charsets.UTF_8))
    }
}

// ------------------------------------------------------------------ JSON

private fun plain(d: BigDecimal): String {
    var s = d.stripTrailingZeros()
    if (s.scale() < 0) s = s.setScale(0)
    return s.toPlainString()
}

private fun num(d: BigDecimal): JsonElement = JsonUnquotedLiteral(plain(d))

private fun Transaction.buildBundle(uid: UUID, exportedAt: Instant): JsonObject {
    // 인스턴스: ACTIVE·PAUSED 만
    val instances = ProgramInstances.selectAll()
        .where {
            (ProgramInstances.userId eq uid) and ProgramInstances.deletedAt.isNull() and
                (ProgramInstances.status inList listOf("ACTIVE", "PAUSED"))
        }
        .orderBy(ProgramInstances.createdAt).toList()
    val instanceIds = instances.map { it[ProgramInstances.id] }.toSet()
    // 정의 교체(v1.2) 이전 회차(planSeq <= base_seq)는 프로그램 연결을 빼고 내보낸다(가져오면 새 정의로 다시 판정되지 않게)
    val baseSeqByInstance = instances.associate { it[ProgramInstances.id] to it[ProgramInstances.baseSeq] }

    // 세션(삭제 제외). 살아 있는 종목·세트가 하나도 없으면 스키마(minItems 1)를 못 지키므로 건너뛴다
    val sessions = WorkoutSessions.selectAll()
        .where { (WorkoutSessions.userId eq uid) and WorkoutSessions.deletedAt.isNull() }
        .orderBy(WorkoutSessions.startedAt).toList()
    val sessionIds = sessions.map { it[WorkoutSessions.id] }
    val ses = if (sessionIds.isEmpty()) emptyList() else SessionExercises.selectAll()
        .where { (SessionExercises.sessionId inList sessionIds) and SessionExercises.deletedAt.isNull() }
        .orderBy(SessionExercises.position to SortOrder.ASC, SessionExercises.id to SortOrder.ASC).toList()
    val seIds = ses.map { it[SessionExercises.id] }
    val sets = if (seIds.isEmpty()) emptyList() else WorkoutSets.selectAll()
        .where { (WorkoutSets.sessionExerciseId inList seIds) and WorkoutSets.deletedAt.isNull() }
        .orderBy(WorkoutSets.position to SortOrder.ASC, WorkoutSets.id to SortOrder.ASC).toList()
    val setsBySe = sets.groupBy { it[WorkoutSets.sessionExerciseId] }
    val sesBySession = ses.groupBy { it[SessionExercises.sessionId] }

    // 종목: 내 종목(삭제 제외) + 세션이 참조하는 삭제된 내 종목(참조가 끊기지 않게)
    val referencedExIds = ses.map { it[SessionExercises.exerciseId] }.distinct()
    val exercises = Exercises.selectAll()
        .where { (Exercises.ownerId eq uid) and (Exercises.deletedAt.isNull() or (Exercises.id inList referencedExIds)) }
        .orderBy(Exercises.createdAt).toList()

    // 프로그램: 내 프로그램(삭제 제외) + 내보내는 인스턴스가 가리키는 삭제된 내 프로그램
    val instProgramIds = instances.map { it[ProgramInstances.programId] }.distinct()
    val programs = Programs.selectAll()
        .where { (Programs.ownerId eq uid) and (Programs.deletedAt.isNull() or (Programs.id inList instProgramIds)) }
        .orderBy(Programs.createdAt).toList()
    val ownProgramIds = programs.map { it[Programs.id] }.toSet()
    val templateKeys: Map<UUID, String?> = if (instProgramIds.isEmpty()) emptyMap() else Programs.selectAll()
        .where { Programs.id inList instProgramIds }
        .associate { it[Programs.id] to it[Programs.templateKey] }

    val bodies = BodyMeasurements.selectAll()
        .where { (BodyMeasurements.userId eq uid) and BodyMeasurements.deletedAt.isNull() }
        .orderBy(BodyMeasurements.measuredAt).toList()

    val scheduled = ScheduledWorkouts.selectAll()
        .where { (ScheduledWorkouts.userId eq uid) and ScheduledWorkouts.deletedAt.isNull() }
        .orderBy(ScheduledWorkouts.plannedDate to SortOrder.ASC, ScheduledWorkouts.createdAt to SortOrder.ASC).toList()

    return buildJsonObject {
        put("schemaVersion", 1)
        put("note", "app=fitlog exportedAt=${Times.format(exportedAt)}")
        putJsonArray("exercises") {
            for (e in exercises) add(buildJsonObject {
                put("id", e[Exercises.id].toString())
                put("nameKo", e[Exercises.nameKo])
                e[Exercises.nameEn]?.let { put("nameEn", it) }
                put("type", e[Exercises.type])
                put("primaryMuscle", e[Exercises.primaryMuscle])
                putJsonArray("secondaryMuscles") { e[Exercises.secondaryMuscles].forEach { add(JsonPrimitive(it)) } }
            })
        }
        putJsonArray("programs") {
            for (p in programs) add(buildJsonObject {
                put("id", p[Programs.id].toString())
                put("definition", AppJson.parseToJsonElement(p[Programs.definition]))
            })
        }
        putJsonArray("startPrograms") {
            for (i in instances) add(buildJsonObject {
                put("id", i[ProgramInstances.id].toString())
                val pid = i[ProgramInstances.programId]
                putJsonObject("program") {
                    val key = templateKeys[pid]
                    if (pid !in ownProgramIds && key != null) put("templateKey", key) else put("id", pid.toString())
                }
                put("startDate", i[ProgramInstances.startDate].toString())
                put("tz", i[ProgramInstances.tz])
                put("skipPolicy", i[ProgramInstances.skipPolicy])
                val init = AppJson.parseToJsonElement(i[ProgramInstances.initialState]) as? JsonObject
                put("tm", init?.get("tm") as? JsonObject ?: JsonObject(emptyMap()))
                put("working", init?.get("working") as? JsonObject ?: JsonObject(emptyMap()))
            })
        }
        putJsonArray("sessions") {
            for (s in sessions) {
                val sid = s[WorkoutSessions.id]
                val exs = (sesBySession[sid] ?: emptyList()).mapNotNull { se ->
                    val ss = setsBySe[se[SessionExercises.id]] ?: return@mapNotNull null
                    se to ss
                }
                if (exs.isEmpty()) continue
                add(buildJsonObject {
                    put("id", sid.toString())
                    put("startedAt", Times.format(s[WorkoutSessions.startedAt]))
                    s[WorkoutSessions.endedAt]?.let { put("endedAt", Times.format(it)) }
                    put("tz", s[WorkoutSessions.tz])
                    s[WorkoutSessions.note]?.let { put("note", it) }
                    s[WorkoutSessions.scheduledWorkoutId]?.let { put("scheduledWorkoutId", it.toString()) }
                    val inst = s[WorkoutSessions.programInstanceId]
                    val planSeq = s[WorkoutSessions.planSeq]
                    if (inst != null && planSeq != null && inst in instanceIds && planSeq > (baseSeqByInstance[inst] ?: 0)) {
                        putJsonObject("program") {
                            put("instanceId", inst.toString())
                            put("planSeq", planSeq)
                        }
                    }
                    putJsonArray("exercises") {
                        for ((se, ss) in exs) add(buildJsonObject {
                            putJsonObject("exercise") { put("id", se[SessionExercises.exerciseId].toString()) }
                            se[SessionExercises.note]?.let { put("note", it) }
                            se[SessionExercises.supersetGroup]?.let { put("supersetGroup", it) }
                            putJsonArray("sets") { for (w in ss) add(setJson(w)) }
                        })
                    }
                })
            }
        }
        // 예정 운동이 없으면 키를 생략한다(이전 형식과 같게 유지)
        if (scheduled.isNotEmpty()) putJsonArray("scheduledWorkouts") {
            for (w in scheduled) add(buildJsonObject {
                put("id", w[ScheduledWorkouts.id].toString())
                put("plannedDate", w[ScheduledWorkouts.plannedDate].toString())
                put("title", w[ScheduledWorkouts.title])
                w[ScheduledWorkouts.note]?.let { put("note", it) }
                putJsonArray("items") {
                    for (item in decodeItems(w[ScheduledWorkouts.items])) add(buildJsonObject {
                        putJsonObject("exercise") { put("id", item.exerciseId.toString()) }
                        item.note?.let { n -> put("note", n) }
                        item.restSec?.let { r -> put("restSec", r) }
                        putJsonArray("sets") {
                            for (s in item.sets) add(buildJsonObject {
                                put("isWarmup", s.isWarmup)
                                s.targetWeightKg?.let { v -> put("targetWeightKg", v) }
                                s.targetReps?.let { v -> put("targetReps", v) }
                                s.targetRepsMax?.let { v -> put("targetRepsMax", v) }
                                s.targetRir?.let { v -> put("targetRir", v) }
                                s.targetRpe?.let { v -> put("targetRpe", v) }
                                s.targetDurationSec?.let { v -> put("targetDurationSec", v) }
                            })
                        }
                    })
                }
            })
        }
        putJsonArray("bodyMeasurements") {
            for (b in bodies) add(buildJsonObject {
                put("id", b[BodyMeasurements.id].toString())
                put("measuredAt", Times.format(b[BodyMeasurements.measuredAt]))
                put("weightKg", num(b[BodyMeasurements.weightKg]))
            })
        }
    }
}

private fun setJson(w: ResultRow): JsonObject = buildJsonObject {
    put("id", w[WorkoutSets.id].toString())
    put("isWarmup", w[WorkoutSets.isWarmup])
    put("setType", w[WorkoutSets.setType])
    w[WorkoutSets.weightKg]?.let { put("weightKg", num(it)) }
    w[WorkoutSets.addedWeightKg]?.let { put("addedWeightKg", num(it)) }
    w[WorkoutSets.reps]?.let { put("reps", it) }
    w[WorkoutSets.durationSec]?.let { put("durationSec", it) }
    w[WorkoutSets.distanceM]?.let { put("distanceM", num(it)) }
    w[WorkoutSets.rpe]?.let { put("rpe", num(it)) }
    w[WorkoutSets.rir]?.let { put("rir", it) }
    w[WorkoutSets.restSec]?.let { put("restSec", it) }
    w[WorkoutSets.note]?.let { put("note", it) }
}

// ------------------------------------------------------------------ CSV

internal fun csvField(v: String?): String {
    if (v == null) return ""
    return if (v.any { it == ',' || it == '"' || it == '\n' || it == '\r' }) "\"" + v.replace("\"", "\"\"") + "\"" else v
}

private fun zone(tz: String?): ZoneId = try {
    ZoneId.of(tz ?: DEFAULT_TZ)
} catch (e: Exception) {
    ZoneId.of(DEFAULT_TZ)
}

private fun local(at: Instant, tz: String?): String = localFmt.format(at.atZone(zone(tz)))

private fun StringBuilder.row(vararg cols: String?) {
    append(cols.joinToString(",") { csvField(it) }).append('\n')
}

private fun Transaction.setsCsv(uid: UUID): String {
    val sessions = WorkoutSessions.selectAll()
        .where { (WorkoutSessions.userId eq uid) and WorkoutSessions.deletedAt.isNull() }
        .orderBy(WorkoutSessions.startedAt).toList()
    val sb = StringBuilder(SETS_HEADER).append('\n')
    val sessionIds = sessions.map { it[WorkoutSessions.id] }
    if (sessionIds.isEmpty()) return sb.toString()
    val instIds = sessions.mapNotNull { it[WorkoutSessions.programInstanceId] }.distinct()
    val programNameByInstance: Map<UUID, String> = if (instIds.isEmpty()) emptyMap() else
        ProgramInstances.join(Programs, org.jetbrains.exposed.sql.JoinType.INNER, ProgramInstances.programId, Programs.id).selectAll()
            .where { ProgramInstances.id inList instIds }
            .associate { it[ProgramInstances.id] to it[Programs.name] }
    val ses = SessionExercises.selectAll()
        .where { (SessionExercises.sessionId inList sessionIds) and SessionExercises.deletedAt.isNull() }
        .orderBy(SessionExercises.position to SortOrder.ASC, SessionExercises.id to SortOrder.ASC).toList().groupBy { it[SessionExercises.sessionId] }
    val exerciseIds = ses.values.flatten().map { it[SessionExercises.exerciseId] }.distinct()
    val exById = if (exerciseIds.isEmpty()) emptyMap() else Exercises.selectAll().where { Exercises.id inList exerciseIds }
        .associateBy { it[Exercises.id] }
    val seIds = ses.values.flatten().map { it[SessionExercises.id] }
    val setsBySe = if (seIds.isEmpty()) emptyMap() else WorkoutSets.selectAll()
        .where { (WorkoutSets.sessionExerciseId inList seIds) and WorkoutSets.deletedAt.isNull() }
        .orderBy(WorkoutSets.position to SortOrder.ASC, WorkoutSets.id to SortOrder.ASC).toList().groupBy { it[WorkoutSets.sessionExerciseId] }

    for (s in sessions) {
        val sid = s[WorkoutSessions.id]
        val date = local(s[WorkoutSessions.startedAt], s[WorkoutSessions.tz])
        val program = s[WorkoutSessions.programInstanceId]?.let { programNameByInstance[it] }
        for (se in ses[sid] ?: emptyList()) {
            val ex = exById[se[SessionExercises.exerciseId]]
            val list = setsBySe[se[SessionExercises.id]] ?: continue
            list.forEachIndexed { idx, w ->
                sb.row(
                    date, sid.toString(), program, s[WorkoutSessions.planDayKey],
                    ex?.get(Exercises.nameKo), ex?.get(Exercises.nameEn), ex?.get(Exercises.type),
                    (idx + 1).toString(), w[WorkoutSets.isWarmup].toString(),
                    w[WorkoutSets.weightKg]?.let(::plain), w[WorkoutSets.addedWeightKg]?.let(::plain),
                    w[WorkoutSets.reps]?.toString(), w[WorkoutSets.rpe]?.let(::plain), w[WorkoutSets.rir]?.toString(),
                    w[WorkoutSets.restSec]?.toString(), w[WorkoutSets.durationSec]?.toString(),
                    w[WorkoutSets.distanceM]?.let(::plain), w[WorkoutSets.targetReps]?.toString(),
                    w[WorkoutSets.targetWeightKg]?.let(::plain), w[WorkoutSets.isAmrap].toString(),
                    w[WorkoutSets.note], se[SessionExercises.supersetGroup], w[WorkoutSets.setType],
                )
            }
        }
    }
    return sb.toString()
}

private fun Transaction.bodyCsv(uid: UUID): String {
    val tz = WorkoutSessions.selectAll()
        .where { (WorkoutSessions.userId eq uid) and WorkoutSessions.deletedAt.isNull() }
        .orderBy(WorkoutSessions.startedAt, SortOrder.DESC).limit(1)
        .firstOrNull()?.get(WorkoutSessions.tz)
    val sb = StringBuilder(BODY_HEADER).append('\n')
    BodyMeasurements.selectAll()
        .where { (BodyMeasurements.userId eq uid) and BodyMeasurements.deletedAt.isNull() }
        .orderBy(BodyMeasurements.measuredAt).forEach {
            sb.row(local(it[BodyMeasurements.measuredAt], tz), plain(it[BodyMeasurements.weightKg]), it[BodyMeasurements.sourceCol])
        }
    return sb.toString()
}
