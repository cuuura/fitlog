package com.fitlog.program.instance

import com.fitlog.core.ProgramAdjustments
import com.fitlog.core.ProgramInstances
import com.fitlog.core.ProgramSkips
import com.fitlog.core.WorkoutSessions
import com.fitlog.engine.E1rmFormula
import com.fitlog.session.deleteSession
import com.fitlog.session.getSession
import com.fitlog.session.insertExercise
import com.fitlog.session.newId
import com.fitlog.session.putSession
import com.fitlog.session.str
import com.fitlog.support.auth
import com.fitlog.support.createUser
import com.fitlog.support.jsonBody
import com.fitlog.support.jsonClient
import io.ktor.client.request.get
import io.ktor.client.request.put
import io.ktor.client.request.setBody
import io.ktor.http.HttpStatusCode
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.jetbrains.exposed.sql.SqlExpressionBuilder.eq
import org.jetbrains.exposed.sql.selectAll
import org.jetbrains.exposed.sql.update
import org.jetbrains.exposed.sql.transactions.transaction
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class InstanceApiTest {
    private class World(val uid: UUID, val squat: UUID, val bench: UUID, val programId: UUID)

    private fun world(withWeekdays: Boolean = true): World {
        val uid = createUser()
        val squat = insertExercise(null, "BARBELL")
        val bench = insertExercise(uid, "DUMBBELL")
        return World(uid, squat, bench, insertProgram(uid, testDefinition(squat, bench, withWeekdays)))
    }

    private fun errField(r: kotlinx.serialization.json.JsonObject) = r["error"]!!.jsonObject.str("field")

    @Test
    fun start_validates_required_inputs_and_returns_instance_with_next() = fakeTest {
        startApplication()
        val c = jsonClient()
        val w = world()

        val noTm = c.startInstance(w.uid, newId(), w.programId, tm = "{}")
        assertEquals(HttpStatusCode.BadRequest, noTm.status)
        assertEquals("tm.bench", errField(noTm.objOf()))
        val noWorking = c.startInstance(w.uid, newId(), w.programId, working = "{}")
        assertEquals(HttpStatusCode.BadRequest, noWorking.status)
        assertEquals("working.squat", errField(noWorking.objOf()))

        val id = newId()
        val res = c.startInstance(w.uid, id, w.programId)
        assertEquals(HttpStatusCode.Created, res.status)
        val inst = res.objOf()
        assertEquals(id, inst.str("id"))
        assertEquals("ACTIVE", inst.str("status"))
        assertEquals("SHIFT", inst.str("skipPolicy"))
        assertEquals("2026-11-02", inst.str("startDate"))
        assertEquals("Fake Program", inst.str("name"))
        assertEquals(0, inst.seq())
        assertEquals(100.0, inst.workingOf("squat"))
        assertEquals(1, inst.nextSeq())
        assertEquals("A", inst.nextDay())
        assertTrue(inst["next"]!!.jsonObject["confirmed"]!!.jsonPrimitive.content.toBoolean())
        assertNull(inst["next"]!!.jsonObject["scheduledDate"])

        // 저장: 스냅샷·initial_state·state_seq
        transaction {
            val row = ProgramInstances.selectAll().where { ProgramInstances.id eq UUID.fromString(id) }.single()
            assertEquals(0, row[ProgramInstances.stateSeq])
            assertTrue(row[ProgramInstances.definition].contains("Fake Program"))
            assertTrue(row[ProgramInstances.initialState].contains("squat"))
        }
    }

    @Test
    fun start_is_idempotent_and_rejects_bad_input() = fakeTest {
        startApplication()
        val c = jsonClient()
        val w = world()
        val id = newId()
        assertEquals(HttpStatusCode.Created, c.startInstance(w.uid, id, w.programId).status)
        val again = c.startInstance(w.uid, id, w.programId)
        assertEquals(HttpStatusCode.Created, again.status)
        assertEquals(id, again.objOf().str("id"))
        assertEquals(1, c.get("/v1/program-instances") { auth(w.uid) }.arrOf().size)

        // 다른 사용자가 같은 id 로 시작 -> 409
        val other = createUser()
        val template = insertProgram(null, testDefinition(w.squat, insertExercise(null, "DUMBBELL")))
        assertEquals(HttpStatusCode.Conflict, c.startInstance(other, id, template).status)

        // 템플릿(owner=null)은 누구나 시작 가능, 남의 프로그램은 400
        assertEquals(HttpStatusCode.Created, c.startInstance(other, newId(), template).status)
        val bad = c.startInstance(other, newId(), w.programId)
        assertEquals(HttpStatusCode.BadRequest, bad.status)
        assertEquals("programId", errField(bad.objOf()))

        assertEquals("tz", errField(c.startInstance(w.uid, newId(), w.programId, tz = "Mars/Base").objOf()))
        assertEquals("startDate", errField(c.startInstance(w.uid, newId(), w.programId, startDate = "11/02/2026").objOf()))
        assertEquals("skipPolicy", errField(c.startInstance(w.uid, newId(), w.programId, skipPolicy = "WEEKLY").objOf()))
        // 삭제된 프로그램
        transaction {
            com.fitlog.core.Programs.update({ com.fitlog.core.Programs.id eq w.programId }) { it[deletedAt] = com.fitlog.core.Times.now() }
        }
        assertEquals("programId", errField(c.startInstance(w.uid, newId(), w.programId).objOf()))
    }

    @Test
    fun fixed_date_requires_weekday_on_every_day() = fakeTest {
        startApplication()
        val c = jsonClient()
        val w = world(withWeekdays = false)
        val res = c.startInstance(w.uid, newId(), w.programId, skipPolicy = "FIXED_DATE")
        assertEquals(HttpStatusCode.BadRequest, res.status)
        assertEquals("skipPolicy", errField(res.objOf()))
        val id = newId()
        assertEquals(HttpStatusCode.Created, c.startInstance(w.uid, id, w.programId).status)
        val p = c.patchInstance(w.uid, id, """{"skipPolicy":"FIXED_DATE"}""")
        assertEquals(HttpStatusCode.BadRequest, p.status)
    }

    @Test
    fun get_list_filter_and_ownership() = fakeTest {
        startApplication()
        val c = jsonClient()
        val w = world()
        val a = newId()
        val b = newId()
        c.startInstance(w.uid, a, w.programId)
        c.startInstance(w.uid, b, w.programId)
        assertEquals(HttpStatusCode.OK, c.patchInstance(w.uid, b, """{"status":"PAUSED"}""").status)

        val all = c.get("/v1/program-instances") { auth(w.uid) }.arrOf()
        assertEquals(setOf(a, b), all.map { it.str("id")!! }.toSet())
        val paused = c.get("/v1/program-instances?status=PAUSED") { auth(w.uid) }.arrOf()
        assertEquals(listOf(b), paused.map { it.str("id") })
        val active = c.get("/v1/program-instances?status=ACTIVE") { auth(w.uid) }.arrOf()
        assertEquals(listOf(a), active.map { it.str("id") })
        assertEquals(HttpStatusCode.BadRequest, c.get("/v1/program-instances?status=NOPE") { auth(w.uid) }.status)

        val other = createUser()
        assertEquals(HttpStatusCode.NotFound, c.getInstance(other, a).status)
        assertEquals(HttpStatusCode.NotFound, c.patchInstance(other, a, """{"status":"PAUSED"}""").status)
        assertEquals(HttpStatusCode.NotFound, c.planOf(other, a).status)
        assertEquals(HttpStatusCode.NotFound, c.skipInstance(other, a, 1).status)
        assertEquals(HttpStatusCode.NotFound, c.deleteInstance(other, a).status)
        assertEquals(0, c.get("/v1/program-instances") { auth(other) }.arrOf().size)
        assertEquals(HttpStatusCode.OK, c.getInstance(w.uid, a).status)
        assertEquals(HttpStatusCode.BadRequest, c.patchInstance(w.uid, a, """{"status":"DONE"}""").status)
    }

    @Test
    fun patch_adjust_records_event_and_changes_state() = fakeTest {
        startApplication()
        val c = jsonClient()
        val w = world()
        val id = newId()
        c.startInstance(w.uid, id, w.programId)
        val res = c.patchInstance(w.uid, id, """{"adjust":{"tm":{"bench":90},"working":{"squat":120.5}}}""")
        assertEquals(HttpStatusCode.OK, res.status)
        val inst = res.objOf()
        assertEquals(120.5, inst.workingOf("squat"))
        assertEquals(90.0, inst["state"]!!.jsonObject["tm"]!!.jsonObject["bench"]!!.jsonPrimitive.content.toDouble())
        transaction {
            val adj = ProgramAdjustments.selectAll().where { ProgramAdjustments.instanceId eq UUID.fromString(id) }.single()
            assertEquals(0, adj[ProgramAdjustments.afterSeq])
        }
        // 알 수 없는 키·빈 조정
        val unknown = c.patchInstance(w.uid, id, """{"adjust":{"working":{"deadlift":100}}}""")
        assertEquals(HttpStatusCode.BadRequest, unknown.status)
        assertEquals("adjust.working.deadlift", errField(unknown.objOf()))
        assertEquals(HttpStatusCode.BadRequest, c.patchInstance(w.uid, id, """{"adjust":{}}""").status)
        assertEquals(HttpStatusCode.OK, c.patchInstance(w.uid, id, """{"status":"FINISHED"}""").status)
        assertEquals("FINISHED", c.getInstance(w.uid, id).objOf().str("status"))
    }

    @Test
    fun adjustment_is_placed_after_its_seq_when_history_changes() = fakeTest {
        startApplication()
        val c = jsonClient()
        val w = world()
        val id = newId()
        c.startInstance(w.uid, id, w.programId)
        val s1 = newId()
        assertEquals(HttpStatusCode.OK, c.putSession(w.uid, s1, linkedSessionJson(s1, id, 1, w.squat)).status)
        assertEquals(102.5, c.getInstance(w.uid, id).objOf().workingOf("squat"))
        // seq 1 뒤에 조정
        c.patchInstance(w.uid, id, """{"adjust":{"working":{"squat":200}}}""")
        transaction {
            assertEquals(1, ProgramAdjustments.selectAll().where { ProgramAdjustments.instanceId eq UUID.fromString(id) }.single()[ProgramAdjustments.afterSeq])
        }
        val s2 = newId()
        c.putSession(w.uid, s2, linkedSessionJson(s2, id, 2, w.bench, liftKey = "bench", dayKey = "B", startedAt = "2026-11-05T01:00:00Z", sets = 1))
        val afterSecond = c.getInstance(w.uid, id).objOf()
        assertEquals(200.0, afterSecond.workingOf("squat"))
        assertEquals(2, afterSecond.seq())
        // 1회차를 실패로 고치면: 100 으로 시작해 조정(200)이 1회차 뒤에 적용되므로 여전히 200
        c.putSession(w.uid, s1, linkedSessionJson(s1, id, 1, w.squat, reps = 3))
        assertEquals(200.0, c.getInstance(w.uid, id).objOf().workingOf("squat"))
    }

    @Test
    fun plan_count_bounds_confirmed_and_accessories() = fakeTest {
        startApplication()
        val c = jsonClient()
        val w = world()
        val id = newId()
        c.startInstance(w.uid, id, w.programId)

        val three = c.planOf(w.uid, id).arrOf()
        assertEquals(3, three.size)
        assertEquals(listOf(1, 2, 3), three.map { it.jsonObject["planSeq"]!!.jsonPrimitive.content.toInt() })
        assertEquals(listOf("A", "B", "A"), three.map { it.str("dayKey") })
        assertEquals(id, three[0].str("instanceId"))
        assertEquals(listOf(true, false, false), three.map { it.jsonObject["confirmed"]!!.jsonPrimitive.content.toBoolean() })
        assertNull(three[0].jsonObject["scheduledDate"])
        val squatSets = three[0].jsonObject["exercises"]!!.jsonArray[0].jsonObject["sets"]!!.jsonArray
        assertEquals(listOf("A.0.0", "A.0.1"), squatSets.map { it.str("plannedSetKey") })
        assertEquals(100.0, squatSets[0].jsonObject["targetWeightKg"]!!.jsonPrimitive.content.toDouble())
        assertEquals(72.0, three[1].jsonObject["exercises"]!!.jsonArray[0].jsonObject["sets"]!!.jsonArray[0].jsonObject["targetWeightKg"]!!.jsonPrimitive.content.toDouble())

        assertEquals(1, c.planOf(w.uid, id, 1).arrOf().size)
        assertEquals(8, c.planOf(w.uid, id, 8).arrOf().size)
        assertEquals(HttpStatusCode.BadRequest, c.planOf(w.uid, id, 0).status)
        assertEquals(HttpStatusCode.BadRequest, c.planOf(w.uid, id, 9).status)

        // 보조운동이 해당 dayKey 뒤에 'acc:<id>' 로 붙는다
        val curl = insertExercise(w.uid, "DUMBBELL")
        val accA = newId()
        val accB = newId()
        val put = c.putAccessories(
            w.uid, id,
            """[{"id":"$accA","dayKey":"A","exerciseId":"$curl","position":0,"sets":3,"reps":10,"weightKg":15},
               {"id":"$accB","dayKey":"B","exerciseId":"$curl","position":0,"sets":2,"reps":12}]""",
        )
        assertEquals(HttpStatusCode.OK, put.status)
        val plan = c.planOf(w.uid, id).arrOf()
        val exA = plan[0].jsonObject["exercises"]!!.jsonArray
        assertEquals(2, exA.size)
        val acc = exA[1].jsonObject
        assertEquals("acc:$accA", acc.str("key"))
        assertEquals(curl.toString(), acc.str("exerciseId"))
        assertTrue(acc["accessory"]!!.jsonPrimitive.content.toBoolean())
        val accSets = acc["sets"]!!.jsonArray
        assertEquals(listOf("acc:$accA.0", "acc:$accA.1", "acc:$accA.2"), accSets.map { it.str("plannedSetKey") })
        assertEquals(10, accSets[0].jsonObject["targetReps"]!!.jsonPrimitive.content.toInt())
        assertEquals(15.0, accSets[0].jsonObject["targetWeightKg"]!!.jsonPrimitive.content.toDouble())
        val accSetsB = plan[1].jsonObject["exercises"]!!.jsonArray[1].jsonObject["sets"]!!.jsonArray
        assertEquals(2, accSetsB.size)
        assertNull(accSetsB[0].jsonObject["targetWeightKg"])
        // next 에도 붙는다
        assertEquals(2, c.getInstance(w.uid, id).objOf()["next"]!!.jsonObject["exercises"]!!.jsonArray.size)
    }

    @Test
    fun engine_settings_use_user_formula_and_barbell_exercise_ids() {
        val fake = FakeCalculator()
        fakeTest(fake) {
            startApplication()
            val c = jsonClient()
            val w = world()
            val id = newId()
            c.startInstance(w.uid, id, w.programId)
            c.put("/v1/me/settings") { auth(w.uid); jsonBody(); setBody("""{"e1rmFormula":"BRZYCKI"}""") }
            c.planOf(w.uid, id)
            val s = fake.lastSettings!!
            assertEquals(E1rmFormula.BRZYCKI, s.e1rmFormula)
            assertEquals(setOf(w.squat.toString()), s.barbellExerciseIds) // bench 는 DUMBBELL
        }
    }

    @Test
    fun skip_requires_next_planSeq_and_shift_keeps_day() = fakeTest {
        startApplication()
        val c = jsonClient()
        val w = world()
        val id = newId()
        c.startInstance(w.uid, id, w.programId)
        assertEquals(HttpStatusCode.Conflict, c.skipInstance(w.uid, id, 2).status)
        assertEquals(HttpStatusCode.Conflict, c.skipInstance(w.uid, id, 0).status)
        val res = c.skipInstance(w.uid, id, 1)
        assertEquals(HttpStatusCode.OK, res.status)
        val inst = res.objOf()
        assertEquals(1, inst.seq())
        assertEquals(2, inst.nextSeq())
        assertEquals("A", inst.nextDay()) // SHIFT: 같은 날
        assertEquals(100.0, inst.workingOf("squat"))
        transaction {
            val skip = ProgramSkips.selectAll().where { ProgramSkips.instanceId eq UUID.fromString(id) }.single()
            assertEquals(1, skip[ProgramSkips.planSeq])
            assertFalse(skip[ProgramSkips.auto])
        }
        // 같은 회차 다시 건너뛰기는 409
        assertEquals(HttpStatusCode.Conflict, c.skipInstance(w.uid, id, 1).status)
        assertEquals(HttpStatusCode.OK, c.skipInstance(w.uid, id, 2).status)
        assertEquals(HttpStatusCode.OK, c.patchInstance(w.uid, id, """{"status":"FINISHED"}""").status)
        assertEquals(HttpStatusCode.Conflict, c.skipInstance(w.uid, id, 3).status)
    }

    @Test
    fun skip_with_fixed_date_moves_to_next_day() = fakeTest {
        startApplication()
        val c = jsonClient()
        val w = world()
        val id = newId()
        withToday("2026-11-02T03:00:00Z") { // 월요일 낮(서울): 첫 예정일이 오늘이라 자동 건너뛰기 없음
            val start = c.startInstance(w.uid, id, w.programId, skipPolicy = "FIXED_DATE").objOf()
            assertEquals("2026-11-02", start["next"]!!.jsonObject.str("scheduledDate"))
            val res = c.skipInstance(w.uid, id, 1).objOf()
            assertEquals(1, res.seq())
            assertEquals("B", res.nextDay())
            assertEquals("2026-11-05", res["next"]!!.jsonObject.str("scheduledDate"))
        }
    }

    @Test
    fun accessories_put_replaces_all_with_soft_delete_and_validates() = fakeTest {
        startApplication()
        val c = jsonClient()
        val w = world()
        val id = newId()
        c.startInstance(w.uid, id, w.programId)
        assertEquals(0, c.get("/v1/program-instances/$id/accessories") { auth(w.uid) }.arrOf().size)
        val ex1 = insertExercise(w.uid, "DUMBBELL")
        val ex2 = insertExercise(null, "MACHINE")
        val a1 = newId()
        val a2 = newId()
        val r1 = c.putAccessories(
            w.uid, id,
            """[{"id":"$a1","dayKey":"A","exerciseId":"$ex1","position":1,"sets":3,"reps":10,"weightKg":12.5},
               {"id":"$a2","dayKey":"A","exerciseId":"$ex2","position":0,"sets":2,"reps":15}]""",
        )
        assertEquals(HttpStatusCode.OK, r1.status)
        assertEquals(listOf(a2, a1), r1.arrOf().map { it.str("id") }) // position 순
        // 전체 교체: a2 만 남기고 수정
        val r2 = c.putAccessories(w.uid, id, """[{"id":"$a2","dayKey":"B","exerciseId":"$ex2","position":0,"sets":4,"reps":8,"weightKg":30}]""")
        val list = r2.arrOf()
        assertEquals(1, list.size)
        assertEquals("B", list[0].str("dayKey"))
        assertEquals("4", list[0].str("sets"))
        assertEquals(1, c.get("/v1/program-instances/$id/accessories") { auth(w.uid) }.arrOf().size)
        // a1 은 소프트 삭제(행은 남음)
        transaction {
            val row = com.fitlog.core.ProgramAccessories.selectAll().where { com.fitlog.core.ProgramAccessories.id eq UUID.fromString(a1) }.single()
            assertNotNull(row[com.fitlog.core.ProgramAccessories.deletedAt])
        }
        // 삭제했던 id 를 다시 보내면 되살아남
        val r3 = c.putAccessories(w.uid, id, """[{"id":"$a1","dayKey":"A","exerciseId":"$ex1","position":0,"sets":1,"reps":1}]""")
        assertEquals(listOf(a1), r3.arrOf().map { it.str("id") })
        assertEquals(0, c.putAccessories(w.uid, id, "[]").arrOf().size)

        fun bad(item: String, field: String) = kotlinx.coroutines.runBlocking {
            val r = c.putAccessories(w.uid, id, "[$item]")
            assertEquals(HttpStatusCode.BadRequest, r.status, item)
            assertEquals(field, errField(r.objOf()), item)
        }
        val foreign = insertExercise(createUser(), "DUMBBELL")
        bad("""{"id":"${newId()}","dayKey":"Z","exerciseId":"$ex1","position":0,"sets":3,"reps":10}""", "[0].dayKey")
        bad("""{"id":"${newId()}","dayKey":"A","exerciseId":"$foreign","position":0,"sets":3,"reps":10}""", "[0].exerciseId")
        bad("""{"id":"${newId()}","dayKey":"A","exerciseId":"$ex1","position":0,"sets":21,"reps":10}""", "[0].sets")
        bad("""{"id":"${newId()}","dayKey":"A","exerciseId":"$ex1","position":0,"sets":0,"reps":10}""", "[0].sets")
        bad("""{"id":"${newId()}","dayKey":"A","exerciseId":"$ex1","position":0,"sets":3,"reps":101}""", "[0].reps")
        // 남의 인스턴스
        assertEquals(HttpStatusCode.NotFound, c.putAccessories(createUser(), id, "[]").status)
        assertEquals(HttpStatusCode.NotFound, c.get("/v1/program-instances/$id/accessories") { auth(createUser()) }.status)
        // 다른 인스턴스의 보조운동 id 는 쓸 수 없다
        val id2 = newId()
        c.startInstance(w.uid, id2, w.programId)
        c.putAccessories(w.uid, id, """[{"id":"$a2","dayKey":"A","exerciseId":"$ex1","position":0,"sets":3,"reps":10}]""")
        val clash = c.putAccessories(w.uid, id2, """[{"id":"$a2","dayKey":"A","exerciseId":"$ex1","position":0,"sets":3,"reps":10}]""")
        assertEquals(HttpStatusCode.BadRequest, clash.status)
    }

    @Test
    fun delete_instance_keeps_sessions_unlinked() = fakeTest {
        startApplication()
        val c = jsonClient()
        val w = world()
        val id = newId()
        c.startInstance(w.uid, id, w.programId)
        val sid = newId()
        assertEquals(HttpStatusCode.OK, c.putSession(w.uid, sid, linkedSessionJson(sid, id, 1, w.squat)).status)
        c.skipInstance(w.uid, id, 2)

        assertEquals(HttpStatusCode.NoContent, c.deleteInstance(w.uid, id).status)
        assertEquals(HttpStatusCode.NotFound, c.getInstance(w.uid, id).status)
        assertEquals(0, c.get("/v1/program-instances") { auth(w.uid) }.arrOf().size)
        val s = c.getSession(w.uid, sid).objOf()
        assertNull(s["programInstanceId"])
        assertEquals("squat", s["exercises"]!!.jsonArray[0].str("liftKey")) // 세션 내용은 그대로
        transaction {
            assertEquals(0, ProgramSkips.selectAll().where { ProgramSkips.instanceId eq UUID.fromString(id) }.count())
        }
        // 다시 지워도 204, 연결이 끊긴 세션을 지워도 문제없음
        assertEquals(HttpStatusCode.NoContent, c.deleteInstance(w.uid, id).status)
        assertEquals(HttpStatusCode.NoContent, c.deleteSession(w.uid, sid).status)
    }

    @Test
    fun fixed_date_plan_fills_auto_skips_for_past_scheduled_days() = fakeTest {
        startApplication()
        val c = jsonClient()
        val w = world()
        val id = newId()
        // 11-19(목) 낮 서울. 예정일: A 월 11-02, B 목 11-05, A 월 11-09, B 목 11-12, A 월 11-16 은 지났고, B 목 11-19 는 오늘
        withToday("2026-11-19T03:00:00Z") {
            val start = c.startInstance(w.uid, id, w.programId, skipPolicy = "FIXED_DATE").objOf()
            assertEquals(5, start.seq())
            assertEquals(6, start.nextSeq())
            assertEquals("B", start.nextDay())
            assertEquals("2026-11-19", start["next"]!!.jsonObject.str("scheduledDate"))
            transaction {
                val skips = ProgramSkips.selectAll().where { ProgramSkips.instanceId eq UUID.fromString(id) }.toList()
                assertEquals(5, skips.size)
                assertTrue(skips.all { it[ProgramSkips.auto] })
                assertEquals((1..5).toList(), skips.map { it[ProgramSkips.planSeq] }.sorted())
                assertEquals("2026-11-16", skips.maxBy { it[ProgramSkips.planSeq] }[ProgramSkips.skippedOn].toString())
            }
            val plan = c.planOf(w.uid, id).arrOf()
            assertEquals(listOf("2026-11-19", "2026-11-23", "2026-11-26"), plan.map { it.str("scheduledDate") })
            assertEquals(listOf("B", "A", "B"), plan.map { it.str("dayKey") })
            // 반복 조회해도 늘지 않는다
            c.planOf(w.uid, id)
            transaction { assertEquals(5, ProgramSkips.selectAll().where { ProgramSkips.instanceId eq UUID.fromString(id) }.count().toInt()) }
        }
        // 다음 날(11-20): 목요일 11-19 가 지났으니 6회차도 자동 건너뜀
        withToday("2026-11-20T03:00:00Z") {
            val inst = c.getInstance(w.uid, id).objOf()
            assertEquals(6, inst.seq())
            assertEquals("2026-11-23", inst["next"]!!.jsonObject.str("scheduledDate"))
        }
    }

    @Test
    fun fixed_date_skips_only_days_without_sessions() = fakeTest {
        startApplication()
        val c = jsonClient()
        val w = world()
        val id = newId()
        withToday("2026-11-02T00:30:00Z") { // 월요일 아침: 아직 지난 예정일 없음
            assertEquals(0, c.startInstance(w.uid, id, w.programId, skipPolicy = "FIXED_DATE").objOf().seq())
        }
        // 1회차(월 11-02)는 했다
        val sid = newId()
        withToday("2026-11-02T10:00:00Z") {
            c.putSession(w.uid, sid, linkedSessionJson(sid, id, 1, w.squat, startedAt = "2026-11-02T01:00:00Z"))
        }
        withToday("2026-11-12T03:00:00Z") { // 목 11-12 낮
            val inst = c.getInstance(w.uid, id).objOf()
            // 2회차(목 11-05), 3회차(월 11-09) 자동 건너뜀, 4회차(목 11-12)는 오늘
            assertEquals(3, inst.seq())
            assertEquals(4, inst.nextSeq())
            assertEquals("B", inst.nextDay())
            assertEquals("2026-11-12", inst["next"]!!.jsonObject.str("scheduledDate"))
            assertEquals(102.5, inst.workingOf("squat"))
            transaction {
                val skips = ProgramSkips.selectAll().where { ProgramSkips.instanceId eq UUID.fromString(id) }.toList()
                assertEquals(listOf(2, 3), skips.map { it[ProgramSkips.planSeq] }.sorted())
            }
        }
    }

    @Test
    fun fixed_date_does_not_skip_paused_or_in_progress() = fakeTest {
        startApplication()
        val c = jsonClient()
        val w = world()
        val paused = newId()
        val running = newId()
        withToday("2026-11-02T00:30:00Z") {
            c.startInstance(w.uid, paused, w.programId, skipPolicy = "FIXED_DATE")
            c.startInstance(w.uid, running, w.programId, skipPolicy = "FIXED_DATE")
        }
        c.patchInstance(w.uid, paused, """{"status":"PAUSED"}""")
        // 진행 중(끝나지 않은) 1회차 세션이 있는 인스턴스
        val sid = newId()
        c.putSession(w.uid, sid, linkedSessionJson(sid, running, 1, w.squat, ended = false))
        withToday("2026-11-19T03:00:00Z") {
            assertEquals(0, c.getInstance(w.uid, paused).objOf().seq())
            assertEquals(0, c.getInstance(w.uid, running).objOf().seq())
        }
    }

    @Test
    fun deleting_a_session_after_auto_skip_restores_schedule() = fakeTest {
        startApplication()
        val c = jsonClient()
        val w = world()
        val id = newId()
        withToday("2026-11-02T00:30:00Z") { c.startInstance(w.uid, id, w.programId, skipPolicy = "FIXED_DATE") }
        withToday("2026-11-06T03:00:00Z") { // 금요일: 1회차(월)·2회차(목)가 지남 -> 둘 다 자동 건너뜀
            assertEquals(2, c.getInstance(w.uid, id).objOf().seq())
        }
        // 나중에 동기화된 1회차 세션이 들어오면 그 회차의 자동 건너뛰기는 세션이 이긴다
        val sid = newId()
        withToday("2026-11-06T03:00:00Z") {
            c.putSession(w.uid, sid, linkedSessionJson(sid, id, 1, w.squat, startedAt = "2026-11-02T01:00:00Z"))
            val inst = c.getInstance(w.uid, id).objOf()
            assertEquals(2, inst.seq())
            assertEquals(102.5, inst.workingOf("squat"))
            transaction {
                val skips = ProgramSkips.selectAll().where { ProgramSkips.instanceId eq UUID.fromString(id) }.toList()
                assertEquals(listOf(2), skips.map { it[ProgramSkips.planSeq] })
            }
        }
    }

    @Test
    fun unauthenticated_requests_are_rejected() = fakeTest {
        startApplication()
        val c = jsonClient()
        assertEquals(HttpStatusCode.Unauthorized, c.get("/v1/program-instances").status)
        assertEquals(HttpStatusCode.Unauthorized, c.get("/v1/program-instances/${newId()}/plan").status)
    }

    @Suppress("unused")
    private fun unusedImports() = listOf(WorkoutSessions)
}
