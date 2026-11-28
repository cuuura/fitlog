package com.fitlog.program.instance

import com.fitlog.core.ApiException
import com.fitlog.core.AppJson
import com.fitlog.core.ErrorCode
import com.fitlog.core.ErrorDetail
import com.fitlog.core.ProgramAdjustments
import com.fitlog.core.ProgramInstances
import com.fitlog.core.Times
import com.fitlog.core.WorkoutSessions
import com.fitlog.core.lockUser
import com.fitlog.core.notFound
import com.fitlog.core.validation
import com.fitlog.engine.ExerciseRef
import com.fitlog.engine.Needs
import com.fitlog.engine.PlannedExercise
import com.fitlog.engine.ProgramCalculator
import com.fitlog.engine.ProgramDefinition
import com.fitlog.engine.ProgramState
import com.fitlog.engine.Rule
import com.fitlog.program.catalog.ExerciseIndex
import com.fitlog.program.schema.ProgramValidator
import com.fitlog.program.schema.orThrow
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import org.jetbrains.exposed.sql.SqlExpressionBuilder.eq
import org.jetbrains.exposed.sql.SqlExpressionBuilder.isNull
import org.jetbrains.exposed.sql.SqlExpressionBuilder.lessEq
import org.jetbrains.exposed.sql.Transaction
import org.jetbrains.exposed.sql.and
import org.jetbrains.exposed.sql.deleteWhere
import org.jetbrains.exposed.sql.selectAll
import org.jetbrains.exposed.sql.update
import java.util.UUID
import kotlin.math.min

/** v1.2 edit.md 3·4절 정의 검증(POST /v1/programs 와 같은 검증기). DB 읽기는 자체 트랜잭션 */
suspend fun validateDefinition(uid: UUID, definition: JsonElement): ProgramDefinition =
    ProgramValidator.validate(definition, ExerciseIndex.load(uid).resolver).orThrow()

private val DAY_ORDER_SERIALIZER = MapSerializer(String.serializer(), ListSerializer(Int.serializer()))

/** 계획 종목의 정의 인덱스: 첫 세트 plannedSetKey "<dayKey>.<종목 인덱스>.<세트>" 의 가운데 값 */
private fun exerciseIndexOf(e: PlannedExercise): Int? =
    e.sets.firstOrNull()?.plannedSetKey?.substringBeforeLast('.', "")?.substringAfterLast('.', "")?.toIntOrNull()

/** 운동 순서 기억(9.5절): order 순서로 정렬. order 에 없거나 인덱스를 못 읽는 종목은 원래 순서대로 뒤에 둔다 */
internal fun applyDayOrder(exercises: List<PlannedExercise>, order: List<Int>?): List<PlannedExercise> {
    if (order.isNullOrEmpty()) return exercises
    val rank = order.withIndex().associate { (pos, idx) -> idx to pos }
    return exercises.withIndex().sortedWith(
        compareBy({ rank[exerciseIndexOf(it.value)] ?: Int.MAX_VALUE }, { it.index }),
    ).map { it.value }
}

internal fun Transaction.putDayOrder(uid: UUID, id: UUID, body: DayOrderRequest): DayOrderResponse {
    lockUser(uid)
    val ctx = InstanceCtx(ownInstance(uid, id))
    val day = ctx.definition.days.firstOrNull { it.key == body.dayKey } ?: validation("unknown dayKey", "dayKey")
    val n = day.exercises.size
    val next = ctx.dayOrder.toMutableMap()
    val identity = body.order == (0 until n).toList()
    if (body.order.isEmpty() || identity) {
        next.remove(body.dayKey)
    } else {
        if (body.order.sorted() != (0 until n).toList()) validation("order must be a permutation of 0..${n - 1}", "order")
        next[body.dayKey] = body.order
    }
    ProgramInstances.update({ ProgramInstances.id eq id }) {
        it[dayOrder] = AppJson.encodeToString(DAY_ORDER_SERIALIZER, next)
        it[updatedAt] = Times.now()
    }
    return DayOrderResponse(next)
}

private fun Rule?.kind() = (this ?: Rule.NoRule)::class

/**
 * 키별 연속·단계·보류 값 필드. 상태 JSON 을 이름으로 다뤄, 엔진에 새 필드가 생겨도(A1: successStreak·periodResult)
 * 목록에 있으면 함께 비워진다.
 */
private val PER_KEY_FIELDS = listOf("stage", "failStreak", "successStreak", "periodResult", "pendingTmDelta")

private fun clearKeys(state: ProgramState, keys: Set<String>): ProgramState {
    if (keys.isEmpty()) return state
    val json = AppJson.encodeToJsonElement(ProgramState.serializer(), state) as JsonObject
    val cleaned = JsonObject(
        json.mapValues { (name, v) -> if (name in PER_KEY_FIELDS && v is JsonObject) JsonObject(v.filterKeys { it !in keys }) else v },
    )
    return AppJson.decodeFromJsonElement(ProgramState.serializer(), cleaned)
}

