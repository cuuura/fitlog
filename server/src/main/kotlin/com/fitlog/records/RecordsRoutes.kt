package com.fitlog.records

import com.fitlog.core.ApiException
import com.fitlog.core.AppConfig
import com.fitlog.core.AppJson
import com.fitlog.core.ErrorCode
import com.fitlog.core.Exercises
import com.fitlog.core.Ids
import com.fitlog.core.InstantSerializer
import com.fitlog.core.Kg
import com.fitlog.core.OneRmMeasurements
import com.fitlog.core.Programs
import com.fitlog.core.SessionExercises
import com.fitlog.core.Times
import com.fitlog.core.UUIDSerializer
import com.fitlog.core.UserSettingsTable
import com.fitlog.core.WorkoutSessions
import com.fitlog.core.WorkoutSets
import com.fitlog.core.dbQuery
import com.fitlog.core.notFound
import com.fitlog.core.userId
import com.fitlog.core.validation
import com.fitlog.engine.E1rmFormula
import com.fitlog.engine.Needs
import com.fitlog.engine.ProgramDefinition
import com.fitlog.engine.ProgramEngine
import io.ktor.http.HttpStatusCode
import io.ktor.server.request.receive
import io.ktor.server.response.respond
import io.ktor.server.routing.Route
import io.ktor.server.routing.delete
import io.ktor.server.routing.get
import io.ktor.server.routing.post
import kotlinx.serialization.Serializable
import org.jetbrains.exposed.sql.JoinType
import org.jetbrains.exposed.sql.ResultRow
import org.jetbrains.exposed.sql.SortOrder
import org.jetbrains.exposed.sql.SqlExpressionBuilder.eq
import org.jetbrains.exposed.sql.SqlExpressionBuilder.greater
import org.jetbrains.exposed.sql.SqlExpressionBuilder.greaterEq
import org.jetbrains.exposed.sql.SqlExpressionBuilder.inList
import org.jetbrains.exposed.sql.SqlExpressionBuilder.isNotNull
import org.jetbrains.exposed.sql.SqlExpressionBuilder.isNull
import org.jetbrains.exposed.sql.and
import org.jetbrains.exposed.sql.insert
import org.jetbrains.exposed.sql.or
import org.jetbrains.exposed.sql.selectAll
import org.jetbrains.exposed.sql.update
import java.math.BigDecimal
import java.math.RoundingMode
import java.time.Instant
import java.time.temporal.ChronoUnit
import java.util.UUID

// ---------------------------------------------------------------- DTO (openapi v0.2)

@Serializable
data class OneRmMeasurement(
    @Serializable(with = UUIDSerializer::class) val id: UUID,
    @Serializable(with = UUIDSerializer::class) val exerciseId: UUID? = null,
    val weightKg: Double,
    @Serializable(with = InstantSerializer::class) val measuredAt: Instant,
    val note: String? = null,
)

@Serializable
data class RecordPoint(
    val weightKg: Double,
    val reps: Int,
    val e1rmKg: Double? = null,
    @Serializable(with = UUIDSerializer::class) val sessionId: UUID,
    @Serializable(with = UUIDSerializer::class) val setId: UUID,
    @Serializable(with = InstantSerializer::class) val achievedAt: Instant,
)

@Serializable
data class RepsRecord(val reps: Int, val point: RecordPoint)

@Serializable
data class ExerciseRecords(
    @Serializable(with = UUIDSerializer::class) val exerciseId: UUID,
    val formula: String,
    val bestWeight: RecordPoint? = null,
    val bestE1rm: RecordPoint? = null,
    val latestMeasured: OneRmMeasurement? = null,
    val byReps: List<RepsRecord>,
)

@Serializable
data class SuggestItem(
    val key: String,
    @Serializable(with = UUIDSerializer::class) val exerciseId: UUID,
    val needs: String,
    val oneRmKg: Double? = null,
    val oneRmSource: String? = null,
    val suggestedKg: Double? = null,
    /** true 면 시작 때 비워둘 수 있는 키(DOUBLE 규칙). 아니면 생략 */
    val optional: Boolean? = null,
)

