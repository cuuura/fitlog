package com.fitlog.program.instance

import com.fitlog.core.AppJson
import com.fitlog.core.ProgramAdjustments
import com.fitlog.core.ProgramInstances
import com.fitlog.core.Programs
import com.fitlog.engine.Day
import com.fitlog.engine.DayExercise
import com.fitlog.engine.ExerciseRef
import com.fitlog.engine.Lift
import com.fitlog.engine.Load
import com.fitlog.engine.ProgramDefinition
import com.fitlog.engine.Rule
import com.fitlog.engine.SetSpec
import com.fitlog.session.insertExercise
import com.fitlog.session.newId
import com.fitlog.session.putSession
import com.fitlog.session.str
import com.fitlog.support.auth
import com.fitlog.support.createUser
import com.fitlog.support.jsonBody
import com.fitlog.support.jsonClient
import io.ktor.client.HttpClient
import io.ktor.client.request.get
import io.ktor.client.request.post
import io.ktor.client.request.put
import io.ktor.client.request.setBody
import io.ktor.client.statement.HttpResponse
import io.ktor.http.HttpStatusCode
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.jetbrains.exposed.sql.SqlExpressionBuilder.eq
import org.jetbrains.exposed.sql.selectAll
import org.jetbrains.exposed.sql.update
import org.jetbrains.exposed.sql.transactions.transaction
import java.time.LocalDate
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/** v1.2 edit.md 3·4절과 벡터 C13~C16 (WP A3) */
class InstanceEditTest {
    private class World(val uid: UUID, val squat: UUID, val bench: UUID, val programId: UUID, val def: ProgramDefinition)

    private fun world(): World {
        val uid = createUser()
        val squat = insertExercise(null, "BARBELL")
        val bench = insertExercise(uid, "DUMBBELL")
        val def = testDefinition(squat, bench)
        return World(uid, squat, bench, insertProgram(uid, def), def)
    }

    private fun json(def: ProgramDefinition) = AppJson.encodeToString(ProgramDefinition.serializer(), def)

    private suspend fun HttpClient.putDefinition(uid: UUID, id: String, def: ProgramDefinition, extra: String = ""): HttpResponse =
        put("/v1/program-instances/$id/definition") { auth(uid); jsonBody(); setBody("""{"definition":${json(def)}$extra}""") }

    private fun instanceRow(id: String) = transaction { ProgramInstances.selectAll().where { ProgramInstances.id eq UUID.fromString(id) }.single() }

    @Test
    fun instance_view_includes_definition_and_follows_replace() = fakeTest {
        startApplication()
        val c = jsonClient()
        val w = world()
        val id = newId()
        withToday("2026-11-10T03:00:00Z") { c.startInstance(w.uid, id, w.programId) }
        val first = withToday("2026-11-10T03:00:00Z") { c.getInstance(w.uid, id).objOf() }
        assertEquals(w.def.name, first["definition"]!!.jsonObject.str("name"))
        val renamed = w.def.copy(name = "이 진행만 바꿈")
        val res = withToday("2026-11-10T03:00:00Z") { c.putDefinition(w.uid, id, renamed) }
        assertEquals(HttpStatusCode.OK, res.status)
        assertEquals("이 진행만 바꿈", res.objOf()["definition"]!!.jsonObject.str("name"))
        val after = withToday("2026-11-10T03:00:00Z") { c.getInstance(w.uid, id).objOf() }
        assertEquals("이 진행만 바꿈", after["definition"]!!.jsonObject.str("name"))
    }

