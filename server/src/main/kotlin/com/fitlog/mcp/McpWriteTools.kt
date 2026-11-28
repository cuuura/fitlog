package com.fitlog.mcp

import com.fitlog.core.AppJson
import com.fitlog.core.DeletionRequests
import com.fitlog.core.Exercises
import com.fitlog.core.Ids
import com.fitlog.core.BodyMeasurements
import com.fitlog.core.ProgramInstances
import com.fitlog.core.Programs
import com.fitlog.core.SessionExercises
import com.fitlog.core.Times
import com.fitlog.core.WorkoutSessions
import com.fitlog.core.dbQuery
import com.fitlog.core.notFound
import com.fitlog.core.validation
import com.fitlog.engine.ProgramDefinition
import com.fitlog.exercise.EXERCISE_TYPES
import com.fitlog.exercise.MUSCLES
import com.fitlog.importing.ImportChannel
import com.fitlog.importing.ImportContext
import com.fitlog.importing.ImportOutcome
import com.fitlog.importing.ImportRequest
import com.fitlog.importing.Resolution
import com.fitlog.scheduled.findScheduled
import com.fitlog.scheduled.setScheduledSkipped
import com.fitlog.core.ImportItems
import com.fitlog.core.lockUser
import kotlinx.serialization.SerializationException
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.encodeToJsonElement
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.jetbrains.exposed.exceptions.ExposedSQLException
import org.jetbrains.exposed.sql.SqlExpressionBuilder.eq
import org.jetbrains.exposed.sql.SqlExpressionBuilder.isNull
import org.jetbrains.exposed.sql.SqlExpressionBuilder.lessEq
import org.jetbrains.exposed.sql.and
import org.jetbrains.exposed.sql.insert
import org.jetbrains.exposed.sql.selectAll
import org.jetbrains.exposed.sql.update
import java.time.ZoneId
import java.util.UUID

private val idS = S.str("UUID", format = "uuid")
private val noteS = S.str("이력 화면에 표시할 설명(최대 500자)")
private val onConflictS = S.str("ASK(기본): 충돌이 남으면 저장하지 않고 목록 반환 / SKIP_ALL: 충돌 항목을 건너뛰고 저장", enum = listOf("ASK", "SKIP_ALL"))
private val resolutionsS = S.map(
    S.anyObj("{action: SKIP|KEEP_BOTH|REPLACE|MAP_TO|CREATE|UNLINK|SET, exerciseId?, exercise?, value?}"),
    "충돌 id → 해결 방법(이전 호출이 돌려준 conflictId 기준)",
)

private val writeOut = S.obj(
    "status" to S.str("SAVED 또는 NEEDS_RESOLUTION", enum = listOf("SAVED", "NEEDS_RESOLUTION")),
    "created" to S.bool("false 면 같은 묶음이 이미 저장되어 있어 바뀐 것이 없음"),
    "importBatchId" to idS,
    "batch" to S.anyObj("ImportBatch: id, createdAt, channel, clientName, note, summary"),
    "conflicts" to S.arr(S.anyObj("Conflict: conflictId, code, path, message, allowed, existing?, candidates?, suggested?")),
    "unresolved" to S.arr(S.str()),
    "counts" to S.anyObj(),
    "message" to S.str(),
    required = listOf("status"),
)

private inline fun <reified T> enc(v: T): JsonElement = AppJson.encodeToJsonElement(v)

private fun parseResolutions(a: Args): Map<String, Resolution> {
    val o = a.obj("resolutions") ?: return emptyMap()
    return try {
        AppJson.decodeFromJsonElement(MapSerializer(String.serializer(), Resolution.serializer()), o)
    } catch (e: SerializationException) {
        validation("resolutions is invalid: ${e.message}", "resolutions")
    } catch (e: IllegalArgumentException) {
        validation("resolutions is invalid: ${e.message}", "resolutions")
    }
}

