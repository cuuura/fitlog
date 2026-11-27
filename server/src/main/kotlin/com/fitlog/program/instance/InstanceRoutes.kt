package com.fitlog.program.instance

import com.fitlog.core.ApiException
import com.fitlog.core.AppConfig
import com.fitlog.core.AppJson
import com.fitlog.core.ErrorCode
import com.fitlog.core.Exercises
import com.fitlog.core.Ids
import com.fitlog.core.ProgramAccessories
import com.fitlog.core.ProgramAdjustments
import com.fitlog.core.ProgramInstances
import com.fitlog.core.ProgramSkips
import com.fitlog.core.Programs
import com.fitlog.core.Times
import com.fitlog.core.WorkoutSessions
import com.fitlog.core.ChangeSeq
import com.fitlog.core.dbQuery
import com.fitlog.core.lockUser
import com.fitlog.core.notFound
import com.fitlog.core.userId
import com.fitlog.core.validation
import com.fitlog.engine.Needs
import com.fitlog.engine.PlannedExercise
import com.fitlog.engine.PlannedSet
import com.fitlog.engine.ProgramCalculator
import com.fitlog.engine.ProgramDefinition
import com.fitlog.engine.ProgramState
import com.fitlog.engine.SkipPolicy
import com.fitlog.session.checkTz
import io.ktor.http.HttpStatusCode
import io.ktor.server.request.receive
import io.ktor.server.response.respond
import io.ktor.server.routing.Route
import io.ktor.server.routing.delete
import io.ktor.server.routing.get
import io.ktor.server.routing.patch
import io.ktor.server.routing.post
import io.ktor.server.routing.put
import io.ktor.server.routing.route
import org.jetbrains.exposed.sql.ResultRow
import org.jetbrains.exposed.sql.SortOrder
import org.jetbrains.exposed.sql.SqlExpressionBuilder.eq
import org.jetbrains.exposed.sql.SqlExpressionBuilder.inList
import org.jetbrains.exposed.sql.SqlExpressionBuilder.isNull
import org.jetbrains.exposed.sql.SqlExpressionBuilder.neq
import org.jetbrains.exposed.sql.SqlExpressionBuilder.notInList
import org.jetbrains.exposed.sql.Transaction
import org.jetbrains.exposed.sql.and
import org.jetbrains.exposed.sql.deleteWhere
import org.jetbrains.exposed.sql.insert
import org.jetbrains.exposed.sql.or
import org.jetbrains.exposed.sql.selectAll
import org.jetbrains.exposed.sql.update
import java.math.BigDecimal
import java.time.LocalDate
import java.time.format.DateTimeParseException
import java.util.UUID

private val STATUSES = setOf("ACTIVE", "PAUSED", "FINISHED")

private fun conflict(msg: String, field: String? = null): Nothing = throw ApiException(ErrorCode.CONFLICT, msg, field)

private fun parseSkipPolicy(s: String, field: String = "skipPolicy"): SkipPolicy =
    runCatching { SkipPolicy.valueOf(s) }.getOrNull() ?: validation("$field must be SHIFT or FIXED_DATE", field)

private fun requireWeekdays(def: ProgramDefinition, field: String = "skipPolicy") {
    val bad = def.days.indexOfFirst { weekdayOf(it.weekday) == null }
    if (bad >= 0) validation("FIXED_DATE requires weekday on every day (days[$bad] has none)", field)
}

private fun ProgramState.toView() = InstanceState(tm, working, stage, failStreak, week, cycle, seq)

