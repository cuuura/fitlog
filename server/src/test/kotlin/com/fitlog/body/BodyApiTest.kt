package com.fitlog.body

import com.fitlog.session.arr
import com.fitlog.session.newId
import com.fitlog.session.obj
import com.fitlog.session.str
import com.fitlog.support.auth
import com.fitlog.support.createUser
import com.fitlog.support.fitlogTest
import com.fitlog.support.jsonBody
import com.fitlog.support.jsonClient
import io.ktor.client.HttpClient
import io.ktor.client.request.delete
import io.ktor.client.request.get
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.HttpResponse
import io.ktor.http.HttpStatusCode
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals

class BodyApiTest {
    private suspend fun HttpClient.postM(uid: UUID, id: String, at: String, weight: String, extra: String = ""): HttpResponse =
        post("/v1/body/measurements") {
            auth(uid); jsonBody()
            setBody("""{"id":"$id","measuredAt":"$at","weightKg":$weight$extra}""")
        }

    @Test
    fun post_creates_with_default_source_and_rounding_then_upserts_same_id() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val id = newId()
        val created = c.postM(uid, id, "2026-11-26T07:00:00Z", "72.456")
        assertEquals(HttpStatusCode.Created, created.status)
        val b = created.obj()
        assertEquals("72.46", b.str("weightKg"))
        assertEquals("MANUAL", b.str("source"))

        val again = c.postM(uid, id, "2026-11-26T07:00:00Z", "71.9", ""","source":"OCR"""")
        assertEquals(HttpStatusCode.Created, again.status)
        val list = c.get("/v1/body/measurements") { auth(uid) }.arr()
        assertEquals(1, list.size)
        assertEquals("71.9", list[0].str("weightKg"))
        assertEquals("OCR", list[0].str("source"))
    }

    @Test
    fun weight_and_source_are_validated() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        for (w in listOf("19.99", "400.01", "0", "-5")) {
            val res = c.postM(uid, newId(), "2026-11-26T07:00:00Z", w)
            assertEquals(HttpStatusCode.BadRequest, res.status, w)
            assertEquals("weightKg", res.obj()["error"]!!.str("field"))
        }
        assertEquals(HttpStatusCode.Created, c.postM(uid, newId(), "2026-11-26T07:00:00Z", "20").status)
        assertEquals(HttpStatusCode.Created, c.postM(uid, newId(), "2026-11-26T07:00:00Z", "400").status)
        val bad = c.postM(uid, newId(), "2026-11-26T07:00:00Z", "70", ""","source":"FOO"""")
        assertEquals(HttpStatusCode.BadRequest, bad.status)
        assertEquals("source", bad.obj()["error"]!!.str("field"))
    }

    @Test
    fun list_filters_by_range_orders_desc_and_excludes_deleted() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val uid = createUser()
        val a = newId()
        val b = newId()
        val d = newId()
        val gone = newId()
        c.postM(uid, a, "2026-11-20T07:00:00Z", "70")
        c.postM(uid, b, "2026-11-22T07:00:00Z", "71")
        c.postM(uid, d, "2026-11-24T07:00:00Z", "72")
        c.postM(uid, gone, "2026-11-23T07:00:00Z", "99")
        assertEquals(HttpStatusCode.NoContent, c.delete("/v1/body/measurements/$gone") { auth(uid) }.status)
        assertEquals(HttpStatusCode.NoContent, c.delete("/v1/body/measurements/$gone") { auth(uid) }.status)
        assertEquals(HttpStatusCode.NoContent, c.delete("/v1/body/measurements/${newId()}") { auth(uid) }.status)

        val all = c.get("/v1/body/measurements") { auth(uid) }.arr()
        assertEquals(listOf(d, b, a), all.map { it.str("id") })
        val ranged = c.get("/v1/body/measurements?from=2026-11-21T00:00:00Z&to=2026-11-24T07:00:00Z") { auth(uid) }.arr()
        assertEquals(listOf(d, b), ranged.map { it.str("id") })
    }

    @Test
    fun measurements_are_isolated_between_users() = fitlogTest {
        startApplication()
        val c = jsonClient()
        val owner = createUser()
        val other = createUser()
        val id = newId()
        c.postM(owner, id, "2026-11-26T07:00:00Z", "70")
        assertEquals(0, c.get("/v1/body/measurements") { auth(other) }.arr().size)
        assertEquals(HttpStatusCode.NotFound, c.postM(other, id, "2026-11-26T07:00:00Z", "80").status)
        assertEquals(HttpStatusCode.NotFound, c.delete("/v1/body/measurements/$id") { auth(other) }.status)
        assertEquals("70.0", c.get("/v1/body/measurements") { auth(owner) }.arr()[0].str("weightKg"))
    }
}
