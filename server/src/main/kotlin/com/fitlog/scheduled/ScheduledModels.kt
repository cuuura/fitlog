@file:UseSerializers(InstantSerializer::class, UUIDSerializer::class)

package com.fitlog.scheduled

import com.fitlog.core.InstantSerializer
import com.fitlog.core.UUIDSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.UseSerializers
import java.time.Instant
import java.util.UUID

/*
 * contracts/v1.0/scheduled-workout.md §2 (트랙 리드 소유, SW-A·SW-B 공용).
 * DB `scheduled_workout.items` jsonb 와 sync payload·REST 응답이 같은 모양이다.
 */

@Serializable
data class ScheduledSet(
    val isWarmup: Boolean = false,
    val targetWeightKg: Double? = null,
    val targetReps: Int? = null,
    val targetRepsMax: Int? = null,
    val targetRir: Int? = null,
    val targetRpe: Double? = null,
    val targetDurationSec: Int? = null,
)

@Serializable
data class ScheduledItem(
    val exerciseId: UUID,
    val note: String? = null,
    val restSec: Int? = null,
    val sets: List<ScheduledSet>,
)

enum class ScheduledStatus { PLANNED, IN_PROGRESS, DONE, SKIPPED }

@Serializable
data class ScheduledWorkout(
    val id: UUID,
    /** YYYY-MM-DD (사용자 현지 날짜) */
    val plannedDate: String,
    val title: String,
    val note: String? = null,
    val items: List<ScheduledItem>,
    val skippedAt: Instant? = null,
    /** readOnly */
    val source: String? = null,
    /** readOnly */
    val importBatchId: UUID? = null,
    /** readOnly */
    val updatedAt: Instant? = null,
    val deletedAt: Instant? = null,
    /** REST·MCP 응답 전용 계산 필드(sync payload 에는 넣지 않음) */
    val status: ScheduledStatus? = null,
    val sessionId: UUID? = null,
)

/** 검증 에러(JSON 포인터 경로, 메시지). 순수 함수: exerciseId 존재 여부는 호출자가 본다. */
fun validateScheduled(w: ScheduledWorkout, base: String = ""): List<Pair<String, String>> {
    val errs = mutableListOf<Pair<String, String>>()
    runCatching { java.time.LocalDate.parse(w.plannedDate) }.onFailure { errs += "$base/plannedDate" to "YYYY-MM-DD" }
    if (w.title.isBlank() || w.title.length > 100) errs += "$base/title" to "1~100 chars"
    if ((w.note?.length ?: 0) > 1000) errs += "$base/note" to "max 1000"
    if (w.items.isEmpty() || w.items.size > 30) errs += "$base/items" to "1~30 items"
    w.items.forEachIndexed { i, it ->
        val p = "$base/items/$i"
        if (it.restSec != null && it.restSec !in 0..3600) errs += "$p/restSec" to "0~3600"
        if (it.sets.isEmpty() || it.sets.size > 50) errs += "$p/sets" to "1~50 sets"
        it.sets.forEachIndexed { j, s ->
            val q = "$p/sets/$j"
            if (s.targetWeightKg != null && s.targetWeightKg < 0) errs += "$q/targetWeightKg" to ">= 0"
            if (s.targetReps != null && s.targetReps < 0) errs += "$q/targetReps" to ">= 0"
            if (s.targetRepsMax != null && (s.targetReps == null || s.targetRepsMax < s.targetReps)) errs += "$q/targetRepsMax" to "needs targetReps <= targetRepsMax"
            if (s.targetRir != null && s.targetRir !in 0..10) errs += "$q/targetRir" to "0~10"
            if (s.targetRpe != null && (s.targetRpe < 1 || s.targetRpe > 10 || (s.targetRpe * 2) % 1.0 != 0.0)) errs += "$q/targetRpe" to "1~10 step 0.5"
            if (s.targetDurationSec != null && s.targetDurationSec < 0) errs += "$q/targetDurationSec" to ">= 0"
        }
    }
    return errs
}
