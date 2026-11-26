package com.fitlog.session

import com.fitlog.core.SessionExercises
import com.fitlog.core.WorkoutSessions
import com.fitlog.core.WorkoutSets
import com.fitlog.support.auth
import com.fitlog.support.createUser
import com.fitlog.support.fitlogTest
import com.fitlog.support.jsonClient
import io.ktor.client.request.get
import io.ktor.http.HttpStatusCode
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive
import org.jetbrains.exposed.sql.selectAll
import org.jetbrains.exposed.sql.transactions.transaction
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull

class SessionApiTest {

    @Test
    fun put_then_get_roundtrip_orders_by_position_and_rounds_weight() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val bench = insertExercise(uid, "BARBELL")
        val pullup = insertExercise(null, "BODYWEIGHT")
        val sid = newId()
        val body = sessionJson(
            id = sid,
            exercises = listOf(
                exJson(exerciseId = pullup, position = 1, sets = listOf(setJson(weightKg = null, reps = "8"))),
                exJson(
                    exerciseId = bench, position = 0,
                    sets = listOf(
                        setJson(position = 1, weightKg = "102.5", reps = "5"),
                        setJson(position = 0, weightKg = "100.456", reps = "8", extra = """"rpe":8.5,"rir":2,"restSec":90"""),
                    ),
                ),
            ),
        )
        val put = c.putSession(uid, sid, body)
        assertEquals(HttpStatusCode.OK, put.status)
        val saved = put.obj()
        assertEquals("APP", saved.str("source"))
        assertNotNull(saved.str("updatedAt"))

