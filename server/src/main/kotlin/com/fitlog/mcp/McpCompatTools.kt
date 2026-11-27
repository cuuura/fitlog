package com.fitlog.mcp

import com.fitlog.core.AppJson
import com.fitlog.core.Exercises
import com.fitlog.core.Ids
import com.fitlog.core.ProgramInstances
import com.fitlog.core.Programs
import com.fitlog.core.SessionExercises
import com.fitlog.core.dbQuery
import com.fitlog.core.lockUser
import com.fitlog.core.notFound
import com.fitlog.core.validation
import com.fitlog.engine.ProgramDefinition
import com.fitlog.exercise.toExercise
import com.fitlog.session.listSummaries
import com.fitlog.session.loadSession
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.jetbrains.exposed.sql.SqlExpressionBuilder.eq
import org.jetbrains.exposed.sql.SqlExpressionBuilder.inList
import org.jetbrains.exposed.sql.SqlExpressionBuilder.isNull
import org.jetbrains.exposed.sql.and
import org.jetbrains.exposed.sql.or
import org.jetbrains.exposed.sql.selectAll
import java.time.ZoneId
import java.util.UUID

/**
 * OpenAI(ChatGPT) 커넥터 호환 도구 `search`·`fetch`.
 * 개발자 모드 밖(일반 채팅·deep research)의 커넥터는 이 이름의 읽기 전용 도구를 요구한다.
 * 응답 content 텍스트는 JSON 문자열이어야 한다(OpenAI 사양).
 */

private const val MAX_RESULTS = 20
private val ID_PREFIXES = listOf("session", "exercise", "program", "instance")

/** 실제로 열리지 않아도 되는 안정적인 식별용 URL */
private fun fixedUrl(ctx: ToolCtx, id: String) = "${ctx.config.publicBaseUrl}/r/$id"

private fun norm(s: String) = s.filterNot { it.isWhitespace() }.lowercase()

private fun parseId(raw: String): Pair<String, UUID> {
    val i = raw.indexOf(':')
    if (i <= 0) validation("id must look like session:<uuid>, exercise:<uuid>, program:<uuid> or instance:<uuid>", "id")
    val kind = raw.substring(0, i)
    if (kind !in ID_PREFIXES) validation("unknown id kind '$kind'", "id")
    return kind to Ids.parse(raw.substring(i + 1), "id")
}

private fun kg(v: Double?): String = v?.let { if (it % 1.0 == 0.0) it.toLong().toString() else it.toString() } ?: "-"

private val searchIn = S.obj(
    "query" to S.str("검색어: 종목·프로그램 이름 또는 날짜(예: 2026-11-27). / Search text: exercise or program name, or a date."),
    required = listOf("query"),
)
private val searchOut = S.obj(
    "results" to S.arr(S.obj("id" to S.str(), "title" to S.str(), "url" to S.str(), required = listOf("id", "title", "url"))),
    required = listOf("results"),
)
private val fetchIn = S.obj(
    "id" to S.str("search 가 돌려준 id (session:/exercise:/program:/instance: 접두사). / An id returned by search."),
    required = listOf("id"),
)
private val fetchOut = S.obj(
    "id" to S.str(), "title" to S.str(), "text" to S.str(), "url" to S.str(), "metadata" to S.anyObj(),
    required = listOf("id", "title", "text", "url"),
)

private class Fetched(val title: String, val text: String, val meta: JsonObject)