/** 계획 + 인스턴스 보조운동 + (FIXED_DATE) 예정일. 호출자는 state 가 최신이라고 보장한다 */
internal fun Transaction.plannedWorkouts(
    engine: ProgramCalculator, ctx: InstanceCtx, state: ProgramState, count: Int, anchor: LocalDate?,
): List<PlannedWorkout> {
    val settings = engineSettings(ctx.userId, ctx.definition)
    val plan = engine.plan(ctx.definition, state, count, settings)
    if (plan.isEmpty()) return emptyList()
    val accessories = ProgramAccessories.selectAll()
        .where { (ProgramAccessories.instanceId eq ctx.id) and ProgramAccessories.deletedAt.isNull() }
        .orderBy(ProgramAccessories.position to SortOrder.ASC, ProgramAccessories.id to SortOrder.ASC)
        .toList().groupBy { it[ProgramAccessories.dayKey] }
    var prev: LocalDate? = null
    return plan.mapIndexed { i, p ->
        val scheduled = if (ctx.policy == SkipPolicy.FIXED_DATE) {
            weekdayOf(ctx.definition.days.getOrNull(p.dayIndex)?.weekday)?.let { wd ->
                val from = if (i == 0) (anchor?.plusDays(1) ?: ctx.startDate) else prev!!.plusDays(1)
                nextOnOrAfter(from, wd).also { prev = it }
            }
        } else null
        val acc = accessories[p.dayKey].orEmpty().map { a ->
            val aid = a[ProgramAccessories.id]
            val w = a[ProgramAccessories.weightKg]?.toDouble()
            PlannedExercise(
                key = "acc:$aid",
                exerciseId = a[ProgramAccessories.exerciseId].toString(),
                accessory = true,
                sets = (0 until a[ProgramAccessories.sets]).map { j ->
                    PlannedSet("acc:$aid.$j", a[ProgramAccessories.reps], w, isAmrap = false, isWarmup = false)
                },
            )
        }
        PlannedWorkout(
            instanceId = ctx.id, planSeq = p.planSeq, dayIndex = p.dayIndex, dayKey = p.dayKey, dayName = p.dayName,
            week = p.week, cycle = p.cycle, scheduledDate = scheduled?.toString(), confirmed = p.confirmed,
            exercises = p.exercises + acc,
        )
    }
}

/**
 * 인스턴스 응답. FIXED_DATE 는 조회 때마다 replay(지난 예정일 자동 건너뛰기 포함)로 최신 상태를 만들고,
 * SHIFT 는 저장된 state 캐시를 쓴다. 호출자는 lockUser 를 먼저 호출한다.
 */
internal fun Transaction.instanceView(engine: ProgramCalculator, row: ResultRow, withNext: Boolean = true): Instance {
    var r = row
    var state: ProgramState
    var anchor: LocalDate? = null
    if (r[ProgramInstances.skipPolicy] == "FIXED_DATE") {
        val res = replayInstance(engine, r)
        state = res.state
        anchor = res.lastEventDate
        r = loadInstanceRow(r[ProgramInstances.userId], r[ProgramInstances.id])!!
    } else {
        state = AppJson.decodeFromString(r[ProgramInstances.state])
    }
    val ctx = InstanceCtx(r)
    val next = if (withNext) plannedWorkouts(engine, ctx, state, 1, anchor).firstOrNull() else null
    return Instance(
        id = ctx.id, programId = r[ProgramInstances.programId], name = ctx.definition.name, status = ctx.status,
        skipPolicy = ctx.policy.name, startDate = ctx.startDate.toString(), state = state.toView(), next = next,
    )
}

private fun Transaction.ownInstance(userId: UUID, id: UUID): ResultRow =
    loadInstanceRow(userId, id) ?: notFound("program instance not found")

private fun Transaction.visibleExercise(userId: UUID, id: UUID): Boolean =
    Exercises.selectAll().where {
        (Exercises.id eq id) and Exercises.deletedAt.isNull() and (Exercises.ownerId.isNull() or (Exercises.ownerId eq userId))
    }.any()

