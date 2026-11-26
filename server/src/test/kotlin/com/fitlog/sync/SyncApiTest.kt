package com.fitlog.sync

import com.fitlog.session.arr
import com.fitlog.session.change
import com.fitlog.session.get
import com.fitlog.session.getSession
import com.fitlog.session.insertExercise
import com.fitlog.session.newId
import com.fitlog.session.obj
import com.fitlog.session.putSession
import com.fitlog.session.pull
import com.fitlog.session.push
import com.fitlog.session.sessionJson
import com.fitlog.session.exJson
import com.fitlog.session.setJson
import com.fitlog.session.str
import com.fitlog.support.auth
import com.fitlog.support.createUser
import com.fitlog.support.fitlogTest
import com.fitlog.support.jsonBody
import com.fitlog.support.jsonClient
import io.ktor.client.request.get
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.http.HttpStatusCode
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class SyncApiTest {
    private val t0 = "2026-11-26T10:00:00Z"
    private val t1 = "2026-11-26T10:01:00Z"
    private val t2 = "2026-11-26T10:02:00Z"

    private fun sessionChange(id: String, at: String, tz: String = "Asia/Seoul", op: String = "UPSERT", note: String? = null) =
        change(
            "workout_session", id, op, at,
            payload = if (op == "DELETE") null else """{"startedAt":"2026-11-26T09:00:00Z","tz":"$tz"${if (note != null) ""","note":"$note"""" else ""}}""",
        )

    private fun seChange(id: String, sessionId: String, exerciseId: UUID, at: String, position: Int = 0) =
        change("session_exercise", id, "UPSERT", at, parentId = sessionId, payload = """{"exerciseId":"$exerciseId","position":$position}""")

    private fun setChange(id: String, seId: String, at: String, position: Int = 0, payload: String = """{"position":$position,"weightKg":100,"reps":5,"completedAt":"$at"}""") =
        change("workout_set", id, "UPSERT", at, parentId = seId, payload = payload)

    private fun JsonObject.results() = this["results"]!!.jsonArray.map { it.jsonObject }

    @Test
    fun push_applies_session_exercise_and_set_in_order() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val ex = insertExercise(uid)
        val sid = newId(); val se = newId(); val set = newId()
        val res = c.push(uid, sessionChange(sid, t0), seChange(se, sid, ex, t0), setChange(set, se, t0)).obj().results()
        assertEquals(listOf("applied", "applied", "applied"), res.map { it.str("status") })

        val s = c.getSession(uid, sid).obj()
        assertEquals("Asia/Seoul", s.str("tz"))
        val exs = s["exercises"]!!.jsonArray
        assertEquals(1, exs.size)
        assertEquals("100.0", exs[0].jsonObject["sets"]!!.jsonArray[0].str("weightKg"))
    }

    @Test
    fun push_is_idempotent() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val ex = insertExercise(uid)
        val sid = newId(); val se = newId(); val set = newId()
        val changes = arrayOf(sessionChange(sid, t0), seChange(se, sid, ex, t0), setChange(set, se, t0))
        val first = c.push(uid, *changes).obj().results()
        val snapshot = c.getSession(uid, sid).obj().toString().replace(Regex(""""updatedAt":"[^"]*""""), "")
        val second = c.push(uid, *changes).obj().results()
        assertEquals(first.map { it.str("status") }, second.map { it.str("status") })
        assertTrue(second.all { it.str("status") == "applied" })
        assertEquals(snapshot, c.getSession(uid, sid).obj().toString().replace(Regex(""""updatedAt":"[^"]*""""), ""))
        // pull 도 같은 행만 준다: 내 종목 1 + 세션/종목/세트 3
        assertEquals(4, c.pull(uid, 0).obj()["changes"]!!.jsonArray.size)
    }

    @Test
    fun applied_push_sets_updated_at_to_client_updated_at() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val sid = newId()
        c.push(uid, sessionChange(sid, t1))
        val ch = c.pull(uid, 0).obj()["changes"]!!.jsonArray.single().jsonObject
        assertEquals(t1, ch.str("clientUpdatedAt"))
        assertEquals("workout_session", ch.str("entity"))
        assertNotNull(ch.str("serverSeq"))
    }

    @Test
    fun conflict_when_server_row_is_newer_and_returns_server_value() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val sid = newId()
        // REST 쓰기는 now. clientUpdatedAt(2026-11-26)이 서버 now 보다 과거이므로 충돌
        c.putSession(uid, sid, sessionJson(sid, tz = "UTC"))
        val res = c.push(uid, sessionChange(sid, t0, tz = "Asia/Seoul")).obj().results().single()
        assertEquals("conflict", res.str("status"))
        val server = res["server"]!!.jsonObject
        assertEquals("workout_session", server.str("entity"))
        assertEquals("UTC", server["payload"]!!.str("tz"))
        assertNotNull(server.str("serverSeq"))
        assertEquals("UTC", c.getSession(uid, sid).obj().str("tz"))
    }

    @Test
    fun equal_or_newer_client_timestamp_wins() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val sid = newId()
        c.push(uid, sessionChange(sid, t1, tz = "UTC"))
        // 더 오래된 변경은 충돌
        assertEquals("conflict", c.push(uid, sessionChange(sid, t0, tz = "Asia/Tokyo")).obj().results().single().str("status"))
        // 같은 시각은 적용
        assertEquals("applied", c.push(uid, sessionChange(sid, t1, tz = "Asia/Seoul")).obj().results().single().str("status"))
        assertEquals("Asia/Seoul", c.getSession(uid, sid).obj().str("tz"))
        // 더 새로운 시각도 적용
        assertEquals("applied", c.push(uid, sessionChange(sid, t2, tz = "Asia/Tokyo")).obj().results().single().str("status"))
        assertEquals("Asia/Tokyo", c.getSession(uid, sid).obj().str("tz"))
    }

    @Test
    fun stale_delete_conflicts_and_server_deleted_row_is_returned_as_delete() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val sid = newId()
        c.push(uid, sessionChange(sid, t1))
        val stale = c.push(uid, sessionChange(sid, t0, op = "DELETE")).obj().results().single()
        assertEquals("conflict", stale.str("status"))
        assertEquals("UPSERT", stale["server"]!!.str("op"))

        c.push(uid, sessionChange(sid, t2, op = "DELETE"))
        val upsertOld = c.push(uid, sessionChange(sid, t1)).obj().results().single()
        assertEquals("conflict", upsertOld.str("status"))
        assertEquals("DELETE", upsertOld["server"]!!.str("op"))
        assertNull(upsertOld["server"]!!["payload"])
    }

    @Test
    fun child_before_parent_is_parent_missing_then_succeeds_on_next_push() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val ex = insertExercise(uid)
        val sid = newId(); val se = newId(); val set = newId()
        // 세트가 가장 먼저
        val first = c.push(uid, setChange(set, se, t0), seChange(se, sid, ex, t0)).obj().results()
        assertEquals("rejected", first[0].str("status"))
        assertEquals("PARENT_MISSING", first[0].str("code"))
        assertEquals("PARENT_MISSING", first[1].str("code")) // 세션도 아직 없음
        // 부모부터 보낸 뒤 다시 보내면 성공
        val second = c.push(uid, sessionChange(sid, t0), seChange(se, sid, ex, t0), setChange(set, se, t0)).obj().results()
        assertTrue(second.all { it.str("status") == "applied" }, second.toString())
        assertEquals(1, c.getSession(uid, sid).obj()["exercises"]!!.jsonArray[0].jsonObject["sets"]!!.jsonArray.size)
    }

    @Test
    fun child_of_deleted_parent_is_parent_missing() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val ex = insertExercise(uid)
        val sid = newId(); val se = newId(); val set = newId()
        c.push(uid, sessionChange(sid, t0), seChange(se, sid, ex, t0))
        c.push(uid, change("session_exercise", se, "DELETE", t1))
        val res = c.push(uid, setChange(set, se, t2)).obj().results().single()
        assertEquals("rejected", res.str("status"))
        assertEquals("PARENT_MISSING", res.str("code"))
    }

    @Test
    fun validation_failure_does_not_block_other_changes() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val ex = insertExercise(uid)
        val sid = newId(); val se = newId(); val badSet = newId(); val goodSet = newId(); val bm = newId()
        val res = c.push(
            uid,
            sessionChange(sid, t0),
            seChange(se, sid, ex, t0),
            setChange(badSet, se, t0, payload = """{"position":0,"weightKg":100,"reps":5,"rpe":7.3,"completedAt":"$t0"}"""),
            setChange(goodSet, se, t0, position = 1),
            change("body_measurement", bm, "UPSERT", t0, payload = """{"measuredAt":"$t0","weightKg":5}"""),
            sessionChange(newId(), t0, tz = "Mars/Base"),
            change("workout_set", newId(), "UPSERT", t0, parentId = se, payload = """{"weightKg":"abc"}"""),
            change("bogus", newId(), "UPSERT", t0, payload = "{}"),
        ).obj().results()
        assertEquals(
            listOf("applied", "applied", "rejected", "applied", "rejected", "rejected", "rejected", "rejected"),
            res.map { it.str("status") },
        )
        assertEquals(listOf(2, 4, 5, 6, 7), res.indices.filter { res[it].str("status") == "rejected" })
        assertTrue(res.filter { it.str("status") == "rejected" }.all { it.str("code") == "VALIDATION_FAILED" })
        val sets = c.getSession(uid, sid).obj()["exercises"]!!.jsonArray[0].jsonObject["sets"]!!.jsonArray
        assertEquals(1, sets.size)
    }

    @Test
    fun set_type_required_fields_checked_in_sync_only_for_completed_sets() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val ex = insertExercise(uid, "BARBELL")
        val sid = newId(); val se = newId()
        c.push(uid, sessionChange(sid, t0), seChange(se, sid, ex, t0))
        val completedNoWeight = c.push(uid, setChange(newId(), se, t0, payload = """{"position":0,"reps":5,"completedAt":"$t0"}""")).obj().results().single()
        assertEquals("VALIDATION_FAILED", completedNoWeight.str("code"))
        val incomplete = c.push(uid, setChange(newId(), se, t0, payload = """{"position":0}""")).obj().results().single()
        assertEquals("applied", incomplete.str("status"))
    }

    @Test
    fun other_users_rows_are_forbidden() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val owner = createUser()
        val intruder = createUser()
        val ex = insertExercise(owner)
        val bmId = newId()
        val sid = newId(); val se = newId(); val set = newId()
        c.push(owner, sessionChange(sid, t0), seChange(se, sid, ex, t0), setChange(set, se, t0), change("body_measurement", bmId, "UPSERT", t0, payload = """{"measuredAt":"$t0","weightKg":70}"""))

        val res = c.push(
            intruder,
            sessionChange(sid, t2, tz = "UTC"),
            sessionChange(sid, t2, op = "DELETE"),
            seChange(se, sid, insertExercise(intruder), t2),
            setChange(set, se, t2),
            setChange(newId(), se, t2), // 남의 session_exercise 아래 새 세트
            change("body_measurement", bmId, "DELETE", t2),
            change("exercise", ex.toString(), "DELETE", t2),
        ).obj().results()
        assertTrue(res.all { it.str("status") == "rejected" && it.str("code") == "FORBIDDEN" }, res.toString())

        // 원본 보존, 침입자 pull 은 비어 있음(내 종목 하나는 위 insertExercise 로 만든 DB 직접 행이라 sync 대상 아님)
        assertEquals("Asia/Seoul", c.getSession(owner, sid).obj().str("tz"))
        val pulled = c.pull(intruder, 0).obj()["changes"]!!.jsonArray
        assertTrue(pulled.none { it.str("entity") != "exercise" })
    }

    @Test
    fun exercise_upsert_delete_only_for_user_exercises() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val builtIn = insertExercise(null)
        val mine = newId()
        val payload = """{"nameKo":"내 운동","type":"MACHINE","primaryMuscle":"BACK","secondaryMuscles":["BICEPS"]}"""
        val res = c.push(
            uid,
            change("exercise", mine, "UPSERT", t0, payload = payload),
            change("exercise", builtIn.toString(), "UPSERT", t2, payload = payload),
            change("exercise", builtIn.toString(), "DELETE", t2),
            change("exercise", newId(), "UPSERT", t0, payload = """{"nameKo":"x","type":"BAD","primaryMuscle":"BACK"}"""),
        ).obj().results()
        assertEquals(listOf("applied", "rejected", "rejected", "rejected"), res.map { it.str("status") })
        assertEquals(listOf(null, "FORBIDDEN", "FORBIDDEN", "VALIDATION_FAILED"), res.map { it.str("code") })

        val pulled = c.pull(uid, 0).obj()["changes"]!!.jsonArray
        assertEquals(1, pulled.size) // 기본 종목은 pull 에 나오지 않는다
        assertEquals(mine, pulled[0].str("id"))
        assertEquals("BACK", pulled[0].jsonObject["payload"]!!.str("primaryMuscle"))

        assertEquals("applied", c.push(uid, change("exercise", mine, "DELETE", t1)).obj().results().single().str("status"))
        val after = c.pull(uid, 0).obj()["changes"]!!.jsonArray.single().jsonObject
        assertEquals("DELETE", after.str("op"))
        assertNull(after["payload"])
    }

    @Test
    fun session_exercise_using_unknown_or_foreign_exercise() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val sid = newId()
        c.push(uid, sessionChange(sid, t0))
        val foreign = insertExercise(createUser())
        val res = c.push(
            uid,
            seChange(newId(), sid, UUID.randomUUID(), t0),
            seChange(newId(), sid, foreign, t0),
        ).obj().results()
        assertEquals("PARENT_MISSING", res[0].str("code"))
        assertEquals("VALIDATION_FAILED", res[1].str("code"))
    }

    @Test
    fun delete_propagates_to_children_and_pull_and_is_idempotent() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val ex = insertExercise(uid)
        val sid = newId(); val se = newId(); val set = newId()
        c.push(uid, sessionChange(sid, t0), seChange(se, sid, ex, t0), setChange(set, se, t0))
        val since = c.pull(uid, 0).obj()["nextSince"]!!.toString().toLong()

        val del = c.push(uid, sessionChange(sid, t1, op = "DELETE")).obj().results().single()
        assertEquals("applied", del.str("status"))
        assertEquals("applied", c.push(uid, sessionChange(sid, t1, op = "DELETE")).obj().results().single().str("status"))
        assertEquals("applied", c.push(uid, sessionChange(newId(), t1, op = "DELETE")).obj().results().single().str("status"))
        assertEquals(HttpStatusCode.NotFound, c.getSession(uid, sid).status)

        val changes = c.pull(uid, since).obj()["changes"]!!.jsonArray.map { it.jsonObject }
        val byEntity = changes.associateBy { it.str("entity") }
        assertEquals(setOf("workout_session", "session_exercise", "workout_set"), byEntity.keys)
        assertTrue(changes.all { it.str("op") == "DELETE" && it["payload"] == null })
        assertEquals(sid, byEntity["session_exercise"]!!.str("parentId"))
        assertEquals(se, byEntity["workout_set"]!!.str("parentId"))
        // 삭제된 부모 밑에 다시 올리면 PARENT_MISSING
        assertEquals("PARENT_MISSING", c.push(uid, setChange(set, se, t2)).obj().results().single().str("code"))
    }

    @Test
    fun rest_writes_show_up_in_pull_and_rest_delete_of_removed_children_propagates() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val ex = insertExercise(uid)
        val sid = newId(); val se = newId(); val keep = newId(); val drop = newId()
        c.putSession(uid, sid, sessionJson(sid, exercises = listOf(exJson(se, ex, 0, listOf(setJson(keep, 0), setJson(drop, 1))))))
        val first = c.pull(uid, 0).obj()
        assertEquals(5, first["changes"]!!.jsonArray.size)
        val since = first["nextSince"]!!.toString().toLong()
        c.putSession(uid, sid, sessionJson(sid, exercises = listOf(exJson(se, ex, 0, listOf(setJson(keep, 0))))))
        val ids = c.pull(uid, since).obj()["changes"]!!.jsonArray
        val del = ids.first { it.str("id") == drop }
        assertEquals("DELETE", del.str("op"))
    }

    @Test
    fun pull_paginates_with_has_more_and_next_since() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val ids = (1..501).map { newId() }
        ids.chunked(200).forEach { chunk ->
            val res = c.push(uid, *chunk.map { change("body_measurement", it, "UPSERT", t0, payload = """{"measuredAt":"$t0","weightKg":70}""") }.toTypedArray())
            assertTrue(res.obj().results().all { it.str("status") == "applied" })
        }
        val p1 = c.pull(uid, 0).obj()
        assertEquals(500, p1["changes"]!!.jsonArray.size)
        assertEquals("true", p1["hasMore"].toString())
        val seqs1 = p1["changes"]!!.jsonArray.map { it.str("serverSeq")!!.toLong() }
        assertEquals(seqs1.sorted(), seqs1)
        assertEquals(seqs1.last(), p1["nextSince"].toString().toLong())

        val p2 = c.pull(uid, p1["nextSince"].toString().toLong()).obj()
        assertEquals(1, p2["changes"]!!.jsonArray.size)
        assertEquals("false", p2["hasMore"].toString())
        val last = p2["changes"]!!.jsonArray[0].str("serverSeq")!!.toLong()
        assertEquals(last, p2["nextSince"].toString().toLong())

        val p3 = c.pull(uid, last).obj()
        assertEquals(0, p3["changes"]!!.jsonArray.size)
        assertEquals(last, p3["nextSince"].toString().toLong()) // 변경이 없으면 since 유지
        assertEquals(ids.toSet(), (p1["changes"]!!.jsonArray + p2["changes"]!!.jsonArray).map { it.str("id") }.toSet())
    }

    @Test
    fun pull_requires_non_negative_since_and_push_limits_to_200() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        for (q in listOf("", "?since=-1", "?since=abc")) {
            val res = c.get("/v1/sync/pull$q") { auth(uid) }
            assertEquals(HttpStatusCode.BadRequest, res.status, q)
            assertEquals("since", res.obj()["error"]!!.str("field"))
        }
        val many = (1..201).map { change("body_measurement", newId(), "UPSERT", t0, payload = """{"measuredAt":"$t0","weightKg":70}""") }
        val res = c.post("/v1/sync/push") { auth(uid); jsonBody(); setBody("""{"changes":[${many.joinToString(",")}]}""") }
        assertEquals(HttpStatusCode.BadRequest, res.status)
        assertEquals(0, c.pull(uid, 0).obj()["changes"]!!.jsonArray.size)
    }

    @Test
    fun pull_is_isolated_per_user() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val a = createUser()
        val b = createUser()
        c.push(a, sessionChange(newId(), t0))
        assertEquals(1, c.pull(a, 0).obj()["changes"]!!.jsonArray.size)
        assertEquals(0, c.pull(b, 0).obj()["changes"]!!.jsonArray.size)
    }

    @Test
    fun offline_scenario_second_device_receives_same_data_and_later_edits() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val sid = newId(); val se1 = newId(); val se2 = newId(); val s1 = newId(); val s2 = newId(); val s3 = newId()
        val exMine = newId()
        val bm = newId()
        val bench = insertExercise(null, "BARBELL")

        // 기기 A: 오프라인에서 만든 것을 부모 순서대로 push (1회 push 가 아니라 outbox 순서)
        val pushRes = c.push(
            uid,
            change("exercise", exMine, "UPSERT", t0, payload = """{"nameKo":"케이블 컬","type":"MACHINE","primaryMuscle":"BICEPS"}"""),
            sessionChange(sid, t0, note = "오프라인 운동"),
            seChange(se1, sid, bench, t0, 0),
            seChange(se2, sid, UUID.fromString(exMine), t0, 1),
            setChange(s1, se1, t0, 0),
            setChange(s2, se1, t0, 1, payload = """{"position":1,"weightKg":102.5,"reps":3,"rpe":9,"completedAt":"$t0"}"""),
            setChange(s3, se2, t0, 0, payload = """{"position":0,"weightKg":30,"reps":12,"completedAt":"$t0"}"""),
            change("body_measurement", bm, "UPSERT", t0, payload = """{"measuredAt":"$t0","weightKg":72.4}"""),
        ).obj().results()
        assertTrue(pushRes.all { it.str("status") == "applied" }, pushRes.toString())

        // 기기 B: 처음부터 pull
        val pulled = c.pull(uid, 0).obj()
        val changes = pulled["changes"]!!.jsonArray.map { it.jsonObject }
        assertEquals("false", pulled["hasMore"].toString())
        assertEquals(8, changes.size)
        assertEquals(setOf(exMine, sid, se1, se2, s1, s2, s3, bm), changes.map { it.str("id") }.toSet())
        val seq = changes.map { it.str("serverSeq")!!.toLong() }
        assertEquals(seq.sorted(), seq)
        val byId = changes.associateBy { it.str("id") }
        assertEquals("오프라인 운동", byId[sid]!!["payload"]!!.str("note"))
        assertEquals(sid, byId[se2]!!.str("parentId"))
        assertEquals(se2, byId[s3]!!.str("parentId"))
        assertEquals("102.5", byId[s2]!!["payload"]!!.str("weightKg"))
        assertEquals("9.0", byId[s2]!!["payload"]!!.str("rpe"))
        assertEquals("72.4", byId[bm]!!["payload"]!!.str("weightKg"))
        assertEquals(exMine, byId[exMine]!!.str("id"))
        assertEquals("케이블 컬", byId[exMine]!!["payload"]!!.str("nameKo"))

        // REST 로 읽은 것과 같은 구조
        val rest = c.getSession(uid, sid).obj()
        assertEquals(listOf(bench.toString(), exMine), rest["exercises"]!!.jsonArray.map { it.str("exerciseId") })

        // 기기 B 가 세트를 고쳐서 push (더 최신 시각) → 기기 A 는 since 이후 변경만 받는다
        val since = pulled["nextSince"].toString().toLong()
        val edit = c.push(uid, setChange(s2, se1, t2, 1, payload = """{"position":1,"weightKg":105,"reps":3,"completedAt":"$t2"}"""))
        assertEquals("applied", edit.obj().results().single().str("status"))
        val delta = c.pull(uid, since).obj()["changes"]!!.jsonArray
        assertEquals(1, delta.size)
        assertEquals(s2, delta[0].str("id"))
        assertEquals("105.0", delta[0].jsonObject["payload"]!!.str("weightKg"))
        assertEquals(t2, delta[0].str("clientUpdatedAt"))
        // 기기 A 가 오래된 편집을 보내면 충돌, 서버 값(105)을 돌려받는다
        val stale = c.push(uid, setChange(s2, se1, t1, 1, payload = """{"position":1,"weightKg":90,"reps":3,"completedAt":"$t1"}""")).obj().results().single()
        assertEquals("conflict", stale.str("status"))
        assertEquals("105.0", stale["server"]!!["payload"]!!.str("weightKg"))
    }

    @Test
    fun body_measurement_sync_roundtrip_and_rest_visibility() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val id = newId()
        c.push(uid, change("body_measurement", id, "UPSERT", t0, payload = """{"measuredAt":"$t0","weightKg":70.255,"source":"HEALTH_CONNECT"}"""))
        val list = c.get("/v1/body/measurements") { auth(uid) }.arr()
        assertEquals("70.26", list.single().str("weightKg"))
        assertEquals("HEALTH_CONNECT", list.single().str("source"))
        c.push(uid, change("body_measurement", id, "DELETE", t1))
        assertEquals(0, c.get("/v1/body/measurements") { auth(uid) }.arr().size)
    }
}
