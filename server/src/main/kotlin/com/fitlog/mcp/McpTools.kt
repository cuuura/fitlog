package com.fitlog.mcp

import com.fitlog.account.loadSettings
import com.fitlog.core.AppConfig
import com.fitlog.core.AppJson
import com.fitlog.core.BodyMeasurements
import com.fitlog.core.DeletionRequests
import com.fitlog.core.Exercises
import com.fitlog.core.Ids
import com.fitlog.core.ProgramInstances
import com.fitlog.core.Programs
import com.fitlog.core.SessionExercises
import com.fitlog.core.Times
import com.fitlog.core.WorkoutSessions
import com.fitlog.core.dbQuery
import com.fitlog.core.lockUser
import com.fitlog.core.notFound
import com.fitlog.core.validation
import com.fitlog.engine.ProgramDefinition
import com.fitlog.exercise.EXERCISE_TYPES
import com.fitlog.exercise.MUSCLES
import com.fitlog.exercise.toExercise
import com.fitlog.oauth.McpPrincipal
import com.fitlog.program.catalog.ExerciseIndex
import com.fitlog.program.catalog.Program
import com.fitlog.program.catalog.ProgramSummary
import com.fitlog.program.instance.Instance
import com.fitlog.program.schema.ProgramValidator
import com.fitlog.program.schema.ValidationResult
import com.fitlog.scheduled.ScheduledStatus
import com.fitlog.scheduled.listScheduled
import com.fitlog.session.listSummaries
import com.fitlog.session.loadSession
import com.fitlog.stats.statsProgress
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.encodeToJsonElement
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.put
import org.jetbrains.exposed.sql.Op
import org.jetbrains.exposed.sql.ResultRow
import org.jetbrains.exposed.sql.SortOrder
import org.jetbrains.exposed.sql.SqlExpressionBuilder.eq
import org.jetbrains.exposed.sql.SqlExpressionBuilder.greaterEq
import org.jetbrains.exposed.sql.SqlExpressionBuilder.inList
import org.jetbrains.exposed.sql.SqlExpressionBuilder.isNull
import org.jetbrains.exposed.sql.SqlExpressionBuilder.lessEq
import org.jetbrains.exposed.sql.and
import org.jetbrains.exposed.sql.or
import org.jetbrains.exposed.sql.selectAll
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeParseException
import java.util.UUID

internal const val SAVED_NOTICE = "앱의 AI 기록에서 되돌릴 수 있습니다"

/** 도구 하나의 실행 문맥. 사용자 id 는 토큰에서만 온다 */
internal class ToolCtx(val config: AppConfig, val principal: McpPrincipal) {
    val userId: UUID get() = principal.userId
}

/** content 의 한 줄 요약 + structuredContent. code 는 ai_tool_call.result_code */
internal class ToolOutput(val text: String, val data: JsonObject, val code: String = "OK")

internal class Tool(
    val name: String,
    val title: String,
    /** 한국어 한 줄 + 영어 한 줄 */
    val description: String,
    val write: Boolean,
    val input: JsonObject,
    val output: JsonObject,
    val idempotent: Boolean = true,
    val run: suspend (ToolCtx, Args) -> ToolOutput,
)

/** 도구 인자 읽기. 잘못되면 400 VALIDATION_FAILED(→ isError 결과) */
internal class Args(val o: JsonObject) {
    private fun prim(key: String): JsonPrimitive? = (o[key] as? JsonPrimitive)?.takeIf { it !is JsonNull }

    fun has(key: String) = o[key] != null && o[key] !is JsonNull

    fun str(key: String, required: Boolean = false, max: Int = 2000): String? {
        val e = o[key]
        if (e == null || e is JsonNull) {
            if (required) validation("$key is required", key)
            return null
        }
        val p = e as? JsonPrimitive
        if (p == null || !p.isString) validation("$key must be a string", key)
        val s = p.content.trim()
        if (required && s.isEmpty()) validation("$key must not be empty", key)
        if (s.length > max) validation("$key must be at most $max characters", key)
        return s.ifEmpty { null }
    }

    fun int(key: String, min: Int, max: Int, default: Int? = null, required: Boolean = false): Int? {
        val p = prim(key)
        if (p == null) {
            if (required) validation("$key is required", key)
            return default
        }
        val n = if (p.isString) null else p.intOrNull
        if (n == null || n < min || n > max) validation("$key must be an integer between $min and $max", key)
        return n
    }