        val got = c.getSession(uid, sid)
        assertEquals(HttpStatusCode.OK, got.status)
        val s = got.obj()
        val exs = s["exercises"]!!.jsonArray
        assertEquals(bench.toString(), exs[0].str("exerciseId"))
        assertEquals(pullup.toString(), exs[1].str("exerciseId"))
        val sets = exs[0].jsonPrimitiveSets()
        assertEquals(listOf(0, 1), sets.map { it.str("position")!!.toInt() })
        assertEquals("100.46", sets[0].str("weightKg"))
        assertEquals("8.5", sets[0].str("rpe"))
        assertEquals("2", sets[0].str("rir"))
        assertEquals("102.5", sets[1].str("weightKg"))
        assertNull(exs[1].jsonPrimitiveSets()[0].str("weightKg"))
    }

    private fun kotlinx.serialization.json.JsonElement.jsonPrimitiveSets() =
        (this as kotlinx.serialization.json.JsonObject)["sets"]!!.jsonArray.map { it as kotlinx.serialization.json.JsonObject }

    @Test
    fun put_again_soft_deletes_missing_exercises_and_sets() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val ex1 = insertExercise(uid)
        val ex2 = insertExercise(uid)
        val sid = newId()
        val se1 = newId()
        val se2 = newId()
        val keepSet = newId()
        val dropSet = newId()
        val dropSetOfDroppedEx = newId()
        c.putSession(
            uid, sid,
            sessionJson(
                id = sid,
                exercises = listOf(
                    exJson(se1, ex1, 0, listOf(setJson(keepSet, 0), setJson(dropSet, 1))),
                    exJson(se2, ex2, 1, listOf(setJson(dropSetOfDroppedEx, 0))),
                ),
            ),
        )
        val second = c.putSession(uid, sid, sessionJson(id = sid, exercises = listOf(exJson(se1, ex1, 0, listOf(setJson(keepSet, 0))))))
        assertEquals(HttpStatusCode.OK, second.status)
        val exs = second.obj()["exercises"]!!.jsonArray
        assertEquals(1, exs.size)
        assertEquals(1, exs[0].jsonPrimitiveSets().size)

        transaction {
            fun deleted(id: String) = WorkoutSets.selectAll().where { WorkoutSets.id eq UUID.fromString(id) }.single()[WorkoutSets.deletedAt]
            assertNull(deleted(keepSet))
            assertNotNull(deleted(dropSet))
            assertNotNull(deleted(dropSetOfDroppedEx))
            assertNotNull(
                SessionExercises.selectAll().where { SessionExercises.id eq UUID.fromString(se2) }.single()[SessionExercises.deletedAt],
            )
        }
    }

    @Test
    fun put_path_and_body_id_mismatch_is_400() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val res = c.putSession(uid, newId(), sessionJson(id = newId()))
        assertEquals(HttpStatusCode.BadRequest, res.status)
        assertEquals("VALIDATION_FAILED", res.obj()["error"]!!.str("code"))
    }

    private suspend fun io.ktor.server.testing.ApplicationTestBuilder.expectField(
        uid: UUID, body: (String) -> String, field: String,
    ) {
        val sid = newId()
        val res = jsonClient().putSession(uid, sid, body(sid))
        assertEquals(HttpStatusCode.BadRequest, res.status, "expected 400 for $field")
        val err = res.obj()["error"]!!
        assertEquals("VALIDATION_FAILED", err.str("code"))
        assertEquals(field, err.str("field"))
    }

    @Test
    fun validation_errors_report_field_paths() = fitlogTest {
        startApplication()
        val uid = createUser()
        val bench = insertExercise(uid, "BARBELL")
        val pullup = insertExercise(null, "BODYWEIGHT")
        val run = insertExercise(uid, "CARDIO")
        val others = insertExercise(createUser(), "BARBELL")
        val deletedOwn = insertExercise(uid, "BARBELL").also { softDeleteExercise(it) }
        fun withSet(set: String, ex: UUID = bench) = { sid: String -> sessionJson(sid, exercises = listOf(exJson(exerciseId = ex, sets = listOf(setJson(extra = """"durationSec":60"""), set)))) }

        expectField(uid, { sessionJson(it, tz = "Mars/Base") }, "tz")
        expectField(uid, { sessionJson(it, startedAt = "2026-11-26T10:00:00Z", endedAt = "2026-11-26T09:00:00Z") }, "endedAt")
        expectField(uid, { sessionJson(it, exercises = listOf(exJson(exerciseId = UUID.randomUUID()))) }, "exercises[0].exerciseId")
        expectField(uid, { sessionJson(it, exercises = listOf(exJson(exerciseId = others))) }, "exercises[0].exerciseId")
        expectField(uid, { sessionJson(it, exercises = listOf(exJson(exerciseId = deletedOwn))) }, "exercises[0].exerciseId")
        expectField(uid, withSet(setJson(position = 1, reps = "-1")), "exercises[0].sets[1].reps")
        expectField(uid, withSet(setJson(position = 1, extra = """"rpe":7.3""")), "exercises[0].sets[1].rpe")
        expectField(uid, withSet(setJson(position = 1, extra = """"rpe":10.5""")), "exercises[0].sets[1].rpe")
        expectField(uid, withSet(setJson(position = 1, extra = """"rir":11""")), "exercises[0].sets[1].rir")
        expectField(uid, withSet(setJson(position = 1, extra = """"restSec":-5""")), "exercises[0].sets[1].restSec")
        expectField(uid, withSet(setJson(position = 1, extra = """"durationSec":-1""")), "exercises[0].sets[1].durationSec")
        // 유형별 필수 필드 (완료된 세트만)
        expectField(uid, withSet(setJson(position = 1, weightKg = null)), "exercises[0].sets[1].weightKg")
        expectField(uid, withSet(setJson(position = 1, reps = null)), "exercises[0].sets[1].reps")
        expectField(uid, withSet(setJson(position = 1, weightKg = null, reps = null), pullup), "exercises[0].sets[1].reps")
        expectField(uid, withSet(setJson(position = 1, weightKg = null, reps = null), run), "exercises[0].sets[1].durationSec")
    }

    @Test
    fun incomplete_sets_skip_required_field_check_and_other_types_pass() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val bench = insertExercise(uid, "BARBELL")
        val run = insertExercise(uid, "CARDIO")
        val sid = newId()
        val res = c.putSession(
            uid, sid,
            sessionJson(
                sid,
                exercises = listOf(
                    exJson(exerciseId = bench, position = 0, sets = listOf(setJson(weightKg = null, reps = null, completed = false))),
                    exJson(exerciseId = run, position = 1, sets = listOf(setJson(weightKg = null, reps = null, extra = """"durationSec":600,"distanceM":2000.04"""))),
                ),
            ),
        )
        assertEquals(HttpStatusCode.OK, res.status)
        assertEquals("2000.0", res.obj()["exercises"]!!.jsonArray[1].jsonPrimitiveSets()[0].str("distanceM"))
    }

    @Test
    fun other_users_cannot_read_write_or_delete_a_session() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val owner = createUser()
        val intruder = createUser()
        val ex = insertExercise(owner)
        val sid = newId()
        c.putSession(owner, sid, sessionJson(sid, exercises = listOf(exJson(exerciseId = ex, sets = listOf(setJson())))))

        assertEquals(HttpStatusCode.NotFound, c.getSession(intruder, sid).status)
        assertEquals(HttpStatusCode.NotFound, c.putSession(intruder, sid, sessionJson(sid)).status)
        assertEquals(HttpStatusCode.NotFound, c.deleteSession(intruder, sid).status)
        assertEquals(0, c.get("/v1/sessions") { auth(intruder) }.arr().size)
        // 원본은 그대로
        val got = c.getSession(owner, sid).obj()
        assertEquals(1, got["exercises"]!!.jsonArray.size)
    }

    @Test
    fun put_rejects_child_ids_that_belong_to_another_session() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val ex = insertExercise(uid)
        val s1 = newId()
        val se = newId()
        c.putSession(uid, s1, sessionJson(s1, exercises = listOf(exJson(se, ex))))
        val s2 = newId()
        val res = c.putSession(uid, s2, sessionJson(s2, exercises = listOf(exJson(se, ex))))
        assertEquals(HttpStatusCode.BadRequest, res.status)
        assertEquals("exercises[0].id", res.obj()["error"]!!.str("field"))
    }

    @Test
    fun list_summaries_compute_counts_and_volume_and_paginate() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val bench = insertExercise(uid, "BARBELL")
        val pullup = insertExercise(null, "BODYWEIGHT")
        val s1 = newId()
        val s2 = newId()
        val s3 = newId()
        c.putSession(uid, s1, sessionJson(s1, startedAt = "2026-11-24T10:00:00Z", endedAt = null))
        c.putSession(
            uid, s2,
            sessionJson(
                s2, startedAt = "2026-11-25T10:00:00Z",
                exercises = listOf(
                    exJson(exerciseId = bench, position = 0, sets = listOf(
                        setJson(position = 0, weightKg = "60", reps = "10", warmup = true),
                        setJson(position = 1, weightKg = "100", reps = "5"),
                        setJson(position = 2, weightKg = "102.5", reps = "3"),
                    )),
                    exJson(exerciseId = pullup, position = 1, sets = listOf(
                        setJson(position = 0, weightKg = null, reps = "10"),
                        setJson(position = 1, weightKg = null, reps = null, completed = false),
                    )),
                ),
            ),
        )
        c.putSession(uid, s3, sessionJson(s3, startedAt = "2026-11-26T10:00:00Z"))
        // 삭제된 세션은 목록에서 제외
        val gone = newId()
        c.putSession(uid, gone, sessionJson(gone, startedAt = "2026-11-27T10:00:00Z"))
        c.deleteSession(uid, gone)

        val all = c.get("/v1/sessions") { auth(uid) }.arr()
        assertEquals(listOf(s3, s2, s1), all.map { it.str("id") })
        val sum = all[1]
        assertEquals("2", sum.str("exerciseCount"))
        assertEquals("4", sum.str("setCount")) // 워밍업 제외: 100x5, 102.5x3, 풀업 2개
        assertEquals("807.5", sum.str("totalVolumeKg")) // 500 + 307.5
        assertEquals("0", all[2].str("exerciseCount"))
        assertEquals("0.0", all[2].str("totalVolumeKg"))

        val page = c.get("/v1/sessions?limit=1") { auth(uid) }.arr()
        assertEquals(1, page.size)
        val next = c.get("/v1/sessions?limit=1&before=${page[0].str("startedAt")}") { auth(uid) }.arr()
        assertEquals(s2, next[0].str("id"))
        val none = c.get("/v1/sessions?before=2026-11-24T10:00:00Z") { auth(uid) }.arr()
        assertEquals(0, none.size)
    }

    @Test
    fun list_rejects_out_of_range_limit() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        for (bad in listOf("0", "101", "-1", "abc")) {
            val res = c.get("/v1/sessions?limit=$bad") { auth(uid) }
            assertEquals(HttpStatusCode.BadRequest, res.status, "limit=$bad")
            assertEquals("limit", res.obj()["error"]!!.str("field"))
        }
        assertEquals(HttpStatusCode.OK, c.get("/v1/sessions?limit=100") { auth(uid) }.status)
        assertEquals(HttpStatusCode.BadRequest, c.get("/v1/sessions?before=yesterday") { auth(uid) }.status)
    }

    @Test
    fun delete_soft_deletes_session_children_and_is_idempotent() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val ex = insertExercise(uid)
        val sid = newId()
        val setId = newId()
        c.putSession(uid, sid, sessionJson(sid, exercises = listOf(exJson(exerciseId = ex, sets = listOf(setJson(setId))))))
        assertEquals(HttpStatusCode.NoContent, c.deleteSession(uid, sid).status)
        assertEquals(HttpStatusCode.NoContent, c.deleteSession(uid, sid).status)
        assertEquals(HttpStatusCode.NoContent, c.deleteSession(uid, newId()).status)
        assertEquals(HttpStatusCode.NotFound, c.getSession(uid, sid).status)
        transaction {
            assertNotNull(WorkoutSessions.selectAll().where { WorkoutSessions.id eq UUID.fromString(sid) }.single()[WorkoutSessions.deletedAt])
            assertNotNull(WorkoutSets.selectAll().where { WorkoutSets.id eq UUID.fromString(setId) }.single()[WorkoutSets.deletedAt])
        }
        // 삭제 뒤 같은 id 로 PUT 하면 되살아난다
        assertEquals(HttpStatusCode.OK, c.putSession(uid, sid, sessionJson(sid)).status)
        assertEquals(HttpStatusCode.OK, c.getSession(uid, sid).status)
    }

    @Test
    fun last_returns_sets_of_most_recent_live_session() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val ex = insertExercise(uid)
        val other = insertExercise(uid)
        assertEquals(HttpStatusCode.NotFound, c.get("/v1/exercises/$ex/last") { auth(uid) }.status)

        val old = newId()
        val recent = newId()
        val newest = newId()
        c.putSession(uid, old, sessionJson(old, startedAt = "2026-11-20T10:00:00Z", exercises = listOf(exJson(exerciseId = ex, sets = listOf(setJson(weightKg = "80"))))))
        c.putSession(uid, recent, sessionJson(recent, startedAt = "2026-11-22T10:00:00Z", exercises = listOf(
            exJson(exerciseId = other, sets = listOf(setJson(weightKg = "10"))),
            exJson(exerciseId = ex, position = 1, sets = listOf(setJson(position = 1, weightKg = "90"), setJson(position = 0, weightKg = "85"))),
        )))
        c.putSession(uid, newest, sessionJson(newest, startedAt = "2026-11-25T10:00:00Z", exercises = listOf(exJson(exerciseId = ex, sets = listOf(setJson(weightKg = "95"))))))
        c.deleteSession(uid, newest)

        val res = c.get("/v1/exercises/$ex/last") { auth(uid) }
        assertEquals(HttpStatusCode.OK, res.status)
        val body = res.obj()
        assertEquals(recent, body.str("sessionId"))
        assertEquals("2026-11-22T10:00:00Z", body.str("startedAt"))
        assertEquals(listOf("85.0", "90.0"), body["sets"]!!.jsonArray.map { it.str("weightKg") })

        // 다른 사용자에게는 보이지 않는다
        assertEquals(HttpStatusCode.NotFound, c.get("/v1/exercises/$ex/last") { auth(createUser()) }.status)
    }

    @Test
    fun unauthenticated_requests_are_401() = fitlogTest {
        startApplication()
        val c = jsonClient()
        assertEquals(HttpStatusCode.Unauthorized, c.get("/v1/sessions").status)
        assertEquals(HttpStatusCode.Unauthorized, c.get("/v1/sync/pull?since=0").status)
        assertEquals(HttpStatusCode.Unauthorized, c.get("/v1/body/measurements").status)
    }
}
