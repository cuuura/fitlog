package com.fitlog.importing

import com.fitlog.core.ImportItems
import com.fitlog.core.ScheduledWorkouts
import com.fitlog.core.WorkoutSessions
import com.fitlog.scheduled.decodeItems
import com.fitlog.session.arr
import com.fitlog.session.obj
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
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.jetbrains.exposed.sql.SqlExpressionBuilder.eq
import org.jetbrains.exposed.sql.SqlExpressionBuilder.isNull
import org.jetbrains.exposed.sql.and
import org.jetbrains.exposed.sql.selectAll
import org.jetbrains.exposed.sql.transactions.transaction
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

private const val SQ = "019b76da-4000-7000-8000-000000000001"
private const val BP = "019b76da-4000-7000-8000-000000000003"

private suspend fun HttpClient.imp(uid: UUID, bundle: String, extra: String = "", path: String = "/v1/imports"): HttpResponse =
    post(path) {
        auth(uid); jsonBody()
        setBody("""{"bundle":$bundle${if (extra.isEmpty()) "" else ",$extra"}}""")
    }

private suspend fun HttpClient.revert(uid: UUID, id: String): HttpResponse = post("/v1/imports/$id/revert") { auth(uid) }

private fun bundle(vararg parts: String) = "{" + (listOf(""""schemaVersion":1""") + parts).joinToString(",") + "}"

private fun sw(
    date: String = "2026-11-28", title: String = "B-2 하체", id: String? = null, ex: String = """{"name":"스쿼트"}""",
    set: String = """{"targetWeightKg":80,"targetReps":12,"targetRepsMax":15,"targetRir":3}""", extraItems: String = "",
): String {
    val idPart = if (id != null) """"id":"$id",""" else ""
    return """{$idPart"plannedDate":"$date","title":"$title","items":[{"exercise":$ex,"restSec":180,"sets":[$set,$set]}$extraItems]}"""
}

private fun scheduled(vararg s: String) = """"scheduledWorkouts":[${s.joinToString(",")}]"""

private fun res(vararg pairs: Pair<String, String>) = """"resolutions":{${pairs.joinToString(",") { """"${it.first}":${it.second}""" }}}"""

private fun live(uid: UUID) = transaction {
    ScheduledWorkouts.selectAll().where { (ScheduledWorkouts.userId eq uid) and ScheduledWorkouts.deletedAt.isNull() }.toList()
}

class ScheduledImportTest {
    @Test
    fun resolves_names_saves_with_source_label_and_summary() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val b = bundle(scheduled(sw(ex = """{"name":"스쿼트"}""", extraItems = ",{\"exercise\":{\"id\":\"$BP\"},\"note\":\"벨트\",\"sets\":[{\"targetReps\":8}]}")))
        val r = c.imp(uid, b, """"clientName":"Claude"""")
        assertEquals(HttpStatusCode.Created, r.status)
        val batch = r.obj()
        assertEquals(1, batch["summary"]!!.jsonObject["scheduledWorkouts"]!!.jsonPrimitive.int)
        val rows = transaction { ScheduledWorkouts.selectAll().where { ScheduledWorkouts.userId eq uid }.toList() }
        assertEquals(1, rows.size)
        val row = rows.single()
        assertEquals("AI_JSON", row[ScheduledWorkouts.sourceCol])
        assertEquals(batch.str("id"), row[ScheduledWorkouts.importBatchId].toString())
        assertEquals("2026-11-28", row[ScheduledWorkouts.plannedDate].toString())
        val items = decodeItems(row[ScheduledWorkouts.items])
        assertEquals(2, items.size)
        assertEquals(UUID.fromString(SQ), items[0].exerciseId)
        assertEquals(180, items[0].restSec)
        assertEquals(12, items[0].sets[0].targetReps)
        assertEquals(15, items[0].sets[0].targetRepsMax)
        assertEquals(UUID.fromString(BP), items[1].exerciseId)
        val det = c.get2(uid, batch.str("id")!!)
        val it = det["items"]!!.jsonArray.map { x -> x.jsonObject }.single { x -> x.str("entity") == "scheduled_workout" }
        assertEquals("CREATED", it.str("action"))
        assertEquals("2026-11-28 B-2 하체", it.str("label"))

        // 같은 묶음을 다시 보내면 바뀐 것이 없다
        assertEquals(HttpStatusCode.OK, c.imp(uid, b).status)
        assertEquals(1, live(uid).size)
    }

