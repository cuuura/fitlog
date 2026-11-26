package com.fitlog.program.instance

import com.fitlog.core.WorkoutSessions
import com.fitlog.session.change
import com.fitlog.session.deleteSession
import com.fitlog.session.getSession
import com.fitlog.session.insertExercise
import com.fitlog.session.newId
import com.fitlog.session.pull
import com.fitlog.session.push
import com.fitlog.session.putSession
import com.fitlog.session.str
import com.fitlog.support.createUser
import com.fitlog.support.jsonClient
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
import kotlin.test.assertNull
import kotlin.test.assertTrue

class SessionLinkTest {
    private class World(val uid: UUID, val squat: UUID, val bench: UUID, val programId: UUID)

    private fun world(): World {
        val uid = createUser()
        val squat = insertExercise(null, "BARBELL")
        val bench = insertExercise(uid, "DUMBBELL")
        return World(uid, squat, bench, insertProgram(uid, testDefinition(squat, bench)))
    }

    private fun errOf(r: JsonObject) = r["error"]!!.jsonObject

    private fun results(r: JsonObject) = r["results"]!!.jsonArray.map { it.jsonObject }

    @Test
    fun rest_put_and_delete_replay_the_instance() = fakeTest {
        startApplication()
        val c = jsonClient()
        val w = world()
        val id = newId()
        c.startInstance(w.uid, id, w.programId)
        val s1 = newId()

        val put = c.putSession(w.uid, s1, linkedSessionJson(s1, id, 1, w.squat))
        assertEquals(HttpStatusCode.OK, put.status)
        val saved = put.objOf()
        assertEquals(id, saved.str("programInstanceId"))
        assertEquals("1", saved.str("planSeq"))
        assertEquals("A", saved.str("planDayKey"))
        var inst = c.getInstance(w.uid, id).objOf()
        assertEquals(1, inst.seq())
        assertEquals(102.5, inst.workingOf("squat"))
        assertEquals("B", inst.nextDay())

        // 지난 세션의 세트를 고치면(5 -> 3회) 이후 계획이 다시 계산된다
        c.putSession(w.uid, s1, linkedSessionJson(s1, id, 1, w.squat, reps = 3))
        inst = c.getInstance(w.uid, id).objOf()
        assertEquals(1, inst.seq())
        assertEquals(100.0, inst.workingOf("squat"))
        // 세트를 하나 빼도(모두 5회) 다시 계산
        c.putSession(w.uid, s1, linkedSessionJson(s1, id, 1, w.squat, reps = 5, sets = 1))
        assertEquals(102.5, c.getInstance(w.uid, id).objOf().workingOf("squat"))

        // 세션 삭제 -> 처음 상태
        assertEquals(HttpStatusCode.NoContent, c.deleteSession(w.uid, s1).status)
        inst = c.getInstance(w.uid, id).objOf()
        assertEquals(0, inst.seq())
        assertEquals(100.0, inst.workingOf("squat"))
        assertEquals(1, inst.nextSeq())
        // 저장된 캐시도 맞다
        transaction {
            val row = com.fitlog.core.ProgramInstances.selectAll().where { com.fitlog.core.ProgramInstances.id eq UUID.fromString(id) }.single()
            assertEquals(0, row[com.fitlog.core.ProgramInstances.stateSeq])
        }
    }

    @Test
    fun unfinished_session_is_not_an_event_until_it_ends() = fakeTest {
        startApplication()
        val c = jsonClient()
        val w = world()
        val id = newId()
        c.startInstance(w.uid, id, w.programId)
        val s1 = newId()
        c.putSession(w.uid, s1, linkedSessionJson(s1, id, 1, w.squat, ended = false))
        assertEquals(0, c.getInstance(w.uid, id).objOf().seq())
        c.putSession(w.uid, s1, linkedSessionJson(s1, id, 1, w.squat, ended = true))
        assertEquals(1, c.getInstance(w.uid, id).objOf().seq())
    }

