package com.fitlog.program.instance

import com.fitlog.core.AppJson
import com.fitlog.core.Programs
import com.fitlog.core.Times
import com.fitlog.engine.Day
import com.fitlog.engine.DayExercise
import com.fitlog.engine.E1rmFormula
import com.fitlog.engine.EngineSettings
import com.fitlog.engine.ExerciseRef
import com.fitlog.engine.Lift
import com.fitlog.engine.Load
import com.fitlog.engine.Needs
import com.fitlog.engine.PlannedDay
import com.fitlog.engine.PlannedExercise
import com.fitlog.engine.PlannedSet
import com.fitlog.engine.ProgramCalculator
import com.fitlog.engine.ProgramDefinition
import com.fitlog.engine.ProgramEvent
import com.fitlog.engine.ProgramState
import com.fitlog.engine.Rule
import com.fitlog.engine.SetSpec
import com.fitlog.engine.SkipPolicy
import com.fitlog.module
import com.fitlog.session.arr
import com.fitlog.session.obj
import com.fitlog.session.str
import com.fitlog.support.TestEnv
import com.fitlog.support.auth
import com.fitlog.support.jsonBody
import io.ktor.client.HttpClient
import io.ktor.client.request.delete
import io.ktor.client.request.get
import io.ktor.client.request.patch
import io.ktor.client.request.post
import io.ktor.client.request.put
import io.ktor.client.request.setBody
import io.ktor.client.statement.HttpResponse
import io.ktor.server.testing.ApplicationTestBuilder
import io.ktor.server.testing.testApplication
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.jetbrains.exposed.sql.insert
import org.jetbrains.exposed.sql.transactions.transaction
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
import java.util.UUID

/**
 * 가짜 엔진(A3 테스트용). 규칙:
 * - days 순환, 회차(seq)는 COMPLETED·SKIPPED 마다 +1
 * - COMPLETED: working 의 각 키에 대해 그 liftKey 종목이 있고 (워밍업 제외) 모든 세트 reps >= 5 면 +2.5
 * - SKIPPED: SHIFT 는 seq 만 +1, FIXED_DATE 는 다음 날로 넘어간다
 * - ADJUSTED: 주어진 키를 덮어쓴다
 */
class FakeCalculator : ProgramCalculator {
    @Volatile var lastSettings: EngineSettings? = null
    val replayCalls = java.util.concurrent.atomic.AtomicInteger()

    override fun requiredInputs(program: ProgramDefinition): Map<String, Needs> {
        val out = linkedMapOf<String, Needs>()
        program.days.forEach { d ->
            d.exercises.forEach { e ->
                e.sets.forEach { s ->
                    when (s.load) {
                        is Load.PercentTm -> out.putIfAbsent(e.lift, Needs.TM)
                        is Load.Working -> out.putIfAbsent(e.lift, Needs.WORKING)
                        else -> {}
                    }
                }
            }
        }
        return out
    }

    override fun initialState(program: ProgramDefinition, tm: Map<String, Double>, working: Map<String, Double>) =
        ProgramState(tm = tm, working = working)

    override fun plan(program: ProgramDefinition, state: ProgramState, count: Int, settings: EngineSettings): List<PlannedDay> {
        lastSettings = settings
        val n = program.days.size
        return (0 until count).map { i ->
            val total = state.nextDayIndex + i
            val idx = total % n
            val day = program.days[idx]
            PlannedDay(
                planSeq = state.seq + 1 + i, dayIndex = idx, dayKey = day.key, dayName = day.name,
                week = state.week + total / n, cycle = state.cycle, confirmed = i == 0,
                exercises = day.exercises.mapIndexed { ei, ex ->
                    var si = 0
                    PlannedExercise(
                        key = ex.lift, exerciseId = program.lifts.getValue(ex.lift).exercise.id!!, accessory = ex.accessory,
                        sets = ex.sets.flatMap { spec ->
                            (0 until spec.count).map {
                                val w = when (val l = spec.load) {
                                    is Load.PercentTm -> (state.tm[ex.lift] ?: 0.0) * l.value
                                    is Load.Working -> (state.working[ex.lift] ?: 0.0) * l.value
                                    is Load.Fixed -> l.kg
                                    else -> null
                                }
                                PlannedSet("${day.key}.$ei.${si++}", spec.reps, w, spec.amrap, spec.warmup)
                            }
                        },
                    )
                },
            )
        }
    }

