package com.fitlog.importing

import com.fitlog.session.obj
import com.fitlog.session.str
import com.fitlog.support.auth
import com.fitlog.support.createUser
import com.fitlog.support.fitlogTest
import com.fitlog.support.jsonBody
import com.fitlog.support.jsonClient
import io.ktor.client.HttpClient
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.HttpResponse
import io.ktor.http.HttpStatusCode
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

private fun resource(name: String) = CsvImportTest::class.java.getResource("/csv/$name")!!.readText()

private suspend fun HttpClient.csv(
    uid: UUID, format: String, text: String, unit: String? = null,
): HttpResponse = post("/v1/imports/csv/preview") {
    auth(uid); jsonBody()
    setBody(buildJsonObject {
        put("format", format); put("csv", text); put("tz", "Asia/Seoul")
        if (unit != null) put("weightUnit", unit)
    }.toString())
}

private fun JsonObject.sets(): List<JsonObject> =
    this["sessions"]!!.jsonArray.flatMap { it.jsonObject["exercises"]!!.jsonArray }.flatMap { it.jsonObject["sets"]!!.jsonArray }.map { it.jsonObject }

class CsvImportTest {
    @Test
    fun tokenizer_handles_bom_crlf_quotes_and_semicolons() {
        val recs = CsvImport.tokenize("﻿a;b;c\r\n1;\"x;y\";\"line1\nline2 \"\"q\"\"\"\r\n")
        assertEquals(2, recs.size)
        assertEquals(listOf("a", "b", "c"), recs[0].fields)
        assertEquals(listOf("1", "x;y", "line1\nline2 \"q\""), recs[1].fields)
        assertEquals(2, recs[1].line)
        assertEquals(listOf("a", "b"), CsvImport.tokenize("a,b\n").single().fields)
    }

    @Test
    fun duration_parsing_accepts_strong_formats() {
        assertEquals(3900, CsvImport.parseDuration("1h 5m"))
        assertEquals(3000, CsvImport.parseDuration("50m"))
        assertEquals(3600, CsvImport.parseDuration("1h"))
        assertEquals(90, CsvImport.parseDuration("90"))
        assertEquals(null, CsvImport.parseDuration("abc"))
    }

    @Test
    fun dictionary_has_enough_names_and_maps_equipment_variants() {
        assertTrue(CsvExerciseDictionary.size >= 60)
        fun seed(n: String) = CsvExerciseDictionary.seedFor(CsvExerciseDictionary.normalize(n))
        assertEquals(0x03, seed("Bench Press (Barbell)"))
        assertEquals(0x13, seed("Bench Press (Dumbbell)"))
        assertEquals(0x3c, seed("pull up"))
        assertEquals(0x2d, seed("Triceps Pushdown (Cable - Straight Bar)"))
        assertEquals(null, seed("Bench Press (Kettlebell)"))
        assertEquals("BICEPS", CsvExerciseDictionary.muscleFor(CsvExerciseDictionary.normalize("Preacher Curl")))
        assertEquals("FULL_BODY", CsvExerciseDictionary.muscleFor(CsvExerciseDictionary.normalize("Zottman Curl")))
    }

