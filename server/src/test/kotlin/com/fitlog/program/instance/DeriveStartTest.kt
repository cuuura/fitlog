package com.fitlog.program.instance

import com.fitlog.core.Ids
import com.fitlog.support.auth
import com.fitlog.support.createUser
import com.fitlog.support.fitlogTest
import com.fitlog.support.jsonBody
import io.ktor.client.request.get
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.HttpStatusCode
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.double
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** v1.1 4절: 실제 엔진·템플릿(gzclp)으로 derive 키를 비우고 시작, suggest 응답 */
class DeriveStartTest {
    private val gzclp = "019b76da-5000-7000-8000-000000000004"

    private val tm = """"tm":{"pulldown":50,"db_row":20}"""
    private val baseWorking = """"squat_t1":100,"bench_t1":70,"ohp_t1":41,"deadlift_t1":120"""

    @Test
    fun start_may_omit_derive_keys_and_engine_fills_them() = fitlogTest {
        startApplication()
        val uid = createUser()
        val id = Ids.newId()
        val res = client.post("/v1/program-instances") {
            auth(uid); jsonBody()
            setBody("""{"id":"$id","programId":"$gzclp","startDate":"2026-12-01","tz":"Asia/Seoul",$tm,"working":{$baseWorking}}""")
        }
        assertEquals(HttpStatusCode.Created, res.status, res.bodyAsText())
        val plan = Json.parseToJsonElement(client.get("/v1/program-instances/$id/plan?count=1") { auth(uid) }.bodyAsText()).jsonArray[0].jsonObject
        val bench = plan["exercises"]!!.jsonArray.map { it.jsonObject }.first { it["key"]!!.jsonPrimitive.content == "bench_t2" }
        // 70 x 0.65 = 45.5 -> 2.5 단위 내림 45.0
        assertEquals(45.0, bench["sets"]!!.jsonArray[0].jsonObject["targetWeightKg"]!!.jsonPrimitive.double)
    }

    @Test
    fun start_still_requires_non_derive_keys_and_accepts_user_override() = fitlogTest {
        startApplication()
        val uid = createUser()
        val missing = client.post("/v1/program-instances") {
            auth(uid); jsonBody()
            setBody("""{"id":"${Ids.newId()}","programId":"$gzclp","startDate":"2026-12-01","tz":"Asia/Seoul",$tm,"working":{"squat_t1":100}}""")
        }
        assertEquals(HttpStatusCode.BadRequest, missing.status)
        val body = missing.bodyAsText()
        assertTrue(Regex("working\\.(bench_t1|ohp_t1|deadlift_t1)").containsMatchIn(body), body)
        assertTrue(!body.contains("_t2"), body)
        val id = Ids.newId()
        val ok = client.post("/v1/program-instances") {
            auth(uid); jsonBody()
            setBody("""{"id":"$id","programId":"$gzclp","startDate":"2026-12-01","tz":"Asia/Seoul",$tm,"working":{$baseWorking,"bench_t2":60}}""")
        }
        assertEquals(HttpStatusCode.Created, ok.status, ok.bodyAsText())
    }

    @Test
    fun suggest_reports_derived_from_and_optional() = fitlogTest {
        startApplication()
        val uid = createUser()
        val res = client.get("/v1/programs/$gzclp/suggest") { auth(uid) }
        assertEquals(HttpStatusCode.OK, res.status)
        val items = Json.parseToJsonElement(res.bodyAsText()).jsonArray.map { it.jsonObject }.associateBy { it["key"]!!.jsonPrimitive.content }
        val t2 = items["squat_t2"]!!
        assertEquals("squat_t1", t2["derivedFrom"]!!.jsonPrimitive.content)
        assertEquals(0.65, t2["derivedRatio"]!!.jsonPrimitive.double)
        assertEquals("true", t2["optional"]!!.jsonPrimitive.content)
        val t1 = items["squat_t1"]!!
        assertNull(t1["derivedFrom"])
        assertNull(t1["optional"])
    }
}