    override fun apply(program: ProgramDefinition, state: ProgramState, event: ProgramEvent, settings: EngineSettings): ProgramState {
        lastSettings = settings
        val n = program.days.size
        fun advance(s: ProgramState): ProgramState {
            val next = s.nextDayIndex + 1
            return s.copy(nextDayIndex = next % n, week = s.week + next / n, seq = s.seq + 1)
        }
        return when (event) {
            is ProgramEvent.Completed -> {
                val w = state.working.mapValues { (key, kg) ->
                    val ex = event.exercises.firstOrNull { it.liftKey == key && !it.accessory }
                    val ok = ex != null && ex.sets.filter { !it.isWarmup }.let { sets -> sets.isNotEmpty() && sets.all { (it.reps ?: 0) >= 5 } }
                    if (ok) kg + 2.5 else kg
                }
                advance(state.copy(working = w))
            }
            is ProgramEvent.Skipped ->
                if (event.policy == SkipPolicy.FIXED_DATE) advance(state) else state.copy(seq = state.seq + 1)
            is ProgramEvent.Adjusted -> state.copy(tm = state.tm + event.tm, working = state.working + event.working)
        }
    }

    override fun replay(program: ProgramDefinition, initial: ProgramState, events: List<ProgramEvent>, settings: EngineSettings): ProgramState {
        replayCalls.incrementAndGet()
        return super.replay(program, initial, events, settings)
    }

    override fun estimateOneRm(formula: E1rmFormula, weightKg: Double?, reps: Int?): Double? = null
    override fun roundWeight(kg: Double, roundingKg: Double, barKg: Double?, barbell: Boolean) = kg
}

/** 가짜 엔진을 주입한 앱 */
fun fakeTest(fake: FakeCalculator = FakeCalculator(), block: suspend ApplicationTestBuilder.() -> Unit) = testApplication {
    application { module(TestEnv.config.copy(calculator = fake)) }
    block()
}

/** 고정 시계로 실행한다(끝나면 되돌림) */
suspend fun <T> withToday(instant: String, block: suspend () -> T): T {
    val old = InstanceClock.clock
    InstanceClock.clock = Clock.fixed(Instant.parse(instant), ZoneOffset.UTC)
    try {
        return block()
    } finally {
        InstanceClock.clock = old
    }
}

/** squat(WORKING, 2x5), bench(PERCENT_TM 0.9, 1x5). 요일: A=MON, B=THU(withWeekdays=false 면 없음) */
fun testDefinition(squat: UUID, bench: UUID, withWeekdays: Boolean = true): ProgramDefinition = ProgramDefinition(
    schemaVersion = 1,
    name = "Fake Program",
    lifts = mapOf(
        "squat" to Lift(ExerciseRef(id = squat.toString())),
        "bench" to Lift(ExerciseRef(id = bench.toString())),
    ),
    progression = mapOf("squat" to Rule.Linear(2.5), "bench" to Rule.Linear(2.5)),
    days = listOf(
        Day("A", "Workout A", if (withWeekdays) "MON" else null, listOf(DayExercise("squat", sets = listOf(SetSpec(count = 2, reps = 5, load = Load.Working()))))),
        Day("B", "Workout B", if (withWeekdays) "THU" else null, listOf(DayExercise("bench", sets = listOf(SetSpec(count = 1, reps = 5, load = Load.PercentTm(0.9)))))),
    ),
)

fun insertProgram(owner: UUID?, def: ProgramDefinition): UUID {
    val pid = com.fitlog.core.Ids.newId()
    transaction {
        Programs.insert {
            it[id] = pid
            it[ownerId] = owner
            it[name] = def.name
            it[definition] = AppJson.encodeToString(ProgramDefinition.serializer(), def)
            it[sourceCol] = if (owner == null) "TEMPLATE" else "USER"
            it[createdAt] = Times.now()
            it[updatedAt] = Times.now()
        }
    }
    return pid
}