    @Test
    fun c13_replace_definition_rebases_and_ignores_older_history() = fakeTest {
        startApplication()
        val c = jsonClient()
        val w = world()
        val id = newId()
        withToday("2026-11-10T03:00:00Z") {
            c.startInstance(w.uid, id, w.programId, skipPolicy = "FIXED_DATE")
        }
        // 3회차를 모두 수행(월 11-02, 목 11-05, 월 11-09). 처음에 한 번 조정도 끼워 둔다
        val s1 = newId()
        val s2 = newId()
        val s3 = newId()
        withToday("2026-11-10T03:00:00Z") {
            c.putSession(w.uid, s1, linkedSessionJson(s1, id, 1, w.squat, startedAt = "2026-11-02T01:00:00Z"))
            c.patchInstance(w.uid, id, """{"adjust":{"working":{"squat":150}}}""")
            c.putSession(w.uid, s2, linkedSessionJson(s2, id, 2, w.bench, liftKey = "bench", dayKey = "B", startedAt = "2026-11-05T01:00:00Z", sets = 1))
            c.putSession(w.uid, s3, linkedSessionJson(s3, id, 3, w.squat, startedAt = "2026-11-09T01:00:00Z"))
        }
        val before = withToday("2026-11-10T03:00:00Z") { c.getInstance(w.uid, id).objOf() }
        assertEquals(3, before.seq())
        assertEquals("B", before.nextDay())
        val squatBefore = before.workingOf("squat")

        // days 순서를 바꾼 정의(B, A)로 교체. 다음 날 key(B)는 유지된다
        val reordered = w.def.copy(days = w.def.days.reversed())
        val res = withToday("2026-11-10T03:00:00Z") { c.putDefinition(w.uid, id, reordered) }
        assertEquals(HttpStatusCode.OK, res.status)
        val inst = res.objOf()
        assertEquals(3, inst.seq())
        assertEquals("B", inst.nextDay())
        assertEquals(4, inst.nextSeq())
        assertEquals(squatBefore, inst.workingOf("squat"))
        // FIXED_DATE 예정일은 교체 시점 날짜 다음부터 이어진다(목 11-12)
        assertEquals("2026-11-12", inst["next"]!!.jsonObject.str("scheduledDate"))
        val row = instanceRow(id)
        assertEquals(3, row[ProgramInstances.baseSeq])
        assertEquals(LocalDate.parse("2026-11-09"), row[ProgramInstances.baseDate])
        assertEquals("{}", row[ProgramInstances.dayOrder])
        assertEquals(3, row[ProgramInstances.stateSeq])

        // 이전 세션을 고치거나 지워도(5 -> 3회) 상태는 그대로다. 이전 조정도 다시 적용되지 않는다
        withToday("2026-11-10T03:00:00Z") {
            c.putSession(w.uid, s1, linkedSessionJson(s1, id, 1, w.squat, reps = 3, startedAt = "2026-11-02T01:00:00Z"))
            c.putSession(w.uid, s3, linkedSessionJson(s3, id, 3, w.squat, reps = 1, startedAt = "2026-11-09T01:00:00Z"))
            val again = c.getInstance(w.uid, id).objOf()
            assertEquals(3, again.seq())
            assertEquals(squatBefore, again.workingOf("squat"))
            assertEquals("B", again.nextDay())
        }
        transaction {
            assertEquals(0, ProgramAdjustments.selectAll().where { ProgramAdjustments.instanceId eq UUID.fromString(id) }.count().toInt())
        }

        // 교체 뒤 4회차(B)를 하면 새 정의 위에서 이어진다
        val s4 = newId()
        withToday("2026-11-12T03:00:00Z") {
            c.putSession(w.uid, s4, linkedSessionJson(s4, id, 4, w.bench, liftKey = "bench", dayKey = "B", startedAt = "2026-11-12T01:00:00Z", sets = 1))
            val next = c.getInstance(w.uid, id).objOf()
            assertEquals(4, next.seq())
            assertEquals("A", next.nextDay())
            // 새 조정은 교체 뒤에도 반영된다
            c.patchInstance(w.uid, id, """{"adjust":{"working":{"squat":200}}}""")
            assertEquals(200.0, c.getInstance(w.uid, id).objOf().workingOf("squat"))
        }

        // 끝나지 않은 다음 회차(5) 세션이 있으면 409
        val s5 = newId()
        withToday("2026-11-13T03:00:00Z") {
            c.putSession(w.uid, s5, linkedSessionJson(s5, id, 5, w.squat, ended = false, startedAt = "2026-11-13T01:00:00Z"))
            val conflict = c.putDefinition(w.uid, id, w.def)
            assertEquals(HttpStatusCode.Conflict, conflict.status)
            assertEquals("CONFLICT", conflict.objOf()["error"]!!.jsonObject.str("code"))
        }
    }

