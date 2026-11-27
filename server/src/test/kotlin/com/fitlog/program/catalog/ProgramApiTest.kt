package com.fitlog.program.catalog

import com.fitlog.core.AppJson
import com.fitlog.core.Exercises
import com.fitlog.core.Ids
import com.fitlog.core.Times
import com.fitlog.support.auth
import com.fitlog.support.createUser
import com.fitlog.support.fitlogTest
import com.fitlog.support.jsonBody
import com.fitlog.support.jsonClient
import io.ktor.client.request.delete
import io.ktor.client.request.get
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.HttpResponse
import io.ktor.client.statement.bodyAsText
import io.ktor.http.HttpStatusCode
import io.ktor.server.testing.ApplicationTestBuilder
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.jetbrains.exposed.sql.insert
import org.jetbrains.exposed.sql.transactions.transaction
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ProgramApiTest {
    private val squatId = "019b76da-4000-7000-8000-000000000001"

    private fun def(name: String = "My Program", lift: String = """{"id":"$squatId"}""") = """
        {"schemaVersion":1,"name":"$name","description":"d",
         "lifts":{"squat":{"exercise":$lift}},
         "progression":{"squat":{"type":"LINEAR","incrementKg":2.5}},
         "days":[{"key":"A","name":"Day A","exercises":[{"lift":"squat","sets":[{"count":5,"reps":5,"load":{"type":"WORKING"}}]}]}]}
    """.trimIndent()

    private fun json(s: String) = Json.parseToJsonElement(s)

    private suspend fun ApplicationTestBuilder.user(): UUID {
        startApplication()
        return createUser()
    }

    private suspend fun ApplicationTestBuilder.save(uid: UUID, id: UUID, definition: String): HttpResponse =
        jsonClient().post("/v1/programs") { auth(uid); jsonBody(); setBody("""{"id":"$id","definition":$definition}""") }

    private suspend fun HttpResponse.obj() = Json.parseToJsonElement(bodyAsText()).jsonObject

    private fun addExercise(owner: UUID, ko: String, en: String?): UUID {
        val id = Ids.newId()
        transaction {
            Exercises.insert {
                it[Exercises.id] = id
                it[ownerId] = owner
                it[nameKo] = ko
                it[nameEn] = en
                it[type] = "DUMBBELL"
                it[primaryMuscle] = "CHEST"
                it[secondaryMuscles] = emptyList()
                it[createdAt] = Times.now()
                it[updatedAt] = Times.now()
                it[serverSeq] = 1L
            }
        }
        return id
    }

    @Test
    fun templates_are_seeded_with_fixed_ids_and_listed() = fitlogTest {
        val uid = user()
        val res = jsonClient().get("/v1/programs?source=TEMPLATE") { auth(uid) }
        assertEquals(HttpStatusCode.OK, res.status)
        val arr = Json.parseToJsonElement(res.bodyAsText()).jsonArray
        assertTrue(arr.size >= 5)
        val byKey = arr.map { it.jsonObject }.associateBy { it["templateKey"]?.jsonPrimitive?.content }
        val keys = listOf("stronglifts-5x5", "nsuns-4day", "wendler-531-bbb", "gzclp", "texas-method")
        keys.forEachIndexed { i, k ->
            val o = byKey[k]!!
            assertEquals("019b76da-5000-7000-8000-00000000000${i + 1}", o["id"]!!.jsonPrimitive.content)
            assertEquals("true", o["builtIn"]!!.jsonPrimitive.content)
            assertEquals("TEMPLATE", o["source"]!!.jsonPrimitive.content)
        }
        assertEquals("2", byKey["stronglifts-5x5"]!!["dayCount"]!!.jsonPrimitive.content)
        assertEquals("4", byKey["nsuns-4day"]!!["dayCount"]!!.jsonPrimitive.content)
        assertEquals("3", byKey["texas-method"]!!["dayCount"]!!.jsonPrimitive.content)
    }

    @Test
    fun list_and_detail_expose_category_for_templates_and_null_for_plain_user_program() = fitlogTest {
        val uid = user()
        val mineId = Ids.newId()
        save(uid, mineId, def("Mine"))
        val arr = Json.parseToJsonElement(jsonClient().get("/v1/programs") { auth(uid) }.bodyAsText()).jsonArray.map { it.jsonObject }
        val sl = arr.first { it["templateKey"]?.jsonPrimitive?.content == "stronglifts-5x5" }
        assertEquals("GENERAL_STRENGTH", sl["category"]!!.jsonPrimitive.content)
        val mine = arr.first { it["id"]!!.jsonPrimitive.content == mineId.toString() }
        assertTrue(mine["category"] == null || mine["category"] is kotlinx.serialization.json.JsonNull)
        val detail = jsonClient().get("/v1/programs/${sl["id"]!!.jsonPrimitive.content}") { auth(uid) }.obj()
        assertEquals("GENERAL_STRENGTH", detail["category"]!!.jsonPrimitive.content)
        assertEquals("GENERAL_STRENGTH", detail["definition"]!!.jsonObject["category"]!!.jsonPrimitive.content)
        val withCat = Ids.newId()
        val d = def("Cat").replaceFirst("\"description\":\"d\",", "\"description\":\"d\",\"category\":\"BODYBUILDING\",")
        assertEquals(HttpStatusCode.Created, save(uid, withCat, d).status)
        val got = jsonClient().get("/v1/programs/$withCat") { auth(uid) }.obj()
        assertEquals("BODYBUILDING", got["category"]!!.jsonPrimitive.content)
    }

    @Test
    fun seeding_is_idempotent() = fitlogTest {
        val uid = user()
        seedProgramTemplates()
        seedProgramTemplates()
        val arr = Json.parseToJsonElement(jsonClient().get("/v1/programs?source=TEMPLATE") { auth(uid) }.bodyAsText()).jsonArray
        val ids = arr.map { it.jsonObject["id"]!!.jsonPrimitive.content }
        assertEquals(ids.size, ids.toSet().size)
    }

    @Test
    fun template_detail_has_definition_with_ids_only() = fitlogTest {
        val uid = user()
        val res = jsonClient().get("/v1/programs/019b76da-5000-7000-8000-000000000001") { auth(uid) }
        assertEquals(HttpStatusCode.OK, res.status)
        val o = res.obj()
        assertEquals("stronglifts-5x5", o["templateKey"]!!.jsonPrimitive.content)
        val squat = o["definition"]!!.jsonObject["lifts"]!!.jsonObject["squat"]!!.jsonObject["exercise"]!!.jsonObject
        assertEquals(squatId, squat["id"]!!.jsonPrimitive.content)
        assertNull(squat["name"])
    }

    @Test
    fun create_resolves_names_and_returns_201() = fitlogTest {
        val uid = user()
        val id = Ids.newId()
        val res = save(uid, id, def(lift = """{"name":" 스 쿼트 "}"""))
        assertEquals(HttpStatusCode.Created, res.status, res.bodyAsText())
        val o = res.obj()
        assertEquals(id.toString(), o["id"]!!.jsonPrimitive.content)
        assertEquals("USER", o["source"]!!.jsonPrimitive.content)
        assertEquals("false", o["builtIn"]!!.jsonPrimitive.content)
        assertEquals("1", o["dayCount"]!!.jsonPrimitive.content)
        val ex = o["definition"]!!.jsonObject["lifts"]!!.jsonObject["squat"]!!.jsonObject["exercise"]!!.jsonObject
        assertEquals(squatId, ex["id"]!!.jsonPrimitive.content)
        // GET 으로도 같은 정의
        val got = jsonClient().get("/v1/programs/$id") { auth(uid) }.obj()
        assertEquals(o["definition"], got["definition"])
    }

    @Test
    fun english_name_match_is_case_and_space_insensitive() = fitlogTest {
        val uid = user()
        val res = save(uid, Ids.newId(), def(lift = """{"name":"barbell BACK squat"}"""))
        assertEquals(HttpStatusCode.Created, res.status, res.bodyAsText())
    }

    @Test
    fun own_exercise_wins_over_builtin_for_same_name() = fitlogTest {
        val uid = user()
        val mine = addExercise(uid, "스쿼트", "My Squat")
        val res = save(uid, Ids.newId(), def(lift = """{"name":"스쿼트"}"""))
        assertEquals(HttpStatusCode.Created, res.status, res.bodyAsText())
        val ex = res.obj()["definition"]!!.jsonObject["lifts"]!!.jsonObject["squat"]!!.jsonObject["exercise"]!!.jsonObject
        assertEquals(mine.toString(), ex["id"]!!.jsonPrimitive.content)
    }

    @Test
    fun ambiguous_own_names_are_an_error() = fitlogTest {
        val uid = user()
        addExercise(uid, "중복이름", null)
        addExercise(uid, "중복이름", "Dup")
        val res = save(uid, Ids.newId(), def(lift = """{"name":"중복이름"}"""))
        assertEquals(HttpStatusCode.BadRequest, res.status)
        val details = res.obj()["error"]!!.jsonObject["details"]!!.jsonArray
        assertEquals("/lifts/squat/exercise/name", details[0].jsonObject["path"]!!.jsonPrimitive.content)
    }

    @Test
    fun other_users_exercise_is_not_visible() = fitlogTest {
        val uid = user()
        val other = createUser()
        val theirs = addExercise(other, "남의종목", "Theirs")
        assertEquals(HttpStatusCode.BadRequest, save(uid, Ids.newId(), def(lift = """{"id":"$theirs"}""")).status)
        assertEquals(HttpStatusCode.BadRequest, save(uid, Ids.newId(), def(lift = """{"name":"남의종목"}""")).status)
    }

    @Test
    fun invalid_definition_returns_400_with_all_details() = fitlogTest {
        val uid = user()
        val bad = """{"schemaVersion":1,"name":"","extra":1,"lifts":{"squat":{"exercise":{"name":"없는종목"}}},
            "days":[{"key":"A","name":"a","exercises":[{"lift":"ghost","sets":[{"reps":5,"load":{"type":"WORKING"}}]}]}]}"""
        val res = save(uid, Ids.newId(), bad)
        assertEquals(HttpStatusCode.BadRequest, res.status)
        val err = res.obj()["error"]!!.jsonObject
        assertEquals("VALIDATION_FAILED", err["code"]!!.jsonPrimitive.content)
        assertEquals("program definition is invalid", err["message"]!!.jsonPrimitive.content)
        val paths = err["details"]!!.jsonArray.map { it.jsonObject["path"]!!.jsonPrimitive.content }.toSet()
        assertEquals(setOf("/name", "/extra", "/lifts/squat/exercise/name", "/days/0/exercises/0/lift"), paths)
    }

    @Test
    fun missing_id_or_definition_is_400() = fitlogTest {
        val uid = user()
        val c = jsonClient()
        assertEquals(HttpStatusCode.BadRequest, c.post("/v1/programs") { auth(uid); jsonBody(); setBody("""{"definition":${def()}}""") }.status)
        assertEquals(HttpStatusCode.BadRequest, c.post("/v1/programs") { auth(uid); jsonBody(); setBody("""{"id":"${Ids.newId()}"}""") }.status)
        assertEquals(HttpStatusCode.BadRequest, c.post("/v1/programs") { auth(uid); jsonBody(); setBody("""{"id":"nope","definition":${def()}}""") }.status)
    }

    @Test
    fun same_id_by_owner_updates_and_201() = fitlogTest {
        val uid = user()
        val id = Ids.newId()
        assertEquals(HttpStatusCode.Created, save(uid, id, def("First")).status)
        val res = save(uid, id, def("Second"))
        assertEquals(HttpStatusCode.Created, res.status)
        assertEquals("Second", res.obj()["name"]!!.jsonPrimitive.content)
        val mine = Json.parseToJsonElement(jsonClient().get("/v1/programs?source=MINE") { auth(uid) }.bodyAsText()).jsonArray
        assertEquals(1, mine.size)
    }

    @Test
    fun foreign_or_template_id_is_409() = fitlogTest {
        val uid = user()
        val other = createUser()
        val id = Ids.newId()
        assertEquals(HttpStatusCode.Created, save(other, id, def()).status)
        val res = save(uid, id, def())
        assertEquals(HttpStatusCode.Conflict, res.status)
        assertEquals("CONFLICT", res.obj()["error"]!!.jsonObject["code"]!!.jsonPrimitive.content)
        assertEquals(HttpStatusCode.Conflict, save(uid, UUID.fromString("019b76da-5000-7000-8000-000000000001"), def()).status)
    }

    @Test
    fun list_filters_by_source_and_hides_others_and_deleted() = fitlogTest {
        val uid = user()
        val other = createUser()
        val mineId = Ids.newId()
        val goneId = Ids.newId()
        save(uid, mineId, def("Mine"))
        save(uid, goneId, def("Gone"))
        save(other, Ids.newId(), def("Theirs"))
        assertEquals(HttpStatusCode.NoContent, jsonClient().delete("/v1/programs/$goneId") { auth(uid) }.status)

        val c = jsonClient()
        fun ids(s: String) = Json.parseToJsonElement(s).jsonArray.map { it.jsonObject["id"]!!.jsonPrimitive.content }
        val mine = ids(c.get("/v1/programs?source=MINE") { auth(uid) }.bodyAsText())
        assertEquals(listOf(mineId.toString()), mine)
        val all = ids(c.get("/v1/programs") { auth(uid) }.bodyAsText())
        assertTrue(mineId.toString() in all)
        assertFalse(goneId.toString() in all)
        assertTrue("019b76da-5000-7000-8000-000000000005" in all)
        val tpl = ids(c.get("/v1/programs?source=TEMPLATE") { auth(uid) }.bodyAsText())
        assertFalse(mineId.toString() in tpl)
        assertEquals(HttpStatusCode.BadRequest, c.get("/v1/programs?source=X") { auth(uid) }.status)
    }

    @Test
    fun get_other_users_program_is_404() = fitlogTest {
        val uid = user()
        val other = createUser()
        val id = Ids.newId()
        save(other, id, def())
        assertEquals(HttpStatusCode.NotFound, jsonClient().get("/v1/programs/$id") { auth(uid) }.status)
        assertEquals(HttpStatusCode.NotFound, jsonClient().get("/v1/programs/${Ids.newId()}") { auth(uid) }.status)
        assertEquals(HttpStatusCode.OK, jsonClient().get("/v1/programs/$id") { auth(other) }.status)
    }

    @Test
    fun delete_rules() = fitlogTest {
        val uid = user()
        val other = createUser()
        val c = jsonClient()
        val id = Ids.newId()
        save(uid, id, def())
        assertEquals(HttpStatusCode.NotFound, c.delete("/v1/programs/$id") { auth(other) }.status)
        assertEquals(HttpStatusCode.Forbidden, c.delete("/v1/programs/019b76da-5000-7000-8000-000000000002") { auth(uid) }.status)
        assertEquals(HttpStatusCode.NoContent, c.delete("/v1/programs/$id") { auth(uid) }.status)
        assertEquals(HttpStatusCode.NotFound, c.get("/v1/programs/$id") { auth(uid) }.status)
        assertEquals(HttpStatusCode.NotFound, c.delete("/v1/programs/$id") { auth(uid) }.status)
        assertEquals(HttpStatusCode.NotFound, c.delete("/v1/programs/${Ids.newId()}") { auth(uid) }.status)
        // 삭제한 id 를 다시 등록하면 되살아난다
        assertEquals(HttpStatusCode.Created, save(uid, id, def("Again")).status)
        assertEquals(HttpStatusCode.OK, c.get("/v1/programs/$id") { auth(uid) }.status)
    }

    @Test
    fun validate_returns_preview_without_id_and_saves_nothing() = fitlogTest {
        val uid = user()
        val c = jsonClient()
        val res = c.post("/v1/programs/validate") { auth(uid); jsonBody(); setBody(def(lift = """{"name":"Back Squat"}""".replace("Back Squat", "barbell back squat"))) }
        assertEquals(HttpStatusCode.OK, res.status, res.bodyAsText())
        val o = res.obj()
        assertNull(o["id"])
        assertEquals("My Program", o["name"]!!.jsonPrimitive.content)
        assertEquals("1", o["dayCount"]!!.jsonPrimitive.content)
        val ex = o["definition"]!!.jsonObject["lifts"]!!.jsonObject["squat"]!!.jsonObject["exercise"]!!.jsonObject
        assertEquals(squatId, ex["id"]!!.jsonPrimitive.content)
        val mine = Json.parseToJsonElement(c.get("/v1/programs?source=MINE") { auth(uid) }.bodyAsText()).jsonArray
        assertEquals(0, mine.size)
    }

    @Test
    fun validate_invalid_returns_400_details() = fitlogTest {
        val uid = user()
        val res = jsonClient().post("/v1/programs/validate") { auth(uid); jsonBody(); setBody("""{"schemaVersion":1,"name":"x","lifts":{},"days":[]}""") }
        assertEquals(HttpStatusCode.BadRequest, res.status)
        val details = res.obj()["error"]!!.jsonObject["details"]!!.jsonArray
        assertEquals(setOf("/lifts", "/days"), details.map { it.jsonObject["path"]!!.jsonPrimitive.content }.toSet())
    }

    @Test
    fun requires_authentication() = fitlogTest {
        startApplication()
        assertEquals(HttpStatusCode.Unauthorized, jsonClient().get("/v1/programs").status)
        assertEquals(HttpStatusCode.Unauthorized, jsonClient().post("/v1/programs/validate") { jsonBody(); setBody("{}") }.status)
    }
}
