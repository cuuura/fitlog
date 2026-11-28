package com.fitlog.program.instance

import com.fitlog.core.ProgramInstances
import com.fitlog.core.Programs
import com.fitlog.engine.PlannedExercise
import com.fitlog.engine.PlannedSet
import com.fitlog.engine.ProgramEngine
import com.fitlog.program.Durations
import com.fitlog.session.newId
import com.fitlog.session.str
import com.fitlog.support.auth
import com.fitlog.support.createUser
import com.fitlog.support.fitlogTest
import com.fitlog.support.jsonBody
import com.fitlog.support.jsonClient
import io.ktor.client.HttpClient
import io.ktor.client.request.get
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.HttpResponse
import io.ktor.http.HttpStatusCode
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.jetbrains.exposed.sql.SqlExpressionBuilder.eq
import org.jetbrains.exposed.sql.selectAll
import org.jetbrains.exposed.sql.transactions.transaction
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** contracts/v1.1/program-start-ext.md 1~3절 */
class ProgramStartExtTest {
    private class World(val uid: UUID, val programId: UUID)

    private fun world(withWeekdays: Boolean = true): World {
        val uid = createUser()
        val squat = com.fitlog.session.insertExercise(null, "BARBELL")
        val bench = com.fitlog.session.insertExercise(uid, "DUMBBELL")
        return World(uid, insertProgram(uid, testDefinition(squat, bench, withWeekdays)))
    }

    private suspend fun HttpClient.preview(uid: UUID, programId: UUID, body: String): HttpResponse =
        post("/v1/programs/$programId/preview") { auth(uid); jsonBody(); setBody(body) }

    private suspend fun HttpClient.start(uid: UUID, id: String, programId: UUID, extra: String): HttpResponse =
        post("/v1/program-instances") {
            auth(uid); jsonBody()
            setBody("""{"id":"$id","programId":"$programId","startDate":"2026-11-02","tz":"Asia/Seoul","tm":{"bench":80},"working":{"squat":100}$extra}""")
        }

    private fun errField(r: JsonObject) = r["error"]!!.jsonObject.str("field")

    private val values = """"tm":{"bench":80},"working":{"squat":100}"""

    // ---------------------------------------------------------------- 1. preview

    @Test
    fun preview_returns_plan_with_fixed_dates_and_writes_nothing() = fakeTest {
        startApplication()
        val c = jsonClient()
        val w = world()
        val before = transaction { ProgramInstances.selectAll().count() }
        // 2026-11-02 는 월요일: A(MON) 당일, B(THU) 11-05
        val r = c.preview(w.uid, w.programId, """{"startDate":"2026-11-02","tz":"Asia/Seoul","skipPolicy":"FIXED_DATE",$values,"count":2}""")
        assertEquals(HttpStatusCode.OK, r.status)
        val o = r.objOf()
        val wk = o["workouts"]!!.jsonArray.map { it.jsonObject }
        assertEquals(listOf("2026-11-02", "2026-11-05"), wk.map { it.str("scheduledDate") })
        assertEquals(listOf("A", "B"), wk.map { it.str("dayKey") })
        assertEquals(listOf(1, 2), wk.map { it["planSeq"]!!.jsonPrimitive.content.toInt() })
        assertEquals(true, wk[0]["confirmed"]!!.jsonPrimitive.content.toBoolean())
        assertTrue(wk.all { it["estimatedMinutes"]!!.jsonPrimitive.content.toInt() >= 5 })
        assertEquals(80.0, o["inputs"]!!.jsonObject["tm"]!!.jsonObject["bench"]!!.jsonPrimitive.content.toDouble())
        assertEquals(100.0, o["inputs"]!!.jsonObject["working"]!!.jsonObject["squat"]!!.jsonPrimitive.content.toDouble())
        assertEquals(0, o["derived"]!!.jsonArray.size)
        assertEquals(before, transaction { ProgramInstances.selectAll().count() })

        // 화요일 시작이면 A 는 다음 월요일
        val tue = c.preview(w.uid, w.programId, """{"startDate":"2026-11-03","skipPolicy":"FIXED_DATE",$values}""").objOf()
        assertEquals("2026-11-09", tue["workouts"]!!.jsonArray.single().jsonObject.str("scheduledDate"))

        // SHIFT 기본이면 예정일 없음
        val shift = c.preview(w.uid, w.programId, """{"startDate":"2026-11-02",$values}""").objOf()
        assertNull(shift["workouts"]!!.jsonArray.single().jsonObject.str("scheduledDate"))
    }