suspend fun HttpClient.startInstance(
    uid: UUID, id: String, programId: UUID, startDate: String = "2026-11-02", tz: String = "Asia/Seoul",
    skipPolicy: String? = null, tm: String = """{"bench":80}""", working: String = """{"squat":100}""",
): HttpResponse = post("/v1/program-instances") {
    auth(uid); jsonBody()
    val sp = if (skipPolicy != null) ""","skipPolicy":"$skipPolicy"""" else ""
    setBody("""{"id":"$id","programId":"$programId","startDate":"$startDate","tz":"$tz"$sp,"tm":$tm,"working":$working}""")
}

suspend fun HttpClient.getInstance(uid: UUID, id: String): HttpResponse = get("/v1/program-instances/$id") { auth(uid) }

suspend fun HttpClient.patchInstance(uid: UUID, id: String, body: String): HttpResponse =
    patch("/v1/program-instances/$id") { auth(uid); jsonBody(); setBody(body) }

suspend fun HttpClient.deleteInstance(uid: UUID, id: String): HttpResponse = delete("/v1/program-instances/$id") { auth(uid) }

suspend fun HttpClient.planOf(uid: UUID, id: String, count: Int? = null): HttpResponse =
    get("/v1/program-instances/$id/plan" + (count?.let { "?count=$it" } ?: "")) { auth(uid) }

suspend fun HttpClient.skipInstance(uid: UUID, id: String, planSeq: Int): HttpResponse =
    post("/v1/program-instances/$id/skip") { auth(uid); jsonBody(); setBody("""{"planSeq":$planSeq}""") }

suspend fun HttpClient.putAccessories(uid: UUID, id: String, body: String): HttpResponse =
    put("/v1/program-instances/$id/accessories") { auth(uid); jsonBody(); setBody(body) }

fun JsonObject.workingOf(key: String): Double = this["state"]!!.jsonObject["working"]!!.jsonObject[key]!!.jsonPrimitive.content.toDouble()
fun JsonObject.seq(): Int = this["state"]!!.jsonObject["seq"]!!.jsonPrimitive.content.toInt()
fun JsonObject.nextSeq(): Int = this["next"]!!.jsonObject["planSeq"]!!.jsonPrimitive.content.toInt()
fun JsonObject.nextDay(): String = this["next"]!!.jsonObject.str("dayKey")!!

/** 연결된 세션 JSON. reps 는 세트마다 같은 값 */
fun linkedSessionJson(
    id: String, instanceId: String?, planSeq: Int?, exerciseId: UUID, liftKey: String = "squat", dayKey: String = "A",
    reps: Int = 5, ended: Boolean = true, startedAt: String = "2026-11-02T01:00:00Z", sets: Int = 2,
    exId: String = com.fitlog.session.newId(), setIds: List<String> = List(sets) { com.fitlog.session.newId() },
): String {
    val link = buildString {
        if (instanceId != null) append(""","programInstanceId":"$instanceId"""")
        if (planSeq != null) append(""","planSeq":$planSeq,"planDayKey":"$dayKey"""")
        if (ended) append(""","endedAt":"${Instant.parse(startedAt).plusSeconds(3600)}"""")
    }
    val setJson = setIds.mapIndexed { i, sid ->
        """{"id":"$sid","position":$i,"weightKg":100,"reps":$reps,"completedAt":"$startedAt","plannedSetKey":"$dayKey.0.$i","targetReps":5,"targetWeightKg":100,"isAmrap":false}"""
    }
    return """{"id":"$id","startedAt":"$startedAt","tz":"Asia/Seoul"$link,"exercises":[{"id":"$exId","exerciseId":"$exerciseId","position":0,"liftKey":"$liftKey","accessory":false,"sets":[${setJson.joinToString(",")}]}]}"""
}

suspend fun HttpResponse.arrOf(): kotlinx.serialization.json.JsonArray = arr()
suspend fun HttpResponse.objOf(): JsonObject = obj()
