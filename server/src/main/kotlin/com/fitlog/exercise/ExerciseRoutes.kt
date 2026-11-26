package com.fitlog.exercise

import com.fitlog.core.ApiException
import com.fitlog.core.AppConfig
import com.fitlog.core.ChangeSeq
import com.fitlog.core.ErrorCode
import com.fitlog.core.Exercises
import com.fitlog.core.Ids
import com.fitlog.core.InstantSerializer
import com.fitlog.core.Times
import com.fitlog.core.UUIDSerializer
import com.fitlog.core.dbQuery
import com.fitlog.core.forbidden
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
import io.ktor.server.routing.put
import kotlinx.serialization.Serializable
import org.jetbrains.exposed.exceptions.ExposedSQLException
import org.jetbrains.exposed.sql.Op
import org.jetbrains.exposed.sql.ResultRow
import org.jetbrains.exposed.sql.SqlExpressionBuilder.eq
import org.jetbrains.exposed.sql.and
import org.jetbrains.exposed.sql.insert
import org.jetbrains.exposed.sql.SqlExpressionBuilder.isNull
import org.jetbrains.exposed.sql.or
import org.jetbrains.exposed.sql.selectAll
import org.jetbrains.exposed.sql.update
import java.time.Instant
import java.util.UUID

/** openapi ExerciseInput. type/muscle 은 문자열로 받고 [validated] 에서 enum 검사한다 */
@Serializable
data class ExerciseInput(
    @Serializable(with = UUIDSerializer::class) val id: UUID,
    val nameKo: String,
    val nameEn: String? = null,
    val type: String,
    val primaryMuscle: String,
    val secondaryMuscles: List<String> = emptyList(),
)

/** openapi Exercise (ExerciseInput + builtIn, updatedAt) */
@Serializable
data class Exercise(
    @Serializable(with = UUIDSerializer::class) val id: UUID,
    val nameKo: String,
    val nameEn: String? = null,
    val type: String,
    val primaryMuscle: String,
    val secondaryMuscles: List<String> = emptyList(),
    val builtIn: Boolean,
    @Serializable(with = InstantSerializer::class) val updatedAt: Instant,
)

val EXERCISE_TYPES = setOf("BARBELL", "DUMBBELL", "MACHINE", "BODYWEIGHT", "BAND", "CARDIO")
val MUSCLES = setOf(
    "CHEST", "BACK", "LATS", "TRAPS", "SHOULDERS", "REAR_DELTS", "BICEPS", "TRICEPS", "FOREARMS",
    "QUADS", "HAMSTRINGS", "GLUTES", "CALVES", "ADDUCTORS", "ABS", "OBLIQUES", "LOWER_BACK", "FULL_BODY", "CARDIO",
)

/**
 * ExerciseInput 검증 (A3 sync 에서도 재사용). 실패하면 400 VALIDATION_FAILED + field.
 * [fieldPrefix] 는 필드 경로 앞에 붙는다 (예: "payload."). 정규화된 사본을 돌려준다
 * (nameKo/nameEn trim, 빈 nameEn → null, 보조근육 중복·주근육과 같은 값 제거).
 */
fun ExerciseInput.validated(fieldPrefix: String = ""): ExerciseInput {
    val ko = nameKo.trim()
    if (ko.isEmpty() || ko.length > 60) validation("nameKo must be 1..60 characters", "${fieldPrefix}nameKo")
    val en = nameEn?.trim()?.ifEmpty { null }
    if (en != null && en.length > 60) validation("nameEn must be at most 60 characters", "${fieldPrefix}nameEn")
    if (type !in EXERCISE_TYPES) validation("type must be one of $EXERCISE_TYPES", "${fieldPrefix}type")
    if (primaryMuscle !in MUSCLES) validation("primaryMuscle is not a valid muscle", "${fieldPrefix}primaryMuscle")
    secondaryMuscles.forEachIndexed { i, m ->
        if (m !in MUSCLES) validation("secondaryMuscles[$i] is not a valid muscle", "${fieldPrefix}secondaryMuscles[$i]")
    }
    return copy(
        nameKo = ko,
        nameEn = en,
        secondaryMuscles = secondaryMuscles.distinct().filter { it != primaryMuscle },
    )
}

/** exercise 행 → Exercise DTO (A3 sync 에서도 재사용) */
fun ResultRow.toExercise(): Exercise = Exercise(
    id = this[Exercises.id],
    nameKo = this[Exercises.nameKo],
    nameEn = this[Exercises.nameEn],
    type = this[Exercises.type],
    primaryMuscle = this[Exercises.primaryMuscle],
    secondaryMuscles = this[Exercises.secondaryMuscles],
    builtIn = this[Exercises.ownerId] == null,
    updatedAt = this[Exercises.updatedAt],
)

private fun normalizeForSearch(s: String): String = s.filterNot { it.isWhitespace() }.lowercase()

private fun isUniqueViolation(e: ExposedSQLException) = e.sqlState == "23505"

