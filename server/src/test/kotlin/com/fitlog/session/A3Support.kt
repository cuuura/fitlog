package com.fitlog.session

import com.fitlog.core.ChangeSeq
import com.fitlog.core.Exercises
import com.fitlog.core.Ids
import com.fitlog.core.Times
import com.fitlog.support.auth
import com.fitlog.support.jsonBody
import io.ktor.client.HttpClient
import io.ktor.client.request.delete
import io.ktor.client.request.get
import io.ktor.client.request.post
import io.ktor.client.request.put
import io.ktor.client.request.setBody
import io.ktor.client.statement.HttpResponse
import io.ktor.client.statement.bodyAsText
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.jetbrains.exposed.sql.insert
import org.jetbrains.exposed.sql.SqlExpressionBuilder.eq
import org.jetbrains.exposed.sql.update
import org.jetbrains.exposed.sql.transactions.transaction
import java.util.UUID

/** A3 테스트 공용 도구 (session/body/sync 테스트가 함께 쓴다) */

fun newId(): String = Ids.newId().toString()

fun obj(s: String): JsonObject = Json.parseToJsonElement(s).jsonObject

suspend fun HttpResponse.obj(): JsonObject = Json.parseToJsonElement(bodyAsText()).jsonObject
suspend fun HttpResponse.arr(): JsonArray = Json.parseToJsonElement(bodyAsText()).jsonArray

fun JsonElement.str(key: String): String? = jsonObject[key]?.jsonPrimitive?.content

/** Exercises 테이블에 직접 종목을 넣는다(owner=null 이면 기본 종목) */
fun insertExercise(owner: UUID?, type: String = "BARBELL"): UUID {
    val id = Ids.newId()
    transaction {
        Exercises.insert {
            it[Exercises.id] = id
            it[ownerId] = owner
            it[nameKo] = "테스트 종목"
            it[Exercises.type] = type
            it[primaryMuscle] = "CHEST"
            it[secondaryMuscles] = emptyList()
            it[createdAt] = Times.now()
            it[updatedAt] = Times.now()
            it[serverSeq] = ChangeSeq.next
        }
    }
    return id
}

fun setJson(
    id: String = newId(),
    position: Int = 0,
    weightKg: String? = "100",
    reps: String? = "5",
    completed: Boolean = true,
    warmup: Boolean = false,
    extra: String = "",
): String = buildString {
    append("""{"id":"$id","position":$position,"isWarmup":$warmup""")
    if (weightKg != null) append(""","weightKg":$weightKg""")
    if (reps != null) append(""","reps":$reps""")
    if (completed) append(""","completedAt":"2026-11-26T10:05:00Z"""")
    if (extra.isNotEmpty()) append(",$extra")
    append("}")
}

fun exJson(id: String = newId(), exerciseId: UUID, position: Int = 0, sets: List<String> = emptyList()): String =
    """{"id":"$id","exerciseId":"$exerciseId","position":$position,"sets":[${sets.joinToString(",")}]}"""

fun sessionJson(
    id: String = newId(),
    startedAt: String = "2026-11-26T10:00:00Z",
    endedAt: String? = "2026-11-26T11:00:00Z",
    tz: String = "Asia/Seoul",
    exercises: List<String> = emptyList(),
): String {
    val end = if (endedAt != null) ""","endedAt":"$endedAt"""" else ""
    return """{"id":"$id","startedAt":"$startedAt"$end,"tz":"$tz","exercises":[${exercises.joinToString(",")}]}"""
}

suspend fun HttpClient.putSession(uid: UUID, id: String, body: String): HttpResponse =
    put("/v1/sessions/$id") { auth(uid); jsonBody(); setBody(body) }

suspend fun HttpClient.getSession(uid: UUID, id: String): HttpResponse = get("/v1/sessions/$id") { auth(uid) }

suspend fun HttpClient.deleteSession(uid: UUID, id: String): HttpResponse = delete("/v1/sessions/$id") { auth(uid) }

suspend fun HttpClient.push(uid: UUID, vararg changes: String): HttpResponse =
    post("/v1/sync/push") { auth(uid); jsonBody(); setBody("""{"changes":[${changes.joinToString(",")}]}""") }

suspend fun HttpClient.pull(uid: UUID, since: Long): HttpResponse = get("/v1/sync/pull?since=$since") { auth(uid) }

/** push Change JSON 한 건 */
fun change(entity: String, id: String, op: String = "UPSERT", at: String, parentId: String? = null, payload: String? = null): String =
    buildString {
        append("""{"entity":"$entity","id":"$id","op":"$op","clientUpdatedAt":"$at"""")
        if (parentId != null) append(""","parentId":"$parentId"""")
        if (payload != null) append(""","payload":$payload""")
        append("}")
    }

fun softDeleteExercise(id: UUID) {
    transaction {
        Exercises.update({ Exercises.id eq id }) { it[deletedAt] = Times.now() }
    }
}

operator fun JsonElement.get(key: String): JsonElement? = jsonObject[key]