    @Test
    fun unknown_exercise_skip_drops_only_that_item_and_all_dropped_is_not_saved() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val two = bundle(scheduled(sw(extraItems = ",{\"exercise\":{\"name\":\"없는운동\"},\"sets\":[{\"targetReps\":5}]}")))
        val pv = c.imp(uid, two, path = "/v1/imports/preview").obj()
        val conflict = pv["conflicts"]!!.jsonArray.single().jsonObject
        val cid = "UNKNOWN_EXERCISE:/scheduledWorkouts/0/items/1/exercise"
        assertEquals(cid, conflict.str("conflictId"))
        assertEquals(HttpStatusCode.Conflict, c.imp(uid, two).status)
        assertEquals(0, live(uid).size)

        assertEquals(HttpStatusCode.Created, c.imp(uid, two, res(cid to """{"action":"SKIP"}""")).status)
        assertEquals(1, decodeItems(live(uid).single()[ScheduledWorkouts.items]).size)

        // 모든 item 이 빠지면 저장하지 않는다
        val only = bundle(scheduled(sw(date = "2026-12-01", title = "전부 빠짐", ex = """{"name":"없는운동"}""")))
        val cid2 = "UNKNOWN_EXERCISE:/scheduledWorkouts/0/items/0/exercise"
        val r = c.imp(uid, only, res(cid2 to """{"action":"SKIP"}"""))
        assertEquals(HttpStatusCode.OK, r.status)
        assertEquals(1, live(uid).size)