    fun num(key: String, required: Boolean = false): Double? {
        val p = prim(key)
        if (p == null) {
            if (required) validation("$key is required", key)
            return null
        }
        val d = if (p.isString) null else p.doubleOrNull
        if (d == null || !d.isFinite()) validation("$key must be a number", key)
        return d
    }

    fun obj(key: String, required: Boolean = false): JsonObject? {
        val e = o[key]
        if (e == null || e is JsonNull) {
            if (required) validation("$key is required", key)
            return null
        }
        return e as? JsonObject ?: validation("$key must be an object", key)
    }

    fun enum(key: String, values: Collection<String>, required: Boolean = false): String? {
        val s = str(key, required) ?: return null
        if (s !in values) validation("$key must be one of ${values.joinToString()}", key)
        return s
    }

    fun uuid(key: String): UUID = Ids.parse(str(key, required = true), key)

    /** 키 → 숫자 맵 */
    fun numMap(key: String): Map<String, Double> {
        val m = obj(key) ?: return emptyMap()
        return m.mapValues { (k, v) ->
            val p = v as? JsonPrimitive
            (if (p == null || p.isString) null else p.doubleOrNull) ?: validation("$key.$k must be a number", "$key.$k")
        }
    }

    fun bool(key: String): Boolean? {
        val p = prim(key) ?: return null
        return (if (p.isString) null else p.booleanOrNull) ?: validation("$key must be a boolean", key)
    }
}

internal fun parseDate(s: String, field: String): LocalDate = try {
    LocalDate.parse(s)
} catch (e: DateTimeParseException) {
    validation("$field must be YYYY-MM-DD", field)
}

/** YYYY-MM-DD(사용자 시간대의 하루 경계) 또는 ISO-8601 시각 */
private fun parseBound(s: String, zone: ZoneId, field: String, end: Boolean): Instant =
    if (s.length == 10) {
        val d = parseDate(s, field)
        if (end) d.plusDays(1).atStartOfDay(zone).toInstant().minusMillis(1) else d.atStartOfDay(zone).toInstant()
    } else Times.parse(s, field)

private inline fun <reified T> enc(v: T): JsonElement = AppJson.encodeToJsonElement(v)

private fun decodeDef(text: String): ProgramDefinition = AppJson.decodeFromString(text)

private fun ResultRow.programSummary(): ProgramSummary {
    val def = decodeDef(this[Programs.definition])
    return ProgramSummary(
        id = this[Programs.id], templateKey = this[Programs.templateKey], name = this[Programs.name],
        description = def.description, builtIn = this[Programs.ownerId] == null,
        dayCount = def.days.size, source = this[Programs.sourceCol],
    )
}

private fun ResultRow.programFull(): Program {
    val def = decodeDef(this[Programs.definition])
    return Program(
        id = this[Programs.id], templateKey = this[Programs.templateKey], name = this[Programs.name],
        description = def.description, builtIn = this[Programs.ownerId] == null,
        dayCount = def.days.size, source = this[Programs.sourceCol], definition = def,
    )
}

private fun normalize(s: String) = s.filterNot { it.isWhitespace() }.lowercase()

// ---------------------------------------------------------------- 출력 스키마 조각

private val idS = S.str("UUID", format = "uuid")
private val exerciseOut = S.obj(
    "id" to idS, "nameKo" to S.str(), "nameEn" to S.str(), "type" to S.str(enum = EXERCISE_TYPES.toList()),
    "primaryMuscle" to S.str(), "secondaryMuscles" to S.arr(S.str()), "builtIn" to S.bool("기본 제공 종목 여부"),
    required = listOf("id", "nameKo", "type", "primaryMuscle", "builtIn"),
)
private val programSummaryOut = S.obj(
    "id" to idS, "templateKey" to S.str(), "name" to S.str(), "description" to S.str(),
    "builtIn" to S.bool(), "dayCount" to S.int(), "source" to S.str(),
    required = listOf("id", "name", "builtIn", "dayCount", "source"),
)
private val instanceOut = S.obj(
    "id" to idS, "programId" to idS, "name" to S.str(), "status" to S.str(enum = listOf("ACTIVE", "PAUSED", "FINISHED")),
    "skipPolicy" to S.str(), "startDate" to S.str(format = "date"),
    "state" to S.anyObj("tm·working(kg), stage, failStreak, week, cycle, seq"),
    "next" to S.anyObj("다음 회차 계획(PlannedWorkout)"),
    required = listOf("id", "programId", "name", "status", "startDate", "state"),
)
private val sessionSummaryOut = S.obj(
    "id" to idS, "date" to S.str("세션 시간대 기준 날짜", format = "date"), "startedAt" to S.str(format = "date-time"),
    "endedAt" to S.str(format = "date-time"), "tz" to S.str(), "exerciseCount" to S.int(), "setCount" to S.int(),
    "totalVolumeKg" to S.num(),
    required = listOf("id", "startedAt", "tz", "exerciseCount", "setCount", "totalVolumeKg"),
)
private val deletionOut = S.obj(
    "id" to idS, "entity" to S.str(), "entityId" to idS, "label" to S.str(), "reason" to S.str(),
    "status" to S.str(enum = listOf("PENDING", "APPROVED", "REJECTED", "EXPIRED")), "note" to S.str(),
    "createdAt" to S.str(format = "date-time"), "expiresAt" to S.str(format = "date-time"), "decidedAt" to S.str(format = "date-time"),
    required = listOf("id", "entity", "entityId", "status", "createdAt", "expiresAt"),
)

