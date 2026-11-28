package com.fitlog.importing

import com.fitlog.body.BodyMeasurement
import com.fitlog.body.softDeleteMeasurementRow
import com.fitlog.body.upsertMeasurementRow
import com.fitlog.core.AppJson
import com.fitlog.core.BodyMeasurements
import com.fitlog.core.ChangeSeq
import com.fitlog.core.Exercises
import com.fitlog.core.Ids
import com.fitlog.core.ImportBatches
import com.fitlog.core.ImportItems
import com.fitlog.core.ProgramInstances
import com.fitlog.core.Programs
import com.fitlog.core.ScheduledWorkouts
import com.fitlog.core.Times
import com.fitlog.core.WorkoutSessions
import com.fitlog.core.dbQuery
import com.fitlog.core.lockUser
import com.fitlog.engine.PlannedDay
import com.fitlog.engine.ProgramDefinition
import com.fitlog.engine.ProgramEngine
import com.fitlog.engine.ProgramState
import com.fitlog.program.instance.engineSettings
import com.fitlog.program.instance.replayInstances
import com.fitlog.session.Session
import com.fitlog.session.SessionExercise
import com.fitlog.session.WorkoutSet
import com.fitlog.scheduled.softDeleteScheduledRow
import com.fitlog.scheduled.upsertScheduledRow
import com.fitlog.session.putSession
import com.fitlog.session.sessionInstanceId
import com.fitlog.session.softDeleteSession
import org.jetbrains.exposed.sql.SortOrder
import org.jetbrains.exposed.sql.SqlExpressionBuilder.eq
import org.jetbrains.exposed.sql.SqlExpressionBuilder.isNull
import org.jetbrains.exposed.sql.Transaction
import org.jetbrains.exposed.sql.and
import org.jetbrains.exposed.sql.batchInsert
import org.jetbrains.exposed.sql.insert
import org.jetbrains.exposed.sql.selectAll
import org.jetbrains.exposed.sql.update
import java.time.Duration
import java.util.UUID

/** import.md 파이프라인: 검증 → 이름 해석 → 충돌 탐지 → (해결됨) 한 트랜잭션 저장 */
object ImportPipeline : Importer {
    /** 테스트용: 저장 단계("exercises", "programs", "instances", "sessions", "bodies", "scheduled")가 끝날 때마다 불린다. 던지면 전체가 롤백된다 */
    @Volatile
    internal var afterPhase: ((String) -> Unit)? = null

    override suspend fun preview(ctx: ImportContext, req: ImportRequest): ImportPreview =
        dbQuery { Analyzer(ctx, req).run().preview() }

    override suspend fun import(ctx: ImportContext, req: ImportRequest): ImportOutcome = dbQuery {
        lockUser(ctx.userId)
        val a = Analyzer(ctx, req).run()
        val out: ImportOutcome =
            if (a.unresolved.isNotEmpty()) ImportOutcome.NeedsResolution(a.preview()) else persist(ctx, a)
        out
    }
}

private class Item(val entity: String, val id: UUID, val action: String, val label: String?)