    @Test
    fun c14_replace_definition_requires_inputs_for_new_lifts() = fakeTest {
        startApplication()
        val c = jsonClient()
        val w = world()
        val id = newId()
        c.startInstance(w.uid, id, w.programId)
        val dead = insertExercise(null, "BARBELL")
        val withDead = w.def.copy(
            lifts = w.def.lifts + ("deadlift" to Lift(ExerciseRef(id = dead.toString()))),
            progression = w.def.progression + ("deadlift" to Rule.Linear(5.0)),
            days = w.def.days + Day("C", "Workout C", "FRI", listOf(DayExercise("deadlift", sets = listOf(SetSpec(count = 1, reps = 5, load = Load.Working()))))),
        )
        val missing = c.putDefinition(w.uid, id, withDead)
        assertEquals(HttpStatusCode.BadRequest, missing.status)
        val err = missing.objOf()["error"]!!.jsonObject
        assertEquals("VALIDATION_FAILED", err.str("code"))
        assertEquals(listOf("/working/deadlift"), err["details"]!!.jsonArray.map { it.jsonObject.str("path") })
        // 아무것도 바뀌지 않았다
        assertEquals(0, instanceRow(id)[ProgramInstances.baseSeq])

        val ok = c.putDefinition(w.uid, id, withDead, ""","working":{"deadlift":120}""")
        assertEquals(HttpStatusCode.OK, ok.status)
        val inst = ok.objOf()
        assertEquals(120.0, inst.workingOf("deadlift"))
        assertEquals(100.0, inst.workingOf("squat"))
        // 본문 값으로 기존 값도 덮어쓸 수 있다
        val over = c.putDefinition(w.uid, id, withDead, ""","working":{"squat":105}""").objOf()
        assertEquals(105.0, over.workingOf("squat"))
        // 규칙 종류가 바뀐 키는 연속 값을 비운다
        transaction {
            val st = """{"working":{"squat":105,"deadlift":120,"bench":0},"tm":{"bench":80},"failStreak":{"squat":2,"bench":1},"stage":{"squat":1}}"""
            ProgramInstances.update({ ProgramInstances.id eq UUID.fromString(id) }) {
                it[ProgramInstances.state] = st
                it[ProgramInstances.initialState] = st
            }
        }
        val changed = withDead.copy(progression = withDead.progression + ("squat" to Rule.Double(2.5)))
        c.putDefinition(w.uid, id, changed)
        val st = AppJson.parseToJsonElement(instanceRow(id)[ProgramInstances.state]).jsonObject
        assertEquals(null, st["failStreak"]!!.jsonObject["squat"])
        assertEquals("1", st["failStreak"]!!.jsonObject["bench"]!!.jsonPrimitive.content)
        assertEquals(null, st["stage"]!!.jsonObject["squat"])
    }

    @Test
    fun c15_swap_changes_exercise_and_keeps_state() = fakeTest {
        startApplication()
        val c = jsonClient()
        val w = world()
        val id = newId()
        c.startInstance(w.uid, id, w.programId)
        val other = insertExercise(null, "BARBELL")
        val res = c.post("/v1/program-instances/$id/swap") {
            auth(w.uid); jsonBody(); setBody("""{"liftKey":"squat","exerciseId":"$other"}""")
        }
        assertEquals(HttpStatusCode.OK, res.status)
        val inst = res.objOf()
        assertEquals(100.0, inst.workingOf("squat"))
        assertEquals(80.0, inst["state"]!!.jsonObject["tm"]!!.jsonObject["bench"]!!.jsonPrimitive.content.toDouble())
        val plan = c.planOf(w.uid, id, 1).arrOf()[0].jsonObject
        assertEquals(other.toString(), plan["exercises"]!!.jsonArray[0].jsonObject.str("exerciseId"))
        assertEquals(other.toString(), AppJson.decodeFromString<ProgramDefinition>(instanceRow(id)[ProgramInstances.definition]).lifts["squat"]!!.exercise.id)
        // 원본 프로그램은 그대로
        assertEquals(w.squat.toString(), transaction {
            AppJson.decodeFromString<ProgramDefinition>(Programs.selectAll().where { Programs.id eq w.programId }.single()[Programs.definition]).lifts["squat"]!!.exercise.id
        })
        // 값을 같이 주면 그 키를 덮어쓴다
        val withValue = c.post("/v1/program-instances/$id/swap") {
            auth(w.uid); jsonBody(); setBody("""{"liftKey":"squat","exerciseId":"$other","working":90}""")
        }.objOf()
        assertEquals(90.0, withValue.workingOf("squat"))

        fun bad(body: String) = kotlinx.coroutines.runBlocking {
            c.post("/v1/program-instances/$id/swap") { auth(w.uid); jsonBody(); setBody(body) }.status
        }
        assertEquals(HttpStatusCode.BadRequest, bad("""{"liftKey":"nope","exerciseId":"$other"}"""))
        assertEquals(HttpStatusCode.NotFound, bad("""{"liftKey":"squat","exerciseId":"${UUID.randomUUID()}"}"""))
        // 남의 종목은 안 보인다
        val theirs = insertExercise(createUser(), "BARBELL")
        assertEquals(HttpStatusCode.NotFound, bad("""{"liftKey":"squat","exerciseId":"$theirs"}"""))
    }

