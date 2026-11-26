package com.fitlog.stats

import com.fitlog.core.ChangeSeq
import com.fitlog.core.Ids
import com.fitlog.core.SessionExercises
import com.fitlog.core.Times
import com.fitlog.core.UserSettingsTable
import com.fitlog.core.WorkoutSessions
import com.fitlog.core.WorkoutSets
import com.fitlog.session.insertExercise
import com.fitlog.support.auth
import com.fitlog.support.createUser
import com.fitlog.support.fitlogTest
import com.fitlog.support.jsonClient
import io.ktor.client.HttpClient
import io.ktor.client.request.get
import io.ktor.client.statement.HttpResponse
import io.ktor.client.statement.bodyAsText
import io.ktor.http.HttpStatusCode
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.jetbrains.exposed.sql.batchInsert
import org.jetbrains.exposed.sql.insert
import org.jetbrains.exposed.sql.transactions.transaction
import java.math.BigDecimal
import java.time.Instant
import java.time.temporal.ChronoUnit
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

class StatsApiTest {

    // ------------------------------------------------------------ 시드 도구 (SQL 직접 삽입)

    private class S(
        val weight: String? = "100",
        val reps: Int? = 5,
        val warmup: Boolean = false,
        val completed: Boolean = true,
        val deleted: Boolean = false,
    )

    private class E(val exerciseId: UUID, val sets: List<S>, val deleted: Boolean = false)

    private fun s(w: String, r: Int) = S(w, r)

    private fun seed(
        uid: UUID,
        startedAt: Instant,
        vararg exercises: E,
        instanceId: UUID? = null,
        dayKey: String? = null,
        deleted: Boolean = false,
    ): UUID {
        val sid = Ids.newId()
        transaction {
            WorkoutSessions.insert {
                it[id] = sid
                it[userId] = uid
                it[WorkoutSessions.startedAt] = startedAt
                it[endedAt] = startedAt.plusSeconds(3600)
                it[tz] = "Asia/Seoul"
                it[sourceCol] = "APP"
                it[createdAt] = Times.now()
                it[updatedAt] = Times.now()
                it[serverSeq] = ChangeSeq.next
                it[programInstanceId] = instanceId
                it[planDayKey] = dayKey
                it[deletedAt] = if (deleted) Times.now() else null
            }
            exercises.forEachIndexed { ei, e ->
                val seId = Ids.newId()
                SessionExercises.insert {
                    it[id] = seId
                    it[sessionId] = sid
                    it[exerciseId] = e.exerciseId
                    it[position] = ei
                    it[updatedAt] = Times.now()
                    it[serverSeq] = ChangeSeq.next
                    it[deletedAt] = if (e.deleted) Times.now() else null
                }
                e.sets.forEachIndexed { si, st ->
                    WorkoutSets.insert {
                        it[id] = Ids.newId()
                        it[sessionExerciseId] = seId
                        it[position] = si
                        it[isWarmup] = st.warmup
                        it[weightKg] = st.weight?.let(::BigDecimal)
                        it[reps] = st.reps
                        it[completedAt] = if (st.completed) startedAt.plusSeconds(600L + si) else null
                        it[updatedAt] = Times.now()
                        it[serverSeq] = ChangeSeq.next
                        it[deletedAt] = if (st.deleted) Times.now() else null
                    }
                }
            }
        }
        return sid
    }

