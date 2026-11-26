package com.fitlog.importing

import com.fitlog.core.AppConfig
import com.fitlog.core.Ids
import com.fitlog.core.Times
import com.fitlog.core.dbQuery
import com.fitlog.core.userId
import com.fitlog.core.validation
import io.ktor.http.HttpStatusCode
import io.ktor.server.request.receive
import io.ktor.server.response.respond
import io.ktor.server.routing.Route
import io.ktor.server.routing.get
import io.ktor.server.routing.post
import io.ktor.server.routing.route
import java.util.UUID

private fun contextOf(uid: UUID, req: ImportRequest): ImportContext {
    if (req.channel != null && req.channel != "APP_JSON") validation("channel must be APP_JSON", "channel")
    return ImportContext(uid, ImportChannel.APP_JSON, req.clientName?.trim()?.ifEmpty { null } ?: "직접 입력")
}

/** A1 소유 (v0.3). 등록 위치: /v1 아래, 인증 필요 */
fun Route.importRoutes(config: AppConfig) {
    route("/imports") {
        post("/preview") {
            val uid = call.userId
            val req = call.receive<ImportRequest>()
            call.respond(config.importer.preview(contextOf(uid, req), req))
        }

        post {
            val uid = call.userId
            val req = call.receive<ImportRequest>()
            when (val out = config.importer.import(contextOf(uid, req), req)) {
                is ImportOutcome.Saved -> call.respond(if (out.created) HttpStatusCode.Created else HttpStatusCode.OK, out.batch)
                // 해석: 409 CONFLICT_UNRESOLVED 의 본문은 에러 봉투가 아니라 ImportPreview 그대로(openapi)
                is ImportOutcome.NeedsResolution -> call.respond(HttpStatusCode.Conflict, out.preview)
            }
        }

        get {
            val uid = call.userId
            val before = call.request.queryParameters["before"]?.let { Times.parse(it, "before") }
            val limit = call.request.queryParameters["limit"]?.let {
                it.toIntOrNull()?.takeIf { n -> n in 1..100 } ?: validation("limit must be between 1 and 100", "limit")
            } ?: 20
            call.respond(dbQuery { listImports(uid, before, limit) })
        }

        route("/{id}") {
            get {
                val uid = call.userId
                val id = Ids.parse(call.parameters["id"])
                call.respond(dbQuery { importDetail(uid, id) })
            }
            post("/revert") {
                val uid = call.userId
                val id = Ids.parse(call.parameters["id"])
                call.respond(dbQuery { revertImport(uid, id) })
            }
        }
    }
}
