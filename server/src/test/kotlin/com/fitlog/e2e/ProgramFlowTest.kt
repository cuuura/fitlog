package com.fitlog.e2e

import com.fitlog.core.Ids
import com.fitlog.support.auth
import com.fitlog.support.createUser
import com.fitlog.support.fitlogTest
import com.fitlog.support.jsonBody
import io.ktor.client.HttpClient
import io.ktor.client.request.get
import io.ktor.client.request.post
import io.ktor.client.request.put
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.HttpStatusCode
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * 실제 엔진으로 v0.2 완료 기준 2~4를 HTTP 로 확인한다(트랙 리드 소유).
 * 템플릿 선택 → 초기 작업 무게 → 계획대로 세션 저장 → 다음 계획 무게 → 지난 세션 수정 시 재계산 → 두 프로그램 격리
 */
class ProgramFlowTest {
    private val stronglifts = "019b76da-5000-7000-8000-000000000001"
    private val nsuns = "019b76da-5000-7000-8000-000000000002"

    private suspend fun HttpClient.json(path: String, uid: UUID): JsonObject =
        Json.parseToJsonElement(get(path) { auth(uid) }.also { check(it.status == HttpStatusCode.OK) { it.bodyAsText() } }.bodyAsText()).jsonObject

    private suspend fun HttpClient.plan(instance: UUID, uid: UUID): JsonObject {
        val res = get("/v1/program-instances/$instance/plan?count=1") { auth(uid) }
        check(res.status == HttpStatusCode.OK) { res.bodyAsText() }
        return Json.parseToJsonElement(res.bodyAsText()).jsonArray[0].jsonObject
    }

    private fun weightOf(plan: JsonObject, key: String): Double =
        plan["exercises"]!!.jsonArray.map { it.jsonObject }.first { it["key"]!!.jsonPrimitive.content == key }["sets"]!!
            .jsonArray[0].jsonObject["targetWeightKg"]!!.jsonPrimitive.double

    /** 계획을 그대로 수행한 세션 본문. repsFor 로 특정 세트 횟수를 바꿀 수 있다 */
    private fun sessionFrom(
        sessionId: UUID, instance: UUID, plan: JsonObject, n: Int,
        repsFor: (String, Int) -> Int = { _, r -> r },
    ): JsonObject {
        val started = "2026-11-%02dT01:00:00Z".format(n)
        val ended = "2026-11-%02dT02:00:00Z".format(n)
        return buildJsonObject {
            put("id", sessionId.toString())
            put("startedAt", started)
            put("endedAt", ended)
            put("tz", "Asia/Seoul")
            put("programInstanceId", instance.toString())
            put("planSeq", plan["planSeq"]!!.jsonPrimitive.int)
            put("planDayKey", plan["dayKey"]!!.jsonPrimitive.content)
            put("exercises", buildJsonArray {
                plan["exercises"]!!.jsonArray.forEachIndexed { ei, e ->
                    val ex = e.jsonObject
                    add(buildJsonObject {
                        put("id", UUID.nameUUIDFromBytes("$sessionId-$ei".toByteArray()).toString())
                        put("exerciseId", ex["exerciseId"]!!.jsonPrimitive.content)
                        put("position", ei)
                        put("liftKey", ex["key"]!!.jsonPrimitive.content)
                        put("accessory", ex["accessory"]!!)
                        put("sets", buildJsonArray {
                            ex["sets"]!!.jsonArray.forEachIndexed { si, s ->
                                val ps = s.jsonObject
                                val key = ps["plannedSetKey"]!!.jsonPrimitive.content
                                val target = ps["targetReps"]!!.jsonPrimitive.int
                                add(buildJsonObject {
                                    put("id", UUID.nameUUIDFromBytes("$sessionId-$ei-$si".toByteArray()).toString())
                                    put("position", si)
                                    ps["targetWeightKg"]?.let { put("weightKg", it); put("targetWeightKg", it) }
                                    put("reps", repsFor(key, target))
                                    put("completedAt", ended)
                                    put("plannedSetKey", key)
                                    put("targetReps", target)
                                    put("isAmrap", ps["isAmrap"]!!)
                                })
                            }
                        })
                    })
                }
            })
        }
    }

