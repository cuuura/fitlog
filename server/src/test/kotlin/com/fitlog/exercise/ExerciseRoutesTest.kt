package com.fitlog.exercise

import com.fitlog.core.AppJson
import com.fitlog.core.Ids
import com.fitlog.support.auth
import com.fitlog.support.createUser
import com.fitlog.support.fitlogTest
import com.fitlog.support.jsonBody
import com.fitlog.support.jsonClient
import io.ktor.client.HttpClient
import io.ktor.client.call.body
import io.ktor.client.request.delete
import io.ktor.client.request.get
import io.ktor.client.request.post
import io.ktor.client.request.put
import io.ktor.client.request.setBody
import io.ktor.client.statement.HttpResponse
import io.ktor.client.statement.bodyAsText
import io.ktor.http.HttpStatusCode
import io.ktor.server.testing.ApplicationTestBuilder
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.Json
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ExerciseRoutesTest {
    private val squatId = UUID.fromString("019b76da-4000-7000-8000-000000000001")

    private fun input(
        id: UUID = Ids.newId(),
        nameKo: String = "내 종목",
        nameEn: String? = "My Exercise",
        type: String = "DUMBBELL",
        primary: String = "CHEST",
        secondary: List<String> = listOf("TRICEPS"),
    ) = ExerciseInput(id, nameKo, nameEn, type, primary, secondary)

    private suspend fun HttpClient.list(uid: UUID, query: String = ""): List<Exercise> =
        get("/v1/exercises$query") { auth(uid) }.body()

    private suspend fun HttpClient.create(uid: UUID, e: ExerciseInput): HttpResponse =
        post("/v1/exercises") { auth(uid); jsonBody(); setBody(e) }

    private suspend fun errorCode(res: HttpResponse): Pair<String, String?> {
        val err = Json.parseToJsonElement(res.bodyAsText()).jsonObject["error"]!!.jsonObject
        return err["code"]!!.jsonPrimitive.content to err["field"]?.jsonPrimitive?.content
    }

    private suspend fun ApplicationTestBuilder.user(): UUID {
        startApplication()
        return createUser()
    }

    @Test
    fun seed_has_expected_count_and_fixed_ids() = fitlogTest {
        val c = jsonClient()
        val uid = user()
        val all = c.list(uid)
        val builtIn = all.filter { it.builtIn }
        assertTrue(builtIn.size >= 70, "seed count ${builtIn.size}")
        val squat = builtIn.single { it.id == squatId }
        assertEquals("스쿼트", squat.nameKo)
        assertEquals("BARBELL", squat.type)
        val types = builtIn.map { it.type }.toSet()
        assertEquals(setOf("BARBELL", "DUMBBELL", "MACHINE", "BODYWEIGHT", "BAND", "CARDIO"), types)
        assertTrue(builtIn.all { it.primaryMuscle in MUSCLES && it.secondaryMuscles.all { m -> m in MUSCLES } })
        // sorted by nameKo
        assertEquals(all.map { it.nameKo }, all.map { it.nameKo }.sorted())
    }

    @Test
    fun search_by_korean_english_and_whitespace_insensitive() = fitlogTest {
        val c = jsonClient()
        val uid = user()
        assertTrue(c.list(uid, "?q=${enc("벤치프레스")}").any { it.nameEn == "Bench Press" })
        assertTrue(c.list(uid, "?q=${enc("벤치 프레스")}").any { it.nameEn == "Bench Press" })
        assertTrue(c.list(uid, "?q=${enc("벤치프레스")}").any { it.nameKo == "인클라인 벤치프레스" })
        assertTrue(c.list(uid, "?q=${enc("bench press")}").any { it.nameEn == "Bench Press" })
        assertTrue(c.list(uid, "?q=${enc("BENCHPRESS")}").any { it.nameEn == "Bench Press" })
        assertTrue(c.list(uid, "?q=zzzznothing").isEmpty())
    }

    @Test
    fun filter_by_muscle_and_type() = fitlogTest {
        val c = jsonClient()
        val uid = user()
        val chest = c.list(uid, "?muscle=CHEST")
        assertTrue(chest.isNotEmpty())
        assertTrue(chest.all { it.primaryMuscle == "CHEST" || "CHEST" in it.secondaryMuscles })
        assertTrue(chest.any { it.primaryMuscle != "CHEST" }, "secondary match included")
        val cardio = c.list(uid, "?type=CARDIO")
        assertTrue(cardio.size in 3..4 && cardio.all { it.type == "CARDIO" })
        val combo = c.list(uid, "?type=BARBELL&muscle=QUADS&q=${enc("스쿼트")}")
        assertTrue(combo.isNotEmpty() && combo.all { it.type == "BARBELL" })
    }

    @Test
    fun invalid_filter_enums_return_400() = fitlogTest {
        val c = jsonClient()
        val uid = user()
        val r1 = c.get("/v1/exercises?muscle=NOPE") { auth(uid) }
        assertEquals(HttpStatusCode.BadRequest, r1.status)
        assertEquals("VALIDATION_FAILED" to "muscle", errorCode(r1))
        val r2 = c.get("/v1/exercises?type=NOPE") { auth(uid) }
        assertEquals("VALIDATION_FAILED" to "type", errorCode(r2))
    }

    @Test
    fun requires_authentication() = fitlogTest {
        val c = jsonClient()
        assertEquals(HttpStatusCode.Unauthorized, c.get("/v1/exercises").status)
    }

    @Test
    fun create_update_delete_flow() = fitlogTest {
        val c = jsonClient()
        val uid = user()
        val e = input(nameKo = "케이블 힙 킥백")
        val res = c.create(uid, e)
        assertEquals(HttpStatusCode.Created, res.status)
        val created: Exercise = res.body()
        assertEquals(e.id, created.id)
        assertFalse(created.builtIn)
        assertEquals(listOf("TRICEPS"), created.secondaryMuscles)
        assertTrue(c.list(uid).any { it.id == e.id })

        val upd = c.put("/v1/exercises/${e.id}") {
            auth(uid); jsonBody(); setBody(e.copy(nameKo = "수정됨", nameEn = null, type = "MACHINE"))
        }
        assertEquals(HttpStatusCode.OK, upd.status)
        val updated: Exercise = upd.body()
        assertEquals("수정됨", updated.nameKo)
        assertNull(updated.nameEn)
        assertEquals("MACHINE", updated.type)
        assertTrue(updated.updatedAt >= created.updatedAt)

        assertEquals(HttpStatusCode.NoContent, c.delete("/v1/exercises/${e.id}") { auth(uid) }.status)
        assertFalse(c.list(uid).any { it.id == e.id })
        // idempotent delete
        assertEquals(HttpStatusCode.NoContent, c.delete("/v1/exercises/${e.id}") { auth(uid) }.status)
        // update after delete is 404
        val after = c.put("/v1/exercises/${e.id}") { auth(uid); jsonBody(); setBody(e) }
        assertEquals(HttpStatusCode.NotFound, after.status)
    }

    @Test
    fun create_same_id_is_idempotent_upsert() = fitlogTest {
        val c = jsonClient()
        val uid = user()
        val e = input()
        assertEquals(HttpStatusCode.Created, c.create(uid, e).status)
        val again = c.create(uid, e.copy(nameKo = "다시"))
        assertEquals(HttpStatusCode.Created, again.status)
        assertEquals("다시", again.body<Exercise>().nameKo)
        assertEquals(1, c.list(uid).count { it.id == e.id })
        // re-create after soft delete revives it
        c.delete("/v1/exercises/${e.id}") { auth(uid) }
        assertEquals(HttpStatusCode.Created, c.create(uid, e).status)
        assertTrue(c.list(uid).any { it.id == e.id })
    }

    @Test
    fun create_conflicts_with_builtin_and_other_user_ids() = fitlogTest {
        val c = jsonClient()
        val a = user()
        val b = createUser()
        val r1 = c.create(a, input(id = squatId))
        assertEquals(HttpStatusCode.Conflict, r1.status)
        assertEquals("CONFLICT", errorCode(r1).first)
        val e = input()
        assertEquals(HttpStatusCode.Created, c.create(a, e).status)
        assertEquals(HttpStatusCode.Conflict, c.create(b, e).status)
    }

    @Test
    fun other_users_exercises_are_invisible_and_untouchable() = fitlogTest {
        val c = jsonClient()
        val a = user()
        val b = createUser()
        val e = input(nameKo = "비밀종목")
        c.create(a, e)
        assertTrue(c.list(a).any { it.id == e.id })
        assertFalse(c.list(b).any { it.id == e.id })
        assertFalse(c.list(b, "?q=${enc("비밀")}").any { it.id == e.id })
        assertEquals(HttpStatusCode.NotFound, c.put("/v1/exercises/${e.id}") { auth(b); jsonBody(); setBody(e) }.status)
        assertEquals(HttpStatusCode.NotFound, c.delete("/v1/exercises/${e.id}") { auth(b) }.status)
        assertTrue(c.list(a).any { it.id == e.id })
    }

    @Test
    fun builtin_cannot_be_modified_or_deleted() = fitlogTest {
        val c = jsonClient()
        val uid = user()
        val put = c.put("/v1/exercises/$squatId") { auth(uid); jsonBody(); setBody(input(id = squatId)) }
        assertEquals(HttpStatusCode.Forbidden, put.status)
        assertEquals("FORBIDDEN", errorCode(put).first)
        assertEquals(HttpStatusCode.Forbidden, c.delete("/v1/exercises/$squatId") { auth(uid) }.status)
    }

    @Test
    fun unknown_id_returns_404() = fitlogTest {
        val c = jsonClient()
        val uid = user()
        val id = Ids.newId()
        assertEquals(HttpStatusCode.NotFound, c.put("/v1/exercises/$id") { auth(uid); jsonBody(); setBody(input(id = id)) }.status)
        assertEquals(HttpStatusCode.NotFound, c.delete("/v1/exercises/$id") { auth(uid) }.status)
    }

    @Test
    fun put_with_mismatched_body_id_returns_400() = fitlogTest {
        val c = jsonClient()
        val uid = user()
        val e = input()
        c.create(uid, e)
        val res = c.put("/v1/exercises/${e.id}") { auth(uid); jsonBody(); setBody(e.copy(id = Ids.newId())) }
        assertEquals(HttpStatusCode.BadRequest, res.status)
        assertEquals("VALIDATION_FAILED" to "id", errorCode(res))
    }

    @Test
    fun validation_errors_report_field() = fitlogTest {
        val c = jsonClient()
        val uid = user()
        suspend fun field(e: ExerciseInput): String? {
            val res = c.create(uid, e)
            assertEquals(HttpStatusCode.BadRequest, res.status)
            return errorCode(res).second
        }
        assertEquals("nameKo", field(input(nameKo = "")))
        assertEquals("nameKo", field(input(nameKo = "   ")))
        assertEquals("nameKo", field(input(nameKo = "가".repeat(61))))
        assertEquals("nameEn", field(input(nameEn = "a".repeat(61))))
        assertEquals("type", field(input(type = "KETTLEBELL")))
        assertEquals("primaryMuscle", field(input(primary = "NECK")))
        assertEquals("secondaryMuscles[1]", field(input(secondary = listOf("CHEST", "WINGS"))))
        // boundary: 60 chars ok
        assertEquals(HttpStatusCode.Created, c.create(uid, input(nameKo = "가".repeat(60), nameEn = "a".repeat(60))).status)
        // not even JSON of the right shape
        val bad = c.post("/v1/exercises") { auth(uid); jsonBody(); setBody("""{"nameKo":"x"}""") }
        assertEquals(HttpStatusCode.BadRequest, bad.status)
    }

    @Test
    fun user_created_exercise_is_searchable_by_name() = fitlogTest {
        val c = jsonClient()
        val uid = user()
        val e = input(nameKo = "아놀드 프레스 변형", nameEn = "Arnold Press Variant", primary = "SHOULDERS")
        c.create(uid, e)
        assertEquals(listOf(e.id), c.list(uid, "?q=${enc("아놀드프레스")}").map { it.id })
        assertEquals(listOf(e.id), c.list(uid, "?q=arnold&muscle=SHOULDERS&type=DUMBBELL").map { it.id })
        assertTrue(AppJson.encodeToString(Exercise.serializer(), c.list(uid).first { it.id == e.id }).contains("\"builtIn\":false"))
    }

    private fun enc(s: String) = java.net.URLEncoder.encode(s, "UTF-8")
}