// ---------------------------------------------------------------- 내부 도구

/** 판정 대상 세트(워밍업·삭제 제외, 끝낸 세트, 무게·횟수 있음) */
internal class DoneSet(
    val setId: UUID,
    val sessionId: UUID,
    val exerciseId: UUID,
    val weightKg: Double,
    val reps: Int,
    val at: Instant,
)

private const val MAX_KG = 9999.99
private const val ESTIMATE_DAYS = 90L

private fun parseFormula(s: String?): E1rmFormula =
    E1rmFormula.entries.firstOrNull { it.name == s } ?: E1rmFormula.EPLEY

private fun ResultRow.toOneRm(): OneRmMeasurement = OneRmMeasurement(
    id = this[OneRmMeasurements.id],
    exerciseId = this[OneRmMeasurements.exerciseId],
    weightKg = this[OneRmMeasurements.weightKg].toDouble(),
    measuredAt = this[OneRmMeasurements.measuredAt],
    note = this[OneRmMeasurements.note],
)

internal fun userFormula(uid: UUID): E1rmFormula =
    parseFormula(
        UserSettingsTable.selectAll().where { UserSettingsTable.userId eq uid }.singleOrNull()?.get(UserSettingsTable.e1rmFormula),
    )

/** 기본 종목이거나 내 종목(삭제 안 됨)이어야 한다. 아니면 404 */
internal fun requireVisibleExercise(uid: UUID, exerciseId: UUID) {
    val row = Exercises.selectAll().where {
        (Exercises.id eq exerciseId) and Exercises.deletedAt.isNull() and (Exercises.ownerId.isNull() or (Exercises.ownerId eq uid))
    }.singleOrNull()
    if (row == null) notFound("exercise not found")
}

/**
 * 내가 끝낸(completedAt 있음) 본 세트들. 워밍업·삭제(세트·종목·세션)·무게/횟수 없는 세트 제외.
 * 끝나지 않은 세션(ended_at 없음)의 완료된 세트도 포함한다.
 */
private fun loadDoneSets(uid: UUID, exerciseIds: Collection<UUID>, since: Instant? = null): List<DoneSet> {
    if (exerciseIds.isEmpty()) return emptyList()
    val join = WorkoutSets
        .join(SessionExercises, JoinType.INNER, WorkoutSets.sessionExerciseId, SessionExercises.id)
        .join(WorkoutSessions, JoinType.INNER, SessionExercises.sessionId, WorkoutSessions.id)
    return join.selectAll().where {
        var c = (WorkoutSessions.userId eq uid) and WorkoutSessions.deletedAt.isNull() and
            SessionExercises.deletedAt.isNull() and WorkoutSets.deletedAt.isNull() and
            (SessionExercises.exerciseId inList exerciseIds.toList()) and
            (WorkoutSets.isWarmup eq false) and WorkoutSets.completedAt.isNotNull() and
            WorkoutSets.weightKg.isNotNull() and (WorkoutSets.weightKg greater BigDecimal.ZERO) and
            WorkoutSets.reps.isNotNull() and (WorkoutSets.reps greaterEq 1)
        if (since != null) c = c and (WorkoutSets.completedAt greaterEq since)
        c
    }.map {
        DoneSet(
            setId = it[WorkoutSets.id],
            sessionId = it[SessionExercises.sessionId],
            exerciseId = it[SessionExercises.exerciseId],
            weightKg = it[WorkoutSets.weightKg]!!.toDouble(),
            reps = it[WorkoutSets.reps]!!,
            at = it[WorkoutSets.completedAt]!!,
        )
    }
}

internal fun point(s: DoneSet, formula: E1rmFormula) = RecordPoint(
    weightKg = s.weightKg,
    reps = s.reps,
    e1rmKg = ProgramEngine.estimateOneRm(formula, s.weightKg, s.reps),
    sessionId = s.sessionId,
    setId = s.setId,
    achievedAt = s.at,
)