    @Test
    fun c16_day_order_reorders_plan_without_changing_judgement() = fakeTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val a = insertExercise(null, "BARBELL")
        val b = insertExercise(uid, "DUMBBELL")
        val r = insertExercise(null, "BARBELL")
        fun ex(lift: String) = DayExercise(lift, sets = listOf(SetSpec(count = 1, reps = 5, load = Load.Working())))
        val def = ProgramDefinition(
            schemaVersion = 1, name = "Three",
            lifts = mapOf("squat" to Lift(ExerciseRef(id = a.toString())), "bench" to Lift(ExerciseRef(id = b.toString())), "row" to Lift(ExerciseRef(id = r.toString()))),
            progression = mapOf("squat" to Rule.Linear(2.5), "bench" to Rule.Linear(2.5), "row" to Rule.Linear(2.5)),
            days = listOf(Day("A", "Workout A", "MON", listOf(ex("squat"), ex("bench"), ex("row")))),
        )
        val pid = insertProgram(uid, def)
        val id = newId()
        c.startInstance(uid, id, pid, tm = "{}", working = """{"squat":100,"bench":60,"row":50}""")
        fun keys(p: JsonObject) = p["exercises"]!!.jsonArray.map { it.jsonObject.str("key") }
        fun setKeys(p: JsonObject) = p["exercises"]!!.jsonArray.map { it.jsonObject["sets"]!!.jsonArray[0].jsonObject.str("plannedSetKey") }
        assertEquals(listOf("squat", "bench", "row"), keys(c.planOf(uid, id, 1).arrOf()[0].jsonObject))

        val put = c.put("/v1/program-instances/$id/day-order") { auth(uid); jsonBody(); setBody("""{"dayKey":"A","order":[2,0,1]}""") }
        assertEquals(HttpStatusCode.OK, put.status)
        assertEquals("2,0,1", put.objOf()["dayOrder"]!!.jsonObject["A"]!!.jsonArray.joinToString(",") { it.jsonPrimitive.content })
        val plan = c.planOf(uid, id, 2).arrOf()
        assertEquals(listOf("row", "squat", "bench"), keys(plan[0].jsonObject))
        assertEquals(listOf("A.2.0", "A.0.0", "A.1.0"), setKeys(plan[0].jsonObject))
        assertEquals(listOf("row", "squat", "bench"), keys(plan[1].jsonObject)) // 다음 회차도 같은 순서
        val view = c.getInstance(uid, id).objOf()
        assertEquals(listOf("row", "squat", "bench"), view["next"]!!.jsonObject["exercises"]!!.jsonArray.map { it.jsonObject.str("key") })
        assertNotNull(view["dayOrder"]!!.jsonObject["A"])