/**
 * 4절 + 9.5절: 진행 중 인스턴스의 정의를 바꾼다(다음 회차부터).
 * 호출자는 dbQuery 안에서 부른다. 새 초기 상태 = 지금 상태 + 정의 변화 보정 + 본문 값.
 */
internal fun Transaction.replaceInstanceDefinition(
    engine: ProgramCalculator, uid: UUID, id: UUID, newDef: ProgramDefinition,
    tm: Map<String, Double>, working: Map<String, Double>,
): Instance {
    lockUser(uid)
    val row = ownInstance(uid, id)
    (tm.entries + working.entries).forEach { (k, v) ->
        if (!v.isFinite() || v < 0 || v > 9999.99) validation("weight must be between 0 and 9999.99", "tm.$k")
    }
    val cur = replayInstance(engine, row) // 최신 상태(FIXED_DATE 자동 건너뛰기 포함)
    val ctx = InstanceCtx(loadInstanceRow(uid, id)!!)
    val s = cur.state
    val n = s.seq
    val unfinished = WorkoutSessions.selectAll().where {
        (WorkoutSessions.programInstanceId eq id) and (WorkoutSessions.planSeq eq (n + 1)) and
            WorkoutSessions.endedAt.isNull() and WorkoutSessions.deletedAt.isNull()
    }.any()
    if (unfinished) conflict("진행 중인 회차를 끝내거나 지운 뒤 바꾸세요")

    val oldDef = ctx.definition
    if (ctx.policy == com.fitlog.engine.SkipPolicy.FIXED_DATE) requireWeekdays(newDef, "definition")
    val tmNew = s.tm + tm
    val workingNew = s.working + working
    val missing = ArrayList<ErrorDetail>()
    val optional = engine.optionalInputs(newDef)
    engine.requiredInputs(newDef).forEach { (key, need) ->
        if (key in optional) return@forEach
        when (need) {
            Needs.TM -> if (key !in tmNew) missing += ErrorDetail("/tm/$key", "tm.$key is required")
            Needs.WORKING -> if (key !in workingNew) missing += ErrorDetail("/working/$key", "working.$key is required")
        }
    }
    if (missing.isNotEmpty()) {
        throw ApiException(ErrorCode.VALIDATION_FAILED, "missing inputs: " + missing.joinToString { it.path }, details = missing)
    }

    val oldNextKey = oldDef.days.getOrNull(s.nextDayIndex)?.key
    val nextIndex = newDef.days.indexOfFirst { it.key == oldNextKey }.takeIf { it >= 0 }
        ?: min(s.nextDayIndex, newDef.days.size - 1).coerceAtLeast(0)
    val week = if (newDef.cycleWeeks != null && s.week > newDef.cycleWeeks!!) 1 else s.week
    val changedKeys = (oldDef.progression.keys + newDef.progression.keys)
        .filter { oldDef.progression[it].kind() != newDef.progression[it].kind() }.toSet()
    val base = clearKeys(s, changedKeys)
    val initial = base.copy(tm = tmNew, working = workingNew, nextDayIndex = nextIndex, week = week)
    val stateJson = AppJson.encodeToString(ProgramState.serializer(), initial)

    // 지금까지의 조정은 새 초기 상태에 이미 들어 있다
    ProgramAdjustments.deleteWhere { (instanceId eq id) and (afterSeq lessEq n) }
    ProgramInstances.update({ ProgramInstances.id eq id }) {
        it[definition] = AppJson.encodeToString(newDef)
        it[initialState] = stateJson
        it[state] = stateJson
        it[stateSeq] = n
        it[baseSeq] = n
        it[baseDate] = cur.lastEventDate
        it[dayOrder] = "{}"
        it[updatedAt] = Times.now()
    }
    replayInstance(engine, loadInstanceRow(uid, id)!!)
    return instanceView(engine, loadInstanceRow(uid, id)!!, withDefinition = true)
}

/** 4절 종목 교체: lifts[liftKey].exercise 만 바꾼 정의로 교체 */
internal fun Transaction.swapInstanceLift(engine: ProgramCalculator, uid: UUID, id: UUID, body: SwapLift): Instance {
    lockUser(uid)
    val ctx = InstanceCtx(ownInstance(uid, id))
    val lift = ctx.definition.lifts[body.liftKey] ?: validation("unknown liftKey", "liftKey")
    if (!visibleExercise(uid, body.exerciseId)) notFound("exercise not found")
    val newDef = ctx.definition.copy(
        lifts = ctx.definition.lifts + (body.liftKey to lift.copy(exercise = ExerciseRef(id = body.exerciseId.toString()))),
    )
    return replaceInstanceDefinition(
        engine, uid, id, newDef,
        tm = body.tm?.let { mapOf(body.liftKey to it) } ?: emptyMap(),
        working = body.working?.let { mapOf(body.liftKey to it) } ?: emptyMap(),
    )
}
