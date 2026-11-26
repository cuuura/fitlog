package com.fitlog.importing

import com.fitlog.core.AppConfig
import com.fitlog.core.notFound
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.server.response.header
import io.ktor.server.response.respondText
import io.ktor.server.routing.Route
import io.ktor.server.routing.get

private val SCHEMA_TYPE = ContentType("application", "schema+json")

private object SchemaResources

private fun readSchema(name: String): String =
    SchemaResources.javaClass.getResourceAsStream("/schemas/$name")?.use { it.readBytes().toString(Charsets.UTF_8) }
        ?: notFound("schema not found")

/** 공개 스키마 (AI-2). 등록 위치: /v1 아래, 인증 없음. 계약 파일의 복사본을 그대로 돌려준다 */
fun Route.publicSchemaRoutes(config: AppConfig) {
    val files = mapOf(
        "/public/schema/import.json" to "import.schema.json",
        "/public/schema/program.json" to "program.schema.json",
    )
    for ((path, file) in files) {
        get(path) {
            call.response.header(HttpHeaders.CacheControl, "max-age=86400")
            call.respondText(readSchema(file), SCHEMA_TYPE)
        }
    }
}