    private fun seedInstance(uid: UUID): UUID {
        val pid = com.fitlog.export.insertProgramRow(uid)
        return com.fitlog.export.insertInstanceRow(uid, pid)
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

    private val day0: Instant = Instant.parse("2026-03-01T01:00:00Z")
    private fun day(n: Long): Instant = day0.plus(n, ChronoUnit.DAYS)
    private val wide = "from=2020-01-01T00:00:00Z&to=2030-01-01T00:00:00Z"

    // ------------------------------------------------------------ 요청 도구

    private suspend fun HttpClient.progress(uid: UUID, ex: UUID, query: String = wide): HttpResponse =
        get("/v1/exercises/$ex/progress?$query") { auth(uid) }

    private suspend fun HttpClient.comparison(uid: UUID, sid: UUID): HttpResponse =
        get("/v1/sessions/$sid/comparison") { auth(uid) }

    private suspend fun HttpResponse.json(): JsonObject = Json.parseToJsonElement(bodyAsText()).jsonObject

    private suspend fun HttpResponse.errorCode(): String =
        Json.parseToJsonElement(bodyAsText()).jsonObject["error"]!!.jsonObject["code"]!!.jsonPrimitive.content

    private fun JsonObject.points() = this["points"]!!.jsonArray.map { it.jsonObject }
    private fun JsonObject.num(k: String) = this[k]!!.jsonPrimitive.double
    private fun JsonObject.int(k: String) = this[k]!!.jsonPrimitive.int
    private fun JsonObject.bool(k: String) = this[k]!!.jsonPrimitive.content.toBoolean()
    private fun JsonObject.str(k: String) = this[k]!!.jsonPrimitive.content
    private fun JsonElement?.isNullish() = this == null || this is JsonNull

    // ------------------------------------------------------------ progress: 세트 필터

    @Test
    fun progress_uses_only_completed_non_warmup_non_deleted_sets_with_weight_and_reps() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val other = createUser()
        val ex = insertExercise(null)
        seed(
            uid, day(0),
            E(ex, listOf(s("100", 5), S("140", 5, warmup = true), S("150", 5, completed = false), S("160", 5, deleted = true),
                S(null, 5), S("170", null), S("120", 0))),
        )
        // 지운 세션·지운 종목 행·남의 세션은 제외
        seed(uid, day(1), E(ex, listOf(s("200", 5))), deleted = true)
        seed(uid, day(2), E(ex, listOf(s("210", 5)), deleted = true))
        seed(other, day(3), E(ex, listOf(s("220", 5))))
        // 세트가 하나도 안 남는 세션은 점이 없다
        seed(uid, day(4), E(ex, listOf(S("100", 5, warmup = true))))

        val body = c.progress(uid, ex).json()
        val pts = body.points()
        assertEquals(1, pts.size)
        assertEquals(100.0, pts[0].num("topWeightKg"))
        assertEquals(1, pts[0].int("workSetCount"))
        assertEquals(500.0, pts[0].num("volumeKg"))
    }

    @Test
    fun progress_aggregates_one_point_per_session_in_ascending_order() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val ex = insertExercise(null)
        val other = insertExercise(null)
        // 입력 순서를 섞어서 넣는다
        val s2 = seed(uid, day(7), E(ex, listOf(s("100", 5), s("100", 8), s("90", 12))), E(other, listOf(s("300", 1))))
        val s1 = seed(uid, day(0), E(ex, listOf(s("80", 10))))
        val s3 = seed(uid, day(14), E(ex, listOf(s("60", 12))))