    @Test
    fun preview_matches_instance_plan() = fakeTest {
        startApplication()
        withToday("2026-11-02T00:00:00Z") {
        val c = jsonClient()
        val w = world()
        val body = """"startDate":"2026-11-03","tz":"Asia/Seoul","skipPolicy":"FIXED_DATE",$values"""
        val pv = c.preview(w.uid, w.programId, "{$body,\"count\":3}").objOf()["workouts"]!!.jsonArray
        val id2 = newId()
        val r = c.post("/v1/program-instances") {
            auth(w.uid); jsonBody()
            setBody("""{"id":"$id2","programId":"${w.programId}","startDate":"2026-11-03","tz":"Asia/Seoul","skipPolicy":"FIXED_DATE",$values}""")
        }
        assertEquals(HttpStatusCode.Created, r.status)
        val plan = c.planOf(w.uid, id2, 3).arrOf()
        for (i in 0 until 3) {
            val a = pv[i].jsonObject
            val b = plan[i].jsonObject
            for (k in listOf("planSeq", "dayKey", "scheduledDate", "estimatedMinutes", "confirmed", "week", "cycle")) {
                assertEquals(b[k], a[k], "workout $i $k")
            }
            assertEquals(b["exercises"], a["exercises"])
        }
        assertNotNull(r.objOf()["next"]!!.jsonObject["estimatedMinutes"])
        }
    }

    @Test
    fun preview_validation_matches_start() = fakeTest {
        startApplication()
        val c = jsonClient()
        val w = world()
        val noTm = c.preview(w.uid, w.programId, """{"working":{"squat":100}}""")
        assertEquals(HttpStatusCode.BadRequest, noTm.status)
        assertEquals("tm.bench", errField(noTm.objOf()))
        val noWorking = c.preview(w.uid, w.programId, """{"tm":{"bench":80}}""")
        assertEquals("working.squat", errField(noWorking.objOf()))
        assertEquals("tm.bench", errField(c.preview(w.uid, w.programId, """{"tm":{"bench":-1},"working":{"squat":100}}""").objOf()))
        assertEquals("count", errField(c.preview(w.uid, w.programId, """{$values,"count":5}""").objOf()))
        assertEquals("count", errField(c.preview(w.uid, w.programId, """{$values,"count":0}""").objOf()))
        assertEquals("skipPolicy", errField(c.preview(w.uid, w.programId, """{$values,"skipPolicy":"X"}""").objOf()))
        assertEquals("startDate", errField(c.preview(w.uid, w.programId, """{$values,"startDate":"11/02"}""").objOf()))
        assertEquals("tz", errField(c.preview(w.uid, w.programId, """{$values,"tz":"Mars/Base"}""").objOf()))
        // 요일 없는 프로그램 FIXED_DATE
        val none = world(withWeekdays = false)
        val fixed = c.preview(none.uid, none.programId, """{$values,"skipPolicy":"FIXED_DATE"}""")
        assertEquals(HttpStatusCode.BadRequest, fixed.status)
        assertEquals("skipPolicy", errField(fixed.objOf()))
        // 없는 프로그램, 남의 프로그램
        assertEquals(HttpStatusCode.NotFound, c.preview(w.uid, UUID.randomUUID(), """{$values}""").status)
        assertEquals(HttpStatusCode.NotFound, c.preview(createUser(), w.programId, """{$values}""").status)
        assertEquals(HttpStatusCode.Unauthorized, c.post("/v1/programs/${w.programId}/preview") { jsonBody(); setBody("{}") }.status)
    }

    // ---------------------------------------------------------------- 2. weekdays

    @Test
    fun weekdays_change_instance_definition_only() = fakeTest {
        startApplication()
        withToday("2026-11-02T00:00:00Z") {
        val c = jsonClient()
        val w = world()
        val id = newId()
        val r = c.start(w.uid, id, w.programId, ""","skipPolicy":"FIXED_DATE","weekdays":{"A":"TUE"}""")
        assertEquals(HttpStatusCode.Created, r.status)
        // 2026-11-02(월) 시작인데 A 가 화요일로 바뀌어 11-03
        assertEquals("2026-11-03", r.objOf()["next"]!!.jsonObject.str("scheduledDate"))
        val defs = transaction {
            ProgramInstances.selectAll().where { ProgramInstances.id eq UUID.fromString(id) }.single()[ProgramInstances.definition] to
                Programs.selectAll().where { Programs.id eq w.programId }.single()[Programs.definition]
        }
        fun weekdaysOf(text: String) = kotlinx.serialization.json.Json.parseToJsonElement(text).jsonObject["days"]!!.jsonArray
            .map { it.jsonObject["weekday"]?.jsonPrimitive?.content }
        assertEquals(listOf<String?>("TUE", "THU"), weekdaysOf(defs.first))
        assertEquals(listOf<String?>("MON", "THU"), weekdaysOf(defs.second))
        // 멱등 재전송은 처음 그대로
        val again = c.start(w.uid, id, w.programId, ""","skipPolicy":"FIXED_DATE","weekdays":{"A":"FRI"}""")
        assertEquals(HttpStatusCode.Created, again.status)
        assertEquals("2026-11-03", again.objOf()["next"]!!.jsonObject.str("scheduledDate"))
        }
    }