    private suspend fun HttpClient.putSession(uid: UUID, body: JsonObject) {
        val res = put("/v1/sessions/${body["id"]!!.jsonPrimitive.content}") { auth(uid); jsonBody(); setBody(body.toString()) }
        check(res.status == HttpStatusCode.OK) { res.bodyAsText() }
    }

    private suspend fun HttpClient.start(uid: UUID, programId: String, values: JsonObject): UUID {
        val id = Ids.newId()
        val body = buildJsonObject {
            put("id", id.toString()); put("programId", programId); put("startDate", "2026-11-01"); put("tz", "Asia/Seoul")
            values.forEach { (k, v) -> put(k, v) }
        }
        val res = post("/v1/program-instances") { auth(uid); jsonBody(); setBody(body.toString()) }
        check(res.status == HttpStatusCode.Created) { res.bodyAsText() }
        return id
    }

    @Test
    fun stronglifts_progresses_recomputes_on_edit_and_stays_isolated() = fitlogTest {
        startApplication()
        val uid = createUser()
        // 템플릿 목록에 5종이 있다
        val templates = Json.parseToJsonElement(client.get("/v1/programs?source=TEMPLATE") { auth(uid) }.bodyAsText()).jsonArray
        val ids = templates.map { it.jsonObject["id"]!!.jsonPrimitive.content }.toSet()
        // 다른 테스트가 같은 DB 에 템플릿 행을 넣을 수 있어 고정 id 5개 포함만 확인
        assertTrue((1..5).all { "019b76da-5000-7000-8000-00000000000$it" in ids }, ids.toString())

        val sl = client.start(uid, stronglifts, buildJsonObject {
            put("working", buildJsonObject { put("squat", 100); put("bench", 60); put("row", 50); put("ohp", 40); put("deadlift", 120) })
        })
        val ns = client.start(uid, nsuns, buildJsonObject {
            put("tm", buildJsonObject { put("bench", 80); put("ohp", 50); put("squat", 120); put("deadlift", 150) })
        })
        val nsBefore = client.json("/v1/program-instances/$ns", uid)["state"]

        // 3회차를 계획대로 모두 성공
        val sessions = mutableListOf<Pair<UUID, JsonObject>>()
        for (n in 1..3) {
            val plan = client.plan(sl, uid)
            assertEquals(100.0 + 2.5 * (n - 1), weightOf(plan, "squat"), "session $n squat plan")
            val sid = Ids.newId()
            client.putSession(uid, sessionFrom(sid, sl, plan, n))
            sessions += sid to plan
        }
        // A, B, A 뒤: 스쿼트 +7.5, 벤치 +5(A 2회), 데드 +5(B 1회)
        var next = client.plan(sl, uid)
        assertEquals("B", next["dayKey"]!!.jsonPrimitive.content)
        assertEquals(107.5, weightOf(next, "squat"))
        assertEquals(125.0, weightOf(next, "deadlift"))

        // 1회차 스쿼트 마지막 세트를 5→3으로 고치면 재계산: 스쿼트 증가가 1회 빠진다
        val (firstId, firstPlan) = sessions[0]
        client.putSession(uid, sessionFrom(firstId, sl, firstPlan, 1) { key, r -> if (key == "A.0.4") 3 else r })
        next = client.plan(sl, uid)
        assertEquals(105.0, weightOf(next, "squat"))
        val st = client.json("/v1/program-instances/$sl", uid)["state"]!!.jsonObject
        assertEquals(0, st["failStreak"]?.jsonObject?.get("squat")?.jsonPrimitive?.int ?: 0)

        // 다른 프로그램(nSuns)의 상태는 그대로
        assertEquals(nsBefore, client.json("/v1/program-instances/$ns", uid)["state"])
    }
}