        val pts = c.progress(uid, ex).json().points()
        assertEquals(listOf(s1, s2, s3).map { it.toString() }, pts.map { it.str("sessionId") })
        val p2 = pts[1]
        assertEquals(100.0, p2.num("topWeightKg"))
        assertEquals(8, p2.int("topReps")) // 최고 무게 세트들 중 최대 횟수
        assertEquals(3, p2.int("workSetCount"))
        assertEquals(100.0 * 5 + 100.0 * 8 + 90.0 * 12, p2.num("volumeKg"))
        assertEquals(126.67, p2.num("bestE1rmKg")) // 100 * (1 + 8/30), 12회 세트는 제외
        assertEquals("2026-03-08T01:00:00Z", p2.str("startedAt"))
        // 1~10회가 없는 세션은 bestE1rmKg 가 null
        assertTrue(pts[2]["bestE1rmKg"].isNullish())
        assertEquals(60.0, pts[2].num("topWeightKg"))
    }

    // ------------------------------------------------------------ progress: PR 판정

    @Test
    fun progress_pr_flags_are_strictly_greater_than_running_max() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val ex = insertExercise(null)
        seed(uid, day(0), E(ex, listOf(s("100", 5)))) // 첫 기록은 PR
        seed(uid, day(1), E(ex, listOf(s("100", 5)))) // 같으면 PR 아님(무게·e1rm 모두)
        seed(uid, day(2), E(ex, listOf(s("100", 6)))) // 무게 같고 e1rm 더 큼
        seed(uid, day(3), E(ex, listOf(s("105", 1)))) // 무게는 PR, e1rm(105)은 120 보다 작아 PR 아님
        seed(uid, day(4), E(ex, listOf(s("105", 1)))) // 다시 같으면 둘 다 아님

        val pts = c.progress(uid, ex).json().points()
        assertEquals(
            listOf(true to true, false to false, false to true, true to false, false to false),
            pts.map { it.bool("isWeightPr") to it.bool("isE1rmPr") },
        )
    }

    @Test
    fun progress_pr_considers_sessions_outside_the_range_and_best_is_all_time() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val ex = insertExercise(null)
        val old = seed(uid, day(0), E(ex, listOf(s("150", 3))))
        seed(uid, day(30), E(ex, listOf(s("140", 3)))) // 기간 밖의 150 보다 낮으므로 PR 아님
        seed(uid, day(31), E(ex, listOf(s("155", 3))))

        val body = c.progress(uid, ex, "from=${day(20)}&to=${day(40)}").json()
        val pts = body.points()
        assertEquals(2, pts.size)
        assertEquals(false, pts[0].bool("isWeightPr"))
        assertEquals(false, pts[0].bool("isE1rmPr"))
        assertEquals(true, pts[1].bool("isWeightPr"))
        // 전체 최고는 기간과 무관
        assertEquals(155.0, body["bestWeight"]!!.jsonObject.num("weightKg"))
        val all = c.progress(uid, ex, "from=${day(0)}&to=${day(0)}").json()
        assertEquals(old.toString(), all.points().single().str("sessionId"))
        assertEquals(155.0, all["bestWeight"]!!.jsonObject.num("weightKg"))
    }

    @Test
    fun progress_bests_equal_the_records_endpoint() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val ex = insertExercise(null)
        seed(uid, day(0), E(ex, listOf(s("100", 5), s("110", 3), s("110", 2))))
        seed(uid, day(1), E(ex, listOf(s("90", 10), S("200", 1, warmup = true))))
        seed(uid, day(2), E(ex, listOf(s("110", 3))))

        val p = c.progress(uid, ex).json()
        val rec = c.get("/v1/exercises/$ex/records") { auth(uid) }.json()
        assertEquals(rec["formula"], p["formula"])
        assertEquals(rec["bestWeight"], p["bestWeight"])
        assertEquals(rec["bestE1rm"], p["bestE1rm"])
        assertNotNull(p["bestWeight"]!!.jsonObject["setId"])
    }

    @Test
    fun progress_uses_the_user_e1rm_formula() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        setFormula(uid, "BRZYCKI")
        val ex = insertExercise(null)
        seed(uid, day(0), E(ex, listOf(s("100", 5))))
        val body = c.progress(uid, ex).json()
        assertEquals("BRZYCKI", body.str("formula"))
        assertEquals(112.5, body.points().single().num("bestE1rmKg")) // 100 * 36 / 32
        assertEquals(112.5, body["bestE1rm"]!!.jsonObject.num("e1rmKg"))
    }

    // ------------------------------------------------------------ progress: 기간·limit·검증

    @Test
    fun progress_defaults_to_last_180_days_and_empty_points_when_no_sessions() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val ex = insertExercise(null)
        val empty = c.get("/v1/exercises/$ex/progress") { auth(uid) }
        assertEquals(HttpStatusCode.OK, empty.status)
        val eb = empty.json()
        assertEquals(0, eb.points().size)
        assertTrue(eb["bestWeight"].isNullish())
        assertTrue(eb["bestE1rm"].isNullish())

        val now = Instant.now()
        val recent = seed(uid, now.minus(170, ChronoUnit.DAYS), E(ex, listOf(s("100", 5))))
        seed(uid, now.minus(190, ChronoUnit.DAYS), E(ex, listOf(s("100", 5))))
        val pts = c.get("/v1/exercises/$ex/progress") { auth(uid) }.json().points()
        assertEquals(listOf(recent.toString()), pts.map { it.str("sessionId") })
        // to 만 주면 from 은 to-180일
        val withTo = c.get("/v1/exercises/$ex/progress?to=${now.minus(100, ChronoUnit.DAYS)}") { auth(uid) }.json().points()
        assertEquals(2, withTo.size) // 170일 전·190일 전 모두 [to-180일(=280일 전), to(=100일 전)] 안
    }

    @Test
    fun progress_limit_keeps_most_recent_points_in_ascending_order() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val ex = insertExercise(null)
        val ids = (0L until 6L).map { seed(uid, day(it), E(ex, listOf(s("100", 5)))) }
        val pts = c.progress(uid, ex, "$wide&limit=3").json().points()
        assertEquals(ids.takeLast(3).map { it.toString() }, pts.map { it.str("sessionId") })
        // 기본값은 100, 500 도 허용
        assertEquals(6, c.progress(uid, ex).json().points().size)
        assertEquals(HttpStatusCode.OK, c.progress(uid, ex, "$wide&limit=500").status)
        assertEquals(HttpStatusCode.OK, c.progress(uid, ex, "$wide&limit=1").status)
    }

    @Test
    fun progress_default_limit_is_100_most_recent() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val ex = insertExercise(null)
        val ids = (0L until 105L).map { seed(uid, day(it), E(ex, listOf(s("100", 5)))) }
        val pts = c.progress(uid, ex).json().points()
        assertEquals(100, pts.size)
        assertEquals(ids[5].toString(), pts.first().str("sessionId"))
        assertEquals(ids.last().toString(), pts.last().str("sessionId"))
    }

    @Test
    fun progress_rejects_bad_query_values_with_validation_failed() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val ex = insertExercise(null)
        for (q in listOf("limit=0", "limit=501", "limit=-1", "limit=abc", "from=yesterday", "to=2026-13-40", "from=2026-05-01T00:00:00Z&to=2026-04-01T00:00:00Z")) {
            val r = c.get("/v1/exercises/$ex/progress?$q") { auth(uid) }
            assertEquals(HttpStatusCode.BadRequest, r.status, q)
            assertEquals("VALIDATION_FAILED", r.errorCode(), q)
        }
        val badId = c.get("/v1/exercises/not-a-uuid/progress") { auth(uid) }
        assertEquals(HttpStatusCode.BadRequest, badId.status)
    }

    @Test
    fun progress_returns_404_for_missing_other_users_or_deleted_exercise() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val other = createUser()
        val theirs = insertExercise(other)
        val mine = insertExercise(uid)
        assertEquals(HttpStatusCode.NotFound, c.progress(uid, theirs).status)
        assertEquals(HttpStatusCode.NotFound, c.progress(uid, UUID.randomUUID()).status)
        assertEquals("NOT_FOUND", c.progress(uid, theirs).errorCode())
        assertEquals(HttpStatusCode.OK, c.progress(uid, mine).status)
        // 인증 없음
        assertEquals(HttpStatusCode.Unauthorized, c.get("/v1/exercises/$mine/progress").status)
    }

    // ------------------------------------------------------------ comparison

    @Test
    fun comparison_lists_exercises_in_session_position_order_even_when_sets_are_empty() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val a = insertExercise(null)
        val b = insertExercise(null)
        val d = insertExercise(null)
        val sid = seed(
            uid, day(0),
            E(b, listOf(s("50", 10))),
            E(a, listOf(S("60", 5, completed = false))), // 필터로 전부 빠져도 종목은 포함
            E(d, listOf(s("70", 3)), deleted = true),    // 지운 종목 행은 제외
        )
        val body = c.comparison(uid, sid).json()
        assertEquals(sid.toString(), body.str("sessionId"))
        assertEquals("EPLEY", body.str("formula"))
        val ex = body["exercises"]!!.jsonArray.map { it.jsonObject }
        assertEquals(listOf(b.toString(), a.toString()), ex.map { it.str("exerciseId") })
        val cur = ex[0]["current"]!!.jsonObject
        assertEquals(sid.toString(), cur.str("sessionId"))
        assertEquals(1, cur.int("setCount"))
        assertEquals(500.0, cur.num("volumeKg"))
        val empty = ex[1]["current"]!!.jsonObject
        assertEquals(0, empty["sets"]!!.jsonArray.size)
        assertEquals(0, empty.int("setCount"))
        assertTrue(empty["topWeightKg"].isNullish())
        assertTrue(empty["bestE1rmKg"].isNullish())
        assertEquals(0.0, empty.num("volumeKg"))
        assertTrue(ex[1]["previous"].isNullish())
        assertTrue(ex[1]["bestWeight"].isNullish())
    }

    @Test
    fun comparison_current_snapshot_has_sets_in_order_with_top_and_e1rm() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val ex = insertExercise(null)
        val sid = seed(uid, day(0), E(ex, listOf(s("100", 5), S("40", 10, warmup = true), s("110", 3), s("90", 12))))
        val cur = c.comparison(uid, sid).json()["exercises"]!!.jsonArray[0].jsonObject["current"]!!.jsonObject
        assertEquals(listOf(100.0 to 5, 110.0 to 3, 90.0 to 12), cur["sets"]!!.jsonArray.map { it.jsonObject.num("weightKg") to it.jsonObject.int("reps") })
        assertEquals(3, cur.int("setCount"))
        assertEquals(110.0, cur.num("topWeightKg"))
        assertEquals(121.0, cur.num("bestE1rmKg")) // 110 * (1 + 3/30); 100x5 = 116.67
        assertEquals(500.0 + 330.0 + 1080.0, cur.num("volumeKg"))
    }

    @Test
    fun comparison_prefers_previous_session_of_same_program_instance_and_day() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val ex = insertExercise(null)
        val inst = seedInstance(uid)
        val a1 = seed(uid, day(0), E(ex, listOf(s("100", 5))), instanceId = inst, dayKey = "A")
        seed(uid, day(2), E(ex, listOf(s("60", 5))), instanceId = inst, dayKey = "B") // 직전이지만 다른 day
        seed(uid, day(3), E(ex, listOf(s("70", 5)))) // 직전이지만 프로그램 없음
        val a2 = seed(uid, day(7), E(ex, listOf(s("105", 5))), instanceId = inst, dayKey = "A")
        seed(uid, day(9), E(ex, listOf(s("200", 5))), instanceId = inst, dayKey = "A") // 이후 세션은 무시

        val prev = c.comparison(uid, a2).json()["exercises"]!!.jsonArray[0].jsonObject["previous"]!!.jsonObject
        assertEquals(a1.toString(), prev.str("sessionId"))
        assertEquals(100.0, prev.num("topWeightKg"))
        assertEquals("2026-03-01T01:00:00Z", prev.str("startedAt"))
    }

    @Test
    fun comparison_falls_back_to_latest_earlier_session_with_the_exercise() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val ex = insertExercise(null)
        val otherEx = insertExercise(null)
        val inst = seedInstance(uid)
        seed(uid, day(0), E(ex, listOf(s("50", 5))))
        val latest = seed(uid, day(3), E(ex, listOf(s("60", 5))), instanceId = inst, dayKey = "B")
        seed(uid, day(5), E(otherEx, listOf(s("999", 5))), instanceId = inst, dayKey = "A") // 그 종목이 없음
        val cur = seed(uid, day(7), E(ex, listOf(s("70", 5))), instanceId = inst, dayKey = "A")
        // 프로그램이 달라도 같은 day 키라고 짝지으면 안 된다
        val otherInst = seedInstance(uid)
        seed(uid, day(6), E(ex, listOf(s("65", 5))), instanceId = otherInst, dayKey = "A")

        val prev = c.comparison(uid, cur).json()["exercises"]!!.jsonArray[0].jsonObject["previous"]!!.jsonObject
        assertEquals(day(6).toString(), prev.str("startedAt")) // 같은 인스턴스·day 가 없으니 그 종목을 한 직전 세션
        assertEquals(65.0, prev.num("topWeightKg"))
        assertTrue(latest.toString() != prev.str("sessionId"))
    }

    @Test
    fun comparison_previous_is_null_when_no_earlier_session_has_the_exercise() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val other = createUser()
        val ex = insertExercise(null)
        val sid = seed(uid, day(5), E(ex, listOf(s("70", 5))))
        seed(uid, day(1), E(ex, listOf(s("500", 5))), deleted = true) // 지운 세션
        seed(uid, day(2), E(ex, listOf(s("500", 5)), deleted = true)) // 지운 종목 행
        seed(other, day(3), E(ex, listOf(s("500", 5)))) // 남의 세션
        seed(uid, day(9), E(ex, listOf(s("500", 5)))) // 이후 세션

        val e = c.comparison(uid, sid).json()["exercises"]!!.jsonArray[0].jsonObject
        assertTrue(e["previous"].isNullish())
        assertTrue(e["bestWeight"].isNullish())
        assertTrue(e["bestE1rm"].isNullish())
    }

    @Test
    fun comparison_previous_may_have_no_countable_sets() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val ex = insertExercise(null)
        val older = seed(uid, day(0), E(ex, listOf(s("80", 5))))
        val prevNoSets = seed(uid, day(3), E(ex, listOf(S("90", 5, completed = false)))) // 종목은 있으나 센 세트가 없음
        val sid = seed(uid, day(6), E(ex, listOf(s("85", 5))))

        val e = c.comparison(uid, sid).json()["exercises"]!!.jsonArray[0].jsonObject
        val prev = e["previous"]!!.jsonObject
        assertEquals(prevNoSets.toString(), prev.str("sessionId"))
        assertEquals(0, prev["sets"]!!.jsonArray.size)
        assertTrue(prev["topWeightKg"].isNullish())
        assertTrue(older.toString() != prev.str("sessionId"))
        // 최고 기록은 그래도 이전 세션 전체에서
        assertEquals(80.0, e["bestWeight"]!!.jsonObject.num("weightKg"))
    }

    @Test
    fun comparison_bests_are_strictly_before_this_session() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val ex = insertExercise(null)
        seed(uid, day(0), E(ex, listOf(s("100", 5))))
        seed(uid, day(2), E(ex, listOf(s("110", 3), S("300", 1, warmup = true))))
        val sid = seed(uid, day(4), E(ex, listOf(s("120", 3), s("90", 12))))
        seed(uid, day(6), E(ex, listOf(s("200", 1)))) // 이후 세션은 포함하지 않는다

        val e = c.comparison(uid, sid).json()["exercises"]!!.jsonArray[0].jsonObject
        val bw = e["bestWeight"]!!.jsonObject
        assertEquals(110.0, bw.num("weightKg")) // 이 세션의 120 은 제외
        assertEquals(3, bw.int("reps"))
        val be = e["bestE1rm"]!!.jsonObject
        assertEquals(121.0, be.num("e1rmKg"))
        // 이 세션의 현재 값은 이전 최고보다 크다 (앱이 PR 비교)
        assertTrue(e["current"]!!.jsonObject.num("topWeightKg") > bw.num("weightKg"))
    }

    @Test
    fun comparison_uses_the_user_formula() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        setFormula(uid, "LOMBARDI")
        val ex = insertExercise(null)
        seed(uid, day(0), E(ex, listOf(s("100", 1))))
        val sid = seed(uid, day(1), E(ex, listOf(s("100", 10))))
        val body = c.comparison(uid, sid).json()
        assertEquals("LOMBARDI", body.str("formula"))
        val e = body["exercises"]!!.jsonArray[0].jsonObject
        assertEquals(125.89, e["current"]!!.jsonObject.num("bestE1rmKg")) // 100 * 10^0.1
        assertEquals(100.0, e["bestE1rm"]!!.jsonObject.num("e1rmKg"))
    }

    @Test
    fun comparison_returns_404_for_other_users_deleted_or_missing_session() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val other = createUser()
        val ex = insertExercise(null)
        val theirs = seed(other, day(0), E(ex, listOf(s("100", 5))))
        val deleted = seed(uid, day(1), E(ex, listOf(s("100", 5))), deleted = true)
        val mine = seed(uid, day(2), E(ex, listOf(s("100", 5))))
        for (sid in listOf(theirs, deleted, UUID.randomUUID())) {
            val r = c.comparison(uid, sid)
            assertEquals(HttpStatusCode.NotFound, r.status, sid.toString())
            assertEquals("NOT_FOUND", r.errorCode())
        }
        assertEquals(HttpStatusCode.OK, c.comparison(uid, mine).status)
        assertEquals(HttpStatusCode.BadRequest, c.get("/v1/sessions/nope/comparison") { auth(uid) }.status)
        assertEquals(HttpStatusCode.Unauthorized, c.get("/v1/sessions/$mine/comparison").status)
    }

    @Test
    fun comparison_of_an_empty_session_has_no_exercises() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val sid = seed(uid, day(0))
        val body = c.comparison(uid, sid).json()
        assertEquals(0, body["exercises"]!!.jsonArray.size)
    }

    // ------------------------------------------------------------ 성능

    @Test
    fun progress_over_one_year_of_four_sessions_a_week_responds_under_500ms() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val exercises = (0 until 5).map { insertExercise(null) }
        val start = Instant.now().minus(364, ChronoUnit.DAYS)
        val sessionCount = 52 * 4
        // 한 트랜잭션에서 일괄 삽입: 세션 208, 종목 행 1040, 세트 5200
        val sessionIds = (0 until sessionCount).map { Ids.newId() }
        transaction {
            val times = (0 until sessionCount).map { i -> start.plus((i / 4 * 7 + (i % 4) * 2).toLong(), ChronoUnit.DAYS).truncatedTo(ChronoUnit.MILLIS) }
            WorkoutSessions.batchInsert(sessionIds.indices.toList(), shouldReturnGeneratedValues = false) { i ->
                this[WorkoutSessions.id] = sessionIds[i]
                this[WorkoutSessions.userId] = uid
                this[WorkoutSessions.startedAt] = times[i]
                this[WorkoutSessions.endedAt] = times[i].plusSeconds(3600)
                this[WorkoutSessions.tz] = "Asia/Seoul"
                this[WorkoutSessions.sourceCol] = "APP"
                this[WorkoutSessions.createdAt] = Times.now()
                this[WorkoutSessions.updatedAt] = Times.now()
                this[WorkoutSessions.serverSeq] = ChangeSeq.next
            }
            val seRows = sessionIds.indices.flatMap { i -> exercises.indices.map { e -> Triple(i, e, Ids.newId()) } }
            SessionExercises.batchInsert(seRows, shouldReturnGeneratedValues = false) { (i, e, id) ->
                this[SessionExercises.id] = id
                this[SessionExercises.sessionId] = sessionIds[i]
                this[SessionExercises.exerciseId] = exercises[e]
                this[SessionExercises.position] = e
                this[SessionExercises.updatedAt] = Times.now()
                this[SessionExercises.serverSeq] = ChangeSeq.next
            }
            val setRows = seRows.flatMap { (i, e, id) -> (0 until 5).map { Triple(Triple(i, e, id), it, 0) } }
            WorkoutSets.batchInsert(setRows, shouldReturnGeneratedValues = false) { (se, si, _) ->
                val (i, e, seId) = se
                this[WorkoutSets.id] = Ids.newId()
                this[WorkoutSets.sessionExerciseId] = seId
                this[WorkoutSets.position] = si
                this[WorkoutSets.isWarmup] = false
                this[WorkoutSets.weightKg] = BigDecimal(60 + e * 10 + i / 8 + si)
                this[WorkoutSets.reps] = 5
                this[WorkoutSets.completedAt] = Times.now()
                this[WorkoutSets.updatedAt] = Times.now()
                this[WorkoutSets.serverSeq] = ChangeSeq.next
            }
        }

        val target = exercises[0]
        // 워밍업(JIT·커넥션 풀)
        repeat(3) { assertEquals(HttpStatusCode.OK, c.get("/v1/exercises/$target/progress?limit=500") { auth(uid) }.status) }
        val times = (0 until 5).map {
            val t0 = System.nanoTime()
            val r = c.get("/v1/exercises/$target/progress?limit=500") { auth(uid) }
            val ms = (System.nanoTime() - t0) / 1_000_000
            assertEquals(HttpStatusCode.OK, r.status)
            assertEquals(sessionCount, r.json().points().size)
            ms
        }
        val cmp = run {
            val t0 = System.nanoTime()
            val r = c.comparison(uid, sessionIds.last())
            assertEquals(HttpStatusCode.OK, r.status)
            (System.nanoTime() - t0) / 1_000_000
        }
        println("[perf] progress(208 sessions, 5 sets each) ms=$times, comparison(5 exercises) ms=$cmp")
        assertTrue(times.max() < 500, "progress took ${times.max()}ms: $times")
        assertTrue(cmp < 500, "comparison took ${cmp}ms")
    }
}
