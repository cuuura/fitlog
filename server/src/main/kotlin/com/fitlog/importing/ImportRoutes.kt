package com.fitlog.importing

import com.fitlog.core.AppConfig
import com.fitlog.core.ErrorBody
import com.fitlog.core.ErrorResponse
import com.fitlog.core.Exercises
import com.fitlog.core.Ids
import com.fitlog.core.Times
import com.fitlog.core.dbQuery
import com.fitlog.core.userId
import com.fitlog.core.validation
import io.ktor.http.HttpStatusCode
import org.jetbrains.exposed.sql.SqlExpressionBuilder.eq
import org.jetbrains.exposed.sql.SqlExpressionBuilder.isNull
import org.jetbrains.exposed.sql.and
import org.jetbrains.exposed.sql.or
import org.jetbrains.exposed.sql.selectAll
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

private suspend fun csvPreview(config: AppConfig, uid: UUID, req: CsvPreviewRequest): CsvPreviewResponse {
    val format = req.format.uppercase()
    if (format !in listOf("STRONG", "HEVY", "AUTO")) validation("format must be one of STRONG, HEVY, AUTO", "format")
    val unit = (req.weightUnit ?: "KG").uppercase()
    if (unit !in listOf("KG", "LB")) validation("weightUnit must be KG or LB", "weightUnit")
    if (req.tz !in java.time.ZoneId.getAvailableZoneIds()) validation("tz must be a valid IANA time zone", "tz")
    if (req.csv.isBlank()) validation("csv is empty", "csv")
    val known = dbQuery {
        val own = HashMap<String, UUID>()
        val builtIn = HashMap<String, UUID>()
        val types = HashMap<UUID, String>()
        Exercises.selectAll().where { Exercises.deletedAt.isNull() and (Exercises.ownerId.isNull() or (Exercises.ownerId eq uid)) }.forEach { r ->
            val id = r[Exercises.id]
            types[id] = r[Exercises.type]
            val target = if (r[Exercises.ownerId] == null) builtIn else own
            listOfNotNull(r[Exercises.nameKo], r[Exercises.nameEn]).forEach { n -> target.putIfAbsent(CsvExerciseDictionary.normalize(n).full, id) }
        }
        CsvKnownExercises(own, builtIn, types)
    }
    val conv = CsvImport.convert(uid, format, req.csv, unit, req.tz, known)
    val chunks = conv.bundles.map { b ->
        val r = ImportRequest(bundle = b, tz = req.tz, onConflict = "ASK")
        CsvChunk(b, config.importer.preview(contextOf(uid, r), r))
    }
    return CsvPreviewResponse(conv.summary, chunks)
}

/** A1 소유 (v0.3). 등록 위치: /v1 아래, 인증 필요 */
fun Route.importRoutes(config: AppConfig) {
    route("/imports") {
        post("/preview") {
            val uid = call.userId
            val req = call.receive<ImportRequest>()
            call.respond(config.importer.preview(contextOf(uid, req), req))
        }

        post("/csv/preview") {
            val uid = call.userId
            val req = call.receive<CsvPreviewRequest>()
            if (req.csv.length > CSV_MAX_BYTES / 4 && req.csv.toByteArray(Charsets.UTF_8).size > CSV_MAX_BYTES) {
                call.respond(HttpStatusCode.PayloadTooLarge, ErrorResponse(ErrorBody("VALIDATION_FAILED", "csv too large (max 4MB)", "csv")))
                return@post
            }
            call.respond(csvPreview(config, uid, req))
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
