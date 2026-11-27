package com.fitlog.importing

import com.fitlog.engine.ProgramDefinition
import com.fitlog.engine.ProgramState
import com.fitlog.scheduled.ScheduledWorkout
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.math.BigDecimal
import java.math.RoundingMode
import java.security.MessageDigest
import java.time.Instant
import java.time.LocalDate
import java.util.UUID

/* 분석(Analyzer) 결과로 만든 "쓸 것" 계획과 공용 도구 */

internal class WExercise(
    val id: UUID, val nameKo: String, val nameEn: String?, val type: String, val primaryMuscle: String,
    val secondary: List<String>, val replace: Boolean,
)

internal class WProgram(val id: UUID, val name: String, val def: ProgramDefinition, val replace: Boolean)

internal class WInstance(
    val id: UUID, val programId: UUID, val def: ProgramDefinition, val policy: String, val startDate: LocalDate,
    val tz: String, val initial: ProgramState, val label: String,
)

/** 계획을 짤 때 필요한 인스턴스 정보(새로 시작하거나 이미 있는 것) */
internal class InstInfo(val id: UUID, val def: ProgramDefinition, val baseSeq: Int, val baseState: ProgramState)

internal class WSet(
    val id: UUID, val position: Int, val isWarmup: Boolean, val weightKg: Double?, val addedWeightKg: Double?,
    val reps: Int?, val durationSec: Int?, val distanceM: Double?, val rpe: Double?, val rir: Int?, val restSec: Int?,
    val note: String?,
)

internal class WSessionEx(val id: UUID, val exerciseId: UUID, val position: Int, val note: String?, val sets: List<WSet>)

internal class WSession(
    val id: UUID, val startedAt: Instant, val endedAt: Instant, val tz: String, val note: String?,
    var link: InstInfo?, val planSeq: Int?, val exercises: List<WSessionEx>, val label: String, val replace: Boolean,
    /** 이 세션이 수행한 예정 운동(최종 확정된 id). 분석 마지막에 정한다 */
    var scheduledId: UUID? = null,
)

internal class WScheduled(val id: UUID, val workout: ScheduledWorkout, val label: String, val replace: Boolean)

internal class WBody(val id: UUID, val measuredAt: Instant, val weightKg: Double, val label: String, val replace: Boolean)

internal class Old(val id: UUID, val label: String)

internal class WritePlan {
    val exercises = mutableListOf<WExercise>()
    val programs = mutableListOf<WProgram>()
    val replacedPrograms = mutableListOf<Old>()
    val instances = mutableListOf<WInstance>()
    val sessions = mutableListOf<WSession>()
    val replacedSessions = mutableListOf<Old>()
    val bodies = mutableListOf<WBody>()
    val replacedBodies = mutableListOf<Old>()
    val scheduled = mutableListOf<WScheduled>()
    val replacedScheduled = mutableListOf<Old>()

    fun isEmpty() = exercises.isEmpty() && programs.isEmpty() && replacedPrograms.isEmpty() && instances.isEmpty() &&
        sessions.isEmpty() && replacedSessions.isEmpty() && bodies.isEmpty() && replacedBodies.isEmpty() &&
        scheduled.isEmpty() && replacedScheduled.isEmpty()
}

// ---------------------------------------------------------------- 해시·결정적 id

/** 키를 정렬해 정규화한 JSON 의 SHA-256(hex). 숫자 표기(1 / 1.0)가 달라도 같다 */
internal fun bundleHash(json: JsonElement): String {
    val sb = StringBuilder()
    fun write(el: JsonElement) {
        when (el) {
            is JsonObject -> {
                sb.append('{')
                el.entries.sortedBy { it.key }.forEachIndexed { i, (k, v) ->
                    if (i > 0) sb.append(',')
                    sb.append(JsonPrimitive(k).toString()).append(':')
                    write(v)
                }
                sb.append('}')
            }
            is JsonArray -> {
                sb.append('[')
                el.forEachIndexed { i, v -> if (i > 0) sb.append(','); write(v) }
                sb.append(']')
            }
            is JsonNull -> sb.append("null")
            is JsonPrimitive -> when {
                el.isString -> sb.append(el.toString())
                else -> el.content.toBigDecimalOrNull()?.let { sb.append(it.stripTrailingZeros().toPlainString()) } ?: sb.append(el.content)
            }
        }
    }
    write(json)
    return sha256Hex(sb.toString())
}

internal fun sha256Hex(s: String): String =
    MessageDigest.getInstance("SHA-256").digest(s.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }

/** SHA-256(userId + bundle_hash + 포인터) 앞 16바이트를 UUIDv7 모양(버전 7, variant 10)으로 맞춘 값 */
internal fun detId(userId: UUID, bundleHash: String, pointer: String): UUID {
    val d = MessageDigest.getInstance("SHA-256").digest((userId.toString() + bundleHash + pointer).toByteArray(Charsets.UTF_8))
    val b = d.copyOf(16)
    b[6] = ((b[6].toInt() and 0x0F) or 0x70).toByte()
    b[8] = ((b[8].toInt() and 0x3F) or 0x80).toByte()
    var msb = 0L
    var lsb = 0L
    for (i in 0 until 8) msb = (msb shl 8) or (b[i].toLong() and 0xFF)
    for (i in 8 until 16) lsb = (lsb shl 8) or (b[i].toLong() and 0xFF)
    return UUID(msb, lsb)
}

// ---------------------------------------------------------------- 내용 비교(UNCHANGED 판정)

internal data class FpSet(
    val warm: Boolean, val w: String?, val aw: String?, val reps: Int?, val dur: Int?, val dist: String?,
    val rpe: String?, val rir: Int?, val rest: Int?, val note: String?,
)

internal data class FpEx(val exerciseId: UUID, val note: String?, val sets: List<FpSet>)

internal data class FpSession(val startedAt: Long, val endedAt: Long?, val tz: String, val note: String?, val exs: List<FpEx>)

private fun d2(d: Double?) = d?.let { BigDecimal.valueOf(it).setScale(2, RoundingMode.HALF_UP).toPlainString() }
private fun d1(d: Double?) = d?.let { BigDecimal.valueOf(it).setScale(1, RoundingMode.HALF_UP).toPlainString() }
internal fun blankNull(s: String?) = s?.takeIf { it.isNotEmpty() }

internal fun fpSet(
    warm: Boolean, w: Double?, aw: Double?, reps: Int?, dur: Int?, dist: Double?, rpe: Double?, rir: Int?, rest: Int?, note: String?,
) = FpSet(warm, d2(w), d2(aw), reps, dur, d1(dist), d1(rpe), rir, rest, blankNull(note))

internal fun fpOf(s: WSession) = FpSession(
    s.startedAt.toEpochMilli(), s.endedAt.toEpochMilli(), s.tz, blankNull(s.note),
    s.exercises.map { e ->
        FpEx(e.exerciseId, blankNull(e.note), e.sets.map { fpSet(it.isWarmup, it.weightKg, it.addedWeightKg, it.reps, it.durationSec, it.distanceM, it.rpe, it.rir, it.restSec, it.note) })
    },
)