private fun Transaction.startInstance(engine: ProgramCalculator, uid: UUID, body: StartInstance): Instance {
    lockUser(uid)
    val existing = ProgramInstances.selectAll().where { ProgramInstances.id eq body.id }.singleOrNull()
    if (existing != null) {
        if (existing[ProgramInstances.userId] != uid || existing[ProgramInstances.deletedAt] != null) conflict("id already in use", "id")
        return instanceView(engine, existing) // 같은 id 재전송은 만들어진 그대로(멱등)
    }
    val startDate = try {
        LocalDate.parse(body.startDate)
    } catch (e: DateTimeParseException) {
        validation("startDate must be yyyy-MM-dd", "startDate")
    }
    checkTz(body.tz)
    val policy = body.skipPolicy?.let { parseSkipPolicy(it) } ?: SkipPolicy.SHIFT

    val program = Programs.selectAll().where {
        (Programs.id eq body.programId) and Programs.deletedAt.isNull() and (Programs.ownerId.isNull() or (Programs.ownerId eq uid))
    }.singleOrNull() ?: validation("unknown program", "programId")
    val def: ProgramDefinition = try {
        AppJson.decodeFromString(program[Programs.definition])
    } catch (e: IllegalArgumentException) {
        throw IllegalStateException("stored program definition is invalid: ${program[Programs.id]}", e)
    }
    if (policy == SkipPolicy.FIXED_DATE) requireWeekdays(def)

    (body.tm.entries + body.working.entries).forEach { (k, v) ->
        if (!v.isFinite() || v < 0 || v > 9999.99) validation("weight must be between 0 and 9999.99", "tm.$k")
    }
    val optionalKeys = engine.optionalInputs(def)
    engine.requiredInputs(def).forEach { (key, need) ->
        if (key in optionalKeys) return@forEach
        when (need) {
            Needs.TM -> if (key !in body.tm) validation("tm.$key is required", "tm.$key")
            Needs.WORKING -> if (key !in body.working) validation("working.$key is required", "working.$key")
        }
    }
    val initial = try {
        engine.initialState(def, body.tm, body.working)
    } catch (e: IllegalArgumentException) {
        validation(e.message ?: "invalid initial values", "tm")
    }
    val stateJson = AppJson.encodeToString(ProgramState.serializer(), initial)
    val now = Times.now()
    ProgramInstances.insert {
        it[id] = body.id
        it[userId] = uid
        it[programId] = body.programId
        it[definition] = program[Programs.definition]
        it[status] = "ACTIVE"
        it[skipPolicy] = policy.name
        it[ProgramInstances.startDate] = startDate
        it[tz] = body.tz
        it[initialState] = stateJson
        it[state] = stateJson
        it[stateSeq] = initial.seq
        it[createdAt] = now
        it[updatedAt] = now
    }
    return instanceView(engine, loadInstanceRow(uid, body.id)!!)
}

internal fun Transaction.patchInstance(engine: ProgramCalculator, uid: UUID, id: UUID, body: PatchInstance): Instance {
    lockUser(uid)
    var row = ownInstance(uid, id)
    val status = body.status?.also { if (it !in STATUSES) validation("status must be ACTIVE, PAUSED or FINISHED", "status") }
    val policy = body.skipPolicy?.let { parseSkipPolicy(it) }
    val ctx = InstanceCtx(row)
    if (policy == SkipPolicy.FIXED_DATE) requireWeekdays(ctx.definition)
    val adjust = body.adjust
    if (adjust != null) {
        if (adjust.tm.isEmpty() && adjust.working.isEmpty()) validation("adjust must have tm or working values", "adjust")
        adjust.tm.forEach { (k, v) ->
            if (k !in ctx.state.tm) validation("unknown tm key", "adjust.tm.$k")
            if (!v.isFinite() || v < 0 || v > 9999.99) validation("weight must be between 0 and 9999.99", "adjust.tm.$k")
        }
        adjust.working.forEach { (k, v) ->
            if (k !in ctx.state.working) validation("unknown working key", "adjust.working.$k")
            if (!v.isFinite() || v < 0 || v > 9999.99) validation("weight must be between 0 and 9999.99", "adjust.working.$k")
        }
    }
    var needsReplay = false
    if (status != null || policy != null) {
        ProgramInstances.update({ ProgramInstances.id eq id }) {
            status?.let { s -> it[ProgramInstances.status] = s }
            policy?.let { p -> it[skipPolicy] = p.name }
            it[updatedAt] = Times.now()
        }
        needsReplay = true
    }
    if (adjust != null) {
        // 현재 회차 수 뒤에 적용한다(조정 뒤에 쌓이는 회차는 조정된 값에서 이어진다)
        val seq = replayInstance(engine, loadInstanceRow(uid, id)!!).state.seq
        ProgramAdjustments.insert {
            it[ProgramAdjustments.id] = Ids.newId()
            it[instanceId] = id
            it[afterSeq] = seq
            it[tm] = AppJson.encodeToString(adjust.tm)
            it[working] = AppJson.encodeToString(adjust.working)
            it[createdAt] = Times.now()
        }
        needsReplay = true
    }
    row = loadInstanceRow(uid, id)!!
    if (needsReplay) replayInstance(engine, row)
    return instanceView(engine, loadInstanceRow(uid, id)!!)
}

