package com.fitlog.account

import com.fitlog.core.AppJson
import com.fitlog.core.AppUsers
import com.fitlog.core.BodyMeasurements
import com.fitlog.core.Consents
import com.fitlog.core.Exercises
import com.fitlog.core.Ids
import com.fitlog.core.RefreshTokens
import com.fitlog.core.SessionExercises
import com.fitlog.core.Times
import com.fitlog.core.UserSettingsTable
import com.fitlog.core.WorkoutSessions
import com.fitlog.core.WorkoutSets
import com.fitlog.support.auth
import com.fitlog.support.createUser
import com.fitlog.support.fitlogTest
import com.fitlog.support.jsonBody
import com.fitlog.support.jsonClient
import io.ktor.client.HttpClient
import io.ktor.client.request.delete
import io.ktor.client.request.get
import io.ktor.client.request.post
import io.ktor.client.request.put
import io.ktor.client.request.setBody
import io.ktor.client.statement.HttpResponse
import io.ktor.client.statement.bodyAsText
import io.ktor.http.HttpStatusCode
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.jetbrains.exposed.sql.insert
import org.jetbrains.exposed.sql.SqlExpressionBuilder.eq
import org.jetbrains.exposed.sql.selectAll
import org.jetbrains.exposed.sql.transactions.transaction
import java.math.BigDecimal
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull

class AccountTest {
    private suspend fun HttpResponse.obj(): JsonObject = AppJson.parseToJsonElement(bodyAsText()).jsonObject
    private suspend fun HttpResponse.arr(): JsonArray = AppJson.parseToJsonElement(bodyAsText()).jsonArray

    private suspend fun HttpClient.consent(uid: UUID, kind: String, version: String, granted: Boolean) =
        post("/v1/me/consents") { auth(uid); jsonBody(); setBody("""{"kind":"$kind","version":"$version","granted":$granted}""") }

    private suspend fun HttpClient.required(uid: UUID): List<String> =
        get("/v1/me") { auth(uid) }.obj().getValue("consentsRequired").jsonArray.map { it.jsonPrimitive.content }

    @Test
    fun meReturnsProfileAndAllConsentsRequiredInitially() = fitlogTest {
        val c = jsonClient()
        c.get("/health")
        val uid = createUser("me@x.com")
        val me = c.get("/v1/me") { auth(uid) }.obj()
        assertEquals(uid.toString(), me.getValue("id").jsonPrimitive.content)
        assertEquals("me@x.com", me.getValue("email").jsonPrimitive.content)
        assertEquals("MEMBER", me.getValue("role").jsonPrimitive.content)
        assertEquals(listOf("TERMS", "PRIVACY", "HEALTH_DATA"), c.required(uid))
    }

    @Test
    fun consentsRequiredChangesWithGrantVersionAndWithdrawal() = fitlogTest {
        val c = jsonClient()
        c.get("/health")
        val uid = createUser()

        val res = c.consent(uid, "TERMS", CURRENT_CONSENT_VERSION, true)
        assertEquals(HttpStatusCode.Created, res.status)
        assertNotNull(res.obj()["createdAt"])
        assertEquals(listOf("PRIVACY", "HEALTH_DATA"), c.required(uid))

        c.consent(uid, "PRIVACY", CURRENT_CONSENT_VERSION, true)
        c.consent(uid, "HEALTH_DATA", "2000-01-01", true) // outdated version does not count
        assertEquals(listOf("HEALTH_DATA"), c.required(uid))
        c.consent(uid, "HEALTH_DATA", CURRENT_CONSENT_VERSION, true)
        assertEquals(emptyList(), c.required(uid))

        // withdrawal adds a granted=false row and makes it required again
        c.consent(uid, "PRIVACY", CURRENT_CONSENT_VERSION, false)
        assertEquals(listOf("PRIVACY"), c.required(uid))

        val latest = c.get("/v1/me/consents") { auth(uid) }.arr()
        assertEquals(3, latest.size)
        val privacy = latest.map { it.jsonObject }.first { it.getValue("kind").jsonPrimitive.content == "PRIVACY" }
        assertEquals("false", privacy.getValue("granted").jsonPrimitive.content)

        val rows = transaction { Consents.selectAll().where { Consents.userId eq uid }.count() }
        assertEquals(5, rows) // history kept
    }

    @Test
    fun consentValidation() = fitlogTest {
        val c = jsonClient()
        c.get("/health")
        val uid = createUser()
        val res = c.consent(uid, "NOPE", "v1", true)
        assertEquals(HttpStatusCode.BadRequest, res.status)
        assertEquals("kind", res.obj().getValue("error").jsonObject.getValue("field").jsonPrimitive.content)
    }