    @Test
    fun out_of_order_sessions_are_replayed_in_plan_seq_order() = fakeTest {
        startApplication()
        val c = jsonClient()
        val w = world()
        val id = newId()
        c.startInstance(w.uid, id, w.programId)
        val s2 = newId()
        val s1 = newId()
        c.putSession(w.uid, s2, linkedSessionJson(s2, id, 2, w.squat, startedAt = "2026-11-04T01:00:00Z"))
        c.putSession(w.uid, s1, linkedSessionJson(s1, id, 1, w.squat, startedAt = "2026-11-02T01:00:00Z"))
        val inst = c.getInstance(w.uid, id).objOf()
        assertEquals(2, inst.seq())
        assertEquals(105.0, inst.workingOf("squat"))
    }

    @Test
    fun moving_a_session_replays_both_old_and_new_instance() = fakeTest {
        startApplication()
        val c = jsonClient()
        val w = world()
        val a = newId()
        val b = newId()
        c.startInstance(w.uid, a, w.programId)
        c.startInstance(w.uid, b, w.programId)
        val s = newId()
        c.putSession(w.uid, s, linkedSessionJson(s, a, 1, w.squat))
        assertEquals(1, c.getInstance(w.uid, a).objOf().seq())
        assertEquals(0, c.getInstance(w.uid, b).objOf().seq())

        c.putSession(w.uid, s, linkedSessionJson(s, b, 1, w.squat))
        assertEquals(0, c.getInstance(w.uid, a).objOf().seq())
        assertEquals(100.0, c.getInstance(w.uid, a).objOf().workingOf("squat"))
        assertEquals(1, c.getInstance(w.uid, b).objOf().seq())
        assertEquals(102.5, c.getInstance(w.uid, b).objOf().workingOf("squat"))

        // 연결을 끊어도 이전 인스턴스가 다시 계산된다
        c.putSession(w.uid, s, linkedSessionJson(s, null, null, w.squat))
        assertEquals(0, c.getInstance(w.uid, b).objOf().seq())
        assertNull(c.getSession(w.uid, s).objOf()["programInstanceId"])
    }

    @Test
    fun programs_do_not_mix_state() = fakeTest {
        startApplication()
        val c = jsonClient()
        val w = world()
        val a = newId()
        val b = newId()
        c.startInstance(w.uid, a, w.programId)
        c.startInstance(w.uid, b, w.programId)
        val s = newId()
        c.putSession(w.uid, s, linkedSessionJson(s, a, 1, w.squat))
        assertEquals(102.5, c.getInstance(w.uid, a).objOf().workingOf("squat"))
        assertEquals(100.0, c.getInstance(w.uid, b).objOf().workingOf("squat"))
    }

    @Test
    fun link_validation_and_unique_plan_seq_on_rest() = fakeTest {
        startApplication()
        val c = jsonClient()
        val w = world()
        val other = world()
        val mine = newId()
        val theirs = newId()
        c.startInstance(w.uid, mine, w.programId)
        c.startInstance(other.uid, theirs, other.programId)

        val s = newId()
        val foreign = c.putSession(w.uid, s, linkedSessionJson(s, theirs, 1, w.squat))
        assertEquals(HttpStatusCode.BadRequest, foreign.status)
        assertEquals("programInstanceId", errOf(foreign.objOf()).str("field"))
        val unknown = c.putSession(w.uid, s, linkedSessionJson(s, newId(), 1, w.squat))
        assertEquals(HttpStatusCode.BadRequest, unknown.status)
        val zero = c.putSession(w.uid, s, linkedSessionJson(s, mine, 0, w.squat))
        assertEquals(HttpStatusCode.BadRequest, zero.status)
        assertEquals("planSeq", errOf(zero.objOf()).str("field"))
        assertEquals(HttpStatusCode.NotFound, c.getSession(w.uid, s).status) // 아무것도 저장되지 않음

        // 같은 (인스턴스, planSeq) 두 번째 세션은 409
        val first = newId()
        assertEquals(HttpStatusCode.OK, c.putSession(w.uid, first, linkedSessionJson(first, mine, 1, w.squat)).status)
        val second = newId()
        val dup = c.putSession(w.uid, second, linkedSessionJson(second, mine, 1, w.squat))
        assertEquals(HttpStatusCode.Conflict, dup.status)
        assertEquals("CONFLICT", errOf(dup.objOf()).str("code"))
        assertEquals(HttpStatusCode.NotFound, c.getSession(w.uid, second).status)
        // 같은 세션을 다시 PUT 은 문제없고, 첫 세션을 지우면 두 번째가 들어간다
        assertEquals(HttpStatusCode.OK, c.putSession(w.uid, first, linkedSessionJson(first, mine, 1, w.squat)).status)
        c.deleteSession(w.uid, first)
        assertEquals(HttpStatusCode.OK, c.putSession(w.uid, second, linkedSessionJson(second, mine, 1, w.squat)).status)
        assertEquals(1, c.getInstance(w.uid, mine).objOf().seq())
    }