    @Test
    fun weekdays_validation() = fakeTest {
        startApplication()
        val c = jsonClient()
        val w = world()
        val dup = c.start(w.uid, newId(), w.programId, ""","weekdays":{"A":"THU"}""")
        assertEquals(HttpStatusCode.BadRequest, dup.status)
        assertEquals("weekdays", errField(dup.objOf()))
        val dup2 = c.start(w.uid, newId(), w.programId, ""","weekdays":{"A":"WED","B":"WED"}""")
        assertEquals("weekdays", errField(dup2.objOf()))
        val badKey = c.start(w.uid, newId(), w.programId, ""","weekdays":{"Z":"MON"}""")
        assertEquals(HttpStatusCode.BadRequest, badKey.status)
        assertEquals("weekdays.Z", errField(badKey.objOf()))
        val badVal = c.start(w.uid, newId(), w.programId, ""","weekdays":{"A":"MONDAY"}""")
        assertEquals("weekdays.A", errField(badVal.objOf()))
        // 두 요일을 서로 바꾸는 건 가능
        assertEquals(HttpStatusCode.Created, c.start(w.uid, newId(), w.programId, ""","weekdays":{"A":"THU","B":"MON"}""").status)
        // preview 도 같은 검증
        assertEquals("weekdays", errField(c.preview(w.uid, w.programId, """{$values,"weekdays":{"A":"THU"}}""").objOf()))
        assertEquals("weekdays.Z", errField(c.preview(w.uid, w.programId, """{$values,"weekdays":{"Z":"MON"}}""").objOf()))
    }

