package com.fitlog.session

import com.fitlog.support.auth
import com.fitlog.support.createUser
import com.fitlog.support.fitlogTest
import com.fitlog.support.jsonBody
import com.fitlog.support.jsonClient
import io.ktor.client.request.get
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.HttpStatusCode
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class SupersetSetTypeTest {
    private fun exWith(id: String, ex: java.util.UUID, group: String?, types: List<String>): String {
        val sets = types.mapIndexed { i, t -> setJson(position = i, extra = """"setType":"$t"""") }
        val g = if (group != null) ""","supersetGroup":"$group"""" else ""
        return exJson(id, ex, 0, sets).replaceFirst("\"position\":0", "\"position\":0$g")
    }

    @Test
    fun put_session_round_trips_superset_group_and_set_type() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val ex = insertExercise(uid)
        val sid = newId()
        val body = sessionJson(sid, exercises = listOf(exWith(newId(), ex, "A", listOf("NORMAL", "DROP", "FAILURE"))))
        assertEquals(HttpStatusCode.OK, c.putSession(uid, sid, body).status)
        val s = c.getSession(uid, sid).obj()
        val e = s["exercises"]!!.jsonArray[0].jsonObject
        assertEquals("A", e.str("supersetGroup"))
        assertEquals(listOf("NORMAL", "DROP", "FAILURE"), e["sets"]!!.jsonArray.map { it.str("setType") })
    }

    @Test
    fun invalid_set_type_and_superset_group_are_rejected_with_validation_failed() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val ex = insertExercise(uid)
        val sid = newId()
        val bad = c.putSession(uid, sid, sessionJson(sid, exercises = listOf(exWith(newId(), ex, null, listOf("SUPER")))))
        assertEquals(HttpStatusCode.BadRequest, bad.status)
        assertEquals("VALIDATION_FAILED", bad.obj()["error"]!!.str("code"))
        val long = c.putSession(uid, sid, sessionJson(sid, exercises = listOf(exWith(newId(), ex, "123456789", listOf("NORMAL")))))
        assertEquals(HttpStatusCode.BadRequest, long.status)
        assertEquals("VALIDATION_FAILED", long.obj()["error"]!!.str("code"))
    }

    @Test
    fun sync_push_and_pull_round_trip_superset_group_and_set_type() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val ex = insertExercise(uid)
        val t = "2026-11-26T10:00:00Z"
        val sid = newId(); val se = newId(); val w1 = newId(); val w2 = newId()
        val res = c.push(
            uid,
            change("workout_session", sid, at = t, payload = """{"startedAt":"$t","tz":"Asia/Seoul"}"""),
            change("session_exercise", se, at = t, parentId = sid, payload = """{"exerciseId":"$ex","position":0,"supersetGroup":"B"}"""),
            change("workout_set", w1, at = t, parentId = se, payload = """{"position":0,"weightKg":100,"reps":5,"setType":"DROP","completedAt":"$t"}"""),
            change("workout_set", w2, at = t, parentId = se, payload = """{"position":1,"weightKg":100,"reps":5,"setType":"BOGUS","completedAt":"$t"}"""),
        ).obj()["results"]!!.jsonArray.map { it.jsonObject }
        assertEquals(listOf("applied", "applied", "applied", "rejected"), res.map { it.str("status") })
        assertEquals("VALIDATION_FAILED", res[3].str("code"))
        val changes = c.pull(uid, 0).obj()["changes"]!!.jsonArray.map { it.jsonObject }
        val seCh = changes.first { it.str("entity") == "session_exercise" }
        assertEquals("B", seCh["payload"]!!.str("supersetGroup"))
        val setCh = changes.first { it.str("entity") == "workout_set" }
        assertEquals("DROP", setCh["payload"]!!.str("setType"))
    }

    @Test
    fun export_json_and_csv_include_superset_group_and_set_type() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val ex = insertExercise(uid)
        val sid = newId()
        c.putSession(uid, sid, sessionJson(sid, exercises = listOf(exWith(newId(), ex, "C", listOf("DROP")))))
        val json = c.get("/v1/export.json") { auth(uid) }.bodyAsText()
        assertTrue(json.contains("\"supersetGroup\":\"C\"") && json.contains("\"setType\":\"DROP\""), json)
        val csv = c.get("/v1/export.csv?kind=sets") { auth(uid) }.bodyAsText().removePrefix("﻿").lines()
        assertTrue(csv[0].endsWith(",superset_group,set_type"))
        assertTrue(csv[1].endsWith(",C,DROP"), csv[1])
    }

    @Test
    fun import_bundle_accepts_set_type_and_superset_group_and_rejects_bad_values() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val sid = newId()
        fun bundle(type: String, group: String) =
            """{"bundle":{"schemaVersion":1,"sessions":[{"id":"$sid","startedAt":"2026-11-26T10:00:00Z","tz":"Asia/Seoul","exercises":[{"exercise":{"id":"019b76da-4000-7000-8000-000000000003"},"supersetGroup":"$group","sets":[{"weightKg":100,"reps":5,"setType":"$type"}]}]}]}}"""
        val bad = c.post("/v1/imports/preview") { auth(uid); jsonBody(); setBody(bundle("NOPE", "A")) }
        assertEquals(HttpStatusCode.BadRequest, bad.status)
        val bad2 = c.post("/v1/imports/preview") { auth(uid); jsonBody(); setBody(bundle("DROP", "123456789")) }
        assertEquals(HttpStatusCode.BadRequest, bad2.status)
        assertEquals(HttpStatusCode.Created, c.post("/v1/imports") { auth(uid); jsonBody(); setBody(bundle("DROP", "A")) }.status)
        val s = c.getSession(uid, sid).obj()["exercises"]!!.jsonArray[0].jsonObject
        assertEquals("A", s.str("supersetGroup"))
        assertEquals("DROP", s["sets"]!!.jsonArray[0].str("setType"))
        val same = c.post("/v1/imports/preview") { auth(uid); jsonBody(); setBody(bundle("DROP", "A")) }.obj()
        assertEquals("1", same["counts"]!!.jsonObject["sessions"]!!.jsonObject["UNCHANGED"]!!.toString())
        val diff = c.post("/v1/imports/preview") { auth(uid); jsonBody(); setBody(bundle("FAILURE", "A")) }.obj()
        assertTrue(diff["counts"]!!.jsonObject["sessions"]?.jsonObject?.get("UNCHANGED") == null, diff.toString())
    }
}
