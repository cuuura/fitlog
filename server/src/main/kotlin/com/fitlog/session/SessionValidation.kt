package com.fitlog.session

import com.fitlog.core.Kg
import com.fitlog.core.validation
import java.math.BigDecimal
import java.math.RoundingMode
import java.time.ZoneId


internal fun checkTz(tz: String, field: String = "tz") {
    if (tz !in ZoneId.getAvailableZoneIds()) validation("tz must be a valid IANA time zone", field)
}

private fun join(path: String, name: String) = if (path.isEmpty()) name else "$path.$name"

internal val SET_TYPES = setOf("NORMAL", "DROP", "FAILURE")

internal fun checkSupersetGroup(g: String?, field: String) {
    if (g != null && (g.isEmpty() || g.length > 8)) validation("supersetGroup must be 1 to 8 characters", field)
}

internal fun bd2(d: Double): BigDecimal = Kg.of(d)
internal fun bd1(d: Double): BigDecimal = BigDecimal.valueOf(d).setScale(1, RoundingMode.HALF_UP)

/**
 * 세트 필드 검증·정규화. [type] 은 종목 유형(알 수 없으면 null: 필수 필드 검사 생략).
 * [path] 는 에러 field 의 접두어(예 "exercises[0].sets[2]"), 비어 있으면 필드명만 쓴다.
 * completedAt 이 null 인 미완료 세트는 유형별 필수 필드 검사를 건너뛴다.
 */
internal fun checkSet(s: WorkoutSet, type: String?, path: String): WorkoutSet {
    fun bad(name: String, msg: String): Nothing = validation(msg, join(path, name))
    if (s.position < 0) bad("position", "position must be >= 0")
    s.weightKg?.let { if (!it.isFinite() || it < 0 || it > 9999.99) bad("weightKg", "weightKg must be between 0 and 9999.99") }
    s.addedWeightKg?.let {
        if (!it.isFinite() || it < -9999.99 || it > 9999.99) bad("addedWeightKg", "addedWeightKg must be between -9999.99 and 9999.99")
    }
    if (s.setType !in SET_TYPES) bad("setType", "setType must be one of NORMAL, DROP, FAILURE")
    s.reps?.let { if (it < 0) bad("reps", "reps must be >= 0") }
    s.durationSec?.let { if (it < 0) bad("durationSec", "durationSec must be >= 0") }
    s.distanceM?.let { if (!it.isFinite() || it < 0 || it > 9_999_999.0) bad("distanceM", "distanceM must be >= 0") }
    s.rpe?.let {
        if (!it.isFinite() || it < 1 || it > 10 || (it * 2) % 1.0 != 0.0) bad("rpe", "rpe must be between 1 and 10 in 0.5 steps")
    }
    s.rir?.let { if (it < 0 || it > 10) bad("rir", "rir must be between 0 and 10") }
    s.restSec?.let { if (it < 0) bad("restSec", "restSec must be >= 0") }
    s.targetReps?.let { if (it < 0) bad("targetReps", "targetReps must be >= 0") }
    s.targetRepsMax?.let { if (it < 0) bad("targetRepsMax", "targetRepsMax must be >= 0") }
    s.targetRir?.let { if (it < 0 || it > 10) bad("targetRir", "targetRir must be between 0 and 10") }
    s.targetRestSec?.let { if (it < 0 || it > 3600) bad("targetRestSec", "targetRestSec must be between 0 and 3600") }
    s.targetWeightKg?.let { if (!it.isFinite() || it < 0 || it > 9999.99) bad("targetWeightKg", "targetWeightKg must be between 0 and 9999.99") }
    if (s.completedAt != null && type != null) {
        val required: List<Pair<String, Any?>> = when (type) {
            "BARBELL", "DUMBBELL", "MACHINE" -> listOf("weightKg" to s.weightKg, "reps" to s.reps)
            "BODYWEIGHT", "BAND" -> listOf("reps" to s.reps)
            "CARDIO" -> listOf("durationSec" to s.durationSec)
            else -> emptyList()
        }
        required.forEach { (name, v) -> if (v == null) bad(name, "$name is required for $type") }
    }
    return s.copy(
        weightKg = s.weightKg?.let { bd2(it).toDouble() },
        addedWeightKg = s.addedWeightKg?.let { bd2(it).toDouble() },
        distanceM = s.distanceM?.let { bd1(it).toDouble() },
        targetWeightKg = s.targetWeightKg?.let { bd2(it).toDouble() },
    )
}
