@file:UseSerializers(InstantSerializer::class, UUIDSerializer::class)

package com.fitlog.body

import com.fitlog.core.AppConfig
import com.fitlog.core.BodyMeasurements
import com.fitlog.core.ChangeSeq
import com.fitlog.core.Ids
import com.fitlog.core.InstantSerializer
import com.fitlog.core.Kg
import com.fitlog.core.Times
import com.fitlog.core.UUIDSerializer
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
import io.ktor.server.routing.post
import kotlinx.serialization.Serializable
import kotlinx.serialization.UseSerializers
import org.jetbrains.exposed.sql.SortOrder
import org.jetbrains.exposed.sql.SqlExpressionBuilder.eq
import org.jetbrains.exposed.sql.SqlExpressionBuilder.greaterEq
import org.jetbrains.exposed.sql.SqlExpressionBuilder.lessEq
import org.jetbrains.exposed.sql.Transaction
import org.jetbrains.exposed.sql.and
import org.jetbrains.exposed.sql.insert
import org.jetbrains.exposed.sql.SqlExpressionBuilder.isNull
import org.jetbrains.exposed.sql.selectAll
import org.jetbrains.exposed.sql.statements.UpdateBuilder
import org.jetbrains.exposed.sql.update
import java.time.Instant
import java.util.UUID

@Serializable
data class BodyMeasurement(
    val id: UUID,
    val measuredAt: Instant,
    val weightKg: Double,
    val source: String? = null,
    /** readOnly (v0.3) */
    val importBatchId: UUID? = null,
)

private val SOURCES = setOf("MANUAL", "HEALTH_CONNECT", "HEALTHKIT", "OCR")

/** 체중 검증·정규화(둘째 자리 반올림, source 기본 MANUAL). sync 도 같이 쓴다 */
internal fun checkMeasurement(m: BodyMeasurement): BodyMeasurement {
    if (!m.weightKg.isFinite() || m.weightKg < 20 || m.weightKg > 400) validation("weightKg must be between 20 and 400", "weightKg")
    val src = m.source ?: "MANUAL"
    if (src !in SOURCES) validation("source must be one of $SOURCES", "source")
    return m.copy(weightKg = Kg.of(m.weightKg).toDouble(), source = src)
}

internal fun Transaction.upsertMeasurementRow(userId: UUID, m: BodyMeasurement, at: Instant) {
    fun fill(b: UpdateBuilder<*>) {
        b[BodyMeasurements.measuredAt] = m.measuredAt
        b[BodyMeasurements.weightKg] = Kg.of(m.weightKg)
        b[BodyMeasurements.sourceCol] = m.source ?: "MANUAL"
        b[BodyMeasurements.updatedAt] = at
        b[BodyMeasurements.deletedAt] = null
        b[BodyMeasurements.serverSeq] = ChangeSeq.next
    }
    val n = BodyMeasurements.update({ BodyMeasurements.id eq m.id }) { fill(it) }
    if (n == 0) BodyMeasurements.insert {
        it[BodyMeasurements.id] = m.id
        it[BodyMeasurements.userId] = userId
        fill(it)
    }
}

internal fun Transaction.softDeleteMeasurementRow(id: UUID, at: Instant) {
    BodyMeasurements.update({ BodyMeasurements.id eq id }) {
        it[deletedAt] = at
        it[updatedAt] = at
        it[serverSeq] = ChangeSeq.next
    }
}

internal fun org.jetbrains.exposed.sql.ResultRow.toMeasurement() = BodyMeasurement(
    id = this[BodyMeasurements.id],
    measuredAt = this[BodyMeasurements.measuredAt],
    weightKg = this[BodyMeasurements.weightKg].toDouble(),
    source = this[BodyMeasurements.sourceCol],
    importBatchId = this[BodyMeasurements.importBatchId],
)

fun Route.bodyRoutes(config: AppConfig) {
    get("/body/measurements") {
        val uid = call.userId
        val from = call.request.queryParameters["from"]?.let { Times.parse(it, "from") }
        val to = call.request.queryParameters["to"]?.let { Times.parse(it, "to") }
        val list = dbQuery {
            BodyMeasurements.selectAll().where {
                var c = (BodyMeasurements.userId eq uid) and BodyMeasurements.deletedAt.isNull()
                if (from != null) c = c and (BodyMeasurements.measuredAt greaterEq from)
                if (to != null) c = c and (BodyMeasurements.measuredAt lessEq to)
                c
            }.orderBy(BodyMeasurements.measuredAt to SortOrder.DESC, BodyMeasurements.id to SortOrder.DESC)
                .map { it.toMeasurement() }
        }
        call.respond(list)
    }

    post("/body/measurements") {
        val uid = call.userId
        val m = checkMeasurement(call.receive<BodyMeasurement>())
        val saved = dbQuery {
            lockUser(uid)
            val existing = BodyMeasurements.selectAll().where { BodyMeasurements.id eq m.id }.singleOrNull()
            if (existing != null && existing[BodyMeasurements.userId] != uid) notFound("measurement not found")
            upsertMeasurementRow(uid, m, Times.now())
            BodyMeasurements.selectAll().where { BodyMeasurements.id eq m.id }.single().toMeasurement()
        }
        call.respond(HttpStatusCode.Created, saved)
    }

    delete("/body/measurements/{id}") {
        val uid = call.userId
        val id = Ids.parse(call.parameters["id"])
        dbQuery {
            lockUser(uid)
            val row = BodyMeasurements.selectAll().where { BodyMeasurements.id eq id }.singleOrNull()
            if (row != null) {
                if (row[BodyMeasurements.userId] != uid) notFound("measurement not found")
                if (row[BodyMeasurements.deletedAt] == null) softDeleteMeasurementRow(id, Times.now())
            }
        }
        call.respond(HttpStatusCode.NoContent)
    }
}
