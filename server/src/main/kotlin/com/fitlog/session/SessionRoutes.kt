package com.fitlog.session

import com.fitlog.core.AppConfig
import com.fitlog.core.Ids
import com.fitlog.core.Times
import com.fitlog.core.dbQuery
import com.fitlog.core.lockUser
import com.fitlog.core.notFound
import com.fitlog.core.userId
import com.fitlog.core.validation
import io.ktor.http.HttpStatusCode
import io.ktor.server.request.receive
import io.ktor.server.response.respond
import io.ktor.server.routing.Route
import io.ktor.server.routing.delete
import io.ktor.server.routing.get
import io.ktor.server.routing.put

/** A3 소유. 경로는 /v1 아래 상대 경로로 등록한다 */
fun Route.sessionRoutes(config: AppConfig) {
    get("/sessions") {
        val uid = call.userId
        val before = call.request.queryParameters["before"]?.let { Times.parse(it, "before") }
        val limit = call.request.queryParameters["limit"]?.let {
            it.toIntOrNull()?.takeIf { n -> n in 1..100 } ?: validation("limit must be between 1 and 100", "limit")
        } ?: 20
        call.respond(dbQuery { listSummaries(uid, before, limit) })
    }

    get("/sessions/{id}") {
        val uid = call.userId
        val id = Ids.parse(call.parameters["id"])
        call.respond(dbQuery { loadSession(uid, id) } ?: notFound("session not found"))
    }

    put("/sessions/{id}") {
        val uid = call.userId
        val id = Ids.parse(call.parameters["id"])
        val body = call.receive<Session>()
        if (body.id != id) validation("path id and body id differ", "id")
        val saved = dbQuery {
            lockUser(uid)
            putSession(uid, id, body)
        }
        call.respond(HttpStatusCode.OK, saved)
    }

    delete("/sessions/{id}") {
        val uid = call.userId
        val id = Ids.parse(call.parameters["id"])
        dbQuery {
            lockUser(uid)
            deleteSessionRest(uid, id)
        }
        call.respond(HttpStatusCode.NoContent)
    }

    get("/exercises/{id}/last") {
        val uid = call.userId
        val id = Ids.parse(call.parameters["id"])
        call.respond(dbQuery { lastSetsFor(uid, id) } ?: notFound("no sets recorded for this exercise"))
    }
}
