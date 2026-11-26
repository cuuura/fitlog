package com.fitlog.account

import com.fitlog.core.ProgramInstances
import com.fitlog.core.WorkoutSessions
import com.fitlog.program.instance.fakeTest
import com.fitlog.program.instance.insertProgram
import com.fitlog.program.instance.linkedSessionJson
import com.fitlog.program.instance.startInstance
import com.fitlog.program.instance.testDefinition
import com.fitlog.session.insertExercise
import com.fitlog.session.newId
import com.fitlog.session.obj
import com.fitlog.session.putSession
import com.fitlog.support.auth
import com.fitlog.support.createUser
import com.fitlog.support.fitlogTest
import com.fitlog.support.jsonBody
import com.fitlog.support.jsonClient
import io.ktor.client.HttpClient
import io.ktor.client.request.delete
import io.ktor.client.request.get
import io.ktor.client.request.put
import io.ktor.client.request.setBody
import io.ktor.client.statement.HttpResponse
import io.ktor.http.HttpStatusCode
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.jetbrains.exposed.sql.SqlExpressionBuilder.eq
import org.jetbrains.exposed.sql.selectAll
import org.jetbrains.exposed.sql.transactions.transaction
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/** PUT /me/settings = JSON merge-patch (v0.2), e1rmFormula, 계정 삭제와 프로그램 데이터 */
class SettingsMergePatchTest {
    private suspend fun HttpClient.putSettings(uid: UUID, body: String): HttpResponse =
        put("/v1/me/settings") { auth(uid); jsonBody(); setBody(body) }

    private fun JsonObject.s(k: String) = this[k]?.jsonPrimitive?.content

    @Test
    fun null_clears_nullable_fields_and_missing_keys_are_kept() = fitlogTest {
        val c = jsonClient()
        c.get("/health")
        val uid = createUser()
        val s1 = c.putSettings(uid, """{"heightCm":180.5,"sex":"MALE","birthYear":1990,"defaultRestSec":90}""").obj()
        assertEquals("180.5", s1.s("heightCm"))

        // 키가 없으면 유지
        val s2 = c.putSettings(uid, """{"keepScreenOn":false}""").obj()
        assertEquals("180.5", s2.s("heightCm"))
        assertEquals("MALE", s2.s("sex"))
        assertEquals("1990", s2.s("birthYear"))
        assertEquals("90", s2.s("defaultRestSec"))
        assertEquals("false", s2.s("keepScreenOn"))

        // null 이면 비움(해당 키만)
        val s3 = c.putSettings(uid, """{"heightCm":null,"sex":null}""").obj()
        assertNull(s3["heightCm"])
        assertNull(s3["sex"])
        assertEquals("1990", s3.s("birthYear"))
        assertEquals("90", s3.s("defaultRestSec"))
        val s4 = c.putSettings(uid, """{"birthYear":null}""").obj()
        assertNull(s4["birthYear"])
        assertEquals(s4, c.get("/v1/me/settings") { auth(uid) }.obj())
        // 비운 뒤 다시 채울 수 있다
        assertEquals("170.0", c.putSettings(uid, """{"heightCm":170}""").obj().s("heightCm"))
        // 빈 객체는 아무것도 바꾸지 않는다
        assertEquals(HttpStatusCode.OK, c.putSettings(uid, "{}").status)
    }

    @Test
    fun null_on_required_fields_is_rejected() = fitlogTest {
        val c = jsonClient()
        c.get("/health")
        val uid = createUser()
        c.putSettings(uid, """{"weightUnit":"LB"}""")
        for (f in listOf("weightUnit", "defaultRestSec", "keepScreenOn", "rpeInputEnabled", "e1rmFormula")) {
            val res = c.putSettings(uid, """{"$f":null}""")
            assertEquals(HttpStatusCode.BadRequest, res.status, f)
            val err = res.obj()["error"]!!.jsonObject
            assertEquals("VALIDATION_FAILED", err.s("code"))
            assertEquals(f, err.s("field"))
        }
        // 거절된 요청은 아무것도 바꾸지 않는다
        assertEquals("LB", c.get("/v1/me/settings") { auth(uid) }.obj().s("weightUnit"))
        // 같은 요청에서 하나라도 틀리면 전체 거절
        assertEquals(HttpStatusCode.BadRequest, c.putSettings(uid, """{"heightCm":170,"weightUnit":null}""").status)
        assertNull(c.get("/v1/me/settings") { auth(uid) }.obj()["heightCm"])
    }

    @Test
    fun wrong_types_are_rejected() = fitlogTest {
        val c = jsonClient()
        c.get("/health")
        val uid = createUser()
        for ((body, field) in mapOf(
            """{"defaultRestSec":"90"}""" to "defaultRestSec",
            """{"keepScreenOn":"yes"}""" to "keepScreenOn",
            """{"heightCm":"tall"}""" to "heightCm",
            """{"birthYear":1990.5}""" to "birthYear",
            """{"weightUnit":5}""" to "weightUnit",
        )) {
            val res = c.putSettings(uid, body)
            assertEquals(HttpStatusCode.BadRequest, res.status, body)
            assertEquals(field, res.obj()["error"]!!.jsonObject.s("field"), body)
        }
        assertEquals(HttpStatusCode.BadRequest, c.putSettings(uid, "[1]").status)
    }

    @Test
    fun e1rm_formula_defaults_to_epley_and_can_be_changed() = fitlogTest {
        val c = jsonClient()
        c.get("/health")
        val uid = createUser()
        assertEquals("EPLEY", c.get("/v1/me/settings") { auth(uid) }.obj().s("e1rmFormula"))
        assertEquals("BRZYCKI", c.putSettings(uid, """{"e1rmFormula":"BRZYCKI"}""").obj().s("e1rmFormula"))
        assertEquals("BRZYCKI", c.get("/v1/me/settings") { auth(uid) }.obj().s("e1rmFormula"))
        // 다른 키만 바꿔도 유지
        assertEquals("BRZYCKI", c.putSettings(uid, """{"defaultRestSec":60}""").obj().s("e1rmFormula"))
        assertEquals("LOMBARDI", c.putSettings(uid, """{"e1rmFormula":"LOMBARDI"}""").obj().s("e1rmFormula"))
        val bad = c.putSettings(uid, """{"e1rmFormula":"NOPE"}""")
        assertEquals(HttpStatusCode.BadRequest, bad.status)
        assertEquals("e1rmFormula", bad.obj()["error"]!!.jsonObject.s("field"))
    }

    @Test
    fun deleting_account_with_instances_and_linked_sessions_works() = fakeTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val squat = insertExercise(null, "BARBELL")
        val bench = insertExercise(uid, "DUMBBELL")
        val pid = insertProgram(uid, testDefinition(squat, bench))
        val inst = newId()
        c.startInstance(uid, inst, pid)
        val sid = newId()
        c.putSession(uid, sid, linkedSessionJson(sid, inst, 1, squat))
        assertEquals(HttpStatusCode.NoContent, c.delete("/v1/me") { auth(uid) }.status)
        transaction {
            assertEquals(0, ProgramInstances.selectAll().where { ProgramInstances.userId eq uid }.count())
            assertEquals(0, WorkoutSessions.selectAll().where { WorkoutSessions.userId eq uid }.count())
        }
    }
}
