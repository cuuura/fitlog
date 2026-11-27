package com.fitlog.mcp

import com.fitlog.core.DeletionRequests
import com.fitlog.core.ScheduledWorkouts
import com.fitlog.core.WorkoutSessions
import com.fitlog.oauth.Connected
import com.fitlog.oauth.a2Test
import com.fitlog.oauth.connect
import com.fitlog.oauth.mcpCall
import com.fitlog.oauth.mcpInit
import com.fitlog.oauth.plainClient
import com.fitlog.oauth.result
import com.fitlog.session.exJson
import com.fitlog.session.insertExercise
import com.fitlog.session.newId
import com.fitlog.session.putSession
import com.fitlog.session.sessionJson
import com.fitlog.session.setJson
import io.ktor.client.HttpClient
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.jetbrains.exposed.sql.SqlExpressionBuilder.eq
import org.jetbrains.exposed.sql.selectAll
import org.jetbrains.exposed.sql.transactions.transaction
import org.jetbrains.exposed.sql.update
import java.time.LocalDate
import java.time.ZoneId
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class McpScheduledTest {
    private class Ctx(val c: HttpClient, val conn: Connected, val sid: String) {
        suspend fun call(tool: String, args: String = "{}") = c.mcpCall(conn.access, sid, tool, args).result()
    }

    private suspend fun HttpClient.ctx(write: Boolean = true): Ctx {
        val conn = connect(write = write)
        return Ctx(this, conn, mcpInit(conn.access))
    }

    private fun JsonObject.isError() = this["isError"]!!.jsonPrimitive.boolean
    private fun JsonObject.sc() = this["structuredContent"]!!.jsonObject

    private fun workout(date: String, title: String, exId: UUID, extra: String = "") =
        """{"plannedDate":"$date","title":"$title"$extra,"items":[{"exercise":{"id":"$exId"},"restSec":180,"sets":[{"targetWeightKg":80,"targetReps":12,"targetRepsMax":15,"targetRir":3},{"isWarmup":true,"targetWeightKg":40,"targetReps":8}]}]}"""

    @Test
    fun schedule_workout_saves_and_lists_with_exercise_names() = a2Test {
        val ctx = plainClient().ctx()
        val uid = ctx.conn.userId
        val ex = insertExercise(uid, "BARBELL")
        val today = LocalDate.now(ZoneId.of("Asia/Seoul"))
        val d1 = today.plusDays(2).toString()
        val d2 = today.plusDays(5).toString()

        val r = ctx.call("schedule_workout", """{"workout":${workout(d1, "하체 1", ex)},"note":"AI 계획"}""")
        assertFalse(r.isError(), r.toString())
        assertEquals("SAVED", r.sc()["status"]!!.jsonPrimitive.content)
        val saved = r.sc()["scheduledWorkouts"]!!.jsonArray.single().jsonObject
        assertEquals(d1, saved["plannedDate"]!!.jsonPrimitive.content)
        assertEquals("하체 1", saved["title"]!!.jsonPrimitive.content)
        assertEquals(1, saved["itemCount"]!!.jsonPrimitive.int)
        assertNotNull(r.sc()["batch"])
        val id = UUID.fromString(saved["id"]!!.jsonPrimitive.content)
        transaction {
            val row = ScheduledWorkouts.selectAll().where { ScheduledWorkouts.id eq id }.single()
            assertEquals("AI_MCP", row[ScheduledWorkouts.sourceCol])
            assertEquals(uid, row[ScheduledWorkouts.userId])
        }
        ctx.call("schedule_workout", """{"workout":${workout(d2, "상체", ex)}}""")

        // 기본 범위(오늘~+14일)
        val list = ctx.call("list_scheduled_workouts")
        assertFalse(list.isError(), list.toString())
        assertEquals(2, list.sc()["count"]!!.jsonPrimitive.int)
        val first = list.sc()["scheduledWorkouts"]!!.jsonArray[0].jsonObject
        assertEquals("하체 1", first["title"]!!.jsonPrimitive.content)
        assertEquals("PLANNED", first["status"]!!.jsonPrimitive.content)
        assertEquals(1, first["itemCount"]!!.jsonPrimitive.int)
        val item = first["items"]!!.jsonArray[0].jsonObject
        assertEquals(ex.toString(), item["exerciseId"]!!.jsonPrimitive.content)
        assertTrue(item["exerciseName"]!!.jsonPrimitive.content.isNotBlank())
        assertEquals(15, item["sets"]!!.jsonArray[0].jsonObject["targetRepsMax"]!!.jsonPrimitive.int)

        // 기간·상태 필터
        assertEquals(1, ctx.call("list_scheduled_workouts", """{"from":"$d2","to":"$d2"}""").sc()["count"]!!.jsonPrimitive.int)
        assertEquals(0, ctx.call("list_scheduled_workouts", """{"status":"DONE"}""").sc()["count"]!!.jsonPrimitive.int)
        assertEquals(2, ctx.call("list_scheduled_workouts", """{"status":"PLANNED"}""").sc()["count"]!!.jsonPrimitive.int)
        assertEquals(0, ctx.call("list_scheduled_workouts", """{"from":"${today.plusDays(20)}","to":"${today.plusDays(30)}"}""").sc()["count"]!!.jsonPrimitive.int)

        // 입력 오류
        assertTrue(ctx.call("list_scheduled_workouts", """{"from":"11/28"}""").isError())
        assertTrue(ctx.call("list_scheduled_workouts", """{"from":"2026-12-10","to":"2026-12-01"}""").isError())
        assertTrue(ctx.call("list_scheduled_workouts", """{"from":"2026-01-01","to":"2026-06-01"}""").isError())
        assertTrue(ctx.call("list_scheduled_workouts", """{"status":"NOPE"}""").isError())

        // 상태 계산: 세션이 연결되면 DONE
        val sid = newId()
        ctx.c.putSession(uid, sid, sessionJson(sid, exercises = listOf(exJson(exerciseId = ex, sets = listOf(setJson())))))
        transaction {
            WorkoutSessions.update({ WorkoutSessions.id eq UUID.fromString(sid) }) { it[scheduledWorkoutId] = id }
        }
        val done = ctx.call("list_scheduled_workouts", """{"status":"DONE","from":"$d1","to":"$d1"}""")
        assertEquals(1, done.sc()["count"]!!.jsonPrimitive.int)
        assertEquals(sid, done.sc()["scheduledWorkouts"]!!.jsonArray[0].jsonObject["sessionId"]!!.jsonPrimitive.content)

        // 다른 사용자에게는 보이지 않는다
        val other = plainClient().ctx()
        assertEquals(0, other.call("list_scheduled_workouts").sc()["count"]!!.jsonPrimitive.int)
    }

    @Test
    fun schedule_workout_conflicts_and_validation_errors() = a2Test {
        val ctx = plainClient().ctx()
        val ex = insertExercise(ctx.conn.userId, "BARBELL")
        val d = LocalDate.now(ZoneId.of("Asia/Seoul")).plusDays(1).toString()

        assertFalse(ctx.call("schedule_workout", """{"workout":${workout(d, "중복", ex)}}""").isError())
        // 같은 날 같은 제목은 충돌로 알려 주고 저장하지 않는다
        val again = ctx.call("schedule_workout", """{"workout":${workout(d, "중 복", ex, ",\"note\":\"다른\"")}}""")
        assertFalse(again.isError(), again.toString())
        assertEquals("NEEDS_RESOLUTION", again.sc()["status"]!!.jsonPrimitive.content)
        val cid = again.sc()["conflicts"]!!.jsonArray.single().jsonObject["conflictId"]!!.jsonPrimitive.content
        assertEquals("SCHEDULED_DUPLICATE:/scheduledWorkouts/0", cid)
        assertEquals(1, ctx.call("list_scheduled_workouts", """{"from":"$d","to":"$d"}""").sc()["count"]!!.jsonPrimitive.int)

        val replaced = ctx.call("schedule_workout", """{"workout":${workout(d, "중 복", ex, ",\"note\":\"다른\"")},"resolutions":{"$cid":{"action":"REPLACE"}}}""")
        assertEquals("SAVED", replaced.sc()["status"]!!.jsonPrimitive.content)
        val after = ctx.call("list_scheduled_workouts", """{"from":"$d","to":"$d"}""")
        assertEquals(1, after.sc()["count"]!!.jsonPrimitive.int)
        assertEquals("다른", after.sc()["scheduledWorkouts"]!!.jsonArray[0].jsonObject["note"]!!.jsonPrimitive.content)

        // 검증 오류는 도구 오류
        val bad = ctx.call("schedule_workout", """{"workout":{"plannedDate":"$d","title":"x","items":[{"exercise":{"id":"$ex"},"sets":[{"targetRepsMax":15}]}]}}""")
        assertTrue(bad.isError(), bad.toString())
        assertTrue(ctx.call("schedule_workout", "{}").isError())
        assertTrue(ctx.call("schedule_workout", """{"workout":"x"}""").isError())

        // 읽기 전용 연결은 쓸 수 없다
        val ro = plainClient().ctx(write = false)
        assertTrue(ro.call("schedule_workout", """{"workout":${workout(d, "읽기전용", ex)}}""").isError())
    }

    @Test
    fun skip_scheduled_workout_toggles_and_rejects_unknown() = a2Test {
        val ctx = plainClient().ctx()
        val ex = insertExercise(ctx.conn.userId, "BARBELL")
        val d = LocalDate.now(ZoneId.of("Asia/Seoul")).plusDays(1).toString()
        val saved = ctx.call("schedule_workout", """{"workout":${workout(d, "건너뛸 것", ex)}}""")
        val id = saved.sc()["scheduledWorkouts"]!!.jsonArray.single().jsonObject["id"]!!.jsonPrimitive.content

        val r = ctx.call("skip_scheduled_workout", """{"id":"$id"}""")
        assertFalse(r.isError(), r.toString())
        assertEquals("SKIPPED", r.sc()["scheduledWorkout"]!!.jsonObject["status"]!!.jsonPrimitive.content)
        assertEquals(1, ctx.call("list_scheduled_workouts", """{"status":"SKIPPED"}""").sc()["count"]!!.jsonPrimitive.int)

        val back = ctx.call("skip_scheduled_workout", """{"id":"$id","skipped":false}""")
        assertEquals("PLANNED", back.sc()["scheduledWorkout"]!!.jsonObject["status"]!!.jsonPrimitive.content)
        transaction {
            assertNull(ScheduledWorkouts.selectAll().where { ScheduledWorkouts.id eq UUID.fromString(id) }.single()[ScheduledWorkouts.skippedAt])
        }

        // 없는 것·남의 것·잘못된 인자는 도구 오류
        assertTrue(ctx.call("skip_scheduled_workout", """{"id":"${UUID.randomUUID()}"}""").isError())
        val other = plainClient().ctx()
        assertTrue(other.call("skip_scheduled_workout", """{"id":"$id"}""").isError())
        assertTrue(ctx.call("skip_scheduled_workout", """{"id":"nope"}""").isError())
        assertTrue(ctx.call("skip_scheduled_workout", "{}").isError())
        assertTrue(ctx.call("skip_scheduled_workout", """{"id":"$id","skipped":"yes"}""").isError())
        assertTrue(plainClient().ctx(write = false).call("skip_scheduled_workout", """{"id":"$id"}""").isError())
    }

    @Test
    fun request_deletion_supports_scheduled_workout() = a2Test {
        val ctx = plainClient().ctx()
        val uid = ctx.conn.userId
        val ex = insertExercise(uid, "BARBELL")
        val d = LocalDate.now(ZoneId.of("Asia/Seoul")).plusDays(3).toString()
        val id = ctx.call("schedule_workout", """{"workout":${workout(d, "지울 계획", ex)}}""")
            .sc()["scheduledWorkouts"]!!.jsonArray.single().jsonObject["id"]!!.jsonPrimitive.content

        val r = ctx.call("request_deletion", """{"entity":"scheduled_workout","id":"$id","reason":"계획이 바뀌었어요"}""")
        assertFalse(r.isError(), r.toString())
        assertEquals("PENDING", r.sc()["status"]!!.jsonPrimitive.content)
        val req = r.sc()["request"]!!.jsonObject
        assertEquals("scheduled_workout", req["entity"]!!.jsonPrimitive.content)
        assertTrue(req["label"]!!.jsonPrimitive.content.contains(d) && req["label"]!!.jsonPrimitive.content.contains("지울 계획"))
        transaction {
            val row = DeletionRequests.selectAll().where { DeletionRequests.id eq UUID.fromString(req["id"]!!.jsonPrimitive.content) }.single()
            assertEquals(UUID.fromString(id), row[DeletionRequests.entityId])
            assertEquals("scheduled_workout", row[DeletionRequests.entity])
        }
        // 지워지지 않았다
        assertEquals(1, ctx.call("list_scheduled_workouts", """{"from":"$d","to":"$d"}""").sc()["count"]!!.jsonPrimitive.int)
        // 같은 대상은 기존 요청을 돌려준다
        assertFalse(ctx.call("request_deletion", """{"entity":"scheduled_workout","id":"$id","reason":"다시"}""").sc()["created"]!!.jsonPrimitive.boolean)
        // 없는 것·남의 것은 거절
        assertTrue(ctx.call("request_deletion", """{"entity":"scheduled_workout","id":"${UUID.randomUUID()}","reason":"x"}""").isError())
        assertTrue(plainClient().ctx().call("request_deletion", """{"entity":"scheduled_workout","id":"$id","reason":"x"}""").isError())
    }
}
