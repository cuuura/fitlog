package com.fitlog.deletion

import com.fitlog.core.BodyMeasurements
import com.fitlog.core.DeletionRequests
import com.fitlog.core.Exercises
import com.fitlog.core.Ids
import com.fitlog.core.ProgramInstances
import com.fitlog.core.Programs
import com.fitlog.core.Times
import com.fitlog.core.WorkoutSessions
import com.fitlog.export.SetSeed
import com.fitlog.export.insertBodyRow
import com.fitlog.export.insertInstanceRow
import com.fitlog.export.insertOwnExercise
import com.fitlog.export.insertProgramRow
import com.fitlog.export.insertSessionRow
import com.fitlog.session.arr
import com.fitlog.session.get
import com.fitlog.session.obj
import com.fitlog.session.str
import com.fitlog.support.auth
import com.fitlog.support.createUser
import com.fitlog.support.fitlogTest
import com.fitlog.support.jsonClient
import io.ktor.client.HttpClient
import io.ktor.client.request.get
import io.ktor.client.request.post
import io.ktor.http.HttpStatusCode
import org.jetbrains.exposed.sql.SqlExpressionBuilder.eq
import org.jetbrains.exposed.sql.insert
import org.jetbrains.exposed.sql.selectAll
import org.jetbrains.exposed.sql.transactions.transaction
import org.jetbrains.exposed.sql.update
import java.time.Instant
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class DeletionApiTest {
    private fun insertRequest(
        uid: UUID,
        entity: String,
        entityId: UUID,
        status: String = "PENDING",
        expiresAt: Instant = Times.now().plusSeconds(3600),
        createdAt: Instant = Times.now(),
    ): UUID {
        val rid = Ids.newId()
        transaction {
            DeletionRequests.insert {
                it[id] = rid
                it[userId] = uid
                it[clientName] = "Claude"
                it[DeletionRequests.entity] = entity
                it[DeletionRequests.entityId] = entityId
                it[label] = "대상"
                it[reason] = "중복"
                it[DeletionRequests.status] = status
                it[DeletionRequests.createdAt] = createdAt
                it[DeletionRequests.expiresAt] = expiresAt
            }
        }
        return rid
    }

    private suspend fun HttpClient.approve(uid: UUID, id: UUID) = post("/v1/deletion-requests/$id/approve") { auth(uid) }
    private suspend fun HttpClient.reject(uid: UUID, id: UUID) = post("/v1/deletion-requests/$id/reject") { auth(uid) }

    private fun status(id: UUID) = transaction { DeletionRequests.selectAll().where { DeletionRequests.id eq id }.single()[DeletionRequests.status] }

    @Test
    fun list_count_filter_and_expiry() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val other = createUser()
        val e = UUID.randomUUID()
        val p1 = insertRequest(uid, "exercise", e, createdAt = Times.now().minusSeconds(10))
        val p2 = insertRequest(uid, "body_measurement", e)
        val old = insertRequest(uid, "program", e, expiresAt = Times.now().minusSeconds(5), createdAt = Times.now().minusSeconds(20))
        insertRequest(uid, "program", e, status = "REJECTED")
        insertRequest(other, "program", e)

        assertEquals("2", c.get("/v1/deletion-requests/count") { auth(uid) }.obj().str("pending"))
        assertEquals("EXPIRED", status(old))
        val all = c.get("/v1/deletion-requests") { auth(uid) }.arr()
        assertEquals(4, all.size)
        val times = all.map { it.str("createdAt")!! }
        assertEquals(times.sortedDescending(), times) // 최신순
        assertEquals(old.toString(), all.last().str("id"))
        val pend = c.get("/v1/deletion-requests?status=PENDING") { auth(uid) }.arr()
        assertEquals(setOf(p1.toString(), p2.toString()), pend.map { it.str("id")!! }.toSet())
        val first = pend.first { it.str("id") == p1.toString() }
        assertEquals("exercise", first.str("entity")); assertEquals("Claude", first.str("clientName"))
        assertEquals("중복", first.str("reason")); assertNotNull(first.str("expiresAt")); assertNull(first.str("decidedAt"))
        assertEquals(1, c.get("/v1/deletion-requests?status=EXPIRED") { auth(uid) }.arr().size)
        assertEquals(HttpStatusCode.BadRequest, c.get("/v1/deletion-requests?status=NOPE") { auth(uid) }.status)
        assertEquals(HttpStatusCode.Unauthorized, c.get("/v1/deletion-requests").status)
    }

    @Test
    fun approve_session_soft_deletes_tree_and_unlinked_session_rows_stay_for_others() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val ex = insertOwnExercise(uid)
        val sid = insertSessionRow(uid, exercises = listOf(ex to listOf(SetSeed(), SetSeed())))
        val keep = insertSessionRow(uid, exercises = listOf(ex to listOf(SetSeed())))
        val rid = insertRequest(uid, "workout_session", sid)
        val before = transaction { WorkoutSessions.selectAll().where { WorkoutSessions.id eq sid }.single()[WorkoutSessions.serverSeq] }

        val res = c.approve(uid, rid)
        assertEquals(HttpStatusCode.OK, res.status)
        val b = res.obj()
        assertEquals("APPROVED", b.str("status")); assertNotNull(b.str("decidedAt")); assertNull(b.str("note"))
        transaction {
            val row = WorkoutSessions.selectAll().where { WorkoutSessions.id eq sid }.single()
            assertNotNull(row[WorkoutSessions.deletedAt])
            assertTrue(row[WorkoutSessions.serverSeq] > before)
            assertNull(WorkoutSessions.selectAll().where { WorkoutSessions.id eq keep }.single()[WorkoutSessions.deletedAt])
        }
        val sets = transaction {
            (com.fitlog.core.SessionExercises.join(com.fitlog.core.WorkoutSets, org.jetbrains.exposed.sql.JoinType.INNER,
                com.fitlog.core.SessionExercises.id, com.fitlog.core.WorkoutSets.sessionExerciseId))
                .selectAll().where { com.fitlog.core.SessionExercises.sessionId eq sid }
                .map { it[com.fitlog.core.WorkoutSets.deletedAt] }
        }
        assertEquals(2, sets.size); assertTrue(sets.all { it != null })
        // 화면에서도 사라진다
        assertEquals(HttpStatusCode.NotFound, c.get("/v1/sessions/$sid") { auth(uid) }.status)
    }

    @Test
    fun approve_program_exercise_and_body_soft_delete_and_template_is_refused() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val prog = insertProgramRow(uid)
        val ex = insertOwnExercise(uid)
        val body = insertBodyRow(uid, Instant.parse("2026-11-20T01:00:00Z"), "70")
        assertEquals("APPROVED", c.approve(uid, insertRequest(uid, "program", prog)).obj().str("status"))
        assertEquals("APPROVED", c.approve(uid, insertRequest(uid, "exercise", ex)).obj().str("status"))
        assertEquals("APPROVED", c.approve(uid, insertRequest(uid, "body_measurement", body)).obj().str("status"))
        transaction {
            assertNotNull(Programs.selectAll().where { Programs.id eq prog }.single()[Programs.deletedAt])
            assertNotNull(Exercises.selectAll().where { Exercises.id eq ex }.single()[Exercises.deletedAt])
            assertNotNull(BodyMeasurements.selectAll().where { BodyMeasurements.id eq body }.single()[BodyMeasurements.deletedAt])
        }
        // 템플릿·기본 종목은 거부하고 요청은 그대로 둔다
        val tmpl = transaction { Programs.selectAll().where { Programs.templateKey eq "stronglifts-5x5" }.first()[Programs.id] }
        val rt = insertRequest(uid, "program", tmpl)
        assertEquals(HttpStatusCode.Forbidden, c.approve(uid, rt).status)
        assertEquals("PENDING", status(rt))
        assertNull(transaction { Programs.selectAll().where { Programs.id eq tmpl }.single()[Programs.deletedAt] })
        val builtIn = transaction { Exercises.selectAll().where { Exercises.ownerId.isNull() }.first()[Exercises.id] }
        val rb = insertRequest(uid, "exercise", builtIn)
        assertEquals(HttpStatusCode.Forbidden, c.approve(uid, rb).status)
        assertNull(transaction { Exercises.selectAll().where { Exercises.id eq builtIn }.single()[Exercises.deletedAt] })
    }

    @Test
    fun approve_instance_hard_deletes_and_unlinks_sessions() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val prog = insertProgramRow(uid)
        val inst = insertInstanceRow(uid, prog)
        val ex = insertOwnExercise(uid)
        val sid = insertSessionRow(uid, instanceId = inst, planSeq = 0, exercises = listOf(ex to listOf(SetSeed())))
        val before = transaction { WorkoutSessions.selectAll().where { WorkoutSessions.id eq sid }.single()[WorkoutSessions.serverSeq] }
        val res = c.approve(uid, insertRequest(uid, "program_instance", inst))
        assertEquals("APPROVED", res.obj().str("status"))
        transaction {
            assertEquals(0L, ProgramInstances.selectAll().where { ProgramInstances.id eq inst }.count())
            val s = WorkoutSessions.selectAll().where { WorkoutSessions.id eq sid }.single()
            assertNull(s[WorkoutSessions.programInstanceId]); assertNull(s[WorkoutSessions.deletedAt])
            assertTrue(s[WorkoutSessions.serverSeq] > before)
        }
    }

    @Test
    fun approve_already_gone_target_closes_with_note_and_never_touches_others_data() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val other = createUser()
        // 존재하지 않는 id, 이미 삭제된 세션
        val r1 = c.approve(uid, insertRequest(uid, "exercise", UUID.randomUUID())).obj()
        assertEquals("APPROVED", r1.str("status")); assertEquals("already deleted", r1.str("note"))
        val ex = insertOwnExercise(uid)
        val sid = insertSessionRow(uid, exercises = listOf(ex to listOf(SetSeed())))
        transaction { WorkoutSessions.update({ WorkoutSessions.id eq sid }) { it[deletedAt] = Times.now() } }
        assertEquals("already deleted", c.approve(uid, insertRequest(uid, "workout_session", sid)).obj().str("note"))
        // 남의 대상은 지우지 않고 already deleted 로 닫는다
        val foreign = insertSessionRow(other, exercises = listOf(ex to listOf(SetSeed())))
        assertEquals("already deleted", c.approve(uid, insertRequest(uid, "workout_session", foreign)).obj().str("note"))
        assertNull(transaction { WorkoutSessions.selectAll().where { WorkoutSessions.id eq foreign }.single()[WorkoutSessions.deletedAt] })
    }

    @Test
    fun reject_decided_expired_and_foreign_requests() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val other = createUser()
        val ex = insertOwnExercise(uid)
        val rid = insertRequest(uid, "exercise", ex)
        val rej = c.reject(uid, rid)
        assertEquals(HttpStatusCode.OK, rej.status)
        assertEquals("REJECTED", rej.obj().str("status")); assertNotNull(rej.obj().str("decidedAt"))
        assertNull(transaction { Exercises.selectAll().where { Exercises.id eq ex }.single()[Exercises.deletedAt] })
        // 이미 결정됨 409
        assertEquals(HttpStatusCode.Conflict, c.approve(uid, rid).status)
        assertEquals(HttpStatusCode.Conflict, c.reject(uid, rid).status)
        val done = insertRequest(uid, "exercise", ex, status = "APPROVED")
        val conflict = c.approve(uid, done)
        assertEquals(HttpStatusCode.Conflict, conflict.status)
        assertEquals("CONFLICT", conflict.obj()["error"]!!.str("code"))
        // 만료 410(v0.1 에러 형식)
        val old = insertRequest(uid, "exercise", ex, expiresAt = Times.now().minusSeconds(1))
        val gone = c.approve(uid, old)
        assertEquals(HttpStatusCode.Gone, gone.status)
        assertEquals("GONE", gone.obj()["error"]!!.str("code"))
        assertTrue(gone.obj()["error"]!!.str("message")!!.isNotEmpty())
        assertEquals("EXPIRED", status(old))
        assertEquals(HttpStatusCode.Gone, c.reject(uid, old).status)
        assertNull(transaction { Exercises.selectAll().where { Exercises.id eq ex }.single()[Exercises.deletedAt] })
        // 남의 요청 404, 없는 요청 404
        val foreign = insertRequest(other, "exercise", ex)
        assertEquals(HttpStatusCode.NotFound, c.approve(uid, foreign).status)
        assertEquals(HttpStatusCode.NotFound, c.reject(uid, foreign).status)
        assertEquals(HttpStatusCode.NotFound, c.approve(uid, UUID.randomUUID()).status)
        assertEquals("PENDING", status(foreign))
        assertEquals(HttpStatusCode.Unauthorized, c.post("/v1/deletion-requests/$rid/approve").status)
    }
}