internal fun deletionJson(r: ResultRow): JsonObject = buildJsonObject {
    put("id", r[DeletionRequests.id].toString())
    put("entity", r[DeletionRequests.entity])
    put("entityId", r[DeletionRequests.entityId].toString())
    r[DeletionRequests.label]?.let { put("label", it) }
    r[DeletionRequests.reason]?.let { put("reason", it) }
    put("status", r[DeletionRequests.status])
    r[DeletionRequests.note]?.let { put("note", it) }
    put("createdAt", Times.format(r[DeletionRequests.createdAt]))
    put("expiresAt", Times.format(r[DeletionRequests.expiresAt]))
    r[DeletionRequests.decidedAt]?.let { put("decidedAt", Times.format(it)) }
}

private fun list(key: String, items: JsonElement, count: Int, extra: Map<String, JsonElement> = emptyMap()) =
    JsonObject(mapOf(key to items, "count" to JsonPrimitive(count)) + extra)

private fun listOut(key: String, item: JsonObject, vararg extra: Pair<String, JsonElement>) =
    S.obj(key to S.arr(item), "count" to S.int(), *extra, required = listOf(key, "count"))

// ---------------------------------------------------------------- 조회 도구 (fitlog.read)

internal val READ_TOOLS: List<Tool> = listOf(
    Tool(
        name = "get_profile", title = "프로필",
        description = "내 단위 설정, 시간대(최근 세션 기준), 최신 체중, 1RM 추정식을 조회합니다. / Get my unit settings, timezone (from latest session), latest body weight and 1RM formula.",
        write = false, input = S.obj(),
        output = S.obj(
            "weightUnit" to S.str("앱 표시 단위. MCP 값은 항상 kg"), "timezone" to S.str("IANA 시간대"),
            "e1rmFormula" to S.str(), "defaultRestSec" to S.int(), "heightCm" to S.num(), "sex" to S.str(), "birthYear" to S.int(),
            "latestBodyWeight" to S.obj("measuredAt" to S.str(format = "date-time"), "weightKg" to S.num()),
            required = listOf("weightUnit", "timezone", "e1rmFormula"),
        ),
        run = { ctx, _ ->
            val data = dbQuery {
                val s = loadSettings(ctx.userId)
                val tz = userTz(ctx.userId)
                val bw = BodyMeasurements.selectAll()
                    .where { (BodyMeasurements.userId eq ctx.userId) and BodyMeasurements.deletedAt.isNull() }
                    .orderBy(BodyMeasurements.measuredAt to SortOrder.DESC).limit(1).firstOrNull()
                buildJsonObject {
                    put("weightUnit", s.weightUnit ?: "KG")
                    put("timezone", tz)
                    put("e1rmFormula", s.e1rmFormula ?: "EPLEY")
                    s.defaultRestSec?.let { put("defaultRestSec", it) }
                    s.heightCm?.let { put("heightCm", it) }
                    s.sex?.let { put("sex", it) }
                    s.birthYear?.let { put("birthYear", it) }
                    if (bw != null) put("latestBodyWeight", buildJsonObject {
                        put("measuredAt", Times.format(bw[BodyMeasurements.measuredAt]))
                        put("weightKg", bw[BodyMeasurements.weightKg].toDouble())
                    })
                }
            }
            val bw = (data["latestBodyWeight"] as? JsonObject)?.get("weightKg")
            ToolOutput("시간대 ${(data["timezone"] as JsonPrimitive).content}, 1RM 추정식 ${(data["e1rmFormula"] as JsonPrimitive).content}" +
                (bw?.let { ", 최신 체중 ${(it as JsonPrimitive).content}kg" } ?: ""), data)
        },
    ),
    Tool(
        name = "search_exercises", title = "종목 검색",
        description = "종목을 이름·부위·유형으로 검색합니다. / Search exercises by name, muscle or type.",
        write = false,
        input = S.obj(
            "query" to S.str("한글·영문 이름 일부(공백 무시)"), "muscle" to S.str(enum = MUSCLES.toList()),
            "type" to S.str(enum = EXERCISE_TYPES.toList()), "limit" to S.int("기본 20, 최대 100", 1, 100),
        ),
        output = listOut("exercises", exerciseOut),
        run = { ctx, a ->
            val q = a.str("query")?.let(::normalize)
            val muscle = a.enum("muscle", MUSCLES)
            val type = a.enum("type", EXERCISE_TYPES)
            val limit = a.int("limit", 1, 100, 20)!!
            val found = dbQuery {
                var cond: Op<Boolean> = Exercises.deletedAt.isNull() and (Exercises.ownerId.isNull() or (Exercises.ownerId eq ctx.userId))
                if (type != null) cond = cond and (Exercises.type eq type)
                Exercises.selectAll().where(cond).map { it.toExercise() }
            }.filter { e -> muscle == null || e.primaryMuscle == muscle || muscle in e.secondaryMuscles }
                .filter { e -> q == null || normalize(e.nameKo).contains(q) || (e.nameEn != null && normalize(e.nameEn).contains(q)) }
                .sortedWith(compareBy({ it.nameKo }, { it.id }))
            val shown = found.take(limit)
            ToolOutput(
                "종목 ${found.size}개 중 ${shown.size}개: " + shown.take(5).joinToString(", ") { it.nameKo } + if (shown.size > 5) " …" else "",
                list("exercises", enc(shown), shown.size, mapOf("total" to JsonPrimitive(found.size))),
            )
        },
    ),
    Tool(
        name = "list_programs", title = "프로그램 목록",
        description = "기본 템플릿과 내 프로그램의 요약을 조회합니다. / List program templates and my programs.",
        write = false, input = S.obj("source" to S.str(enum = listOf("TEMPLATE", "MINE"))),
        output = listOut("programs", programSummaryOut),
        run = { ctx, a ->
            val source = a.enum("source", listOf("TEMPLATE", "MINE"))
            val rows = dbQuery {
                val visible = when (source) {
                    "TEMPLATE" -> Programs.ownerId.isNull()
                    "MINE" -> Programs.ownerId eq ctx.userId
                    else -> Programs.ownerId.isNull() or (Programs.ownerId eq ctx.userId)
                }
                Programs.selectAll().where { Programs.deletedAt.isNull() and visible }.map { it.programSummary() }
            }.sortedWith(compareBy({ !it.builtIn }, { it.id.toString() }))
            ToolOutput("프로그램 ${rows.size}개: " + rows.take(6).joinToString(", ") { it.name }, list("programs", enc(rows), rows.size))
        },
    ),
    Tool(
        name = "get_program", title = "프로그램 정의",
        description = "프로그램 정의 전체를 조회합니다(id 또는 templateKey 중 하나). / Get a full program definition by id or templateKey.",
        write = false,
        input = S.obj("id" to idS, "templateKey" to S.str("예: stronglifts-5x5")),
        output = S.obj(
            "program" to S.obj(
                "id" to idS, "templateKey" to S.str(), "name" to S.str(), "builtIn" to S.bool(), "dayCount" to S.int(),
                "definition" to S.anyObj("program.schema.json 형식"),
                required = listOf("id", "name", "definition"),
            ),
            required = listOf("program"),
        ),
        run = { ctx, a ->
            val id = if (a.has("id")) a.uuid("id") else null
            val key = a.str("templateKey")
            if (id == null && key == null) validation("id or templateKey is required", "id")
            val p = dbQuery {
                Programs.selectAll().where {
                    Programs.deletedAt.isNull() and (Programs.ownerId.isNull() or (Programs.ownerId eq ctx.userId)) and
                        (if (id != null) Programs.id eq id else Programs.templateKey eq key!!)
                }.firstOrNull()?.programFull()
            } ?: notFound("program not found")
            ToolOutput("프로그램 '${p.name}' (${p.dayCount}일 구성)", JsonObject(mapOf("program" to enc(p))))
        },
    ),
    Tool(
        name = "validate_program", title = "프로그램 검증",
        description = "프로그램 정의를 저장하지 않고 검증합니다. 오류는 JSON 포인터 경로로 알려줍니다. / Validate a program definition without saving; errors use JSON pointer paths.",
        write = false,
        input = S.obj("definition" to S.anyObj("program.schema.json 형식의 프로그램 정의"), required = listOf("definition")),
        output = S.obj(
            "valid" to S.bool(), "name" to S.str(), "dayCount" to S.int(),
            "errors" to S.arr(S.obj("path" to S.str(), "message" to S.str(), required = listOf("path", "message"))),
            required = listOf("valid"),
        ),
        run = { ctx, a ->
            val def = a.obj("definition", required = true)!!
            val index = ExerciseIndex.load(ctx.userId)
            when (val r = ProgramValidator.validate(def, index.resolver)) {
                is ValidationResult.Valid -> ToolOutput(
                    "유효한 프로그램 정의입니다 ('${r.definition.name}', ${r.definition.days.size}일)",
                    buildJsonObject { put("valid", true); put("name", r.definition.name); put("dayCount", r.definition.days.size) },
                )
                is ValidationResult.Invalid -> ToolOutput(
                    "프로그램 정의에 오류 ${r.errors.size}건: " + r.errors.take(3).joinToString("; ") { "${it.path} ${it.message}" },
                    buildJsonObject { put("valid", false); put("errors", enc(r.errors)) },
                )
            }
        },
    ),
    Tool(
        name = "list_program_instances", title = "진행 중인 프로그램",
        description = "시작한 프로그램 인스턴스(상태, TM·작업 무게, 주차, 다음 회차)를 조회합니다. / List started program instances with state and next workout.",
        write = false, input = S.obj("status" to S.str(enum = listOf("ACTIVE", "PAUSED", "FINISHED"))),
        output = listOut("instances", instanceOut),
        run = { ctx, a ->
            val status = a.enum("status", listOf("ACTIVE", "PAUSED", "FINISHED"))
            val rows = dbQuery {
                lockUser(ctx.userId)
                ProgramInstances.selectAll().where {
                    val base = (ProgramInstances.userId eq ctx.userId) and ProgramInstances.deletedAt.isNull()
                    if (status != null) base and (ProgramInstances.status eq status) else base
                }.orderBy(ProgramInstances.createdAt to SortOrder.DESC, ProgramInstances.id to SortOrder.DESC)
                    .toList().map { mcpInstanceView(ctx.config.engine, it) }
            }
            ToolOutput("프로그램 인스턴스 ${rows.size}개" + if (rows.isNotEmpty()) ": " + rows.take(4).joinToString(", ") { "${it.name}(${it.status})" } else "",
                list("instances", enc(rows), rows.size))
        },
    ),
    Tool(
        name = "get_plan", title = "다음 회차 계획",
        description = "인스턴스의 다음 운동 계획(세트별 목표 무게·횟수)을 조회합니다. / Get upcoming planned workouts for a program instance.",
        write = false,
        input = S.obj("instanceId" to idS, "count" to S.int("기본 3, 1~8", 1, 8), required = listOf("instanceId")),
        output = listOut("plan", S.anyObj("PlannedWorkout: planSeq, dayName, week, exercises[sets[plannedSetKey,targetReps,targetWeightKg]]")),
        run = { ctx, a ->
            val id = a.uuid("instanceId")
            val count = a.int("count", 1, 8, 3)!!
            val plan = dbQuery { mcpPlan(ctx.config.engine, ctx.userId, id, count) }
            ToolOutput(
                "다음 ${plan.size}회차 계획" + (plan.firstOrNull()?.let { ": ${it.dayName} (planSeq ${it.planSeq})부터" } ?: ""),
                list("plan", enc(plan), plan.size),
            )
        },
    ),
    Tool(
        name = "list_sessions", title = "운동 세션 목록",
        description = "기간별 운동 세션 요약(날짜, 종목 수, 세트 수, 볼륨)을 최신순으로 조회합니다. / List workout session summaries, newest first.",
        write = false,
        input = S.obj(
            "from" to S.str("시작 날짜 YYYY-MM-DD(내 시간대)", format = "date"), "to" to S.str("끝 날짜 YYYY-MM-DD(포함)", format = "date"),
            "limit" to S.int("기본 20, 최대 100", 1, 100),
        ),
        output = listOut("sessions", sessionSummaryOut),
        run = { ctx, a ->
            val limit = a.int("limit", 1, 100, 20)!!
            val from = a.str("from")?.let { parseDate(it, "from") }
            val to = a.str("to")?.let { parseDate(it, "to") }
            if (from != null && to != null && to < from) validation("to must be on or after from", "to")
            val rows = dbQuery {
                val zone = ZoneId.of(userTz(ctx.userId))
                val before = to?.plusDays(1)?.atStartOfDay(zone)?.toInstant()
                val start = from?.atStartOfDay(zone)?.toInstant()
                listSummaries(ctx.userId, before, limit).filter { start == null || !it.startedAt.isBefore(start) }
            }
            val items = buildJsonArray {
                rows.forEach {
                    val j = enc(it) as JsonObject
                    val date = it.startedAt.atZone(ZoneId.of(it.tz)).toLocalDate().toString()
                    add(JsonObject(j + ("date" to JsonPrimitive(date))))
                }
            }
            ToolOutput("세션 ${rows.size}건" + (rows.firstOrNull()?.let { " (최신 ${it.startedAt.atZone(ZoneId.of(it.tz)).toLocalDate()})" } ?: ""),
                list("sessions", items, rows.size))
        },
    ),
    Tool(
        name = "get_session", title = "운동 세션 상세",
        description = "세션 한 건의 종목·세트·계획 목표를 모두 조회합니다. / Get a full workout session with exercises, sets and plan targets.",
        write = false, input = S.obj("id" to idS, required = listOf("id")),
        output = S.obj(
            "session" to S.anyObj("세션(startedAt, endedAt, tz, exercises[sets[weightKg,reps,...]])"),
            "exerciseNames" to S.map(S.str(), "종목 id → 이름"),
            required = listOf("session"),
        ),
        run = { ctx, a ->
            val id = a.uuid("id")
            val (s, names) = dbQuery {
                val s = loadSession(ctx.userId, id) ?: notFound("session not found")
                val ids = s.exercises.map { it.exerciseId }.distinct()
                val names = if (ids.isEmpty()) emptyMap() else Exercises.select(Exercises.id, Exercises.nameKo)
                    .where { Exercises.id inList ids }.associate { it[Exercises.id].toString() to it[Exercises.nameKo] }
                s to names
            }
            val setCount = s.exercises.sumOf { it.sets.size }
            ToolOutput(
                "${s.startedAt.atZone(ZoneId.of(s.tz)).toLocalDate()} 세션: 종목 ${s.exercises.size}개, 세트 ${setCount}개",
                JsonObject(mapOf("session" to enc(s), "exerciseNames" to JsonObject(names.mapValues { JsonPrimitive(it.value) }))),
            )
        },
    ),
    Tool(
        name = "get_exercise_records", title = "종목 기록(PR)",
        description = "종목의 최고 무게, 최고 추정 1RM, 횟수별 기록을 조회합니다. / Get PRs and 1RM estimates for an exercise.",
        write = false, input = S.obj("exerciseId" to idS, required = listOf("exerciseId")),
        output = S.obj("records" to S.anyObj("bestWeight, bestE1rm, latestMeasured, byReps"), required = listOf("records")),
        run = { ctx, a ->
            val id = a.uuid("exerciseId")
            val r = dbQuery { mcpExerciseRecords(ctx.userId, id) }
            ToolOutput(
                "최고 무게 ${r.bestWeight?.let { "${it.weightKg}kg x ${it.reps}" } ?: "기록 없음"}" +
                    (r.bestE1rm?.e1rmKg?.let { ", 최고 추정 1RM ${it}kg (${r.formula})" } ?: ""),
                JsonObject(mapOf("records" to enc(r))),
            )
        },
    ),
    Tool(
        name = "get_exercise_progress", title = "종목 추이(그래프)",
        description = "종목의 세션별 최고 무게·추정 1RM·볼륨 추이와 PR 여부를 조회합니다(REST /v1/exercises/{id}/progress와 같음). / Get per-session progress points (top weight, e1RM, volume, PR flags) for an exercise.",
        write = false,
        input = S.obj(
            "exerciseId" to idS,
            "from" to S.str("ISO-8601 시각. 기본 to-180일", format = "date-time"),
            "to" to S.str("ISO-8601 시각. 기본 지금", format = "date-time"),
            "limit" to S.int("기본 100, 최대 500. 최근 것부터 자른 뒤 오름차순", min = 1, max = 500),
            required = listOf("exerciseId"),
        ),
        output = S.obj("progress" to S.anyObj("exerciseId, formula, points[], bestWeight, bestE1rm"), required = listOf("progress")),
        run = { ctx, a ->
            val id = a.uuid("exerciseId")
            val from = a.str("from")
            val to = a.str("to")
            val limit = a.int("limit", 1, 500)
            val p = dbQuery { statsProgress(ctx.userId, id, from, to, limit) }
            ToolOutput(
                "추이 ${p.points.size}점" + (p.bestWeight?.let { ", 최고 무게 ${it.weightKg}kg x ${it.reps}" } ?: ", 기록 없음"),
                JsonObject(mapOf("progress" to enc(p))),
            )
        },
    ),
    Tool(
        name = "get_training_summary", title = "훈련 요약",
        description = "기간의 종목별 세트 수·볼륨·최고 무게·최고 추정 1RM과 주 단위 운동 횟수를 집계합니다. / Aggregate sets, volume, best weight and e1RM per exercise plus weekly session counts.",
        write = false,
        input = S.obj(
            "from" to S.str("YYYY-MM-DD", format = "date"), "to" to S.str("YYYY-MM-DD(포함)", format = "date"),
            required = listOf("from", "to"),
        ),
        output = S.obj(
            "from" to S.str(), "to" to S.str(), "timezone" to S.str(), "sessionCount" to S.int(),
            "exercises" to S.arr(S.obj(
                "exerciseId" to idS, "name" to S.str(), "sets" to S.int(), "volumeKg" to S.num(),
                "maxWeightKg" to S.num(), "bestE1rmKg" to S.num(),
                required = listOf("exerciseId", "sets", "volumeKg"),
            )),
            "weeks" to S.arr(S.obj("weekStart" to S.str(format = "date"), "sessions" to S.int(), required = listOf("weekStart", "sessions"))),
            required = listOf("from", "to", "sessionCount", "exercises", "weeks"),
        ),
        run = { ctx, a ->
            val from = parseDate(a.str("from", required = true)!!, "from")
            val to = parseDate(a.str("to", required = true)!!, "to")
            if (to < from) validation("to must be on or after from", "to")
            if (to.toEpochDay() - from.toEpochDay() > 366) validation("range must be at most 367 days", "to")
            val data = dbQuery { mcpTrainingSummary(ctx.userId, from, to) }
            val exCount = (data["exercises"] as JsonArray).size
            ToolOutput("$from~$to: 운동 ${(data["sessionCount"] as JsonPrimitive).content}회, 종목 ${exCount}개", data)
        },
    ),
    Tool(
        name = "get_body_measurements", title = "체중 기록",
        description = "체중 기록을 최신순으로 조회합니다. / List body weight measurements, newest first.",
        write = false,
        input = S.obj("from" to S.str("YYYY-MM-DD 또는 ISO-8601 시각"), "to" to S.str("YYYY-MM-DD(포함) 또는 ISO-8601 시각")),
        output = listOut("measurements", S.obj(
            "id" to idS, "measuredAt" to S.str(format = "date-time"), "weightKg" to S.num(), "source" to S.str(),
            required = listOf("id", "measuredAt", "weightKg"),
        )),
        run = { ctx, a ->
            val fromS = a.str("from")
            val toS = a.str("to")
            val rows = dbQuery {
                val zone = ZoneId.of(userTz(ctx.userId))
                val from = fromS?.let { parseBound(it, zone, "from", end = false) }
                val to = toS?.let { parseBound(it, zone, "to", end = true) }
                BodyMeasurements.selectAll().where {
                    var c = (BodyMeasurements.userId eq ctx.userId) and BodyMeasurements.deletedAt.isNull()
                    if (from != null) c = c and (BodyMeasurements.measuredAt greaterEq from)
                    if (to != null) c = c and (BodyMeasurements.measuredAt lessEq to)
                    c
                }.orderBy(BodyMeasurements.measuredAt to SortOrder.DESC, BodyMeasurements.id to SortOrder.DESC)
                    .limit(1000).toList()
            }
            val items = buildJsonArray {
                rows.forEach {
                    add(buildJsonObject {
                        put("id", it[BodyMeasurements.id].toString())
                        put("measuredAt", Times.format(it[BodyMeasurements.measuredAt]))
                        put("weightKg", it[BodyMeasurements.weightKg].toDouble())
                        put("source", it[BodyMeasurements.sourceCol])
                    })
                }
            }
            val latest = rows.firstOrNull()?.get(BodyMeasurements.weightKg)?.toDouble()
            ToolOutput("체중 기록 ${rows.size}건" + (latest?.let { " (최신 ${it}kg)" } ?: ""), list("measurements", items, rows.size))
        },
    ),
    Tool(
        name = "list_scheduled_workouts", title = "예정 운동 목록",
        description = "앞으로 할 하루짜리 예정 운동(날짜·제목·종목별 세트 목표·상태 PLANNED/IN_PROGRESS/DONE/SKIPPED)을 조회합니다. 기간 기본값은 오늘~14일 뒤(내 시간대), 최대 92일. / List scheduled one-day workouts with per-exercise set targets and computed status; default range is today..+14 days (max 92 days).",
        write = false,
        input = S.obj(
            "from" to S.str("시작 날짜 YYYY-MM-DD(포함). 기본 오늘", format = "date"),
            "to" to S.str("끝 날짜 YYYY-MM-DD(포함). 기본 from+14일", format = "date"),
            "status" to S.str("이 상태만", enum = ScheduledStatus.entries.map { it.name }),
        ),
        output = listOut(
            "scheduledWorkouts",
            S.obj(
                "id" to idS, "plannedDate" to S.str(format = "date"), "title" to S.str(), "note" to S.str(),
                "items" to S.arr(S.anyObj("exerciseId, exerciseName, note, restSec, sets[{isWarmup,targetWeightKg,targetReps,targetRepsMax,targetRir,targetRpe,targetDurationSec}]")),
                "itemCount" to S.int(), "status" to S.str(enum = ScheduledStatus.entries.map { it.name }), "sessionId" to idS,
                "skippedAt" to S.str(format = "date-time"), "source" to S.str(),
                required = listOf("id", "plannedDate", "title", "items", "status"),
            ),
            "from" to S.str(format = "date"), "to" to S.str(format = "date"),
        ),
        run = { ctx, a ->
            val status = a.enum("status", ScheduledStatus.entries.map { it.name })
            val fromArg = a.str("from")?.let { parseDate(it, "from") }
            val toArg = a.str("to")?.let { parseDate(it, "to") }
            val found = dbQuery {
                val today = LocalDate.now(ZoneId.of(userTz(ctx.userId)))
                val from = fromArg ?: today
                val to = toArg ?: from.plusDays(14)
                if (to < from) validation("to must be on or after from", "to")
                if (java.time.temporal.ChronoUnit.DAYS.between(from, to) > 91) validation("range must be at most 92 days", "to")
                Triple(from, to, scheduledJson(listScheduled(ctx.userId, from, to).filter { status == null || it.status?.name == status }))
            }
            val (from, to, rows) = found
            ToolOutput(
                "예정 운동 ${rows.size}건 ($from ~ $to)" + rows.take(3).joinToString("") { "\n- ${(it["plannedDate"] as JsonPrimitive).content} ${(it["title"] as JsonPrimitive).content} [${(it["status"] as JsonPrimitive).content}]" },
                list("scheduledWorkouts", JsonArray(rows), rows.size, mapOf("from" to JsonPrimitive(from.toString()), "to" to JsonPrimitive(to.toString()))),
            )
        },
    ),
    Tool(
        name = "list_deletion_requests", title = "삭제 요청 목록",
        description = "이 AI 연결이 만든 삭제 요청과 상태를 조회합니다. / List deletion requests created by this connection and their status.",
        write = false, input = S.obj("status" to S.str(enum = listOf("PENDING", "APPROVED", "REJECTED", "EXPIRED"))),
        output = listOut("requests", deletionOut),
        run = { ctx, a ->
            val status = a.enum("status", listOf("PENDING", "APPROVED", "REJECTED", "EXPIRED"))
            val rows = dbQuery {
                DeletionRequests.selectAll().where {
                    val base = (DeletionRequests.userId eq ctx.userId) and (DeletionRequests.connectionId eq ctx.principal.connectionId)
                    if (status != null) base and (DeletionRequests.status eq status) else base
                }.orderBy(DeletionRequests.createdAt to SortOrder.DESC).limit(200).map(::deletionJson)
            }
            ToolOutput("삭제 요청 ${rows.size}건", list("requests", JsonArray(rows), rows.size))
        },
    ),
) + OPENAI_COMPAT_TOOLS
