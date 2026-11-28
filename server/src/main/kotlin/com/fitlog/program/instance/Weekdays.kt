package com.fitlog.program.instance

import com.fitlog.engine.ProgramDefinition

internal class WeekdayException(val field: String, message: String) : RuntimeException(message)

private val WEEKDAYS = setOf("MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN")

/**
 * 시작할 때 요일 바꾸기(contracts/v1.1 2절). 정의 사본의 days[].weekday 만 바꾼 새 정의를 돌려준다.
 * 잘못된 키·값은 field = weekdays.<key>, 적용 뒤 같은 요일 중복은 field = weekdays
 */
internal fun applyWeekdays(def: ProgramDefinition, weekdays: Map<String, String>): ProgramDefinition {
    if (weekdays.isEmpty()) return def
    val keys = def.days.map { it.key }.toSet()
    weekdays.forEach { (k, v) ->
        if (k !in keys) throw WeekdayException("weekdays.$k", "unknown day key")
        if (v !in WEEKDAYS) throw WeekdayException("weekdays.$k", "weekday must be one of ${WEEKDAYS.joinToString(", ")}")
    }
    val days = def.days.map { d -> weekdays[d.key]?.let { d.copy(weekday = it) } ?: d }
    val used = days.mapNotNull { it.weekday }
    if (used.size != used.toSet().size) throw WeekdayException("weekdays", "two days on the same weekday")
    return def.copy(days = days)
}