        // 순서가 바뀐 계획대로 기록해도 판정은 같다(plannedSetKey 기준)
        val before = c.getInstance(uid, id).objOf()
        val sid = newId()
        val sets = fun(lift: String, idx: Int, ex: UUID): String =
            """{"id":"${newId()}","exerciseId":"$ex","position":0,"liftKey":"$lift","accessory":false,"sets":[{"id":"${newId()}","position":0,"weightKg":100,"reps":5,"completedAt":"2026-11-02T01:00:00Z","plannedSetKey":"A.$idx.0","targetReps":5,"targetWeightKg":100,"isAmrap":false}]}"""
        val body = """{"id":"$sid","startedAt":"2026-11-02T01:00:00Z","endedAt":"2026-11-02T02:00:00Z","tz":"Asia/Seoul","programInstanceId":"$id","planSeq":1,"planDayKey":"A","exercises":[${sets("row", 2, r)},${sets("squat", 0, a)},${sets("bench", 1, b)}]}"""
        assertEquals(HttpStatusCode.OK, c.putSession(uid, sid, body).status)
        val after = c.getInstance(uid, id).objOf()
        assertEquals(before.workingOf("squat") + 2.5, after.workingOf("squat"))
        assertEquals(before.workingOf("row") + 2.5, after.workingOf("row"))

        // 잘못된 순열·모르는 날은 400, 원래 순서나 빈 배열은 그 날 항목을 지운다
        fun bad(b: String) = kotlinx.coroutines.runBlocking { c.put("/v1/program-instances/$id/day-order") { auth(uid); jsonBody(); setBody(b) }.status }
        assertEquals(HttpStatusCode.BadRequest, bad("""{"dayKey":"A","order":[0,0,1]}"""))
        assertEquals(HttpStatusCode.BadRequest, bad("""{"dayKey":"A","order":[0,1]}"""))
        assertEquals(HttpStatusCode.BadRequest, bad("""{"dayKey":"Z","order":[0,1,2]}"""))
        assertEquals(HttpStatusCode.OK, bad("""{"dayKey":"A","order":[0,1,2]}"""))
        assertEquals("{}", instanceRow(id)[ProgramInstances.dayOrder])
        assertEquals(listOf("squat", "bench", "row"), keys(c.planOf(uid, id, 1).arrOf()[0].jsonObject))
    }

    @Test
    fun put_program_edits_own_programs_and_lists_active_instances() = fakeTest {
        startApplication()
        val c = jsonClient()
        val w = world()
        val id = newId()
        c.startInstance(w.uid, id, w.programId)
        val edited = w.def.copy(description = "새 설명")
        val res = c.put("/v1/programs/${w.programId}") { auth(w.uid); jsonBody(); setBody("""{"name":"고친 이름","definition":${json(edited)}}""") }
        assertEquals(HttpStatusCode.OK, res.status)
        val body = res.objOf()
        assertEquals("고친 이름", body.str("name"))
        assertEquals("새 설명", body.str("description"))
        assertEquals(listOf(id), body["activeInstanceIds"]!!.jsonArray.map { it.jsonPrimitive.content })
        // 진행 중 인스턴스의 정의는 그대로
        assertEquals("Fake Program", AppJson.decodeFromString<ProgramDefinition>(instanceRow(id)[ProgramInstances.definition]).name)
        assertEquals(HttpStatusCode.OK, c.getProgram(w.uid, w.programId.toString()).status)

        // 검증 실패는 POST 와 같은 400 + details
        val bad = c.put("/v1/programs/${w.programId}") { auth(w.uid); jsonBody(); setBody("""{"definition":{"schemaVersion":1,"name":"x"}}""") }
        assertEquals(HttpStatusCode.BadRequest, bad.status)
        assertTrue(bad.objOf()["error"]!!.jsonObject["details"]!!.jsonArray.isNotEmpty())
        // 기본 템플릿 403, 남의 것 404, 없는 것 404
        val template = insertProgram(null, w.def)
        assertEquals(HttpStatusCode.Forbidden, c.put("/v1/programs/$template") { auth(w.uid); jsonBody(); setBody("""{"definition":${json(w.def)}}""") }.status)
        val other = createUser()
        assertEquals(HttpStatusCode.NotFound, c.put("/v1/programs/${w.programId}") { auth(other); jsonBody(); setBody("""{"definition":${json(w.def)}}""") }.status)
        assertEquals(HttpStatusCode.NotFound, c.put("/v1/programs/${UUID.randomUUID()}") { auth(w.uid); jsonBody(); setBody("""{"definition":${json(w.def)}}""") }.status)
    }

    private suspend fun HttpClient.getProgram(uid: UUID, id: String) =
        get("/v1/programs/$id") { auth(uid) }
}