/** 쓰기 도구 공통: 묶음을 만들어 config.importer 로 가져온다 (import.md 파이프라인) */
private suspend fun importBundle(ctx: ToolCtx, a: Args, bundle: JsonObject, tz: String? = null): ToolOutput {
    val onConflict = a.enum("onConflict", listOf("ASK", "SKIP_ALL")) ?: "ASK"
    val req = ImportRequest(
        bundle = bundle,
        channel = "MCP",
        clientName = ctx.principal.clientName,
        tz = tz,
        onConflict = onConflict,
        resolutions = parseResolutions(a),
    )
    val ictx = ImportContext(ctx.userId, ImportChannel.MCP, ctx.principal.clientName, ctx.principal.connectionId)
    return when (val out = ctx.config.importer.import(ictx, req)) {
        is ImportOutcome.Saved -> {
            val b = out.batch
            val sum = b.summary.entries.filter { it.value != 0 }.joinToString(", ") { "${it.key} ${it.value}" }
            val msg = if (out.created) "저장했습니다" + (if (sum.isNotEmpty()) " ($sum)" else "") + ". $SAVED_NOTICE."
            else "이미 저장된 같은 묶음입니다. 바뀐 것이 없습니다."
            ToolOutput(
                msg,
                buildJsonObject {
                    put("status", "SAVED")
                    put("created", out.created)
                    put("importBatchId", b.id.toString())
                    put("batch", enc(b))
                    put("message", "$SAVED_NOTICE")
                },
            )
        }
        is ImportOutcome.NeedsResolution -> {
            val p = out.preview
            ToolOutput(
                "충돌 ${p.conflicts.size}건이 남아 저장하지 않았습니다. conflicts 의 allowed 중 하나를 골라 resolutions 에 넣고 다시 호출하세요.",
                buildJsonObject {
                    put("status", "NEEDS_RESOLUTION")
                    put("created", false)
                    put("conflicts", enc(p.conflicts))
                    put("unresolved", enc(p.unresolved))
                    put("counts", enc(p.counts))
                    put("message", "저장되지 않았습니다. 충돌을 해결한 뒤 같은 묶음에 resolutions 를 붙여 다시 호출하세요.")
                },
                code = "NEEDS_RESOLUTION",
            )
        }
    }
}

private fun bundleOf(a: Args, vararg parts: Pair<String, JsonElement>): JsonObject = buildJsonObject {
    put("schemaVersion", 1)
    a.str("note", max = 500)?.let { put("note", it) }
    parts.forEach { (k, v) -> put(k, v) }
}

private val DELETE_ENTITIES = mapOf(
    "session" to "workout_session",
    "program" to "program",
    "program_instance" to "program_instance",
    "exercise" to "exercise",
    "body_measurement" to "body_measurement",
    "scheduled_workout" to "scheduled_workout",
)

