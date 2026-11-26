package com.fitlog.sync

import com.fitlog.core.AppConfig
import com.fitlog.core.dbQuery
import com.fitlog.core.userId
import com.fitlog.core.validation
import io.ktor.server.request.receive
import io.ktor.server.response.respond
import io.ktor.server.routing.Route
import io.ktor.server.routing.get
import io.ktor.server.routing.post

/** A3 소유. 경로는 /v1 아래 상대 경로로 등록한다 */
fun Route.syncRoutes(config: AppConfig) {
    post("/sync/push") {
        val uid = call.userId
        val req = call.receive<PushRequest>()
        if (req.changes.size > MAX_PUSH) validation("changes must have at most $MAX_PUSH items", "changes")
        val results = dbQuery { push(uid, req.changes) }
        call.respond(PushResponse(results))
    }

    get("/sync/pull") {
        val uid = call.userId
        val raw = call.request.queryParameters["since"] ?: validation("since is required", "since")
        val since = raw.toLongOrNull()?.takeIf { it >= 0 } ?: validation("since must be an integer >= 0", "since")
        call.respond(dbQuery { pull(uid, since) })
    }
}