    @Test
    fun get_session_returns_plan_link_fields() = fakeTest {
        startApplication()
        val c = jsonClient()
        val w = world()
        val id = newId()
        c.startInstance(w.uid, id, w.programId)
        val s = newId()
        c.putSession(w.uid, s, linkedSessionJson(s, id, 1, w.squat, setIds = listOf(newId())))
        val got = c.getSession(w.uid, s).objOf()
        val ex = got["exercises"]!!.jsonArray[0].jsonObject
        assertEquals("squat", ex.str("liftKey"))
        assertEquals("false", ex.str("accessory"))
        val set = ex["sets"]!!.jsonArray[0].jsonObject
        assertEquals("A.0.0", set.str("plannedSetKey"))
        assertEquals("5", set.str("targetReps"))
        assertEquals("100.0", set.str("targetWeightKg"))
        assertEquals("false", set.str("isAmrap"))
        // 연결 없는 일반 세션은 필드가 없다
        val plain = newId()
        c.putSession(w.uid, plain, linkedSessionJson(plain, null, null, w.squat))
        assertNull(c.getSession(w.uid, plain).objOf()["planSeq"])
    }

    // ---- sync ----

    private fun sessionPayload(instanceId: String?, planSeq: Int?, ended: Boolean = true, dayKey: String = "A", startedAt: String = "2026-11-02T01:00:00Z"): String {
        val link = buildString {
            if (instanceId != null) append(""","programInstanceId":"$instanceId"""")
            if (planSeq != null) append(""","planSeq":$planSeq,"planDayKey":"$dayKey"""")
            if (ended) append(""","endedAt":"${java.time.Instant.parse(startedAt).plusSeconds(3600)}"""")
        }
        return """{"startedAt":"$startedAt","tz":"Asia/Seoul"$link}"""
    }

    private fun sePayload(exerciseId: UUID, liftKey: String? = "squat") =
        """{"exerciseId":"$exerciseId","position":0${if (liftKey != null) ""","liftKey":"$liftKey","accessory":false""" else ""}}"""

    private fun setPayload(i: Int, reps: Int) =
        """{"position":$i,"weightKg":100,"reps":$reps,"completedAt":"2026-11-02T01:10:00Z","plannedSetKey":"A.0.$i","targetReps":5,"targetWeightKg":100,"isAmrap":false}"""

    private fun at(n: Int) = "2026-11-02T03:00:%02dZ".format(n)

    @Test
    fun push_replays_each_affected_instance_once_after_all_changes() {
        val fake = FakeCalculator()
        fakeTest(fake) {
            startApplication()
            val c = jsonClient()
            val w = world()
            val id = newId()
            c.startInstance(w.uid, id, w.programId)
            val sid = newId()
            val se = newId()
            val set0 = newId()
            val set1 = newId()
            fake.replayCalls.set(0)
            val res = c.push(
                w.uid,
                change("workout_session", sid, at = at(1), payload = sessionPayload(id, 1)),
                change("session_exercise", se, at = at(2), parentId = sid, payload = sePayload(w.squat)),
                change("workout_set", set0, at = at(3), parentId = se, payload = setPayload(0, 5)),
                change("workout_set", set1, at = at(4), parentId = se, payload = setPayload(1, 5)),
            )
            assertEquals(listOf("applied", "applied", "applied", "applied"), results(res.objOf()).map { it.str("status") })
            assertEquals(1, fake.replayCalls.get())
            var inst = c.getInstance(w.uid, id).objOf()
            assertEquals(1, inst.seq())
            assertEquals(102.5, inst.workingOf("squat"))

            // 세트 하나만 바뀌어도(5 -> 3회) 재계산된다
            fake.replayCalls.set(0)
            val edit = c.push(w.uid, change("workout_set", set1, at = at(10), parentId = se, payload = setPayload(1, 3)))
            assertEquals("applied", results(edit.objOf())[0].str("status"))
            assertEquals(1, fake.replayCalls.get())
            inst = c.getInstance(w.uid, id).objOf()
            assertEquals(100.0, inst.workingOf("squat"))

            // 세트 삭제(나머지 세트는 5회) -> 다시 +2.5
            val del = c.push(w.uid, change("workout_set", set1, op = "DELETE", at = at(20), parentId = se))
            assertEquals("applied", results(del.objOf())[0].str("status"))
            assertEquals(102.5, c.getInstance(w.uid, id).objOf().workingOf("squat"))

            // 세션 삭제 -> 처음 상태
            val delS = c.push(w.uid, change("workout_session", sid, op = "DELETE", at = at(30)))
            assertEquals("applied", results(delS.objOf())[0].str("status"))
            assertEquals(0, c.getInstance(w.uid, id).objOf().seq())
        }
    }

    @Test
    fun push_touching_two_instances_replays_each_once_and_unlinked_sessions_do_not_replay() {
        val fake = FakeCalculator()
        fakeTest(fake) {
            startApplication()
            val c = jsonClient()
            val w = world()
            val a = newId()
            val b = newId()
            c.startInstance(w.uid, a, w.programId)
            c.startInstance(w.uid, b, w.programId)
            fake.replayCalls.set(0)
            val s1 = newId()
            val s2 = newId()
            val s3 = newId()
            c.push(
                w.uid,
                change("workout_session", s1, at = at(1), payload = sessionPayload(a, 1)),
                change("workout_session", s2, at = at(2), payload = sessionPayload(b, 1)),
                change("workout_session", s3, at = at(3), payload = sessionPayload(a, 2)),
            )
            assertEquals(2, fake.replayCalls.get())
            fake.replayCalls.set(0)
            c.push(w.uid, change("workout_session", newId(), at = at(5), payload = sessionPayload(null, null)))
            assertEquals(0, fake.replayCalls.get())
            // 세션 이동(a -> b 의 다른 회차): 이전·새 인스턴스 모두
            fake.replayCalls.set(0)
            c.push(w.uid, change("workout_session", s3, at = at(9), payload = sessionPayload(b, 2)))
            assertEquals(2, fake.replayCalls.get())
            assertEquals(1, c.getInstance(w.uid, a).objOf().seq())
            assertEquals(2, c.getInstance(w.uid, b).objOf().seq())
        }
    }

    @Test
    fun push_rejects_foreign_instance_and_duplicate_plan_seq() = fakeTest {
        startApplication()
        val c = jsonClient()
        val w = world()
        val other = world()
        val mine = newId()
        val theirs = newId()
        c.startInstance(w.uid, mine, w.programId)
        c.startInstance(other.uid, theirs, other.programId)

        val bad = newId()
        val r1 = c.push(w.uid, change("workout_session", bad, at = at(1), payload = sessionPayload(theirs, 1))).objOf()
        assertEquals("rejected", results(r1)[0].str("status"))
        assertEquals("VALIDATION_FAILED", results(r1)[0].str("code"))
        assertEquals(HttpStatusCode.NotFound, c.getSession(w.uid, bad).status)

        val first = newId()
        val second = newId()
        val r2 = c.push(
            w.uid,
            change("workout_session", first, at = at(2), payload = sessionPayload(mine, 1)),
            change("workout_session", second, at = at(3), payload = sessionPayload(mine, 1, startedAt = "2026-11-03T01:00:00Z")),
        ).objOf()
        assertEquals(listOf("applied", "rejected"), results(r2).map { it.str("status") })
        assertEquals("CONFLICT", results(r2)[1].str("code"))
        assertEquals(1, c.getInstance(w.uid, mine).objOf().seq())
        // 같은 push 에서 첫 세션을 지우고 둘째를 넣으면 통과
        val r3 = c.push(
            w.uid,
            change("workout_session", first, op = "DELETE", at = at(20)),
            change("workout_session", second, at = at(21), payload = sessionPayload(mine, 1, startedAt = "2026-11-03T01:00:00Z")),
        ).objOf()
        assertEquals(listOf("applied", "applied"), results(r3).map { it.str("status") })
        transaction {
            val row = WorkoutSessions.selectAll().where { WorkoutSessions.id eq UUID.fromString(second) }.single()
            assertEquals(1, row[WorkoutSessions.planSeq])
        }
    }

    @Test
    fun pull_payloads_carry_plan_fields() = fakeTest {
        startApplication()
        val c = jsonClient()
        val w = world()
        val id = newId()
        c.startInstance(w.uid, id, w.programId)
        val sid = newId()
        val se = newId()
        val set0 = newId()
        c.push(
            w.uid,
            change("workout_session", sid, at = at(1), payload = sessionPayload(id, 1)),
            change("session_exercise", se, at = at(2), parentId = sid, payload = sePayload(w.squat)),
            change("workout_set", set0, at = at(3), parentId = se, payload = setPayload(0, 5)),
        )
        val pulled = c.pull(w.uid, 0).objOf()["changes"]!!.jsonArray.map { it.jsonObject }.associateBy { it.str("id") }
        val sp = pulled.getValue(sid)["payload"]!!.jsonObject
        assertEquals(id, sp.str("programInstanceId"))
        assertEquals("1", sp.str("planSeq"))
        assertEquals("A", sp.str("planDayKey"))
        val ep = pulled.getValue(se)["payload"]!!.jsonObject
        assertEquals("squat", ep.str("liftKey"))
        assertEquals("false", ep.str("accessory"))
        val tp = pulled.getValue(set0)["payload"]!!.jsonObject
        assertEquals("A.0.0", tp.str("plannedSetKey"))
        assertEquals("5", tp.str("targetReps"))
        assertEquals("100.0", tp.str("targetWeightKg"))
        assertEquals("false", tp.str("isAmrap"))

        // REST 로 만든 연결 세션도 같은 payload 로 나온다
        val sid2 = newId()
        c.putSession(w.uid, sid2, linkedSessionJson(sid2, id, 2, w.squat, startedAt = "2026-11-04T01:00:00Z"))
        val again = c.pull(w.uid, 0).objOf()["changes"]!!.jsonArray.map { it.jsonObject }.first { it.str("id") == sid2 }
        assertEquals("2", again["payload"]!!.jsonObject.str("planSeq"))
    }

    @Test
    fun deleting_instance_changes_session_in_pull() = fakeTest {
        startApplication()
        val c = jsonClient()
        val w = world()
        val id = newId()
        c.startInstance(w.uid, id, w.programId)
        val sid = newId()
        c.putSession(w.uid, sid, linkedSessionJson(sid, id, 1, w.squat))
        val before = c.pull(w.uid, 0).objOf()
        val next = before["nextSince"]!!.jsonPrimitive.content.toLong()
        c.deleteInstance(w.uid, id)
        val after = c.pull(w.uid, next).objOf()["changes"]!!.jsonArray.map { it.jsonObject }
        val ses = after.first { it.str("id") == sid }
        assertTrue(ses["payload"]!!.jsonObject["programInstanceId"] == null)
    }
}
