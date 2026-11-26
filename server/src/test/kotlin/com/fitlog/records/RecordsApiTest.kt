package com.fitlog.records

import com.fitlog.core.AppJson
import com.fitlog.core.Programs
import com.fitlog.core.Times
import com.fitlog.core.UserSettingsTable
import com.fitlog.engine.DayExercise
import com.fitlog.engine.Day
import com.fitlog.engine.ExerciseRef
import com.fitlog.engine.Lift
import com.fitlog.engine.Load
import com.fitlog.engine.ProgramDefinition
import com.fitlog.engine.SetSpec
import com.fitlog.session.arr
import com.fitlog.session.deleteSession
import com.fitlog.session.exJson
import com.fitlog.session.insertExercise
import com.fitlog.session.newId
import com.fitlog.session.obj
import com.fitlog.session.putSession
import com.fitlog.session.sessionJson
import com.fitlog.session.setJson
import com.fitlog.session.str
import com.fitlog.support.auth
import com.fitlog.support.createUser
import com.fitlog.support.fitlogTest
import com.fitlog.support.jsonBody
import com.fitlog.support.jsonClient
import io.ktor.client.HttpClient
import io.ktor.client.request.delete
import io.ktor.client.request.get
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.HttpResponse
import io.ktor.http.HttpStatusCode
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.double
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.jetbrains.exposed.sql.SqlExpressionBuilder.eq
import org.jetbrains.exposed.sql.insert
import org.jetbrains.exposed.sql.update
import org.jetbrains.exposed.sql.transactions.transaction
import java.time.Instant
import java.time.temporal.ChronoUnit
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull

class RecordsApiTest {

    private fun JsonObject.num(key: String): Double = this[key]!!.jsonPrimitive.double

    /** 끝낸 세트: 무게·횟수·완료 시각 */
    private fun done(w: String, r: String, at: String = "2026-11-20T10:05:00Z", warmup: Boolean = false, position: Int = 0) =
        setJson(position = position, weightKg = w, reps = r, completed = false, warmup = warmup, extra = """"completedAt":"$at"""")

    private suspend fun HttpClient.session(uid: UUID, ex: UUID, sets: List<String>, endedAt: String? = "2026-11-20T11:00:00Z"): String {
        val sid = newId()
        val res = putSession(uid, sid, sessionJson(id = sid, startedAt = "2026-11-20T10:00:00Z", endedAt = endedAt, exercises = listOf(exJson(exerciseId = ex, sets = sets))))
        assertEquals(HttpStatusCode.OK, res.status, res.toString())
        return sid
    }

    private fun setFormula(uid: UUID, formula: String) {
        transaction {
            UserSettingsTable.insert {
                it[userId] = uid
                it[weightUnit] = "KG"
                it[defaultRestSec] = 90
                it[keepScreenOn] = true
                it[rpeInputEnabled] = false
                it[e1rmFormula] = formula
                it[updatedAt] = Times.now()
            }
        }
    }

    private suspend fun HttpClient.records(uid: UUID, ex: UUID): HttpResponse = get("/v1/exercises/$ex/records") { auth(uid) }

    // ------------------------------------------------------------ records

    @Test
    fun records_empty_for_exercise_without_history() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val ex = insertExercise(null)
        val res = c.records(uid, ex)
        assertEquals(HttpStatusCode.OK, res.status)
        val o = res.obj()
        assertEquals("EPLEY", o.str("formula"))
        assertNull(o["bestWeight"])
        assertNull(o["bestE1rm"])
        assertNull(o["latestMeasured"])
        assertEquals(0, o["byReps"]!!.jsonArray.size)
    }

    @Test
    fun records_best_weight_e1rm_and_by_reps_exclude_warmup_uncompleted_deleted() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val ex = insertExercise(null)
        c.session(
            uid, ex, listOf(
                done("100", "5", position = 0),
                done("110", "3", position = 1),
                done("100", "8", position = 2),
                done("200", "5", warmup = true, position = 3), // 워밍업 제외
                done("60", "12", position = 4), // 10회 초과: 최고 무게 후보지만 e1RM·byReps 제외
                setJson(position = 5, weightKg = "300", reps = "5", completed = false), // 완료 안 한 세트 제외
            ),
        )
        val deletedSession = c.session(uid, ex, listOf(done("500", "1")))
        assertEquals(HttpStatusCode.NoContent, c.deleteSession(uid, deletedSession).status)