/** A2 소유. 경로는 /v1 아래 상대 경로로 등록한다 */
fun Route.exerciseRoutes(config: AppConfig) {
    get("/exercises") {
        val uid = call.userId
        val q = call.request.queryParameters["q"]?.let(::normalizeForSearch)?.ifEmpty { null }
        val muscle = call.request.queryParameters["muscle"]?.also {
            if (it !in MUSCLES) validation("muscle is not a valid muscle", "muscle")
        }
        val type = call.request.queryParameters["type"]?.also {
            if (it !in EXERCISE_TYPES) validation("type must be one of $EXERCISE_TYPES", "type")
        }
        val list = dbQuery {
            var cond: Op<Boolean> = Exercises.deletedAt.isNull() and
                (Exercises.ownerId.isNull() or (Exercises.ownerId eq uid))
            if (type != null) cond = cond and (Exercises.type eq type)
            Exercises.selectAll().where(cond).map { it.toExercise() }
        }
        val result = list
            .filter { e -> muscle == null || e.primaryMuscle == muscle || muscle in e.secondaryMuscles }
            .filter { e ->
                q == null || normalizeForSearch(e.nameKo).contains(q) ||
                    (e.nameEn != null && normalizeForSearch(e.nameEn).contains(q))
            }
            .sortedWith(compareBy<Exercise> { it.nameKo }.thenBy { it.id })
        call.respond(result)
    }

    post("/exercises") {
        val uid = call.userId
        val input = call.receive<ExerciseInput>().validated()
        // 해석: 내 종목의 같은 id 가 이미 있으면(삭제된 것 포함) 멱등 갱신(삭제 해제) 후 201 을 그대로 돌려준다.
        val created = try {
            dbQuery {
                lockUser(uid)
                val now = Times.now()
                val existing = Exercises.selectAll().where { Exercises.id eq input.id }.singleOrNull()
                when {
                    existing == null -> Exercises.insert {
                        it[id] = input.id
                        it[ownerId] = uid
                        it[nameKo] = input.nameKo
                        it[nameEn] = input.nameEn
                        it[type] = input.type
                        it[primaryMuscle] = input.primaryMuscle
                        it[secondaryMuscles] = input.secondaryMuscles
                        it[createdAt] = now
                        it[updatedAt] = now
                        it[serverSeq] = ChangeSeq.next
                    }
                    existing[Exercises.ownerId] == uid -> Exercises.update({ Exercises.id eq input.id }) {
                        it[nameKo] = input.nameKo
                        it[nameEn] = input.nameEn
                        it[type] = input.type
                        it[primaryMuscle] = input.primaryMuscle
                        it[secondaryMuscles] = input.secondaryMuscles
                        it[deletedAt] = null
                        it[updatedAt] = now
                        it[serverSeq] = ChangeSeq.next
                    }
                    else -> throw ApiException(ErrorCode.CONFLICT, "exercise id already in use", "id")
                }
                Exercises.selectAll().where { Exercises.id eq input.id }.single().toExercise()
            }
        } catch (e: ExposedSQLException) {
            if (isUniqueViolation(e)) throw ApiException(ErrorCode.CONFLICT, "exercise id already in use", "id")
            throw e
        }
        call.respond(HttpStatusCode.Created, created)
    }

    put("/exercises/{id}") {
        val uid = call.userId
        val pathId = Ids.parse(call.parameters["id"])
        val input = call.receive<ExerciseInput>().validated()
        if (input.id != pathId) validation("body id must match path id", "id")
        val updated = dbQuery {
            lockUser(uid)
            val row = Exercises.selectAll().where { Exercises.id eq pathId }.singleOrNull() ?: notFound("exercise not found")
            val owner = row[Exercises.ownerId]
            if (owner == null) forbidden("built-in exercises cannot be modified")
            if (owner != uid || row[Exercises.deletedAt] != null) notFound("exercise not found")
            Exercises.update({ Exercises.id eq pathId }) {
                it[nameKo] = input.nameKo
                it[nameEn] = input.nameEn
                it[type] = input.type
                it[primaryMuscle] = input.primaryMuscle
                it[secondaryMuscles] = input.secondaryMuscles
                it[updatedAt] = Times.now()
                it[serverSeq] = ChangeSeq.next
            }
            Exercises.selectAll().where { Exercises.id eq pathId }.single().toExercise()
        }
        call.respond(updated)
    }

    delete("/exercises/{id}") {
        val uid = call.userId
        val pathId = Ids.parse(call.parameters["id"])
        dbQuery {
            lockUser(uid)
            val row = Exercises.selectAll().where { Exercises.id eq pathId }.singleOrNull() ?: notFound("exercise not found")
            val owner = row[Exercises.ownerId]
            if (owner == null) forbidden("built-in exercises cannot be deleted")
            if (owner != uid) notFound("exercise not found")
            if (row[Exercises.deletedAt] == null) {
                val now = Times.now()
                Exercises.update({ Exercises.id eq pathId }) {
                    it[deletedAt] = now
                    it[updatedAt] = now
                    it[serverSeq] = ChangeSeq.next
                }
            }
        }
        call.respond(HttpStatusCode.NoContent)
    }
}