private fun Transaction.skipInstance(engine: ProgramCalculator, uid: UUID, id: UUID, planSeq: Int): Instance {
    lockUser(uid)
    val row = ownInstance(uid, id)
    if (row[ProgramInstances.status] == "FINISHED") conflict("instance is finished")
    val res = replayInstance(engine, row) // 최신 상태(FIXED_DATE 자동 건너뛰기 포함)로 확인
    if (planSeq != res.state.seq + 1) conflict("planSeq must be ${res.state.seq + 1}", "planSeq")
    val tz = row[ProgramInstances.tz]
    ProgramSkips.insert {
        it[ProgramSkips.id] = Ids.newId()
        it[instanceId] = id
        it[ProgramSkips.planSeq] = planSeq
        it[dayIndex] = res.state.nextDayIndex
        it[skippedOn] = InstanceClock.today(tz)
        it[auto] = false
        it[createdAt] = Times.now()
    }
    replayInstance(engine, loadInstanceRow(uid, id)!!)
    return instanceView(engine, loadInstanceRow(uid, id)!!)
}

internal fun Transaction.deleteInstance(uid: UUID, id: UUID) {
    lockUser(uid)
    val row = ProgramInstances.selectAll().where { ProgramInstances.id eq id }.singleOrNull() ?: return
    if (row[ProgramInstances.userId] != uid) notFound("program instance not found")
    // 하드 삭제. 연결된 세션은 남기고 연결만 끊는다(FK SET NULL 과 같은 결과지만, 앱이 pull 로 알 수 있게 server_seq 도 올린다)
    WorkoutSessions.update({ WorkoutSessions.programInstanceId eq id }) {
        it[programInstanceId] = null
        it[serverSeq] = ChangeSeq.next
    }
    ProgramInstances.deleteWhere { ProgramInstances.id eq id }
}

private fun Transaction.accessories(id: UUID): List<Accessory> =
    ProgramAccessories.selectAll()
        .where { (ProgramAccessories.instanceId eq id) and ProgramAccessories.deletedAt.isNull() }
        .orderBy(ProgramAccessories.dayKey to SortOrder.ASC, ProgramAccessories.position to SortOrder.ASC, ProgramAccessories.id to SortOrder.ASC)
        .map {
            Accessory(
                it[ProgramAccessories.id], it[ProgramAccessories.dayKey], it[ProgramAccessories.exerciseId],
                it[ProgramAccessories.position], it[ProgramAccessories.sets], it[ProgramAccessories.reps],
                it[ProgramAccessories.weightKg]?.toDouble(),
            )
        }

private fun Transaction.replaceAccessories(uid: UUID, id: UUID, body: List<Accessory>): List<Accessory> {
    lockUser(uid)
    val ctx = InstanceCtx(ownInstance(uid, id))
    val dayKeys = ctx.definition.days.map { it.key }.toSet()
    val seen = HashSet<UUID>()
    body.forEachIndexed { i, a ->
        val p = "[$i]"
        if (!seen.add(a.id)) validation("duplicate id", "$p.id")
        if (a.dayKey !in dayKeys) validation("unknown dayKey", "$p.dayKey")
        if (a.position < 0) validation("position must be >= 0", "$p.position")
        if (a.sets !in 1..20) validation("sets must be 1..20", "$p.sets")
        if (a.reps !in 0..100) validation("reps must be 0..100", "$p.reps")
        a.weightKg?.let { if (!it.isFinite() || it < 0 || it > 9999.99) validation("weightKg must be between 0 and 9999.99", "$p.weightKg") }
        if (!visibleExercise(uid, a.exerciseId)) validation("unknown exercise", "$p.exerciseId")
        val other = ProgramAccessories.selectAll()
            .where { (ProgramAccessories.id eq a.id) and (ProgramAccessories.instanceId neq id) }.any()
        if (other) validation("id is used by another instance", "$p.id")
    }
    val now = Times.now()
    body.forEach { a ->
        val w = a.weightKg?.let { BigDecimal.valueOf(it).setScale(2, java.math.RoundingMode.HALF_UP) }
        val n = ProgramAccessories.update({ ProgramAccessories.id eq a.id }) {
            it[dayKey] = a.dayKey
            it[exerciseId] = a.exerciseId
            it[position] = a.position
            it[sets] = a.sets
            it[reps] = a.reps
            it[weightKg] = w
            it[updatedAt] = now
            it[deletedAt] = null
        }
        if (n == 0) ProgramAccessories.insert {
            it[ProgramAccessories.id] = a.id
            it[instanceId] = id
            it[dayKey] = a.dayKey
            it[exerciseId] = a.exerciseId
            it[position] = a.position
            it[sets] = a.sets
            it[reps] = a.reps
            it[weightKg] = w
            it[updatedAt] = now
        }
    }
    ProgramAccessories.update({
        (ProgramAccessories.instanceId eq id) and ProgramAccessories.deletedAt.isNull() and
            (if (seen.isEmpty()) org.jetbrains.exposed.sql.Op.TRUE else ProgramAccessories.id notInList seen)
    }) {
        it[deletedAt] = now
        it[updatedAt] = now
    }
    return accessories(id)
}