private fun Transaction.persist(ctx: ImportContext, a: Analyzer): ImportOutcome.Saved {
    val uid = ctx.userId
    val p = a.plan
    if (p.isEmpty()) {
        // 바뀌는 것이 없다: 같은 묶음을 다시 보낸 경우. 되돌리지 않은 같은 묶음이 있으면 그것을 돌려준다
        val prev = ImportBatches.selectAll()
            .where { (ImportBatches.userId eq uid) and (ImportBatches.bundleHash eq a.hash) and ImportBatches.revertedAt.isNull() }
            .orderBy(ImportBatches.createdAt to SortOrder.DESC, ImportBatches.id to SortOrder.DESC).limit(1).firstOrNull()
        val batch = prev?.toImportBatch() ?: ImportBatch(
            id = detId(uid, a.hash, "/empty"), createdAt = Times.now(), channel = ctx.channel.name,
            clientName = ctx.clientName, note = a.bundle.note, summary = emptyMap(),
        )
        return ImportOutcome.Saved(batch, false)
    }

    val hook = ImportPipeline.afterPhase
    val now = Times.now()
    val batchId = Ids.newId()
    val src = if (ctx.channel == ImportChannel.MCP) "AI_MCP" else "AI_JSON"
    ImportBatches.insert {
        it[id] = batchId
        it[userId] = uid
        it[channel] = ctx.channel.name
        it[clientName] = ctx.clientName
        it[aiConnectionId] = ctx.aiConnectionId
        it[note] = a.bundle.note
        it[bundleHash] = a.hash
        it[summary] = "{}"
        it[createdAt] = now
    }
    val items = mutableListOf<Item>()
    val affected = mutableSetOf<UUID>()

    // ---- 종목
    for (w in p.exercises) {
        val n = Exercises.update({ (Exercises.id eq w.id) and (Exercises.ownerId eq uid) }) {
            it[nameKo] = w.nameKo
            it[nameEn] = w.nameEn
            it[type] = w.type
            it[primaryMuscle] = w.primaryMuscle
            it[secondaryMuscles] = w.secondary
            it[deletedAt] = null
            it[updatedAt] = now
            it[serverSeq] = ChangeSeq.next
            it[importBatchId] = batchId
            it[sourceCol] = src
        }
        if (n == 0) Exercises.insert {
            it[id] = w.id
            it[ownerId] = uid
            it[nameKo] = w.nameKo
            it[nameEn] = w.nameEn
            it[type] = w.type
            it[primaryMuscle] = w.primaryMuscle
            it[secondaryMuscles] = w.secondary
            it[createdAt] = now
            it[updatedAt] = now
            it[serverSeq] = ChangeSeq.next
            it[importBatchId] = batchId
            it[sourceCol] = src
        }
        items += Item("exercise", w.id, "CREATED", w.nameKo)
    }
    hook?.invoke("exercises")

    // ---- 프로그램
    for (o in p.replacedPrograms) {
        Programs.update({ (Programs.id eq o.id) and (Programs.ownerId eq uid) }) {
            it[deletedAt] = now
            it[updatedAt] = now
        }
        items += Item("program", o.id, "REPLACED_OLD", o.label)
    }
    for (w in p.programs) {
        val text = AppJson.encodeToString(ProgramDefinition.serializer(), w.def)
        val n = Programs.update({ (Programs.id eq w.id) and (Programs.ownerId eq uid) }) {
            it[name] = w.name
            it[definition] = text
            it[sourceCol] = src
            it[updatedAt] = now
            it[deletedAt] = null
            it[importBatchId] = batchId
        }
        if (n == 0) Programs.insert {
            it[id] = w.id
            it[ownerId] = uid
            it[name] = w.name
            it[definition] = text
            it[sourceCol] = src
            it[createdAt] = now
            it[updatedAt] = now
            it[importBatchId] = batchId
        }
        items += Item("program", w.id, "CREATED", w.name)
    }
    hook?.invoke("programs")

    // ---- 인스턴스 시작
    for (w in p.instances) {
        val defText = AppJson.encodeToString(ProgramDefinition.serializer(), w.def)
        val stateText = AppJson.encodeToString(ProgramState.serializer(), w.initial)
        val n = ProgramInstances.update({ (ProgramInstances.id eq w.id) and (ProgramInstances.userId eq uid) }) {
            it[programId] = w.programId
            it[definition] = defText
            it[status] = "ACTIVE"
            it[skipPolicy] = w.policy
            it[startDate] = w.startDate
            it[tz] = w.tz
            it[initialState] = stateText
            it[state] = stateText
            it[stateSeq] = w.initial.seq
            it[updatedAt] = now
            it[deletedAt] = null
            it[importBatchId] = batchId
        }
        if (n == 0) ProgramInstances.insert {
            it[id] = w.id
            it[userId] = uid
            it[programId] = w.programId
            it[definition] = defText
            it[status] = "ACTIVE"
            it[skipPolicy] = w.policy
            it[startDate] = w.startDate
            it[tz] = w.tz
            it[initialState] = stateText
            it[state] = stateText
            it[stateSeq] = w.initial.seq
            it[createdAt] = now
            it[updatedAt] = now
            it[importBatchId] = batchId
        }
        affected += w.id
        items += Item("program_instance", w.id, "CREATED", w.label)
    }
    hook?.invoke("instances")

    // ---- 예정 운동
    for (o in p.replacedScheduled) {
        softDeleteScheduledRow(uid, o.id, now)
        items += Item("scheduled_workout", o.id, "REPLACED_OLD", o.label)
    }
    for (w in p.scheduled) {
        upsertScheduledRow(uid, w.workout, now, src, batchId)
        ScheduledWorkouts.update({ (ScheduledWorkouts.id eq w.id) and (ScheduledWorkouts.userId eq uid) }) { it[importBatchId] = batchId }
        items += Item("scheduled_workout", w.id, "CREATED", w.label)
    }
    hook?.invoke("scheduled")

    // ---- 세션
    for (o in p.replacedSessions) {
        sessionInstanceId(o.id)?.let { affected += it }
        softDeleteSession(o.id, now)
        items += Item("workout_session", o.id, "REPLACED_OLD", o.label)
    }
    val plans = HashMap<UUID, List<PlannedDay>>()
    fun dayFor(ws: WSession): PlannedDay? {
        val link = ws.link ?: return null
        val seq = ws.planSeq ?: return null
        val list = plans.getOrPut(link.id) {
            val maxOffset = p.sessions.filter { it.link?.id == link.id }.maxOf { (it.planSeq ?: 0) - link.startSeq }.coerceAtLeast(1)
            ProgramEngine.plan(link.def, link.baseState, maxOffset, engineSettings(uid, link.def))
        }
        return list.getOrNull(seq - link.startSeq - 1)
    }
    for (ws in p.sessions) {
        val day = dayFor(ws)
        val used = mutableSetOf<Int>()
        var k = 0
        val exs = ws.exercises.map { e ->
            val pi = day?.exercises?.indices?.firstOrNull { it !in used && day.exercises[it].exerciseId.equals(e.exerciseId.toString(), ignoreCase = true) }
            if (pi != null) used += pi
            val pe = pi?.let { day!!.exercises[it] }
            SessionExercise(
                id = e.id, exerciseId = e.exerciseId, position = e.position, note = e.note,
                sets = e.sets.mapIndexed { si, s ->
                    k++
                    val ps = pe?.sets?.getOrNull(si)
                    val doneAt = ws.startedAt.plus(Duration.ofMinutes(3L * k)).let { if (it.isAfter(ws.endedAt)) ws.endedAt else it }
                    WorkoutSet(
                        id = s.id, position = s.position, isWarmup = s.isWarmup, weightKg = s.weightKg, addedWeightKg = s.addedWeightKg,
                        reps = s.reps, durationSec = s.durationSec, distanceM = s.distanceM, rpe = s.rpe, rir = s.rir, restSec = s.restSec,
                        note = s.note, completedAt = doneAt,
                        plannedSetKey = ps?.plannedSetKey, targetReps = ps?.targetReps, targetWeightKg = ps?.targetWeightKg,
                        isAmrap = ps?.isAmrap ?: false,
                    )
                },
                liftKey = pe?.key, accessory = pe?.accessory ?: false,
            )
        }
        val body = Session(
            id = ws.id, startedAt = ws.startedAt, endedAt = ws.endedAt, tz = ws.tz, note = ws.note, exercises = exs,
            programInstanceId = ws.link?.id, planSeq = if (ws.link != null) ws.planSeq else null, planDayKey = day?.dayKey,
        )
        putSession(uid, ws.id, body, ProgramEngine)
        WorkoutSessions.update({ WorkoutSessions.id eq ws.id }) {
            it[sourceCol] = src
            it[importBatchId] = batchId
            it[serverSeq] = ChangeSeq.next
            it[scheduledWorkoutId] = ws.scheduledId
        }
        ws.link?.id?.let { affected += it }
        items += Item("workout_session", ws.id, "CREATED", ws.label)
    }
    hook?.invoke("sessions")

    // ---- 체중
    for (o in p.replacedBodies) {
        softDeleteMeasurementRow(o.id, now)
        items += Item("body_measurement", o.id, "REPLACED_OLD", o.label)
    }
    for (w in p.bodies) {
        upsertMeasurementRow(uid, BodyMeasurement(w.id, w.measuredAt, w.weightKg, src), now)
        BodyMeasurements.update({ BodyMeasurements.id eq w.id }) { it[importBatchId] = batchId }
        items += Item("body_measurement", w.id, "CREATED", w.label)
    }
    hook?.invoke("bodies")

    replayInstances(ProgramEngine, uid, affected)

    ImportItems.batchInsert(items) { i ->
        this[ImportItems.id] = Ids.newId()
        this[ImportItems.batchId] = batchId
        this[ImportItems.entity] = i.entity
        this[ImportItems.entityId] = i.id
        this[ImportItems.action] = i.action
        this[ImportItems.label] = i.label
    }
    val summary = linkedMapOf<String, Int>()
    fun put(k: String, n: Int) { if (n > 0) summary[k] = n }
    put("exercises", p.exercises.size)
    put("programs", p.programs.size)
    put("programInstances", p.instances.size)
    put("sessions", p.sessions.size)
    put("bodyMeasurements", p.bodies.size)
    put("scheduledWorkouts", p.scheduled.size)
    put(
        "replaced",
        p.replacedPrograms.size + p.replacedSessions.size + p.replacedBodies.size + p.replacedScheduled.size +
            p.exercises.count { it.replace } + p.programs.count { it.replace } + p.sessions.count { it.replace } + p.bodies.count { it.replace } +
            p.scheduled.count { it.replace },
    )
    ImportBatches.update({ ImportBatches.id eq batchId }) { it[ImportBatches.summary] = AppJson.encodeToString(summary) }
    val row = ImportBatches.selectAll().where { ImportBatches.id eq batchId }.single()
    return ImportOutcome.Saved(row.toImportBatch(), true)
}
