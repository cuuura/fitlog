package com.fitlog.export

import com.fitlog.core.BodyMeasurements
import com.fitlog.core.ChangeSeq
import com.fitlog.core.Exercises
import com.fitlog.core.Ids
import com.fitlog.core.ProgramInstances
import com.fitlog.core.Programs
import com.fitlog.core.SessionExercises
import com.fitlog.core.Times
import com.fitlog.core.WorkoutSessions
import com.fitlog.core.WorkoutSets
import org.jetbrains.exposed.sql.insert
import org.jetbrains.exposed.sql.transactions.transaction
import java.math.BigDecimal
import java.time.Instant
import java.time.LocalDate
import java.util.UUID

/** export·deletion 테스트가 함께 쓰는, DB 에 직접 행을 넣는 도구 */

data class SetSeed(
    val weight: String? = "100",
    val reps: Int? = 5,
    val warmup: Boolean = false,
    val note: String? = null,
    val rpe: String? = null,
    val rir: Int? = null,
    val rest: Int? = null,
    val duration: Int? = null,
    val distance: String? = null,
    val added: String? = null,
    val targetReps: Int? = null,
    val targetWeight: String? = null,
    val amrap: Boolean = false,
)

fun insertOwnExercise(
    uid: UUID?,
    ko: String = "내 종목",
    en: String? = "My Lift",
    type: String = "BARBELL",
    muscle: String = "CHEST",
    secondary: List<String> = listOf("TRICEPS"),
): UUID {
    val id = Ids.newId()
    transaction {
        Exercises.insert {
            it[Exercises.id] = id
            it[ownerId] = uid
            it[nameKo] = ko
            it[nameEn] = en
            it[Exercises.type] = type
            it[primaryMuscle] = muscle
            it[secondaryMuscles] = secondary
            it[createdAt] = Times.now()
            it[updatedAt] = Times.now()
            it[serverSeq] = ChangeSeq.next
        }
    }
    return id
}

fun insertSessionRow(
    uid: UUID,
    startedAt: Instant = Instant.parse("2026-11-26T01:00:00Z"),
    tz: String = "Asia/Seoul",
    note: String? = null,
    instanceId: UUID? = null,
    planSeq: Int? = null,
    planDayKey: String? = null,
    exercises: List<Pair<UUID, List<SetSeed>>> = emptyList(),
    ended: Boolean = true,
): UUID {
    val sid = Ids.newId()
    transaction {
        WorkoutSessions.insert {
            it[id] = sid
            it[userId] = uid
            it[WorkoutSessions.startedAt] = startedAt
            it[endedAt] = if (ended) startedAt.plusSeconds(3600) else null
            it[WorkoutSessions.tz] = tz
            it[WorkoutSessions.note] = note
            it[sourceCol] = "APP"
            it[createdAt] = Times.now()
            it[updatedAt] = Times.now()
            it[serverSeq] = ChangeSeq.next
            it[programInstanceId] = instanceId
            it[WorkoutSessions.planSeq] = planSeq
            it[WorkoutSessions.planDayKey] = planDayKey
        }
        exercises.forEachIndexed { ei, (exId, sets) ->
            val seId = Ids.newId()
            SessionExercises.insert {
                it[id] = seId
                it[sessionId] = sid
                it[exerciseId] = exId
                it[position] = ei
                it[updatedAt] = Times.now()
                it[serverSeq] = ChangeSeq.next
            }
            sets.forEachIndexed { si, s ->
                WorkoutSets.insert {
                    it[id] = Ids.newId()
                    it[sessionExerciseId] = seId
                    it[position] = si
                    it[isWarmup] = s.warmup
                    it[weightKg] = s.weight?.let(::BigDecimal)
                    it[addedWeightKg] = s.added?.let(::BigDecimal)
                    it[reps] = s.reps
                    it[durationSec] = s.duration
                    it[distanceM] = s.distance?.let(::BigDecimal)
                    it[rpe] = s.rpe?.let(::BigDecimal)
                    it[rir] = s.rir
                    it[restSec] = s.rest
                    it[WorkoutSets.note] = s.note
                    it[updatedAt] = Times.now()
                    it[serverSeq] = ChangeSeq.next
                    it[targetReps] = s.targetReps
                    it[targetWeightKg] = s.targetWeight?.let(::BigDecimal)
                    it[isAmrap] = s.amrap
                    it[plannedSetKey] = "internal-key"
                }
            }
        }
    }
    return sid
}

fun insertBodyRow(uid: UUID, at: Instant, kg: String, source: String = "MANUAL"): UUID {
    val bid = Ids.newId()
    transaction {
        BodyMeasurements.insert {
            it[id] = bid
            it[userId] = uid
            it[measuredAt] = at
            it[weightKg] = BigDecimal(kg)
            it[sourceCol] = source
            it[updatedAt] = Times.now()
            it[serverSeq] = ChangeSeq.next
        }
    }
    return bid
}

fun insertProgramRow(owner: UUID?, name: String = "내 프로그램", templateKey: String? = null): UUID {
    val pid = Ids.newId()
    transaction {
        Programs.insert {
            it[id] = pid
            it[ownerId] = owner
            it[Programs.templateKey] = templateKey
            it[Programs.name] = name
            it[definition] = """{"schemaVersion":1,"name":"$name","lifts":{},"days":[]}"""
            it[sourceCol] = "USER"
            it[createdAt] = Times.now()
            it[updatedAt] = Times.now()
        }
    }
    return pid
}

fun insertInstanceRow(
    uid: UUID,
    programId: UUID,
    status: String = "ACTIVE",
    tm: String = """{"squat":100.0}""",
    working: String = """{"squat":80.0}""",
): UUID {
    val iid = Ids.newId()
    transaction {
        ProgramInstances.insert {
            it[id] = iid
            it[userId] = uid
            it[ProgramInstances.programId] = programId
            it[definition] = """{"schemaVersion":1,"name":"x","lifts":{},"days":[]}"""
            it[ProgramInstances.status] = status
            it[skipPolicy] = "SHIFT"
            it[startDate] = LocalDate.parse("2026-11-01")
            it[tz] = "Asia/Seoul"
            it[initialState] = """{"tm":$tm,"working":$working}"""
            it[state] = """{"tm":$tm,"working":$working}"""
            it[stateSeq] = 0
            it[createdAt] = Times.now()
            it[updatedAt] = Times.now()
        }
    }
    return iid
}