        val o = c.records(uid, ex).obj()
        assertEquals(110.0, o["bestWeight"]!!.jsonObject.num("weightKg"))
        assertEquals(3, o["bestWeight"]!!.jsonObject["reps"]!!.jsonPrimitive.content.toInt())
        assertEquals(121.0, o["bestWeight"]!!.jsonObject.num("e1rmKg")) // 110 × (1 + 3/30)
        val e1 = o["bestE1rm"]!!.jsonObject
        assertEquals(126.67, e1.num("e1rmKg")) // 100 × 8 회: 100 × (1 + 8/30)
        assertEquals(100.0, e1.num("weightKg"))
        assertNotNull(e1.str("sessionId"))
        assertNotNull(e1.str("setId"))
        assertEquals("2026-11-20T10:05:00Z", e1.str("achievedAt"))
        val byReps = o["byReps"]!!.jsonArray.associate { it.jsonObject["reps"]!!.jsonPrimitive.content.toInt() to it.jsonObject["point"]!!.jsonObject.num("weightKg") }
        assertEquals(mapOf(3 to 110.0, 5 to 100.0, 8 to 100.0), byReps)
    }

    @Test
    fun records_include_completed_sets_of_unfinished_session() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val ex = insertExercise(uid)
        c.session(uid, ex, listOf(done("90", "5")), endedAt = null)
        val o = c.records(uid, ex).obj()
        assertEquals(90.0, o["bestWeight"]!!.jsonObject.num("weightKg"))
    }

    @Test
    fun records_use_user_formula() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        setFormula(uid, "BRZYCKI")
        val ex = insertExercise(null)
        c.session(uid, ex, listOf(done("100", "5")))
        val o = c.records(uid, ex).obj()
        assertEquals("BRZYCKI", o.str("formula"))
        assertEquals(112.5, o["bestE1rm"]!!.jsonObject.num("e1rmKg"))
    }

    @Test
    fun records_are_per_user_and_404_for_foreign_or_unknown_exercise() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val a = createUser()
        val b = createUser()
        val mine = insertExercise(a)
        val builtin = insertExercise(null)
        c.session(a, builtin, listOf(done("100", "5")))
        // 다른 사용자는 같은 기본 종목이어도 내 기록만 본다
        assertNull(c.records(b, builtin).obj()["bestWeight"])
        assertEquals(HttpStatusCode.NotFound, c.records(b, mine).status)
        assertEquals(HttpStatusCode.NotFound, c.records(a, UUID.randomUUID()).status)
        assertEquals(HttpStatusCode.BadRequest, c.get("/v1/exercises/not-a-uuid/records") { auth(a) }.status)
        assertEquals(HttpStatusCode.Unauthorized, c.get("/v1/exercises/$mine/records").status)
    }

    // ------------------------------------------------------------ one-rm

    private fun oneRmJson(id: String = newId(), kg: String = "140", at: String = "2026-11-01T09:00:00Z", note: String? = null) =
        """{"id":"$id","weightKg":$kg,"measuredAt":"$at"${if (note != null) ""","note":"$note"""" else ""}}"""

    private suspend fun HttpClient.postOneRm(uid: UUID, ex: UUID, body: String) =
        post("/v1/exercises/$ex/one-rm") { auth(uid); jsonBody(); setBody(body) }

    @Test
    fun one_rm_create_list_delete_and_idempotent_post() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val ex = insertExercise(null)
        val id1 = newId()
        val r1 = c.postOneRm(uid, ex, oneRmJson(id1, "140.555", "2026-11-01T09:00:00Z", "첫 측정"))
        assertEquals(HttpStatusCode.Created, r1.status)
        val o1 = r1.obj()
        assertEquals(id1, o1.str("id"))
        assertEquals(ex.toString(), o1.str("exerciseId"))
        assertEquals(140.56, o1.num("weightKg"))
        assertEquals("첫 측정", o1.str("note"))
        // 같은 id 재전송 = 201, 한 건만 존재
        assertEquals(HttpStatusCode.Created, c.postOneRm(uid, ex, oneRmJson(id1, "140.555", "2026-11-01T09:00:00Z", "첫 측정")).status)
        val id2 = newId()
        assertEquals(HttpStatusCode.Created, c.postOneRm(uid, ex, oneRmJson(id2, "150", "2026-11-10T09:00:00Z")).status)

        val list = c.get("/v1/exercises/$ex/one-rm") { auth(uid) }.arr()
        assertEquals(listOf(id2, id1), list.map { it.str("id") }) // 최근 측정이 먼저
        assertEquals(id2, c.records(uid, ex).obj()["latestMeasured"]!!.jsonObject.str("id"))

        assertEquals(HttpStatusCode.NoContent, c.delete("/v1/one-rm/$id2") { auth(uid) }.status)
        assertEquals(HttpStatusCode.NoContent, c.delete("/v1/one-rm/$id2") { auth(uid) }.status) // 다시 지워도 204
        assertEquals(listOf(id1), c.get("/v1/exercises/$ex/one-rm") { auth(uid) }.arr().map { it.str("id") })
        assertEquals(id1, c.records(uid, ex).obj()["latestMeasured"]!!.jsonObject.str("id"))
    }

    @Test
    fun one_rm_validation_and_access_rules() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val a = createUser()
        val b = createUser()
        val ex = insertExercise(null)
        val foreign = insertExercise(b)
        assertEquals(HttpStatusCode.BadRequest, c.postOneRm(a, ex, oneRmJson(kg = "0")).status)
        assertEquals(HttpStatusCode.BadRequest, c.postOneRm(a, ex, oneRmJson(kg = "-5")).status)
        assertEquals(HttpStatusCode.BadRequest, c.postOneRm(a, ex, oneRmJson(kg = "0.001")).status)
        assertEquals(HttpStatusCode.BadRequest, c.postOneRm(a, ex, """{"id":"${newId()}","measuredAt":"2026-11-01T09:00:00Z"}""").status)
        assertEquals(HttpStatusCode.BadRequest, c.postOneRm(a, ex, oneRmJson(at = "yesterday")).status)
        assertEquals(HttpStatusCode.NotFound, c.postOneRm(a, foreign, oneRmJson()).status)
        assertEquals(HttpStatusCode.NotFound, c.get("/v1/exercises/$foreign/one-rm") { auth(a) }.status)

        // 남의 측정은 지울 수 없다(404), 없는 id 는 204
        val id = newId()
        assertEquals(HttpStatusCode.Created, c.postOneRm(a, ex, oneRmJson(id)).status)
        assertEquals(HttpStatusCode.NotFound, c.delete("/v1/one-rm/$id") { auth(b) }.status)
        assertEquals(1, c.get("/v1/exercises/$ex/one-rm") { auth(a) }.arr().size)
        assertEquals(HttpStatusCode.NoContent, c.delete("/v1/one-rm/${UUID.randomUUID()}") { auth(a) }.status)
        // 다른 사용자가 같은 id 로 만들려 하면 409
        assertEquals(HttpStatusCode.Conflict, c.postOneRm(b, ex, oneRmJson(id)).status)
        // 다른 사용자의 목록은 비어 있다
        assertEquals(0, c.get("/v1/exercises/$ex/one-rm") { auth(b) }.arr().size)
    }

    // ------------------------------------------------------------ suggest

    private fun insertProgram(owner: UUID?, squat: UUID, bench: UUID, ohp: UUID, tmPercent: Double = 0.9, workingPercent: Double = 0.8): UUID {
        val def = ProgramDefinition(
            schemaVersion = 1, name = "suggest-test", tmPercent = tmPercent, workingPercent = workingPercent,
            lifts = mapOf(
                "squat" to Lift(ExerciseRef(id = squat.toString())),
                "bench" to Lift(ExerciseRef(id = bench.toString())),
                "ohp" to Lift(ExerciseRef(id = ohp.toString())),
            ),
            days = listOf(
                Day("A", "A", null, listOf(
                    DayExercise("squat", sets = listOf(SetSpec(reps = 5, load = Load.PercentTm(0.85)))),
                    DayExercise("bench", sets = listOf(SetSpec(reps = 5, load = Load.Working()))),
                    DayExercise("ohp", sets = listOf(SetSpec(reps = 5, load = Load.PercentTm(0.8)))),
                )),
            ),
        )
        val id = UUID.randomUUID()
        transaction {
            Programs.insert {
                it[Programs.id] = id
                it[ownerId] = owner
                it[name] = "suggest-test"
                it[definition] = AppJson.encodeToString(ProgramDefinition.serializer(), def)
                it[sourceCol] = if (owner == null) "TEMPLATE" else "USER"
                it[createdAt] = Times.now()
                it[updatedAt] = Times.now()
            }
        }
        return id
    }

    private suspend fun HttpClient.suggest(uid: UUID, pid: UUID) = get("/v1/programs/$pid/suggest") { auth(uid) }

    @Test
    fun suggest_prefers_measured_then_estimated_then_omits() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val squat = insertExercise(null)
        val bench = insertExercise(null)
        val ohp = insertExercise(null)
        val pid = insertProgram(null, squat, bench, ohp)

        // squat: 측정 1RM 200 (세트 기록이 더 커도 측정 우선)
        assertEquals(HttpStatusCode.Created, c.postOneRm(uid, squat, oneRmJson(kg = "200", at = "2026-01-01T00:00:00Z")).status)
        val recent = Instant.now().minus(10, ChronoUnit.DAYS).truncatedTo(ChronoUnit.SECONDS).toString()
        c.session(uid, squat, listOf(done("250", "1", at = recent)))
        // bench: 최근 90일 세트 추정 (100×5 → 116.67, 오래된 120×5 는 제외)
        val old = Instant.now().minus(100, ChronoUnit.DAYS).truncatedTo(ChronoUnit.SECONDS).toString()
        c.session(uid, bench, listOf(done("100", "5", at = recent), done("120", "5", at = old, position = 1)))
        // ohp: 기록 없음

        val res = c.suggest(uid, pid)
        assertEquals(HttpStatusCode.OK, res.status)
        val items = res.arr().associateBy { it.str("key")!! }
        assertEquals(setOf("squat", "bench", "ohp"), items.keys)

        val sq = items["squat"]!!.jsonObject
        assertEquals(squat.toString(), sq.str("exerciseId"))
        assertEquals("TM", sq.str("needs"))
        assertEquals("MEASURED", sq.str("oneRmSource"))
        assertEquals(200.0, sq.num("oneRmKg"))
        assertEquals(180.0, sq.num("suggestedKg")) // 200 × 0.9, 반올림 단위 적용 안 함

        val be = items["bench"]!!.jsonObject
        assertEquals("WORKING", be.str("needs"))
        assertEquals("ESTIMATED", be.str("oneRmSource"))
        assertEquals(116.67, be.num("oneRmKg"))
        assertEquals(93.34, be.num("suggestedKg")) // 116.67 × 0.8 = 93.336

        val oh = items["ohp"]!!.jsonObject
        assertEquals("TM", oh.str("needs"))
        assertNull(oh["oneRmKg"])
        assertNull(oh["oneRmSource"])
        assertNull(oh["suggestedKg"])
    }

    @Test
    fun suggest_uses_user_program_percent_and_formula() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        setFormula(uid, "BRZYCKI")
        val squat = insertExercise(null)
        val bench = insertExercise(null)
        val ohp = insertExercise(null)
        val pid = insertProgram(uid, squat, bench, ohp, tmPercent = 0.85, workingPercent = 0.7)
        val recent = Instant.now().minus(1, ChronoUnit.DAYS).truncatedTo(ChronoUnit.SECONDS).toString()
        c.session(uid, squat, listOf(done("100", "5", at = recent)))
        val sq = c.suggest(uid, pid).arr().first { it.str("key") == "squat" }.jsonObject
        assertEquals(112.5, sq.num("oneRmKg"))
        assertEquals(95.63, sq.num("suggestedKg")) // 112.5 × 0.85 = 95.625
    }

    @Test
    fun suggest_404_for_others_program_unknown_or_deleted() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val a = createUser()
        val b = createUser()
        val e = insertExercise(null)
        val mine = insertProgram(a, e, e, e)
        val template = insertProgram(null, e, e, e)
        assertEquals(HttpStatusCode.OK, c.suggest(a, mine).status)
        assertEquals(HttpStatusCode.NotFound, c.suggest(b, mine).status)
        assertEquals(HttpStatusCode.OK, c.suggest(b, template).status)
        assertEquals(HttpStatusCode.NotFound, c.suggest(a, UUID.randomUUID()).status)
        transaction {
            Programs.update({ Programs.id eq mine }) { it[deletedAt] = Times.now() }
        }
        assertEquals(HttpStatusCode.NotFound, c.suggest(a, mine).status)
    }
}