/** 내 것이고 삭제되지 않은 대상이면 요약(label), 아니면 404 */
private fun org.jetbrains.exposed.sql.Transaction.deletionLabel(userId: UUID, table: String, id: UUID): String {
    val missing = "삭제 요청 대상을 찾을 수 없습니다(내 데이터만 요청할 수 있습니다)"
    return when (table) {
        "workout_session" -> {
            val r = WorkoutSessions.selectAll().where {
                (WorkoutSessions.id eq id) and (WorkoutSessions.userId eq userId) and WorkoutSessions.deletedAt.isNull()
            }.singleOrNull() ?: notFound(missing)
            val n = SessionExercises.selectAll().where { (SessionExercises.sessionId eq id) and SessionExercises.deletedAt.isNull() }.count()
            val date = r[WorkoutSessions.startedAt].atZone(ZoneId.of(r[WorkoutSessions.tz])).toLocalDate()
            "$date 운동 세션 (종목 ${n}개)"
        }
        "program" -> {
            val r = Programs.selectAll().where { (Programs.id eq id) and (Programs.ownerId eq userId) and Programs.deletedAt.isNull() }
                .singleOrNull() ?: notFound(missing)
            "프로그램 ${r[Programs.name]}"
        }
        "program_instance" -> {
            val r = ProgramInstances.selectAll().where {
                (ProgramInstances.id eq id) and (ProgramInstances.userId eq userId) and ProgramInstances.deletedAt.isNull()
            }.singleOrNull() ?: notFound(missing)
            val name = runCatching { AppJson.decodeFromString<ProgramDefinition>(r[ProgramInstances.definition]).name }.getOrDefault("프로그램")
            "진행 중인 프로그램 $name (시작 ${r[ProgramInstances.startDate]})"
        }
        "exercise" -> {
            val r = Exercises.selectAll().where { (Exercises.id eq id) and (Exercises.ownerId eq userId) and Exercises.deletedAt.isNull() }
                .singleOrNull() ?: notFound(missing)
            "종목 ${r[Exercises.nameKo]}"
        }
        "scheduled_workout" -> {
            val w = findScheduled(userId, id) ?: notFound(missing)
            "${w.plannedDate} 예정 운동 ${w.title} (종목 ${w.items.size}개)"
        }
        else -> {
            val r = BodyMeasurements.selectAll().where {
                (BodyMeasurements.id eq id) and (BodyMeasurements.userId eq userId) and BodyMeasurements.deletedAt.isNull()
            }.singleOrNull() ?: notFound(missing)
            "${r[BodyMeasurements.measuredAt].atZone(ZoneId.of(userTz(userId))).toLocalDate()} 체중 ${r[BodyMeasurements.weightKg].toDouble()}kg"
        }
    }
}

private suspend fun createDeletionRequest(ctx: ToolCtx, entity: String, id: UUID, reason: String): Pair<JsonObject, Boolean> {
    val table = DELETE_ENTITIES.getValue(entity)
    suspend fun tx() = dbQuery {
        val now = Times.now()
        val label = deletionLabel(ctx.userId, table, id)
        // 기한이 지난 PENDING 은 닫는다(같은 대상에 새 요청을 만들 수 있게)
        DeletionRequests.update({
            (DeletionRequests.userId eq ctx.userId) and (DeletionRequests.entity eq table) and
                (DeletionRequests.entityId eq id) and (DeletionRequests.status eq "PENDING") and (DeletionRequests.expiresAt lessEq now)
        }) {
            it[status] = "EXPIRED"
            it[decidedAt] = now
        }
        val existing = DeletionRequests.selectAll().where {
            (DeletionRequests.userId eq ctx.userId) and (DeletionRequests.entity eq table) and
                (DeletionRequests.entityId eq id) and (DeletionRequests.status eq "PENDING")
        }.singleOrNull()
        if (existing != null) return@dbQuery deletionJson(existing) to false
        val rid = Ids.newId()
        DeletionRequests.insert {
            it[DeletionRequests.id] = rid
            it[userId] = ctx.userId
            it[connectionId] = ctx.principal.connectionId
            it[clientName] = ctx.principal.clientName
            it[DeletionRequests.entity] = table
            it[entityId] = id
            it[DeletionRequests.label] = label
            it[DeletionRequests.reason] = reason
            it[status] = "PENDING"
            it[createdAt] = now
            it[expiresAt] = now.plusSeconds(7L * 24 * 3600)
        }
        deletionJson(DeletionRequests.selectAll().where { DeletionRequests.id eq rid }.single()) to true
    }
    return try {
        tx()
    } catch (e: ExposedSQLException) {
        // 같은 대상 동시 요청: 유니크 인덱스에 걸리면 이미 있는 PENDING 을 돌려준다
        if (e.sqlState != "23505") throw e
        tx()
    }
}

// ---------------------------------------------------------------- 쓰기 도구 (fitlog.write)