internal val OPENAI_COMPAT_TOOLS: List<Tool> = listOf(
    Tool(
        name = "search", title = "검색",
        description = "내 기록(종목, 운동 세션, 프로그램, 진행 중인 프로그램)을 이름·날짜로 검색합니다. 결과의 id 를 fetch 에 넘기세요. / Search my fitness data (exercises, workout sessions, programs, instances) by name or date; pass a result id to fetch.",
        write = false, input = searchIn, output = searchOut,
        run = { ctx, a ->
            val q = a.str("query", required = true)!!
            val nq = norm(q)
            val dateQ = q.trim().replace('.', '-').replace('/', '-')
            val found = dbQuery {
                lockUser(ctx.userId)
                val out = ArrayList<Triple<String, String, String>>() // 종류, uuid, 제목
                val exercises = Exercises.selectAll().where {
                    Exercises.deletedAt.isNull() and (Exercises.ownerId.isNull() or (Exercises.ownerId eq ctx.userId))
                }.map { it.toExercise() }
                val matched = exercises.filter { e -> norm(e.nameKo).contains(nq) || (e.nameEn != null && norm(e.nameEn).contains(nq)) }
                matched.sortedBy { it.nameKo }.forEach { out += Triple("exercise", it.id.toString(), "종목: ${it.nameKo}") }

                // 세션: 날짜 문자열이 맞거나 일치한 종목을 한 세션
                val matchedIds = matched.map { it.id }
                val withExercise: Set<UUID> = if (matchedIds.isEmpty()) emptySet() else SessionExercises.selectAll()
                    .where { (SessionExercises.exerciseId inList matchedIds) and SessionExercises.deletedAt.isNull() }
                    .map { it[SessionExercises.sessionId] }.toSet()
                listSummaries(ctx.userId, null, 200).forEach { s ->
                    val date = s.startedAt.atZone(ZoneId.of(s.tz)).toLocalDate().toString()
                    if (date.contains(dateQ) || s.id in withExercise) {
                        out += Triple("session", s.id.toString(), "세션 $date (종목 ${s.exerciseCount}개, 세트 ${s.setCount}개)")
                    }
                }
                Programs.selectAll().where {
                    Programs.deletedAt.isNull() and (Programs.ownerId.isNull() or (Programs.ownerId eq ctx.userId))
                }.forEach { r ->
                    if (norm(r[Programs.name]).contains(nq)) out += Triple("program", r[Programs.id].toString(), "프로그램: ${r[Programs.name]}")
                }
                ProgramInstances.selectAll().where { (ProgramInstances.userId eq ctx.userId) and ProgramInstances.deletedAt.isNull() }
                    .toList().map { mcpInstanceView(ctx.config.engine, it, withNext = false) }
                    .filter { norm(it.name).contains(nq) }
                    .forEach { out += Triple("instance", it.id.toString(), "진행 중인 프로그램: ${it.name} (${it.status})") }
                out
            }.take(MAX_RESULTS)
            val results = buildJsonArray {
                found.forEach { (kind, uuid, title) ->
                    val id = "$kind:$uuid"
                    add(buildJsonObject { put("id", id); put("title", title); put("url", fixedUrl(ctx, id)) })
                }
            }
            val data = buildJsonObject { put("results", results) }
            // OpenAI 사양: content 텍스트가 곧 {"results":[...]} JSON 문자열
            ToolOutput(data.toString(), data)
        },
    ),
    Tool(
        name = "fetch", title = "상세 조회",
        description = "search 결과 id 의 내용(세션 세트 기록, 종목 PR, 프로그램 정의 요약 등)을 읽기 좋은 텍스트로 돌려줍니다. / Fetch the readable content for an id returned by search.",
        write = false, input = fetchIn, output = fetchOut,
        run = { ctx, a ->
            val (kind, uuid) = parseId(a.str("id", required = true)!!)
            val id = "$kind:$uuid"
            val f = dbQuery {
                when (kind) {
                    "session" -> {
                        val s = loadSession(ctx.userId, uuid) ?: notFound("session not found")
                        val ids = s.exercises.map { it.exerciseId }.distinct()
                        val names = if (ids.isEmpty()) emptyMap() else Exercises.select(Exercises.id, Exercises.nameKo)
                            .where { Exercises.id inList ids }.associate { it[Exercises.id] to it[Exercises.nameKo] }
                        val date = s.startedAt.atZone(ZoneId.of(s.tz)).toLocalDate().toString()
                        val text = buildString {
                            append("운동 세션 $date (시간대 ${s.tz}, 무게 단위 kg)\n")
                            s.note?.let { append("메모: $it\n") }
                            s.exercises.sortedBy { it.position }.forEach { ex ->
                                append("- ").append(names[ex.exerciseId] ?: ex.exerciseId.toString()).append(": ")
                                append(ex.sets.sortedBy { it.position }.joinToString(", ") { st ->
                                    (if (st.isWarmup) "워밍업 " else "") + when {
                                        st.weightKg != null || st.reps != null -> "${kg(st.weightKg)}×${st.reps ?: "-"}"
                                        st.durationSec != null -> "${st.durationSec}초"
                                        else -> "-"
                                    } + (st.rir?.let { " RIR$it" } ?: "")
                                }.ifEmpty { "세트 없음" })
                                append('\n')
                            }
                        }.trimEnd()
                        Fetched("세션 $date", text, buildJsonObject {
                            put("type", "session"); put("date", date); put("exerciseCount", s.exercises.size)
                            put("setCount", s.exercises.sumOf { it.sets.size })
                        })
                    }
                    "exercise" -> {
                        val e = Exercises.selectAll().where {
                            (Exercises.id eq uuid) and Exercises.deletedAt.isNull() and (Exercises.ownerId.isNull() or (Exercises.ownerId eq ctx.userId))
                        }.firstOrNull()?.toExercise() ?: notFound("exercise not found")
                        val r = mcpExerciseRecords(ctx.userId, uuid)
                        val text = buildString {
                            append("종목 ${e.nameKo}").append(e.nameEn?.let { " ($it)" } ?: "").append('\n')
                            append("유형 ${e.type}, 주동근 ${e.primaryMuscle}")
                            if (e.secondaryMuscles.isNotEmpty()) append(", 보조 ${e.secondaryMuscles.joinToString()}")
                            append('\n')
                            append("최고 무게: ").append(r.bestWeight?.let { "${kg(it.weightKg)}kg × ${it.reps}" } ?: "기록 없음").append('\n')
                            append("최고 추정 1RM(${r.formula}): ").append(r.bestE1rm?.e1rmKg?.let { "${kg(it)}kg" } ?: "기록 없음")
                            if (r.byReps.isNotEmpty()) {
                                append("\n횟수별 최고: ").append(r.byReps.sortedBy { it.reps }.joinToString(", ") { "${it.reps}회 ${kg(it.point.weightKg)}kg" })
                            }
                        }
                        Fetched("종목: ${e.nameKo}", text, buildJsonObject { put("type", "exercise"); put("builtIn", e.builtIn) })
                    }
                    "program" -> {
                        val row = Programs.selectAll().where {
                            (Programs.id eq uuid) and Programs.deletedAt.isNull() and (Programs.ownerId.isNull() or (Programs.ownerId eq ctx.userId))
                        }.firstOrNull() ?: notFound("program not found")
                        val def = AppJson.decodeFromString<ProgramDefinition>(row[Programs.definition])
                        val name = row[Programs.name]
                        val text = buildString {
                            append("프로그램 $name (${def.days.size}일 구성)\n")
                            def.description?.let { append(it).append('\n') }
                            def.days.forEach { d -> append("- ${d.name}: ${d.exercises.size}종목\n") }
                        }.trimEnd()
                        Fetched("프로그램: $name", text, buildJsonObject { put("type", "program"); put("dayCount", def.days.size) })
                    }
                    else -> {
                        lockUser(ctx.userId)
                        val row = ProgramInstances.selectAll().where {
                            (ProgramInstances.id eq uuid) and (ProgramInstances.userId eq ctx.userId) and ProgramInstances.deletedAt.isNull()
                        }.firstOrNull() ?: notFound("instance not found")
                        val v = mcpInstanceView(ctx.config.engine, row)
                        val text = buildString {
                            append("진행 중인 프로그램 ${v.name} (${v.status}), 시작일 ${v.startDate}\n")
                            append("주차 ${v.state.week}, 사이클 ${v.state.cycle}, 완료 회차 ${v.state.seq}\n")
                            if (v.state.tm.isNotEmpty()) append("TM(kg): ").append(v.state.tm.entries.joinToString(", ") { "${it.key} ${kg(it.value)}" }).append('\n')
                            if (v.state.working.isNotEmpty()) append("작업 무게(kg): ").append(v.state.working.entries.joinToString(", ") { "${it.key} ${kg(it.value)}" }).append('\n')
                            v.next?.let { append("다음 회차: ${it.dayName}") }
                        }.trimEnd()
                        Fetched("진행 중인 프로그램: ${v.name}", text, buildJsonObject { put("type", "instance"); put("status", v.status) })
                    }
                }
            }
            val data = buildJsonObject {
                put("id", id); put("title", f.title); put("text", f.text); put("url", fixedUrl(ctx, id)); put("metadata", f.meta)
            }
            ToolOutput(data.toString(), data)
        },
    ),
)
