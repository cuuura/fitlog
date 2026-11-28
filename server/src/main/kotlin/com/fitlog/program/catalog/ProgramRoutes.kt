package com.fitlog.program.catalog

import com.fitlog.core.ApiException
import com.fitlog.core.AppConfig
import com.fitlog.core.AppJson
import com.fitlog.core.ErrorCode
import com.fitlog.core.Ids
import com.fitlog.core.Programs
import com.fitlog.core.Times
import com.fitlog.core.UUIDSerializer
import com.fitlog.core.dbQuery
import com.fitlog.core.forbidden
import com.fitlog.core.notFound
import com.fitlog.core.userId
import com.fitlog.core.validation
import com.fitlog.engine.ProgramDefinition
import com.fitlog.engine.ProgramRules
import com.fitlog.program.schema.ProgramValidator
import com.fitlog.program.schema.orThrow
import io.ktor.http.HttpStatusCode
import io.ktor.server.request.receive
import io.ktor.server.response.respond
import io.ktor.server.routing.Route
import io.ktor.server.routing.delete
import io.ktor.server.routing.get
import io.ktor.server.routing.post
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.jetbrains.exposed.exceptions.ExposedSQLException
import org.jetbrains.exposed.sql.ResultRow
import org.jetbrains.exposed.sql.SqlExpressionBuilder.eq
import org.jetbrains.exposed.sql.SqlExpressionBuilder.isNull
import org.jetbrains.exposed.sql.and
import org.jetbrains.exposed.sql.insert
import org.jetbrains.exposed.sql.or
import org.jetbrains.exposed.sql.selectAll
import org.jetbrains.exposed.sql.update
import java.util.UUID

/** openapi ProgramSummary */
@Serializable
data class ProgramSummary(
    @Serializable(with = UUIDSerializer::class) val id: UUID,
    val templateKey: String? = null,
    val name: String,
    val description: String? = null,
    val category: String? = null,
    val level: String? = null,
    val family: String? = null,
    val variantLabel: String? = null,
    val aka: List<String>? = null,
    val rules: ProgramRules? = null,
    val builtIn: Boolean,
    val dayCount: Int,
    val source: String,
    @Serializable(with = UUIDSerializer::class) val importBatchId: UUID? = null,
)

/** openapi Program. 저장 전 미리보기(validate)에서는 id 가 없다 */
@Serializable
data class Program(
    @Serializable(with = UUIDSerializer::class) val id: UUID? = null,
    val templateKey: String? = null,
    val name: String,
    val description: String? = null,
    val category: String? = null,
    val level: String? = null,
    val family: String? = null,
    val variantLabel: String? = null,
    val aka: List<String>? = null,
    val rules: ProgramRules? = null,
    val builtIn: Boolean,
    val dayCount: Int,
    val source: String,
    val definition: ProgramDefinition,
    @Serializable(with = UUIDSerializer::class) val importBatchId: UUID? = null,
)

private fun decode(text: String): ProgramDefinition = AppJson.decodeFromString(ProgramDefinition.serializer(), text)

private fun summary(r: ResultRow): ProgramSummary {
    val def = decode(r[Programs.definition])
    return ProgramSummary(
        id = r[Programs.id], templateKey = r[Programs.templateKey], name = r[Programs.name],
        description = def.description, category = def.category, level = def.level, family = def.family,
        variantLabel = def.variantLabel, aka = def.aka, rules = def.rules, builtIn = r[Programs.ownerId] == null,
        dayCount = def.days.size, source = r[Programs.sourceCol], importBatchId = r[Programs.importBatchId],
    )
}

private fun program(r: ResultRow): Program {
    val def = decode(r[Programs.definition])
    return Program(
        id = r[Programs.id], templateKey = r[Programs.templateKey], name = r[Programs.name],
        description = def.description, category = def.category, level = def.level, family = def.family,
        variantLabel = def.variantLabel, aka = def.aka, rules = def.rules, builtIn = r[Programs.ownerId] == null,
        dayCount = def.days.size, source = r[Programs.sourceCol], definition = def,
        importBatchId = r[Programs.importBatchId],
    )
}