        // MAP_TO 로 이어 붙이기
        val mapped = c.imp(uid, only, res(cid2 to """{"action":"MAP_TO","exerciseId":"$BP"}"""))
        assertEquals(HttpStatusCode.Created, mapped.status)
        assertEquals(2, live(uid).size)
    }

    @Test
    fun scheduled_duplicate_skip_keep_both_replace_and_revert_restores() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        c.imp(uid, bundle(scheduled(sw(title = "하체 데이"))))
        val oldId = live(uid).single()[ScheduledWorkouts.id]

        val b = bundle(scheduled(sw(title = "하체 데이", set = """{"targetWeightKg":90,"targetReps":10}""")))
        val cid = "SCHEDULED_DUPLICATE:/scheduledWorkouts/0"
        val pv = c.imp(uid, b, path = "/v1/imports/preview").obj()
        val conflict = pv["conflicts"]!!.jsonArray.single().jsonObject
        assertEquals(cid, conflict.str("conflictId"))
        assertEquals(oldId.toString(), conflict["existing"]!!.jsonObject.str("id"))
        assertEquals(listOf("SKIP", "KEEP_BOTH", "REPLACE"), conflict["allowed"]!!.jsonArray.map { it.jsonPrimitive.content })
        assertEquals(HttpStatusCode.Conflict, c.imp(uid, b).status)

        assertEquals(HttpStatusCode.OK, c.imp(uid, b, res(cid to """{"action":"SKIP"}""")).status)
        assertEquals(1, live(uid).size)

        // 제목 대소문자·공백 무시
        val ci = bundle(scheduled(sw(title = "하체데이".replace("하체", "하체 ").uppercase(), set = """{"targetReps":3}""")))
        assertEquals(HttpStatusCode.Conflict, c.imp(uid, ci).status)
        // 다른 날이면 충돌 아님
        assertEquals(HttpStatusCode.Created, c.imp(uid, bundle(scheduled(sw(date = "2026-11-29", title = "하체 데이")))).status)
        assertEquals(2, live(uid).size)

        assertEquals(HttpStatusCode.Created, c.imp(uid, b, res(cid to """{"action":"KEEP_BOTH"}""")).status)
        assertEquals(3, live(uid).size)

        val b2 = bundle(scheduled(sw(title = "하체 데이", set = """{"targetWeightKg":100,"targetReps":6}""")))
        val rep = c.imp(uid, b2, res(cid to """{"action":"REPLACE"}"""))
        assertEquals(HttpStatusCode.Created, rep.status)
        val det = c.get2(uid, rep.obj().str("id")!!)
        assertTrue(det["items"]!!.jsonArray.any { it.jsonObject.str("entity") == "scheduled_workout" && it.jsonObject.str("action") == "REPLACED_OLD" })
        // 2026-11-28 의 같은 제목 둘(첫 것과 KEEP_BOTH)이 모두 교체됨
        val d28 = live(uid).filter { it[ScheduledWorkouts.plannedDate].toString() == "2026-11-28" }
        assertEquals(1, d28.size)
        assertEquals(100.0, decodeItems(d28.single()[ScheduledWorkouts.items])[0].sets[0].targetWeightKg)
        assertTrue(rep.obj()["summary"]!!.jsonObject["replaced"]!!.jsonPrimitive.int >= 1)

        // 되돌리면 새 것은 삭제되고 지웠던 것이 살아난다
        val rv = c.revert(uid, rep.obj().str("id")!!)
        assertEquals(HttpStatusCode.OK, rv.status)
        val after = live(uid).filter { it[ScheduledWorkouts.plannedDate].toString() == "2026-11-28" }
        assertEquals(2, after.size)
        assertTrue(oldId in after.map { it[ScheduledWorkouts.id] })
    }

    @Test
    fun revert_soft_deletes_created_scheduled_workout() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val r = c.imp(uid, bundle(scheduled(sw()))).obj()
        assertEquals(1, live(uid).size)
        assertEquals(HttpStatusCode.OK, c.revert(uid, r.str("id")!!).status)
        assertEquals(0, live(uid).size)
        assertEquals(1, transaction { ScheduledWorkouts.selectAll().where { ScheduledWorkouts.userId eq uid }.count() }.toInt())
    }

    @Test
    fun id_exists_applies_and_other_users_ids_are_remapped() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val other = createUser()
        val sid = UUID.randomUUID().toString()
        assertEquals(HttpStatusCode.Created, c.imp(uid, bundle(scheduled(sw(id = sid)))).status)
        val changed = bundle(scheduled(sw(id = sid, title = "다른 제목")))
        val cid = "ID_EXISTS:/scheduledWorkouts/0"
        assertEquals(HttpStatusCode.Conflict, c.imp(uid, changed).status)
        assertEquals(HttpStatusCode.Created, c.imp(uid, changed, res(cid to """{"action":"REPLACE"}""")).status)
        assertEquals("다른 제목", live(uid).single()[ScheduledWorkouts.title])
        // 같은 내용이면 UNCHANGED
        assertEquals(HttpStatusCode.OK, c.imp(uid, changed).status)

        // 다른 사용자의 id 와 겹치면 알리지 않고 새 id
        assertEquals(HttpStatusCode.Created, c.imp(other, bundle(scheduled(sw(id = sid)))).status)
        assertEquals(1, live(uid).size)
        assertEquals(1, live(other).size)
        assertNotEquals(sid, live(other).single()[ScheduledWorkouts.id].toString())
    }

    @Test
    fun session_links_to_bundle_or_existing_scheduled_workout() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val sid = UUID.randomUUID().toString()
        fun session(start: String, link: String?, name: String = "스쿼트") =
            """{"startedAt":"$start","tz":"Asia/Seoul",${if (link != null) """"scheduledWorkoutId":"$link",""" else ""}"exercises":[{"exercise":{"name":"$name"},"sets":[{"weightKg":80,"reps":12}]}]}"""
        fun link(day: String): UUID? = transaction {
            WorkoutSessions.selectAll().where { (WorkoutSessions.userId eq uid) and WorkoutSessions.deletedAt.isNull() }
                .single { it[WorkoutSessions.startedAt].toString().startsWith(day) }[WorkoutSessions.scheduledWorkoutId]
        }

        // 묶음 안 예정과 세션
        val b = bundle(scheduled(sw(id = sid)), """"sessions":[${session("2026-11-28T10:00:00+09:00", sid)}]""")
        assertEquals(HttpStatusCode.Created, c.imp(uid, b).status)
        assertEquals(UUID.fromString(sid), link("2026-11-28"))

        // 같은 예정을 가리키는 두 번째 세션(다른 날)은 연결 없이 저장
        val second = bundle(""""sessions":[${session("2026-11-30T10:00:00+09:00", sid)}]""")
        assertEquals(HttpStatusCode.Created, c.imp(uid, second).status)
        assertNull(link("2026-11-30"))

        // 없는 id 는 연결 없이 저장
        val unknown = bundle(""""sessions":[${session("2026-12-02T10:00:00+09:00", UUID.randomUUID().toString())}]""")
        assertEquals(HttpStatusCode.Created, c.imp(uid, unknown).status)
        assertNull(link("2026-12-02"))

        // 기존 살아 있는 예정(아직 세션 없음)
        val ex = UUID.randomUUID().toString()
        assertEquals(HttpStatusCode.Created, c.imp(uid, bundle(scheduled(sw(id = ex, date = "2026-12-05", title = "다른 날")))).status)
        val existing = bundle(""""sessions":[${session("2026-12-05T10:00:00+09:00", ex)}]""")
        assertEquals(HttpStatusCode.Created, c.imp(uid, existing).status)
        assertEquals(UUID.fromString(ex), link("2026-12-05"))

        // 다른 사용자의 예정은 연결하지 않는다
        val other = createUser()
        val theirs = UUID.randomUUID().toString()
        assertEquals(HttpStatusCode.Created, c.imp(other, bundle(scheduled(sw(id = theirs)))).status)
        val steal = bundle(""""sessions":[${session("2026-12-08T10:00:00+09:00", theirs)}]""")
        assertEquals(HttpStatusCode.Created, c.imp(uid, steal).status)
        assertNull(link("2026-12-08"))
    }

    @Test
    fun skipped_scheduled_workout_leaves_session_without_link() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val sid = UUID.randomUUID().toString()
        val b = bundle(
            scheduled(sw(id = sid, ex = """{"name":"없는운동"}""")),
            """"sessions":[{"startedAt":"2026-11-28T10:00:00+09:00","tz":"Asia/Seoul","scheduledWorkoutId":"$sid","exercises":[{"exercise":{"name":"스쿼트"},"sets":[{"weightKg":80,"reps":12}]}]}]""",
        )
        val r = c.imp(uid, b, res("UNKNOWN_EXERCISE:/scheduledWorkouts/0/items/0/exercise" to """{"action":"SKIP"}"""))
        assertEquals(HttpStatusCode.Created, r.status)
        assertEquals(0, live(uid).size)
        assertNull(transaction { WorkoutSessions.selectAll().where { WorkoutSessions.userId eq uid }.single()[WorkoutSessions.scheduledWorkoutId] })
    }

    @Test
    fun schema_violations_are_validation_failed_with_json_pointer_paths() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val bad = bundle(
            scheduled(
                // targetRepsMax 만 있고 targetReps 없음
                sw(set = """{"targetRepsMax":15}"""),
                // targetRepsMax < targetReps
                sw(set = """{"targetReps":12,"targetRepsMax":8}"""),
                """{"plannedDate":"nope","title":"","items":[]}""",
                """{"plannedDate":"2026-11-28","title":"x","items":[{"exercise":{"name":"스쿼트"},"restSec":4000,"sets":[{"targetRpe":7.3,"targetRir":11,"bogus":1}]}],"extra":1}""",
            ),
        )
        val r = c.imp(uid, bad)
        assertEquals(HttpStatusCode.BadRequest, r.status)
        val e = r.obj()["error"]!!.jsonObject
        assertEquals("VALIDATION_FAILED", e.str("code"))
        val paths = e["details"]!!.jsonArray.map { it.str("path")!! }
        assertTrue("/scheduledWorkouts/0/items/0/sets/0/targetRepsMax" in paths, paths.toString())
        assertTrue("/scheduledWorkouts/1/items/0/sets/0/targetRepsMax" in paths, paths.toString())
        assertTrue("/scheduledWorkouts/2/plannedDate" in paths, paths.toString())
        assertTrue("/scheduledWorkouts/2/title" in paths, paths.toString())
        assertTrue("/scheduledWorkouts/2/items" in paths, paths.toString())
        assertTrue("/scheduledWorkouts/3/extra" in paths, paths.toString())
        assertTrue("/scheduledWorkouts/3/items/0/restSec" in paths, paths.toString())
        assertTrue("/scheduledWorkouts/3/items/0/sets/0/targetRpe" in paths, paths.toString())
        assertTrue("/scheduledWorkouts/3/items/0/sets/0/targetRir" in paths, paths.toString())
        assertTrue("/scheduledWorkouts/3/items/0/sets/0/bogus" in paths, paths.toString())
        assertEquals(0, live(uid).size)

        // 31개는 한도 초과
        val many = bundle(scheduled(*Array(31) { sw(date = "2026-12-01", title = "t$it") }))
        assertEquals(HttpStatusCode.BadRequest, c.imp(uid, many).status)
        // 잘못된 tz
        val tz = bundle(scheduled(sw().replace("""{"plannedDate""", """{"tz":"Nope/Zone","plannedDate""")))
        val rt = c.imp(uid, tz)
        assertEquals(HttpStatusCode.BadRequest, rt.status)
        assertTrue(rt.obj()["error"]!!.jsonObject["details"]!!.jsonArray.any { it.str("path") == "/scheduledWorkouts/0/tz" })
    }

    @Test
    fun import_items_are_recorded_per_scheduled_workout() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val r = c.imp(uid, bundle(scheduled(sw(), sw(date = "2026-11-29", title = "상체")))).obj()
        assertEquals(2, r["summary"]!!.jsonObject["scheduledWorkouts"]!!.jsonPrimitive.int)
        val n = transaction {
            ImportItems.selectAll().where { (ImportItems.entity eq "scheduled_workout") and (ImportItems.batchId eq UUID.fromString(r.str("id")!!)) }.count()
        }
        assertEquals(2L, n)
    }
}

private suspend fun HttpClient.get2(uid: UUID, id: String): JsonObject =
    get("/v1/imports/$id") { auth(uid) }.obj()
