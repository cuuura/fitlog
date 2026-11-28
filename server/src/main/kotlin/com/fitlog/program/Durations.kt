package com.fitlog.program

import com.fitlog.core.AppJson
import com.fitlog.engine.Needs
import com.fitlog.engine.PlannedExercise
import com.fitlog.engine.ProgramCalculator
import com.fitlog.engine.ProgramDefinition
import kotlinx.serialization.Serializable
import java.util.concurrent.ConcurrentHashMap

/** 프로그램 한 회당 어림 시간(분) 범위. openapi ProgramSummary.sessionMinutes */
@Serializable
data class SessionMinutes(val min: Int, val max: Int)

/** contracts/v1.1/program-start-ext.md 3절 어림 규칙. 순수 함수 */
object Durations {
    private const val WORK_SEC = 40
    private const val WARMUP_WORK_SEC = 30
    private const val WARMUP_REST_SEC = 60
    private const val ACCESSORY_REST_SEC = 90
    private const val MAIN_REST_SEC = 150
    private const val SWITCH_SEC = 120

    /** 운동 한 회의 어림 분: 올림 후 5분 단위 반올림, 최소 5 */
    fun estimateMinutes(exercises: List<PlannedExercise>): Int {
        var sec = 0
        var counted = 0
        for (ex in exercises) {
            if (ex.sets.isEmpty()) continue
            if (counted > 0) sec += SWITCH_SEC
            counted++
            ex.sets.forEachIndexed { i, s ->
                val work = if (s.isWarmup) WARMUP_WORK_SEC else WORK_SEC
                val rest = s.restSec ?: when {
                    s.isWarmup -> WARMUP_REST_SEC
                    ex.accessory -> ACCESSORY_REST_SEC
                    else -> MAIN_REST_SEC
                }
                sec += work + if (i == ex.sets.lastIndex) 0 else rest
            }
        }
        val minutes = (sec + 59) / 60
        return maxOf(5, (minutes + 2) / 5 * 5)
    }

    private val cache = ConcurrentHashMap<String, SessionMinutes?>()

    /** 정의 텍스트 기준으로 프로세스 안에 캐시한 [sessionMinutes]. 계산 실패면 null */
    fun sessionMinutes(engine: ProgramCalculator, definitionText: String): SessionMinutes? {
        if (cache.size > 512) cache.clear()
        val hit = cache[definitionText]
        if (hit != null) return hit
        val v = runCatching {
            sessionMinutes(engine, AppJson.decodeFromString(ProgramDefinition.serializer(), definitionText))
        }.getOrNull()
        if (v != null) cache[definitionText] = v
        return v
    }

    /**
     * 필수 입력을 모두 100kg 으로 둔 가짜 상태로 한 바퀴(최대 64회차)를 펼친 회차별 어림의 최소·최대.
     * 계산 실패면 null
     */
    fun sessionMinutes(engine: ProgramCalculator, def: ProgramDefinition): SessionMinutes? = runCatching {
        val needs = engine.requiredInputs(def)
        val tm = needs.filterValues { it == Needs.TM }.mapValues { 100.0 }
        val working = needs.filterValues { it == Needs.WORKING }.mapValues { 100.0 }
        val state = engine.initialState(def, tm, working)
        val count = minOf(def.days.size * maxOf(def.cycleWeeks ?: 1, 1), 64)
        val mins = engine.plan(def, state, count).map { estimateMinutes(it.exercises) }
        if (mins.isEmpty()) null else SessionMinutes(mins.min(), mins.max())
    }.getOrNull()
}