/** A1 소유 (v0.2). 경로는 /v1 아래 상대 경로로 등록한다 */
fun Route.programRoutes(config: AppConfig) {
    // 템플릿 시드는 프로세스당 한 번(Application.kt 수정 없이)
    ProgramTemplates.seedOnce()

    get("/programs") {
        val uid = call.userId
        val source = call.request.queryParameters["source"]
        if (source != null && source != "TEMPLATE" && source != "MINE") validation("source must be TEMPLATE or MINE", "source")
        val list = dbQuery {
            val visible = when (source) {
                "TEMPLATE" -> Programs.ownerId.isNull()
                "MINE" -> Programs.ownerId eq uid
                else -> Programs.ownerId.isNull() or (Programs.ownerId eq uid)
            }
            Programs.selectAll().where { Programs.deletedAt.isNull() and visible }
                .map(::summary)
        }
        // 템플릿은 고정 순서(id 순), 내 것은 뒤
        call.respond(list.sortedWith(compareBy({ !it.builtIn }, { it.id.toString() })))
    }

    post("/programs/validate") {
        val uid = call.userId
        val body: JsonElement = call.receive()
        val index = ExerciseIndex.load(uid)
        val def = ProgramValidator.validate(body, index.resolver).orThrow()
        call.respond(
            Program(
                id = null, name = def.name, description = def.description, category = def.category, level = def.level, family = def.family,
        variantLabel = def.variantLabel, aka = def.aka, rules = def.rules, builtIn = false,
                dayCount = def.days.size, source = "USER", definition = def,
            ),
        )
    }

    post("/programs") {
        val uid = call.userId
        val body: JsonElement = call.receive()
        val obj = body as? JsonObject ?: validation("body must be an object")
        for (k in obj.keys) if (k != "id" && k != "definition") validation("unknown property '$k'", k)
        val idEl = obj["id"] as? JsonPrimitive
        if (idEl == null || !idEl.isString) validation("id is required", "id")
        val id = Ids.parse(idEl.content)
        val defEl = obj["definition"] ?: validation("definition is required", "definition")
        val index = ExerciseIndex.load(uid)
        val def = ProgramValidator.validate(defEl, index.resolver).orThrow()
        val text = AppJson.encodeToString(def)
        val now = Times.now()

        val saved = try {
            dbQuery {
                val existing = Programs.selectAll().where { Programs.id eq id }.firstOrNull()
                if (existing == null) {
                    Programs.insert {
                        it[Programs.id] = id
                        it[ownerId] = uid
                        it[name] = def.name
                        it[definition] = text
                        it[sourceCol] = "USER"
                        it[createdAt] = now
                        it[updatedAt] = now
                    }
                } else {
                    if (existing[Programs.ownerId] != uid) {
                        throw ApiException(ErrorCode.CONFLICT, "program id is already used", "id")
                    }
                    Programs.update({ Programs.id eq id }) {
                        it[name] = def.name
                        it[definition] = text
                        it[updatedAt] = now
                        it[deletedAt] = null
                    }
                }
                Programs.selectAll().where { Programs.id eq id }.first().let(::program)
            }
        } catch (e: ExposedSQLException) {
            // 같은 id 동시 등록 경합
            throw ApiException(ErrorCode.CONFLICT, "program id is already used", "id")
        }
        call.respond(HttpStatusCode.Created, saved)
    }

    get("/programs/{id}") {
        val uid = call.userId
        val id = Ids.parse(call.parameters["id"])
        val p = dbQuery {
            Programs.selectAll().where {
                (Programs.id eq id) and Programs.deletedAt.isNull() and (Programs.ownerId.isNull() or (Programs.ownerId eq uid))
            }.firstOrNull()?.let(::program)
        } ?: notFound("program not found")
        call.respond(p)
    }

    delete("/programs/{id}") {
        val uid = call.userId
        val id = Ids.parse(call.parameters["id"])
        dbQuery {
            val row = Programs.selectAll().where { Programs.id eq id and Programs.deletedAt.isNull() }.firstOrNull()
                ?: notFound("program not found")
            val owner = row[Programs.ownerId]
            if (owner == null) forbidden("built-in templates cannot be deleted")
            if (owner != uid) notFound("program not found")
            val now = Times.now()
            Programs.update({ Programs.id eq id }) {
                it[deletedAt] = now
                it[updatedAt] = now
            }
        }
        call.respond(HttpStatusCode.NoContent)
    }
}
