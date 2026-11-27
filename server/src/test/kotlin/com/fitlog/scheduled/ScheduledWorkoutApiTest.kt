package com.fitlog.scheduled

import com.fitlog.core.AppJson
import com.fitlog.core.DeletionRequests
import com.fitlog.core.Ids
import com.fitlog.core.ScheduledWorkouts
import com.fitlog.core.Times
import com.fitlog.core.WorkoutSessions
import com.fitlog.core.WorkoutSets
import com.fitlog.export.MiniSchema
import com.fitlog.session.arr
import com.fitlog.session.change
import com.fitlog.session.exJson
import com.fitlog.session.get
import com.fitlog.session.getSession
import com.fitlog.session.insertExercise
import com.fitlog.session.newId
import com.fitlog.session.obj
import com.fitlog.session.pull
import com.fitlog.session.push
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
import io.ktor.client.request.put
import io.ktor.client.request.setBody
import io.ktor.client.statement.HttpResponse
import io.ktor.client.statement.bodyAsText
import io.ktor.http.HttpStatusCode
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import org.jetbrains.exposed.sql.SqlExpressionBuilder.eq
import org.jetbrains.exposed.sql.insert
import org.jetbrains.exposed.sql.selectAll
import org.jetbrains.exposed.sql.transactions.transaction
import java.time.LocalDate
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ScheduledWorkoutApiTest {
    private val t0 = "2026-11-26T10:00:00Z"
    private val t1 = "2026-11-26T10:01:00Z"
    private val t2 = "2026-11-26T10:02:00Z"

    private fun body(id: String, ex: UUID, date: String = "2026-11-28", title: String = "B-2 하체", extra: String = "") =
        """{"id":"$id","plannedDate":"$date","title":"$title","note":"RIR 3~4",$extra"items":[{"exerciseId":"$ex","note":"벨트","restSec":180,"sets":[""" +
            """{"isWarmup":false,"targetWeightKg":80,"targetReps":12,"targetRepsMax":15,"targetRir":3},{"targetReps":10}]}]}"""

    private fun payload(ex: UUID, date: String = "2026-11-28", title: String = "B-2") =
        """{"plannedDate":"$date","title":"$title","items":[{"exerciseId":"$ex","sets":[{"targetReps":10,"targetRepsMax":12}]}]}"""

    private fun scChange(id: String, at: String, p: String?, op: String = "UPSERT") = change("scheduled_workout", id, op, at, payload = p)

    private fun sessionChange(id: String, at: String, scheduledId: String?) =
        change(
            "workout_session", id, "UPSERT", at,
            payload = """{"startedAt":"2026-11-28T09:00:00Z","tz":"Asia/Seoul"${if (scheduledId != null) ""","scheduledWorkoutId":"$scheduledId"""" else ""}}""",
        )

    private fun JsonObject.results() = this["results"]!!.jsonArray.map { it.jsonObject }

    private suspend fun HttpClient.putSc(uid: UUID, id: String, b: String): HttpResponse =
        put("/v1/scheduled-workouts/$id") { auth(uid); jsonBody(); setBody(b) }

    // ---------------------------------------------------------------- sync

    @Test
    fun sync_push_and_pull_roundtrip_scheduled_workout() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val ex = insertExercise(uid)
        val id = newId()
        val res = c.push(uid, scChange(id, t0, payload(ex))).obj().results()
        assertEquals("applied", res[0].str("status"))

        val pulled = c.pull(uid, 0).obj()["changes"]!!.jsonArray.map { it.jsonObject }.first { it.str("entity") == "scheduled_workout" }
        assertEquals(id, pulled.str("id"))
        assertEquals("UPSERT", pulled.str("op"))
        val p = pulled["payload"]!!.jsonObject
        assertEquals("2026-11-28", p.str("plannedDate"))
        assertEquals("B-2", p.str("title"))
        assertNull(p["status"]); assertNull(p["sessionId"])
        val set = p["items"]!!.jsonArray[0].jsonObject["sets"]!!.jsonArray[0]
        assertEquals("12", set.str("targetRepsMax"))
        val seq = pulled.str("serverSeq")!!.toLong()
        assertTrue(c.pull(uid, seq).obj()["changes"]!!.jsonArray.none { it.str("entity") == "scheduled_workout" })

        // LWW: 오래된 변경은 conflict, 삭제는 pull 에 DELETE 로 나온다
        assertEquals("conflict", c.push(uid, scChange(id, "2026-11-26T09:00:00Z", payload(ex, title = "old"))).obj().results()[0].str("status"))
        assertEquals("applied", c.push(uid, scChange(id, t1, null, op = "DELETE")).obj().results()[0].str("status"))
        val del = c.pull(uid, seq).obj()["changes"]!!.jsonArray.map { it.jsonObject }.single { it.str("entity") == "scheduled_workout" }
        assertEquals("DELETE", del.str("op"))
    }

    @Test
    fun sync_rejects_invalid_scheduled_workout_and_foreign_exercise() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val other = createUser()
        val builtIn = insertExercise(null)
        val foreign = insertExercise(other)
        val res = c.push(
            uid,
            scChange(newId(), t0, payload(builtIn)),
            scChange(newId(), t0, payload(foreign)),
            scChange(newId(), t0, payload(UUID.randomUUID())),
            scChange(newId(), t0, """{"plannedDate":"nope","title":"x","items":[]}"""),
        ).obj().results()
        assertEquals(listOf("applied", "rejected", "rejected", "rejected"), res.map { it.str("status") })
        assertEquals("VALIDATION_FAILED", res[1].str("code"))
        assertEquals("VALIDATION_FAILED", res[2].str("code"))
        assertEquals("VALIDATION_FAILED", res[3].str("code"))
    }

    @Test
    fun sync_other_users_scheduled_id_is_forbidden() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val a = createUser(); val b = createUser()
        val ex = insertExercise(null)
        val id = newId()
        c.push(a, scChange(id, t0, payload(ex)))
        val res = c.push(b, scChange(id, t1, payload(ex, title = "hijack"))).obj().results()[0]
        assertEquals("rejected", res.str("status"))
        assertEquals("FORBIDDEN", res.str("code"))
    }

    @Test
    fun session_with_missing_scheduled_workout_is_parent_missing() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val other = createUser()
        val ex = insertExercise(null)
        val foreign = newId()
        c.push(other, scChange(foreign, t0, payload(ex)))
        val res = c.push(uid, sessionChange(newId(), t0, newId()), sessionChange(newId(), t0, foreign)).obj().results()
        assertEquals(listOf("rejected", "rejected"), res.map { it.str("status") })
        assertEquals(listOf("PARENT_MISSING", "PARENT_MISSING"), res.map { it.str("code") })
    }

    @Test
    fun session_links_scheduled_workout_and_duplicate_link_is_unlinked() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val ex = insertExercise(null)
        val sc = newId(); val s1 = newId(); val s2 = newId()
        c.push(uid, scChange(sc, t0, payload(ex)))
        assertEquals("applied", c.push(uid, sessionChange(s1, t0, sc)).obj().results()[0].str("status"))
        assertEquals(sc, c.getSession(uid, s1).obj().str("scheduledWorkoutId"))

        // 같은 예정을 가리키는 두 번째 세션: applied, 연결은 끊긴다
        assertEquals("applied", c.push(uid, sessionChange(s2, t1, sc)).obj().results()[0].str("status"))
        assertNull(c.getSession(uid, s2).obj().str("scheduledWorkoutId"))
        val pulled = c.pull(uid, 0).obj()["changes"]!!.jsonArray.map { it.jsonObject }
            .first { it.str("entity") == "workout_session" && it.str("id") == s2 }
        assertNull(pulled["payload"]!!.jsonObject.str("scheduledWorkoutId"))

        // 같은 세션을 다시 보내도 연결이 유지된다
        c.push(uid, sessionChange(s1, t2, sc))
        assertEquals(sc, c.getSession(uid, s1).obj().str("scheduledWorkoutId"))

        // 예정을 지워도 세션의 연결은 그대로
        c.push(uid, scChange(sc, t2, null, op = "DELETE"))
        assertEquals(sc, c.getSession(uid, s1).obj().str("scheduledWorkoutId"))
    }

    @Test
    fun workout_set_target_fields_roundtrip_via_sync_and_rest() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val ex = insertExercise(uid)
        val sid = newId(); val se = newId(); val set = newId()
        val res = c.push(
            uid,
            sessionChange(sid, t0, null),
            change("session_exercise", se, "UPSERT", t0, parentId = sid, payload = """{"exerciseId":"$ex","position":0}"""),
            change(
                "workout_set", set, "UPSERT", t0, parentId = se,
                payload = """{"position":0,"targetReps":12,"targetRepsMax":15,"targetRir":3,"targetRestSec":120}""",
            ),
        ).obj().results()
        assertEquals(listOf("applied", "applied", "applied"), res.map { it.str("status") })
        val s = c.getSession(uid, sid).obj()["exercises"]!!.jsonArray[0].jsonObject["sets"]!!.jsonArray[0]
        assertEquals("15", s.str("targetRepsMax")); assertEquals("3", s.str("targetRir")); assertEquals("120", s.str("targetRestSec"))
        val pulled = c.pull(uid, 0).obj()["changes"]!!.jsonArray.map { it.jsonObject }.first { it.str("entity") == "workout_set" }
        assertEquals("120", pulled["payload"]!!.jsonObject.str("targetRestSec"))

        // PUT /v1/sessions 도 같은 필드를 받는다
        val sid2 = newId()
        val r = c.putSession(
            uid, sid2,
            sessionJson(sid2, exercises = listOf(exJson(exerciseId = ex, sets = listOf(setJson(extra = """"targetRepsMax":8,"targetRir":2,"targetRestSec":90""")))))
        )
        assertEquals(HttpStatusCode.OK, r.status)
        val s2 = r.obj()["exercises"]!!.jsonArray[0].jsonObject["sets"]!!.jsonArray[0]
        assertEquals("8", s2.str("targetRepsMax")); assertEquals("2", s2.str("targetRir")); assertEquals("90", s2.str("targetRestSec"))
        val bid = newId()
        val bad = c.putSession(uid, bid, sessionJson(bid, exercises = listOf(exJson(exerciseId = ex, sets = listOf(setJson(extra = """"targetRir":11"""))))))
        assertEquals(HttpStatusCode.BadRequest, bad.status)
    }

    @Test
    fun put_session_scheduled_link_validates_and_conflicts() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val ex = insertExercise(null)
        val sc = newId()
        assertEquals(HttpStatusCode.OK, c.putSc(uid, sc, body(sc, ex)).status)
        fun withLink(id: String, link: String) = sessionJson(id).replace("\"exercises\"", "\"scheduledWorkoutId\":\"$link\",\"exercises\"")
        val a = newId(); val b = newId()
        assertEquals(HttpStatusCode.OK, c.putSession(uid, a, withLink(a, sc)).status)
        assertEquals(sc, c.getSession(uid, a).obj().str("scheduledWorkoutId"))
        assertEquals(HttpStatusCode.Conflict, c.putSession(uid, b, withLink(b, sc)).status)
        assertEquals(HttpStatusCode.BadRequest, c.putSession(uid, b, withLink(b, newId())).status)
    }

    // ---------------------------------------------------------------- REST

    @Test
    fun rest_put_get_skip_delete_with_status() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val ex = insertExercise(null)
        val id = newId()
        val put = c.putSc(uid, id, body(id, ex))
        assertEquals(HttpStatusCode.OK, put.status)
        val saved = put.obj()
        assertEquals("PLANNED", saved.str("status"))
        assertEquals("APP", saved.str("source"))
        assertEquals("15", saved["items"]!!.jsonArray[0].jsonObject["sets"]!!.jsonArray[0].str("targetRepsMax"))
        assertNotNull(saved.str("updatedAt"))

        // 전체 교체
        val replaced = c.putSc(uid, id, body(id, ex, title = "바뀜")).obj()
        assertEquals("바뀜", replaced.str("title"))

        val list = c.get("/v1/scheduled-workouts?from=2026-11-01&to=2026-11-30") { auth(uid) }.obj()["items"]!!.jsonArray
        assertEquals(listOf(id), list.map { it.str("id") })

        // skip / unskip
        val skipped = c.post("/v1/scheduled-workouts/$id/skip") { auth(uid); jsonBody(); setBody("""{"skipped":true}""") }
        assertEquals(HttpStatusCode.OK, skipped.status)
        assertEquals("SKIPPED", skipped.obj().str("status"))
        assertNotNull(skipped.obj().str("skippedAt"))
        val unskipped = c.post("/v1/scheduled-workouts/$id/skip") { auth(uid); jsonBody(); setBody("""{"skipped":false}""") }.obj()
        assertEquals("PLANNED", unskipped.str("status"))
        assertNull(unskipped.str("skippedAt"))

        // 세션 연결 → IN_PROGRESS → DONE
        val sid = newId()
        c.push(uid, sessionChange(sid, t0, id))
        var item = c.get("/v1/scheduled-workouts?from=2026-11-01&to=2026-11-30") { auth(uid) }.obj()["items"]!!.jsonArray[0]
        assertEquals("IN_PROGRESS", item.str("status")); assertEquals(sid, item.str("sessionId"))
        c.push(uid, change("workout_session", sid, "UPSERT", t1, payload = """{"startedAt":"2026-11-28T09:00:00Z","endedAt":"2026-11-28T10:00:00Z","tz":"Asia/Seoul","scheduledWorkoutId":"$id"}"""))
        item = c.get("/v1/scheduled-workouts?from=2026-11-01&to=2026-11-30") { auth(uid) }.obj()["items"]!!.jsonArray[0]
        assertEquals("DONE", item.str("status"))

        assertEquals(HttpStatusCode.NoContent, c.delete("/v1/scheduled-workouts/$id") { auth(uid) }.status)
        assertEquals(0, c.get("/v1/scheduled-workouts?from=2026-11-01&to=2026-11-30") { auth(uid) }.obj()["items"]!!.jsonArray.size)
        // 삭제된 것도 sync pull 에는 DELETE 로 나온다
        assertTrue(c.pull(uid, 0).obj()["changes"]!!.jsonArray.any { it.str("entity") == "scheduled_workout" && it.str("op") == "DELETE" })
    }

    @Test
    fun rest_other_users_and_missing_are_404_and_validation_is_400() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val a = createUser(); val b = createUser()
        val ex = insertExercise(null)
        val foreignEx = insertExercise(b)
        val id = newId()
        c.putSc(a, id, body(id, ex))
        assertEquals(HttpStatusCode.NotFound, c.putSc(b, id, body(id, ex)).status)
        assertEquals(HttpStatusCode.NotFound, c.delete("/v1/scheduled-workouts/$id") { auth(b) }.status)
        assertEquals(HttpStatusCode.NotFound, c.post("/v1/scheduled-workouts/$id/skip") { auth(b); jsonBody(); setBody("""{"skipped":true}""") }.status)
        val missing = newId()
        assertEquals(HttpStatusCode.NotFound, c.delete("/v1/scheduled-workouts/$missing") { auth(a) }.status)
        assertEquals(HttpStatusCode.NotFound, c.post("/v1/scheduled-workouts/$missing/skip") { auth(a); jsonBody(); setBody("""{"skipped":true}""") }.status)
        assertEquals(0, c.get("/v1/scheduled-workouts?from=2026-11-01&to=2026-11-30") { auth(b) }.obj()["items"]!!.jsonArray.size)

        val id2 = newId()
        assertEquals(HttpStatusCode.BadRequest, c.putSc(a, id2, body(id2, foreignEx)).status)
        assertEquals(HttpStatusCode.BadRequest, c.putSc(a, id2, body(id2, ex, date = "2026-13-40")).status)
        assertEquals(HttpStatusCode.BadRequest, c.putSc(a, id2, body(newId(), ex)).status)
        assertEquals(HttpStatusCode.Unauthorized, c.get("/v1/scheduled-workouts").status)
    }

    @Test
    fun rest_list_range_default_and_92_day_limit() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val ex = insertExercise(null)
        val today = LocalDate.now(java.time.ZoneId.of("Asia/Seoul"))
        val inRange = newId(); val farFuture = newId(); val past = newId()
        c.putSc(uid, inRange, body(inRange, ex, date = today.plusDays(5).toString()))
        c.putSc(uid, farFuture, body(farFuture, ex, date = today.plusDays(60).toString()))
        c.putSc(uid, past, body(past, ex, date = today.minusDays(3).toString()))
        val def = c.get("/v1/scheduled-workouts") { auth(uid) }.obj()["items"]!!.jsonArray.map { it.str("id") }
        assertEquals(listOf(past, inRange), def)

        assertEquals(HttpStatusCode.OK, c.get("/v1/scheduled-workouts?from=2026-01-01&to=2026-04-02") { auth(uid) }.status) // 92일
        assertEquals(HttpStatusCode.BadRequest, c.get("/v1/scheduled-workouts?from=2026-01-01&to=2026-04-03") { auth(uid) }.status) // 93일
        assertEquals(HttpStatusCode.BadRequest, c.get("/v1/scheduled-workouts?from=2026-01-10&to=2026-01-01") { auth(uid) }.status)
        assertEquals(HttpStatusCode.BadRequest, c.get("/v1/scheduled-workouts?from=abc") { auth(uid) }.status)
    }

    // ---------------------------------------------------------------- export / deletion / account

    @Test
    fun export_json_includes_scheduled_workouts_and_session_link() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val ex = insertExercise(uid)
        val live = newId(); val gone = newId()
        c.putSc(uid, live, body(live, ex))
        c.putSc(uid, gone, body(gone, ex, title = "지움"))
        c.post("/v1/scheduled-workouts/$live/skip") { auth(uid); jsonBody(); setBody("""{"skipped":true}""") }
        c.delete("/v1/scheduled-workouts/$gone") { auth(uid) }
        val sid = newId()
        c.putSession(
            uid, sid,
            sessionJson(sid, exercises = listOf(exJson(exerciseId = ex, sets = listOf(setJson()))))
                .replace("\"exercises\"", "\"scheduledWorkoutId\":\"$live\",\"exercises\""),
        )

        val text = c.get("/v1/export.json") { auth(uid) }.bodyAsText()
        val bundle = AppJson.parseToJsonElement(text).jsonObject
        val errors = MiniSchema.load().validate(bundle)
        assertTrue(errors.isEmpty(), errors.joinToString("\n"))
        val sw = bundle["scheduledWorkouts"]!!.jsonArray
        assertEquals(1, sw.size)
        val w = sw[0].jsonObject
        assertEquals(live, w.str("id"))
        assertEquals("2026-11-28", w.str("plannedDate"))
        assertEquals("B-2 하체", w.str("title"))
        assertNull(w["skippedAt"]); assertNull(w["status"])
        val item = w["items"]!!.jsonArray[0].jsonObject
        assertEquals(ex.toString(), item["exercise"]!!.jsonObject.str("id"))
        assertEquals("180", item.str("restSec"))
        assertEquals("15", item["sets"]!!.jsonArray[0].str("targetRepsMax"))
        assertEquals(live, bundle["sessions"]!!.jsonArray[0].str("scheduledWorkoutId"))
    }

    @Test
    fun approved_deletion_request_soft_deletes_scheduled_workout() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val other = createUser()
        val ex = insertExercise(null)
        val id = newId()
        c.putSc(uid, id, body(id, ex))
        fun request(owner: UUID, entityId: String): UUID {
            val rid = Ids.newId()
            transaction {
                DeletionRequests.insert {
                    it[DeletionRequests.id] = rid
                    it[userId] = owner
                    it[clientName] = "Claude"
                    it[entity] = "scheduled_workout"
                    it[DeletionRequests.entityId] = UUID.fromString(entityId)
                    it[status] = "PENDING"
                    it[createdAt] = Times.now()
                    it[expiresAt] = Times.now().plusSeconds(3600)
                }
            }
            return rid
        }
        val r = request(uid, id)
        val res = c.post("/v1/deletion-requests/$r/approve") { auth(uid) }
        assertEquals(HttpStatusCode.OK, res.status)
        assertEquals("APPROVED", res.obj().str("status"))
        val row = transaction { ScheduledWorkouts.selectAll().where { ScheduledWorkouts.id eq UUID.fromString(id) }.single() }
        assertNotNull(row[ScheduledWorkouts.deletedAt])
        assertEquals(0, c.get("/v1/scheduled-workouts?from=2026-11-01&to=2026-11-30") { auth(uid) }.obj()["items"]!!.jsonArray.size)

        // 이미 지워졌거나 남의 것이면 "already deleted" 로 승인만 된다
        val r2 = request(uid, id)
        assertEquals("already deleted", c.post("/v1/deletion-requests/$r2/approve") { auth(uid) }.obj().str("note"))
        val id3 = newId()
        c.putSc(other, id3, body(id3, ex))
        val r3 = request(uid, id3)
        assertEquals("already deleted", c.post("/v1/deletion-requests/$r3/approve") { auth(uid) }.obj().str("note"))
        assertNull(transaction { ScheduledWorkouts.selectAll().where { ScheduledWorkouts.id eq UUID.fromString(id3) }.single()[ScheduledWorkouts.deletedAt] })
    }

    @Test
    fun account_deletion_removes_scheduled_workouts_and_linked_sessions() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val ex = insertExercise(null)
        val sc = newId(); val sid = newId()
        c.putSc(uid, sc, body(sc, ex))
        c.push(uid, sessionChange(sid, t0, sc))
        assertEquals(HttpStatusCode.NoContent, c.delete("/v1/me") { auth(uid) }.status)
        assertEquals(0L, transaction { ScheduledWorkouts.selectAll().where { ScheduledWorkouts.userId eq uid }.count() })
        assertEquals(0L, transaction { WorkoutSessions.selectAll().where { WorkoutSessions.userId eq uid }.count() })
    }
}