/** A3 소유 (v0.2). 경로는 /v1 아래 상대 경로로 등록한다 */
fun Route.instanceRoutes(config: AppConfig) {
    route("/program-instances") {
        get {
            val uid = call.userId
            val status = call.request.queryParameters["status"]?.also {
                if (it !in STATUSES) validation("status must be ACTIVE, PAUSED or FINISHED", "status")
            }
            val list = dbQuery {
                lockUser(uid)
                ProgramInstances.selectAll()
                    .where {
                        val base = (ProgramInstances.userId eq uid) and ProgramInstances.deletedAt.isNull()
                        if (status != null) base and (ProgramInstances.status eq status) else base
                    }
                    .orderBy(ProgramInstances.createdAt to SortOrder.DESC, ProgramInstances.id to SortOrder.DESC)
                    .toList().map { instanceView(config.engine, it) }
            }
            call.respond(list)
        }

        post {
            val uid = call.userId
            val body = call.receive<StartInstance>()
            call.respond(HttpStatusCode.Created, dbQuery { startInstance(config.engine, uid, body) })
        }

        route("/{id}") {
            get {
                val uid = call.userId
                val id = Ids.parse(call.parameters["id"])
                call.respond(dbQuery { lockUser(uid); instanceView(config.engine, ownInstance(uid, id)) })
            }

            patch {
                val uid = call.userId
                val id = Ids.parse(call.parameters["id"])
                val body = call.receive<PatchInstance>()
                call.respond(dbQuery { patchInstance(config.engine, uid, id, body) })
            }

            delete {
                val uid = call.userId
                val id = Ids.parse(call.parameters["id"])
                dbQuery { deleteInstance(uid, id) }
                call.respond(HttpStatusCode.NoContent)
            }

            get("/plan") {
                val uid = call.userId
                val id = Ids.parse(call.parameters["id"])
                val count = call.request.queryParameters["count"]?.let {
                    it.toIntOrNull()?.takeIf { n -> n in 1..8 } ?: validation("count must be between 1 and 8", "count")
                } ?: 3
                val plan = dbQuery {
                    lockUser(uid)
                    var row = ownInstance(uid, id)
                    var anchor: LocalDate? = null
                    val state: ProgramState
                    if (row[ProgramInstances.skipPolicy] == "FIXED_DATE") {
                        val res = replayInstance(config.engine, row)
                        state = res.state
                        anchor = res.lastEventDate
                        row = loadInstanceRow(uid, id)!!
                    } else {
                        state = AppJson.decodeFromString(row[ProgramInstances.state])
                    }
                    plannedWorkouts(config.engine, InstanceCtx(row), state, count, anchor)
                }
                call.respond(plan)
            }

            post("/skip") {
                val uid = call.userId
                val id = Ids.parse(call.parameters["id"])
                val body = call.receive<SkipRequest>()
                call.respond(dbQuery { skipInstance(config.engine, uid, id, body.planSeq) })
            }

            route("/accessories") {
                get {
                    val uid = call.userId
                    val id = Ids.parse(call.parameters["id"])
                    call.respond(dbQuery { ownInstance(uid, id); accessories(id) })
                }
                put {
                    val uid = call.userId
                    val id = Ids.parse(call.parameters["id"])
                    val body = call.receive<List<Accessory>>()
                    call.respond(dbQuery { replaceAccessories(uid, id, body) })
                }
            }
        }
    }
}