    @Test
    fun settingsDefaultsAndPartialUpdate() = fitlogTest {
        val c = jsonClient()
        c.get("/health")
        val uid = createUser() // no settings row yet
        val s0 = c.get("/v1/me/settings") { auth(uid) }.obj()
        assertEquals("KG", s0.getValue("weightUnit").jsonPrimitive.content)
        assertEquals("120", s0.getValue("defaultRestSec").jsonPrimitive.content)
        assertEquals("true", s0.getValue("keepScreenOn").jsonPrimitive.content)
        assertNull(s0["heightCm"])

        val res = c.put("/v1/me/settings") { auth(uid); jsonBody(); setBody("""{"weightUnit":"LB","heightCm":180.5,"sex":"MALE","birthYear":1990}""") }
        assertEquals(HttpStatusCode.OK, res.status)
        val s1 = res.obj()
        assertEquals("LB", s1.getValue("weightUnit").jsonPrimitive.content)
        assertEquals("180.5", s1.getValue("heightCm").jsonPrimitive.content)
        assertEquals("120", s1.getValue("defaultRestSec").jsonPrimitive.content) // untouched

        val s2 = c.put("/v1/me/settings") { auth(uid); jsonBody(); setBody("""{"defaultRestSec":90}""") }.obj()
        assertEquals("90", s2.getValue("defaultRestSec").jsonPrimitive.content)
        assertEquals("LB", s2.getValue("weightUnit").jsonPrimitive.content) // kept
        assertEquals("1990", s2.getValue("birthYear").jsonPrimitive.content)
        assertEquals(s2, c.get("/v1/me/settings") { auth(uid) }.obj())
    }

    @Test
    fun settingsValidationRejectsOutOfRange() = fitlogTest {
        val c = jsonClient()
        c.get("/health")
        val uid = createUser()
        val cases = mapOf(
            """{"defaultRestSec":3601}""" to "defaultRestSec",
            """{"defaultRestSec":-1}""" to "defaultRestSec",
            """{"birthYear":1899}""" to "birthYear",
            """{"birthYear":2101}""" to "birthYear",
            """{"heightCm":49.9}""" to "heightCm",
            """{"heightCm":300.5}""" to "heightCm",
            """{"weightUnit":"STONE"}""" to "weightUnit",
            """{"sex":"X"}""" to "sex",
        )
        for ((body, field) in cases) {
            val res = c.put("/v1/me/settings") { auth(uid); jsonBody(); setBody(body) }
            assertEquals(HttpStatusCode.BadRequest, res.status, body)
            val err = res.obj().getValue("error").jsonObject
            assertEquals("VALIDATION_FAILED", err.getValue("code").jsonPrimitive.content)
            assertEquals(field, err.getValue("field").jsonPrimitive.content, body)
        }
        // boundaries are accepted
        val ok = c.put("/v1/me/settings") { auth(uid); jsonBody(); setBody("""{"defaultRestSec":3600,"birthYear":1900,"heightCm":300}""") }
        assertEquals(HttpStatusCode.OK, ok.status)
    }

    @Test
    fun deleteAccountRemovesAllDataWithoutFkErrors() = fitlogTest {
        val c = jsonClient()
        c.get("/health")
        val uid = createUser()
        val other = createUser()
        val now = Times.now()
        transaction {
            fun seed(owner: UUID): UUID {
                val ex = Ids.newId(); val ses = Ids.newId(); val se = Ids.newId()
                Exercises.insert {
                    it[id] = ex; it[ownerId] = owner; it[nameKo] = "내 종목"; it[type] = "BARBELL"
                    it[primaryMuscle] = "CHEST"; it[createdAt] = now; it[updatedAt] = now
                }
                WorkoutSessions.insert {
                    it[id] = ses; it[userId] = owner; it[startedAt] = now; it[tz] = "Asia/Seoul"
                    it[sourceCol] = "APP"; it[createdAt] = now; it[updatedAt] = now
                }
                SessionExercises.insert {
                    it[id] = se; it[sessionId] = ses; it[exerciseId] = ex; it[position] = 0; it[updatedAt] = now
                }
                WorkoutSets.insert {
                    it[id] = Ids.newId(); it[sessionExerciseId] = se; it[position] = 0; it[isWarmup] = false
                    it[weightKg] = BigDecimal("60.00"); it[reps] = 5; it[updatedAt] = now
                }
                BodyMeasurements.insert {
                    it[id] = Ids.newId(); it[userId] = owner; it[measuredAt] = now
                    it[weightKg] = BigDecimal("70.50"); it[sourceCol] = "MANUAL"; it[updatedAt] = now
                }
                return ses
            }
            seed(uid); seed(other)
        }
        c.get("/v1/me/settings") { auth(uid) } // creates settings row
        c.consent(uid, "TERMS", CURRENT_CONSENT_VERSION, true)

        assertEquals(HttpStatusCode.NoContent, c.delete("/v1/me") { auth(uid) }.status)

        transaction {
            assertEquals(0, AppUsers.selectAll().where { AppUsers.id eq uid }.count())
            assertEquals(0, WorkoutSessions.selectAll().where { WorkoutSessions.userId eq uid }.count())
            assertEquals(0, Exercises.selectAll().where { Exercises.ownerId eq uid }.count())
            assertEquals(0, BodyMeasurements.selectAll().where { BodyMeasurements.userId eq uid }.count())
            assertEquals(0, Consents.selectAll().where { Consents.userId eq uid }.count())
            assertEquals(0, UserSettingsTable.selectAll().where { UserSettingsTable.userId eq uid }.count())
            assertEquals(0, RefreshTokens.selectAll().where { RefreshTokens.userId eq uid }.count())
            // other user untouched
            assertEquals(1, WorkoutSessions.selectAll().where { WorkoutSessions.userId eq other }.count())
            assertEquals(1, BodyMeasurements.selectAll().where { BodyMeasurements.userId eq other }.count())
        }
        // the old access token no longer maps to a user
        assertEquals(HttpStatusCode.Unauthorized, c.get("/v1/me") { auth(uid) }.status)
    }
}