/** 가장 무거운 세트. 같으면 횟수 많은 쪽, 그래도 같으면 먼저 한 쪽 */
internal val heavier = compareByDescending<DoneSet> { it.weightKg }.thenByDescending { it.reps }.thenBy { it.at }.thenBy { it.setId }

internal fun bestEstimated(sets: List<DoneSet>, formula: E1rmFormula): Pair<DoneSet, Double>? =
    sets.mapNotNull { s -> ProgramEngine.estimateOneRm(formula, s.weightKg, s.reps)?.let { s to it } }
        .minWithOrNull(compareByDescending<Pair<DoneSet, Double>> { it.second }.thenBy { it.first.at }.thenBy { it.first.setId })

private fun latestMeasured(uid: UUID, exerciseId: UUID): ResultRow? =
    OneRmMeasurements.selectAll().where {
        (OneRmMeasurements.userId eq uid) and (OneRmMeasurements.exerciseId eq exerciseId) and OneRmMeasurements.deletedAt.isNull()
    }.orderBy(OneRmMeasurements.measuredAt to SortOrder.DESC, OneRmMeasurements.createdAt to SortOrder.DESC)
        .limit(1).singleOrNull()

private fun validateMeasurement(m: OneRmMeasurement) {
    if (!m.weightKg.isFinite() || m.weightKg <= 0.0) validation("weightKg must be greater than 0", "weightKg")
    if (m.weightKg > MAX_KG) validation("weightKg must be at most $MAX_KG", "weightKg")
    if (Kg.of(m.weightKg).signum() <= 0) validation("weightKg must be greater than 0", "weightKg")
    if (m.note != null && m.note.length > 500) validation("note must be at most 500 characters", "note")
}