    @Test
    fun weekdays_make_fixed_date_possible_for_weekdayless_program() = fakeTest {
        startApplication()
        withToday("2026-11-02T00:00:00Z") {
        val c = jsonClient()
        val w = world(withWeekdays = false)
        assertEquals(HttpStatusCode.BadRequest, c.start(w.uid, newId(), w.programId, ""","skipPolicy":"FIXED_DATE"""").status)
        // 일부 날만 주면 여전히 부족
        assertEquals(HttpStatusCode.BadRequest, c.start(w.uid, newId(), w.programId, ""","skipPolicy":"FIXED_DATE","weekdays":{"A":"MON"}""").status)
        val ok = c.start(w.uid, newId(), w.programId, ""","skipPolicy":"FIXED_DATE","weekdays":{"A":"WED","B":"SAT"}""")
        assertEquals(HttpStatusCode.Created, ok.status)
        assertEquals("2026-11-04", ok.objOf()["next"]!!.jsonObject.str("scheduledDate"))
        val pv = c.preview(w.uid, w.programId, """{"startDate":"2026-11-02","skipPolicy":"FIXED_DATE",$values,"count":2,"weekdays":{"A":"WED","B":"SAT"}}""").objOf()
        assertEquals(listOf("2026-11-04", "2026-11-07"), pv["workouts"]!!.jsonArray.map { it.jsonObject.str("scheduledDate") })
        }
    }

    @Test
    fun real_template_preview_with_weekdays_and_session_minutes_in_lists() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val list = c.get("/v1/programs?source=TEMPLATE") { auth(uid) }.arrOf().map { it.jsonObject }
        val sl = list.first { it.str("templateKey") == "stronglifts-5x5" }
        val pid = sl.str("id")!!
        val sm = sl["sessionMinutes"]!!.jsonObject
        val min = sm["min"]!!.jsonPrimitive.content.toInt()
        val max = sm["max"]!!.jsonPrimitive.content.toInt()
        assertTrue(min in 5..max && max < 240, "$min..$max")
        assertTrue(list.all { it["sessionMinutes"] != null }, "모든 템플릿에 sessionMinutes")
        val detail = c.get("/v1/programs/$pid") { auth(uid) }.objOf()
        assertEquals(sm, detail["sessionMinutes"])

        val body = """{"startDate":"2026-11-04","tz":"Asia/Seoul","skipPolicy":"FIXED_DATE","working":{"squat":100,"bench":60,"row":50,"ohp":40,"deadlift":120},"weekdays":{"A":"MON","B":"THU"},"count":2}"""
        val r = c.post("/v1/programs/$pid/preview") { auth(uid); jsonBody(); setBody(body) }
        assertEquals(HttpStatusCode.OK, r.status)
        val wk = r.objOf()["workouts"]!!.jsonArray.map { it.jsonObject }
        assertEquals(listOf("2026-11-09", "2026-11-12"), wk.map { it.str("scheduledDate") })
        assertTrue(wk[0]["exercises"]!!.jsonArray.isNotEmpty())
        // 요일 없는 템플릿에 weekdays 없이 FIXED_DATE 는 400
        val bad = c.post("/v1/programs/$pid/preview") {
            auth(uid); jsonBody()
            setBody("""{"skipPolicy":"FIXED_DATE","working":{"squat":100,"bench":60,"row":50,"ohp":40,"deadlift":120}}""")
        }
        assertEquals(HttpStatusCode.BadRequest, bad.status)
        // 템플릿 원본은 그대로
        assertTrue(!detail["definition"]!!.jsonObject["days"]!!.jsonArray.any { it.jsonObject["weekday"] != null })
    }

    @Test
    fun import_start_programs_applies_weekdays() = fitlogTest {
        startApplication()
        withToday("2026-11-02T00:00:00Z") {
        val c = jsonClient()
        val uid = createUser()
        val iid = newId()
        fun imp(extra: String) = kotlinx.coroutines.runBlocking {
            c.post("/v1/imports") {
                auth(uid); jsonBody()
                setBody("""{"bundle":{"schemaVersion":1,"startPrograms":[{"id":"$iid","program":{"templateKey":"stronglifts-5x5"},"startDate":"2026-11-02","skipPolicy":"FIXED_DATE","working":{"squat":100,"bench":60,"row":50,"ohp":40,"deadlift":120}$extra}]}}""")
            }
        }
        assertEquals(HttpStatusCode.BadRequest, imp("").status) // 요일 없음
        assertEquals(HttpStatusCode.BadRequest, imp(""","weekdays":{"A":"MON","B":"MON"}""").status)
        assertEquals(HttpStatusCode.BadRequest, imp(""","weekdays":{"Z":"MON"}""").status)
        assertEquals(HttpStatusCode.Created, imp(""","weekdays":{"A":"MON","B":"THU"}""").status)
        val inst = c.get("/v1/program-instances/$iid") { auth(uid) }.objOf()
        assertEquals("2026-11-02", inst["next"]!!.jsonObject.str("scheduledDate"))
        }
    }

    // ---------------------------------------------------------------- 3. Durations

    private fun ex(sets: List<PlannedSet>, accessory: Boolean = false) = PlannedExercise("k", "e", accessory, sets)
    private fun set(warmup: Boolean = false, rest: Int? = null) = PlannedSet("s", 5, 100.0, isAmrap = false, isWarmup = warmup, restSec = rest)

    @Test
    fun durations_rules() {
        // 본 세트 3개: 40*3 + 150*2 = 420s = 7분 → 5분 단위 반올림 5
        assertEquals(5, Durations.estimateMinutes(listOf(ex(List(3) { set() }))))
        // 본 5세트: 200 + 600 = 800s → 14분 → 15
        assertEquals(15, Durations.estimateMinutes(listOf(ex(List(5) { set() }))))
        // 종목 바꿈 2분: 5세트 2종목 = 800*2 + 120 = 1720s → 29분 → 30
        assertEquals(30, Durations.estimateMinutes(listOf(ex(List(5) { set() }), ex(List(5) { set() }))))
        // 보조는 휴식 90: 5세트 = 200 + 360 = 560s → 10분 → 10
        assertEquals(10, Durations.estimateMinutes(listOf(ex(List(5) { set() }, accessory = true))))
        // 워밍업: 30 + 60, 휴식 지정은 그것: 워밍업 2 + 본 1 = (30+60)+(30+60)+40 = 220s → 4분 → 5
        assertEquals(5, Durations.estimateMinutes(listOf(ex(listOf(set(true), set(true), set())))))
        // restSec 지정: 3세트 휴식 600 → 40*3 + 600*2 = 1320s → 22분 → 20
        assertEquals(20, Durations.estimateMinutes(listOf(ex(List(3) { set(rest = 600) }))))
        // 빈 계획도 최소 5
        assertEquals(5, Durations.estimateMinutes(emptyList()))
    }

    @Test
    fun session_minutes_for_real_template_and_failure_is_null() {
        val sm = Durations.sessionMinutes(ProgramEngine, "{not json")
        assertNull(sm)
        val text = Durations::class.java.getResource("/programs/stronglifts-5x5.json")!!.readText()
        val v = Durations.sessionMinutes(ProgramEngine, text)
        assertNotNull(v)
        assertTrue(v.min in 5..v.max)
        assertEquals(v, Durations.sessionMinutes(ProgramEngine, text)) // 캐시
    }
}