    @Test
    fun strong_sample_maps_set_orders_and_new_exercises() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val res = c.csv(uid, "STRONG", resource("strong-sample.csv"))
        assertEquals(HttpStatusCode.OK, res.status)
        val body = res.obj()
        val sum = body["csv"]!!.jsonObject
        assertEquals("STRONG", sum.str("format"))
        assertEquals(2, sum["sessions"]!!.jsonPrimitive.int)
        assertEquals(15, sum["sets"]!!.jsonPrimitive.int)
        assertEquals(6, sum["matchedExercises"]!!.jsonPrimitive.int)
        assertEquals(listOf("Zottman Curl (Dumbbell)"), sum["newExercises"]!!.jsonArray.map { it.jsonPrimitive.content })
        assertEquals(listOf(10, 18), sum["skippedRows"]!!.jsonArray.map { it.jsonObject["line"]!!.jsonPrimitive.int })
        val chunk = body["chunks"]!!.jsonArray.single().jsonObject
        assertEquals("true", chunk["preview"]!!.jsonObject["valid"]!!.toString())
        val bundle = chunk["bundle"]!!.jsonObject
        val newEx = bundle["exercises"]!!.jsonArray.single().jsonObject
        assertEquals("FULL_BODY", newEx.str("primaryMuscle"))
        assertEquals("DUMBBELL", newEx.str("type"))
        val sets = bundle.sets()
        assertEquals(1, sets.count { it["isWarmup"]?.toString() == "true" })
        assertEquals(1, sets.count { it.str("setType") == "DROP" })
        assertEquals(2, sets.count { it.str("setType") == "FAILURE" })
        assertEquals(bundle, c.csv(uid, "AUTO", resource("strong-sample.csv")).obj()["chunks"]!!.jsonArray[0].jsonObject["bundle"])
    }

    @Test
    fun hevy_sample_maps_superset_set_type_and_distance() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val body = c.csv(uid, "AUTO", resource("hevy-sample.csv")).obj()
        val sum = body["csv"]!!.jsonObject
        assertEquals("HEVY", sum.str("format"))
        assertEquals(2, sum["sessions"]!!.jsonPrimitive.int)
        assertEquals(10, sum["sets"]!!.jsonPrimitive.int)
        assertEquals(listOf("Cable Woodchop"), sum["newExercises"]!!.jsonArray.map { it.jsonPrimitive.content })
        assertEquals(1, sum["skippedRows"]!!.jsonArray.size)
        val bundle = body["chunks"]!!.jsonArray.single().jsonObject["bundle"]!!.jsonObject
        val exs = bundle["sessions"]!!.jsonArray[0].jsonObject["exercises"]!!.jsonArray.map { it.jsonObject }
        assertEquals(listOf("1", "1", null, null, null), exs.map { it.str("supersetGroup") })
        val sets = bundle.sets()
        assertEquals(1, sets.count { it["isWarmup"]?.toString() == "true" })
        assertEquals(1, sets.count { it.str("setType") == "DROP" })
        assertEquals(1, sets.count { it.str("setType") == "FAILURE" })
        assertTrue(sets.any { it["distanceM"]?.jsonPrimitive?.content == "3200.0" && it["durationSec"]?.jsonPrimitive?.int == 1000 })
    }

    @Test
    fun lb_weight_unit_is_converted_and_semicolons_work() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val text = "Date;Workout Name;Duration;Exercise Name;Set Order;Weight;Reps;Distance;Seconds;Notes;Workout Notes;RPE\r\n" +
            "2024-03-04 18:30:12;Push;1h;Bench Press (Barbell);1;225;5;0;0;;;\r\n"
        val body = c.csv(uid, "STRONG", "﻿$text", "LB").obj()
        val w = body["chunks"]!!.jsonArray[0].jsonObject["bundle"]!!.jsonObject.sets().single()["weightKg"]!!.jsonPrimitive.content
        assertEquals("102.06", w)
    }

    @Test
    fun csv_errors_are_reported() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        assertEquals(HttpStatusCode.BadRequest, c.csv(uid, "AUTO", "a,b\n1,2\n").status)
        assertEquals(HttpStatusCode.BadRequest, c.csv(uid, "NOPE", "a").status)
        val big = "x".repeat(4 * 1024 * 1024 + 10)
        assertEquals(HttpStatusCode.PayloadTooLarge, c.csv(uid, "STRONG", big).status)
    }

    @Test
    fun large_csv_splits_into_two_chunks_and_second_preview_shows_existing_ids() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val sb = StringBuilder("Date,Workout Name,Duration,Exercise Name,Set Order,Weight,Reps,Distance,Seconds,Notes,Workout Notes,RPE\n")
        val base = java.time.LocalDate.of(2020, 1, 1)
        for (d in 0 until 250) {
            val date = base.plusDays(d.toLong())
            for (ex in listOf("Bench Press (Barbell)", "Squat (Barbell)")) for (s in 1..3) {
                sb.append("$date 18:00:00,Workout,45m,$ex,$s,${60 + s},5,0,0,,,\n")
            }
        }
        val body = c.csv(uid, "STRONG", sb.toString()).obj()
        assertEquals(250, body["csv"]!!.jsonObject["sessions"]!!.jsonPrimitive.int)
        val chunks = body["chunks"]!!.jsonArray.map { it.jsonObject }
        assertEquals(2, chunks.size)
        assertEquals(200, chunks[0]["bundle"]!!.jsonObject["sessions"]!!.jsonArray.size)
        assertEquals(50, chunks[1]["bundle"]!!.jsonObject["sessions"]!!.jsonArray.size)
        fun count(chunk: JsonObject, kind: String) =
            chunk["preview"]!!.jsonObject["counts"]!!.jsonObject["sessions"]!!.jsonObject[kind]?.jsonPrimitive?.int ?: 0
        assertEquals(200, count(chunks[0], "NEW"))
        val commit = c.post("/v1/imports") { auth(uid); jsonBody(); setBody("""{"bundle":${chunks[0]["bundle"]},"tz":"Asia/Seoul"}""") }
        assertEquals(HttpStatusCode.Created, commit.status)
        val again = c.csv(uid, "STRONG", sb.toString()).obj()["chunks"]!!.jsonArray.map { it.jsonObject }
        assertEquals(200, count(again[0], "UNCHANGED"))
        assertEquals(50, count(again[1], "NEW"))
    }
}