/** A2 소유 (v0.2). 경로는 /v1 아래 상대 경로로 등록한다 */
fun Route.recordsRoutes(config: AppConfig) {
    get("/exercises/{id}/records") {
        val uid = call.userId
        val exerciseId = Ids.parse(call.parameters["id"])
        val body = dbQuery {
            requireVisibleExercise(uid, exerciseId)
            val formula = userFormula(uid)
            val sets = loadDoneSets(uid, listOf(exerciseId))
            val byReps = (1..10).mapNotNull { r ->
                sets.filter { it.reps == r }.minWithOrNull(heavier)?.let { RepsRecord(r, point(it, formula)) }
            }
            ExerciseRecords(
                exerciseId = exerciseId,
                formula = formula.name,
                bestWeight = sets.minWithOrNull(heavier)?.let { point(it, formula) },
                bestE1rm = bestEstimated(sets, formula)?.let { point(it.first, formula) },
                latestMeasured = latestMeasured(uid, exerciseId)?.toOneRm(),
                byReps = byReps,
            )
        }
        call.respond(body)
    }

    get("/exercises/{id}/one-rm") {
        val uid = call.userId
        val exerciseId = Ids.parse(call.parameters["id"])
        val list = dbQuery {
            requireVisibleExercise(uid, exerciseId)
            OneRmMeasurements.selectAll().where {
                (OneRmMeasurements.userId eq uid) and (OneRmMeasurements.exerciseId eq exerciseId) and OneRmMeasurements.deletedAt.isNull()
            }.orderBy(OneRmMeasurements.measuredAt to SortOrder.DESC, OneRmMeasurements.createdAt to SortOrder.DESC)
                .map { it.toOneRm() }
        }
        call.respond(list)
    }

    post("/exercises/{id}/one-rm") {
        val uid = call.userId
        val exerciseId = Ids.parse(call.parameters["id"])
        val input = call.receive<OneRmMeasurement>()
        validateMeasurement(input)
        if (input.exerciseId != null && input.exerciseId != exerciseId) validation("exerciseId must match path id", "exerciseId")
        val note = input.note?.trim()?.ifEmpty { null }
        val saved = dbQuery {
            requireVisibleExercise(uid, exerciseId)
            // 같은 id 가 이미 있으면(내 것·같은 종목) 같은 내용으로 갱신해 돌려준다(재전송 멱등). 남의 것이면 409
            val existing = OneRmMeasurements.selectAll().where { OneRmMeasurements.id eq input.id }.singleOrNull()
            if (existing == null) {
                OneRmMeasurements.insert {
                    it[id] = input.id
                    it[userId] = uid
                    it[OneRmMeasurements.exerciseId] = exerciseId
                    it[weightKg] = Kg.of(input.weightKg)
                    it[measuredAt] = input.measuredAt
                    it[OneRmMeasurements.note] = note
                    it[createdAt] = Times.now()
                }
            } else {
                if (existing[OneRmMeasurements.userId] != uid || existing[OneRmMeasurements.exerciseId] != exerciseId) {
                    throw ApiException(ErrorCode.CONFLICT, "one-rm id already in use", "id")
                }
                OneRmMeasurements.update({ OneRmMeasurements.id eq input.id }) {
                    it[weightKg] = Kg.of(input.weightKg)
                    it[measuredAt] = input.measuredAt
                    it[OneRmMeasurements.note] = note
                    it[deletedAt] = null
                }
            }
            OneRmMeasurements.selectAll().where { OneRmMeasurements.id eq input.id }.single().toOneRm()
        }
        call.respond(HttpStatusCode.Created, saved)
    }

    delete("/one-rm/{id}") {
        val uid = call.userId
        val id = Ids.parse(call.parameters["id"])
        dbQuery {
            val row = OneRmMeasurements.selectAll().where { OneRmMeasurements.id eq id }.singleOrNull()
            // 없으면 204(멱등), 남의 것이면 404, 이미 지운 내 것도 204
            if (row != null) {
                if (row[OneRmMeasurements.userId] != uid) notFound("measurement not found")
                if (row[OneRmMeasurements.deletedAt] == null) {
                    OneRmMeasurements.update({ OneRmMeasurements.id eq id }) { it[deletedAt] = Times.now() }
                }
            }
        }
        call.respond(HttpStatusCode.NoContent)
    }

    get("/programs/{id}/suggest") {
        val uid = call.userId
        val programId = Ids.parse(call.parameters["id"])
        val items = dbQuery {
            val row = Programs.selectAll().where {
                (Programs.id eq programId) and Programs.deletedAt.isNull() and (Programs.ownerId.isNull() or (Programs.ownerId eq uid))
            }.singleOrNull() ?: notFound("program not found")
            val def = AppJson.decodeFromString<ProgramDefinition>(row[Programs.definition])
            val inputs = ProgramEngine.requiredInputs(def)
            val optionalKeys = ProgramEngine.optionalInputs(def)
            val formula = userFormula(uid)
            val exerciseIds = inputs.keys.mapNotNull { k -> def.lifts[k]?.exercise?.id?.let { runCatching { UUID.fromString(it) }.getOrNull() } }.distinct()
            val since = Times.now().minus(ESTIMATE_DAYS, ChronoUnit.DAYS)
            val recent = loadDoneSets(uid, exerciseIds, since).groupBy { it.exerciseId }
            inputs.mapNotNull { (key, needs) ->
                val exerciseId = def.lifts[key]?.exercise?.id?.let { runCatching { UUID.fromString(it) }.getOrNull() }
                    ?: return@mapNotNull null
                val measured = latestMeasured(uid, exerciseId)?.get(OneRmMeasurements.weightKg)?.toDouble()
                val estimated = if (measured == null) recent[exerciseId]?.let { bestEstimated(it, formula)?.second } else null
                val oneRm = measured ?: estimated
                val percent = if (needs == Needs.TM) def.tmPercent else def.workingPercent
                SuggestItem(
                    key = key,
                    exerciseId = exerciseId,
                    needs = needs.name,
                    oneRmKg = oneRm,
                    oneRmSource = when {
                        measured != null -> "MEASURED"
                        estimated != null -> "ESTIMATED"
                        else -> null
                    },
                    suggestedKg = oneRm?.let { BigDecimal.valueOf(it).multiply(BigDecimal.valueOf(percent)).setScale(2, RoundingMode.HALF_UP).toDouble() },
                    optional = if (key in optionalKeys) true else null,
                )
            }
        }
        call.respond(items)
    }
}