internal val WRITE_TOOLS: List<Tool> = listOf(
    Tool(
        name = "import_bundle", title = "묶음 가져오기",
        description = "import 스키마(exercises, programs, startPrograms, sessions, bodyMeasurements)의 묶음을 가져옵니다. 충돌이 없으면 바로 저장, 있으면 저장하지 않고 충돌 목록을 돌려줍니다. / Import a bundle; saves immediately if no conflicts, otherwise returns the conflicts without saving.",
        write = true,
        input = S.obj(
            "bundle" to S.anyObj("import.schema.json 형식 (schemaVersion: 1 필수). 스키마: /v1/public/schema/import.json"),
            "resolutions" to resolutionsS, "onConflict" to onConflictS,
            required = listOf("bundle"),
        ),
        output = writeOut,
        run = { ctx, a -> importBundle(ctx, a, a.obj("bundle", required = true)!!) },
    ),
    Tool(
        name = "create_program", title = "프로그램 만들기",
        description = "프로그램 정의를 검증해 내 프로그램으로 저장합니다. / Validate and save a program definition as my program.",
        write = true,
        input = S.obj(
            "definition" to S.anyObj("program.schema.json 형식. 스키마: /v1/public/schema/program.json"),
            "onConflict" to onConflictS, "resolutions" to resolutionsS, "note" to noteS,
            required = listOf("definition"),
        ),
        output = writeOut,
        run = { ctx, a ->
            val def = a.obj("definition", required = true)!!
            importBundle(ctx, a, bundleOf(a, "programs" to buildJsonArray { add(buildJsonObject { put("definition", def) }) }))
        },
    ),
    Tool(
        name = "start_program", title = "프로그램 시작",
        description = "프로그램(내 것 또는 템플릿)을 시작일과 TM·작업 무게로 시작합니다. 값이 모자라면 INSTANCE_NEEDS_VALUE 충돌과 제안값을 돌려줍니다. / Start a program with start date and TM/working weights; missing values are returned as conflicts with suggestions.",
        write = true,
        input = S.obj(
            "program" to S.obj("id" to idS, "templateKey" to S.str("예: stronglifts-5x5"), desc = "id 또는 templateKey 중 하나"),
            "startDate" to S.str("YYYY-MM-DD", format = "date"),
            "tm" to S.map(S.num(min = 0.0), "리프트 키 → TM(kg)"), "working" to S.map(S.num(min = 0.0), "리프트 키 → 작업 무게(kg)"),
            "skipPolicy" to S.str(enum = listOf("SHIFT", "FIXED_DATE")), "tz" to S.str("IANA 시간대. 기본 Asia/Seoul"),
            "onConflict" to onConflictS, "resolutions" to resolutionsS, "note" to noteS,
            required = listOf("program", "startDate"),
        ),
        output = writeOut,
        run = { ctx, a ->
            val program = a.obj("program", required = true)!!
            val startDate = a.str("startDate", required = true)!!
            parseDate(startDate, "startDate")
            val sp = buildJsonObject {
                put("program", program)
                put("startDate", startDate)
                if (a.has("tm")) put("tm", a.obj("tm")!!)
                if (a.has("working")) put("working", a.obj("working")!!)
                a.enum("skipPolicy", listOf("SHIFT", "FIXED_DATE"))?.let { put("skipPolicy", it) }
            }
            importBundle(ctx, a, bundleOf(a, "startPrograms" to JsonArray(listOf(sp))), tz = a.str("tz"))
        },
    ),
    Tool(
        name = "log_session", title = "운동 기록 추가",
        description = "이미 한 운동 세션 한 건(종목·세트)을 기록합니다. 종목은 id 또는 이름으로 지정합니다. exercises·sets 배열 순서가 수행 순서입니다. 앞으로 할 하루짜리 운동 계획은 schedule_workout, 여러 주 반복 규칙은 create_program 을 쓰세요. / Log one workout session that was already done; exercises by id or name. For a future one-day plan use schedule_workout; for a multi-week program use create_program.",
        write = true,
        input = S.obj(
            "session" to S.anyObj("import.schema.json 의 session: startedAt, exercises[{exercise:{id|name}, supersetGroup?(1~8자, 같은 값끼리 슈퍼세트), sets[{weightKg, reps, setType?(NORMAL|DROP|FAILURE), isWarmup?,...}]}] ..."),
            "onConflict" to onConflictS, "resolutions" to resolutionsS, "note" to noteS,
            required = listOf("session"),
        ),
        output = writeOut,
        run = { ctx, a ->
            val s = a.obj("session", required = true)!!
            importBundle(ctx, a, bundleOf(a, "sessions" to JsonArray(listOf(s))))
        },
    ),
    Tool(
        name = "schedule_workout", title = "예정 운동 추가",
        description = "앞으로 할 하루짜리 운동 계획(날짜·제목·종목별 세트 목표)을 예정 운동으로 저장합니다. 사용자가 그날 앱에서 눌러 시작하면 목표가 채워진 세션이 열립니다. items·sets 배열 순서가 수행 순서입니다. 이미 한 운동 기록은 log_session, 여러 주 반복 규칙은 create_program 을 쓰세요. 같은 날 같은 제목이 있으면 SCHEDULED_DUPLICATE 충돌(SKIP/KEEP_BOTH/REPLACE)로 알려줍니다. 예: 벨트 스쿼트 80kg×12 → {targetWeightKg:80,targetReps:12}, 12~15회 → targetReps 12 + targetRepsMax 15. / Save a future one-day workout plan (date, title, per-exercise set targets) as a scheduled workout the user can start in the app. Use log_session for workouts already done and create_program for multi-week programs.",
        write = true,
        input = S.obj(
            "workout" to S.obj(
                "plannedDate" to S.str("할 날짜 YYYY-MM-DD(사용자 현지)", format = "date"),
                "title" to S.str("제목 1~100자. 예: B-2 하체 2"),
                "note" to S.str("메모(최대 1000자). 예: RIR 3~4"),
                "items" to S.arr(
                    S.obj(
                        "exercise" to S.obj("id" to idS, "name" to S.str("종목 이름(한글·영문)"), desc = "id 또는 name 중 하나"),
                        "note" to S.str("종목 메모"),
                        "restSec" to S.int("세트 사이 목표 휴식(초) 0~3600", 0, 3600),
                        "sets" to S.arr(
                            S.obj(
                                "isWarmup" to S.bool("웜업 세트면 true. 기본 false"),
                                "targetWeightKg" to S.num("목표 무게(kg). 덤벨은 한쪽 무게", 0.0),
                                "targetReps" to S.int("목표 횟수(범위면 하한)", 0),
                                "targetRepsMax" to S.int("범위 상한. targetReps 이상이어야 하고 targetReps 도 함께 필요", 0),
                                "targetRir" to S.int("목표 RIR 0~10", 0, 10),
                                "targetRpe" to S.num("목표 RPE 1~10(0.5 단위)", 1.0, 10.0),
                                "targetDurationSec" to S.int("목표 시간(초)", 0),
                            ),
                            "1~50개. 모든 필드 선택",
                        ),
                        required = listOf("exercise", "sets"),
                    ),
                    "1~30개, 순서 = 운동 순서",
                ),
                required = listOf("plannedDate", "title", "items"),
                desc = "예정 운동 하나(import.schema.json 의 scheduledWorkout). id?, tz? 도 가능",
            ),
            "onConflict" to onConflictS, "resolutions" to resolutionsS, "note" to noteS,
            required = listOf("workout"),
        ),
        output = S.obj(
            *writeOut["properties"]!!.jsonObject.map { it.key to it.value }.toTypedArray(),
            "scheduledWorkouts" to S.arr(
                S.obj(
                    "id" to idS, "plannedDate" to S.str(format = "date"), "title" to S.str(), "itemCount" to S.int(),
                    required = listOf("id", "plannedDate", "title", "itemCount"),
                ),
                "이번 호출로 저장된 예정 운동",
            ),
            required = listOf("status"),
        ),
        run = { ctx, a ->
            val w = a.obj("workout", required = true)!!
            val out = importBundle(ctx, a, bundleOf(a, "scheduledWorkouts" to JsonArray(listOf(w))))
            if (out.data["status"]?.jsonPrimitive?.content != "SAVED") out else {
                val batchId = UUID.fromString(out.data["importBatchId"]!!.jsonPrimitive.content)
                val saved = dbQuery {
                    val ids = ImportItems.selectAll().where {
                        (ImportItems.batchId eq batchId) and (ImportItems.entity eq "scheduled_workout") and (ImportItems.action eq "CREATED")
                    }.map { it[ImportItems.entityId] }
                    ids.mapNotNull { findScheduled(ctx.userId, it) }
                }
                val arr = buildJsonArray {
                    saved.forEach {
                        add(buildJsonObject {
                            put("id", it.id.toString()); put("plannedDate", it.plannedDate); put("title", it.title); put("itemCount", it.items.size)
                        })
                    }
                }
                val text = if (saved.isEmpty()) out.text else out.text + saved.joinToString("") { " [${it.plannedDate} ${it.title}, 종목 ${it.items.size}개, id ${it.id}]" }
                ToolOutput(text, JsonObject(out.data + ("scheduledWorkouts" to arr)), out.code)
            }
        },
    ),
    Tool(
        name = "skip_scheduled_workout", title = "예정 운동 건너뛰기",
        description = "예정 운동을 건너뜀(SKIPPED)으로 표시하거나 skipped=false 로 되돌립니다. 삭제는 request_deletion 을 쓰세요. 이미 세션이 있으면 상태는 계속 DONE/IN_PROGRESS 입니다. / Mark a scheduled workout as skipped (or unskip with skipped=false); to delete use request_deletion.",
        write = true,
        input = S.obj("id" to idS, "skipped" to S.bool("기본 true. false 면 건너뜀 해제"), required = listOf("id")),
        output = S.obj("scheduledWorkout" to S.anyObj("예정 운동(status 포함)"), "message" to S.str(), required = listOf("scheduledWorkout")),
        run = { ctx, a ->
            val id = a.uuid("id")
            val skipped = a.bool("skipped") ?: true
            val w = dbQuery {
                lockUser(ctx.userId)
                val r = setScheduledSkipped(ctx.userId, id, skipped, Times.now()) ?: notFound("scheduled workout not found")
                scheduledJson(listOf(r)).single()
            }
            ToolOutput(
                "예정 운동 '${(w["title"] as JsonPrimitive).content}'을(를) " + (if (skipped) "건너뜀으로 표시했습니다" else "건너뜀을 해제했습니다") + " (상태 ${(w["status"] as JsonPrimitive).content}).",
                buildJsonObject { put("scheduledWorkout", w); put("message", if (skipped) "건너뜀으로 표시했습니다." else "건너뜀을 해제했습니다.") },
            )
        },
    ),
    Tool(
        name = "log_body_weight", title = "체중 기록 추가",
        description = "체중(kg) 한 건을 기록합니다. / Log one body weight measurement in kg.",
        write = true,
        input = S.obj(
            "measuredAt" to S.str("ISO-8601 시각(시간대 포함)", format = "date-time"),
            "weightKg" to S.num("20~400", 20.0, 400.0),
            "onConflict" to onConflictS, "resolutions" to resolutionsS, "note" to noteS,
            required = listOf("measuredAt", "weightKg"),
        ),
        output = writeOut,
        run = { ctx, a ->
            val at = a.str("measuredAt", required = true)!!
            Times.parse(at, "measuredAt")
            val w = a.num("weightKg", required = true)!!
            val m = buildJsonObject { put("measuredAt", at); put("weightKg", w) }
            importBundle(ctx, a, bundleOf(a, "bodyMeasurements" to JsonArray(listOf(m))))
        },
    ),
    Tool(
        name = "create_exercise", title = "종목 만들기",
        description = "내 종목을 하나 만듭니다. 같은 이름이 있으면 충돌로 알려줍니다. / Create a custom exercise; a same-name exercise is reported as a conflict.",
        write = true,
        input = S.obj(
            "id" to idS, "nameKo" to S.str(), "nameEn" to S.str(), "type" to S.str(enum = EXERCISE_TYPES.toList()),
            "primaryMuscle" to S.str(enum = MUSCLES.toList()), "secondaryMuscles" to S.arr(S.str(enum = MUSCLES.toList())),
            "onConflict" to onConflictS, "resolutions" to resolutionsS, "note" to noteS,
            required = listOf("nameKo", "type", "primaryMuscle"),
        ),
        output = writeOut,
        run = { ctx, a ->
            val ex = JsonObject(a.o.filterKeys { it !in setOf("onConflict", "resolutions", "note") })
            importBundle(ctx, a, bundleOf(a, "exercises" to JsonArray(listOf(ex))))
        },
    ),
    Tool(
        name = "adjust_program_instance", title = "프로그램 무게·상태 조정",
        description = "진행 중인 프로그램의 TM·작업 무게를 조정하거나 일시중지/재개합니다. 종료(FINISHED)와 삭제는 할 수 없습니다. / Adjust TM/working weights or pause/resume a program instance; finishing and deleting are not allowed.",
        write = true,
        input = S.obj(
            "instanceId" to idS, "tm" to S.map(S.num(min = 0.0), "리프트 키 → 새 TM(kg)"),
            "working" to S.map(S.num(min = 0.0), "리프트 키 → 새 작업 무게(kg)"),
            "status" to S.str(enum = listOf("ACTIVE", "PAUSED")),
            required = listOf("instanceId"),
        ),
        output = S.obj("instance" to S.anyObj("Instance"), "message" to S.str(), required = listOf("instance")),
        idempotent = true,
        run = { ctx, a ->
            val id = a.uuid("instanceId")
            val tm = a.numMap("tm")
            val working = a.numMap("working")
            val status = a.enum("status", listOf("ACTIVE", "PAUSED"))
            if (tm.isEmpty() && working.isEmpty() && status == null) validation("tm, working or status is required", "tm")
            val inst = dbQuery { mcpAdjustInstance(ctx.config.engine, ctx.userId, id, status, tm, working) }
            ToolOutput(
                "프로그램 '${inst.name}' 조정 완료 (상태 ${inst.status})",
                buildJsonObject { put("instance", enc(inst)); put("message", "조정했습니다. 앱의 프로그램 화면에서 확인할 수 있습니다.") },
            )
        },
    ),
    Tool(
        name = "request_deletion", title = "삭제 요청",
        description = "데이터를 직접 지우지 않고 삭제 요청만 만듭니다. 사용자가 앱에서 승인해야 실행되고 7일 안에 결정이 없으면 만료됩니다. / Only creates a deletion request; the user must approve it in the app (expires in 7 days).",
        write = true,
        input = S.obj(
            "entity" to S.str(enum = DELETE_ENTITIES.keys.toList()), "id" to idS,
            "reason" to S.str("사용자에게 보여줄 삭제 이유(최대 500자)"),
            required = listOf("entity", "id", "reason"),
        ),
        output = S.obj(
            "status" to S.str(enum = listOf("PENDING")), "created" to S.bool("false 면 이미 있던 PENDING 요청"),
            "request" to S.anyObj("id, entity, entityId, label, reason, status, createdAt, expiresAt"),
            "message" to S.str(), required = listOf("status", "request"),
        ),
        run = { ctx, a ->
            val entity = a.enum("entity", DELETE_ENTITIES.keys, required = true)!!
            val id = a.uuid("id")
            val reason = a.str("reason", required = true, max = 500)!!
            val (req, created) = createDeletionRequest(ctx, entity, id, reason)
            val label = (req["label"] as? JsonPrimitive)?.content ?: entity
            ToolOutput(
                (if (created) "삭제 요청을 만들었습니다" else "이미 대기 중인 삭제 요청이 있습니다") + ": $label. 사용자가 앱에서 승인해야 삭제됩니다.",
                buildJsonObject {
                    put("status", "PENDING")
                    put("created", created)
                    put("request", req)
                    put("message", "삭제는 아직 실행되지 않았습니다. 사용자가 앱에서 승인하면 실행됩니다.")
                },
            )
        },
    ),
)
