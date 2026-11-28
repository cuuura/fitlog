package com.fitlog.mcp

import com.fitlog.oauth.a2Test
import com.fitlog.oauth.connect
import com.fitlog.oauth.mcpCall
import com.fitlog.oauth.mcpInit
import com.fitlog.oauth.plainClient
import com.fitlog.oauth.result
import com.fitlog.program.catalog.ProgramTemplates
import com.fitlog.session.insertExercise
import com.fitlog.session.newId
import com.fitlog.support.auth
import com.fitlog.support.jsonBody
import io.ktor.client.HttpClient
import io.ktor.client.request.get
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.HttpStatusCode
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** v1.2 AI-4 도구: get_program_analysis, update_program, edit_program_instance */
class McpEditToolsTest {
    private fun JsonObject.isError() = this["isError"]!!.jsonPrimitive.boolean
    private fun JsonObject.sc() = this["structuredContent"]!!.jsonObject

    @Test
    fun analysis_update_and_edit_tools() = a2Test {
        val c: HttpClient = plainClient()
        val conn = c.connect(write = true)
        val sid = c.mcpInit(conn.access)
        suspend fun call(tool: String, args: String) = c.mcpCall(conn.access, sid, tool, args).result()
        val uid = conn.userId

        // 내 프로그램: 템플릿 정의를 복사해 만든다
        val tpl = Json.parseToJsonElement(c.get("/v1/programs/${ProgramTemplates.idOf("stronglifts-5x5")}") { auth(uid) }.bodyAsText()).jsonObject
        val def = JsonObject(tpl["definition"]!!.jsonObject.filterKeys { it != "family" && it != "variantLabel" })
        val pid = newId()
        val created = c.post("/v1/programs") { auth(uid); jsonBody(); setBody("""{"id":"$pid","definition":$def}""") }
        assertEquals(HttpStatusCode.Created, created.status, created.bodyAsText())
        val iid = newId()
        val started = c.post("/v1/program-instances") {
            auth(uid); jsonBody()
            setBody("""{"id":"$iid","programId":"$pid","startDate":"2026-11-02","tz":"Asia/Seoul","working":{"squat":100,"bench":60,"row":50,"ohp":40,"deadlift":120}}""")
        }
        assertEquals(HttpStatusCode.Created, started.status, started.bodyAsText())

        val an = call("get_program_analysis", """{"instanceId":"$iid","sessions":3}""")
        assertFalse(an.isError(), an.toString())
        val a = an.sc()["analysis"]!!.jsonObject
        assertTrue(a["lifts"]!!.jsonArray.isNotEmpty())
        assertEquals(0, a["adherence"]!!.jsonObject["completed"]!!.jsonPrimitive.content.toInt())
        assertTrue(call("get_program_analysis", """{"instanceId":"${UUID.randomUUID()}"}""").isError())
        assertTrue(call("get_program_analysis", """{"instanceId":"$iid","sessions":99}""").isError())

        // update_program
        val renamed = call("update_program", """{"programId":"$pid","definition":$def,"name":"AI 수정본"}""")
        assertFalse(renamed.isError(), renamed.toString())
        assertEquals("AI 수정본", renamed.sc()["program"]!!.jsonObject["name"]!!.jsonPrimitive.content)
        assertEquals(listOf(iid), renamed.sc()["program"]!!.jsonObject["activeInstanceIds"]!!.jsonArray.map { it.jsonPrimitive.content })
        assertTrue(call("update_program", """{"programId":"${ProgramTemplates.idOf("stronglifts-5x5")}","definition":$def}""").isError())

        // edit_program_instance: definition / swap, 둘 다·둘 다 없음은 오류
        val newDef = JsonObject(def + ("name" to JsonPrimitive("진행 중 수정")))
        val edited = call("edit_program_instance", """{"instanceId":"$iid","definition":$newDef}""")
        assertFalse(edited.isError(), edited.toString())
        assertEquals("진행 중 수정", edited.sc()["instance"]!!.jsonObject["name"]!!.jsonPrimitive.content)
        val ex = insertExercise(null, "BARBELL")
        val swapped = call("edit_program_instance", """{"instanceId":"$iid","swap":{"liftKey":"squat","exerciseId":"$ex"}}""")
        assertFalse(swapped.isError(), swapped.toString())
        val squat = swapped.sc()["instance"]!!.jsonObject["next"]!!.jsonObject["exercises"]!!.jsonArray
            .map { it.jsonObject }.first { it["key"]!!.jsonPrimitive.content == "squat" }
        assertEquals(ex.toString(), squat["exerciseId"]!!.jsonPrimitive.content)
        assertTrue(call("edit_program_instance", """{"instanceId":"$iid"}""").isError())
        assertTrue(call("edit_program_instance", """{"instanceId":"$iid","definition":$newDef,"swap":{"liftKey":"squat","exerciseId":"$ex"}}""").isError())
        assertTrue(call("edit_program_instance", """{"instanceId":"$iid","swap":{"liftKey":"nope","exerciseId":"$ex"}}""").isError())
    }
}
