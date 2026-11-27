package com.fitlog.engine

import java.math.BigDecimal
import java.math.RoundingMode
import kotlin.math.pow

/**
 * 계산 엔진 (engine.md). 순수 Kotlin: DB·HTTP·시계·난수에 의존하지 않는다.
 *
 * 해석(계약 보충):
 * - 판정은 COMPLETED 이벤트의 planSeq 가 아니라 "그 이벤트를 받는 시점의 state" 위치(nextDayIndex·week)의 계획 기준이다.
 * - plan() 의 "모두 성공" 가정에서 AMRAP_TABLE 의 amrapSet 은 max(목표 횟수, 증가분이 0보다 큰 가장 낮은 표 구간의 minReps) 회로 친다.
 * - CYCLE 규칙의 "이 사이클에서 AMRAP 목표 미달이 있었는지"는 failStreak[key] 에 센다(사이클 끝에 0으로 되돌림).
 * - FIXED 하중은 반올림하지 않는다(사용자가 정한 값 그대로).
 */
object ProgramEngine : ProgramCalculator {

    // ------------------------------------------------------------ 입력·초기 상태

    override fun requiredInputs(program: ProgramDefinition): Map<String, Needs> {
        val result = LinkedHashMap<String, Needs>()
        for (day in program.days) for (de in day.exercises) for (spec in de.sets) {
            when (val load = spec.load) {
                is Load.PercentTm -> result.putIfAbsent(stateKey(program, de.lift, load.of), Needs.TM)
                is Load.Working -> result.putIfAbsent(stateKey(program, de.lift, load.of), Needs.WORKING)
                else -> {}
            }
        }
        for ((key, rule) in program.progression) if (rule is Rule.Stages) result[stateKey(program, key, null)] = Needs.WORKING
        return result
    }

    override fun optionalInputs(program: ProgramDefinition): Set<String> {
        val required = requiredInputs(program)
        return program.progression.filter { it.value is Rule.Double }.keys
            .map { stateKey(program, it, null) }.filter { required[it] == Needs.WORKING }.toSet()
    }

    override fun initialState(program: ProgramDefinition, tm: Map<String, Double>, working: Map<String, Double>): ProgramState {
        val optional = optionalInputs(program)
        for ((key, needs) in requiredInputs(program)) {
            if (key in optional) continue
            val ok = if (needs == Needs.TM) tm.containsKey(key) else working.containsKey(key)
            require(ok) { "missing ${needs.name} value for key: $key" }
        }
        return ProgramState(
            tm = tm.mapValues { r2(it.value) },
            working = working.mapValues { r2(it.value) },
        )
    }

    // ------------------------------------------------------------ 계획

    override fun plan(program: ProgramDefinition, state: ProgramState, count: Int, settings: EngineSettings): List<PlannedDay> {
        val out = ArrayList<PlannedDay>()
        var s = state
        for (i in 0 until count) {
            val day = program.days[s.nextDayIndex]
            val expanded = expandDay(program, s, day, settings)
            val planSeq = s.seq + 1
            out += PlannedDay(
                planSeq = planSeq,
                dayIndex = s.nextDayIndex,
                dayKey = day.key,
                dayName = day.name,
                week = s.week,
                cycle = s.cycle,
                confirmed = i == 0,
                exercises = expanded.map { x ->
                    PlannedExercise(
                        key = x.de.lift,
                        exerciseId = x.exerciseId,
                        accessory = x.de.accessory,
                        sets = x.sets.mapIndexed { si, xs ->
                            PlannedSet("${day.key}.${x.index}.$si", xs.reps, xs.weight, xs.amrap, xs.warmup, xs.repsMax, xs.restSec)
                        },
                    )
                },
            )
            if (i < count - 1) {
                val next = apply(program, s, ProgramEvent.Completed(planSeq, assumeAllSuccess(program, day, expanded)), settings)
                // DOUBLE 키는 "모두 성공" 가정에서 무게 유지(범위 안 가정)
                val keys = program.progression.filter { it.value is Rule.Double }.keys
                s = if (keys.isEmpty()) next else next.copy(
                    working = next.working.filterKeys { it !in keys } + s.working.filterKeys { it in keys },
                    failStreak = next.failStreak.filterKeys { it !in keys } + s.failStreak.filterKeys { it in keys },
                )
            }
        }
        return out
    }

    private fun assumeAllSuccess(program: ProgramDefinition, day: Day, expanded: List<XEx>): List<PerformedExercise> =
        expanded.map { x ->
            val rule = program.progression[x.de.lift]
            val amrapIdx = if (rule is Rule.AmrapTable) amrapIndex(x) else -1
            PerformedExercise(
                liftKey = x.de.lift,
                accessory = x.de.accessory,
                sets = x.sets.mapIndexed { si, xs ->
                    var reps = xs.reps
                    if (si == amrapIdx && rule is Rule.AmrapTable) {
                        val lowestPositive = rule.table.filter { it.incrementKg > 0 }.minOfOrNull { it.minReps }
                        if (lowestPositive != null) reps = maxOf(reps, lowestPositive)
                    }
                    PerformedSet("${day.key}.${x.index}.$si", reps, xs.weight, xs.warmup)
                },
            )
        }

    // ------------------------------------------------------------ 세트 펼치기

    private class XSet(val reps: Int, val amrap: Boolean, val warmup: Boolean, val weight: Double?, val repsMax: Int? = null, val restSec: Int? = null)
    private class XEx(val de: DayExercise, val index: Int, val exerciseId: String, val sets: List<XSet>)

    private fun expandDay(p: ProgramDefinition, s: ProgramState, day: Day, settings: EngineSettings): List<XEx> =
        day.exercises.mapIndexedNotNull { ei, de ->
            val exerciseId = requireNotNull(p.lifts[de.lift]?.exercise?.id) { "lift has no exercise id: ${de.lift}" }
            val stageRule = p.progression[de.lift] as? Rule.Stages
            val sets = ArrayList<XSet>()
            var stageDone = false
            for (spec in de.sets) {
                val weekly = spec.weekly?.getOrNull(s.week - 1)
                if (weekly?.skip == true) continue
                val load = overrideValue(spec.load, weekly?.value)
                val addKg = weekly?.addKg ?: 0.0
                val rest = spec.restSec ?: de.restSec
                if (stageRule != null && !spec.warmup) {
                    if (stageDone) continue
                    stageDone = true
                    val idx = (s.stage[de.lift] ?: 0).coerceIn(0, stageRule.stages.lastIndex)
                    val st = stageRule.stages[idx]
                    val w = weightOf(p, s, de, load, exerciseId, settings, addKg)
                    repeat(st.sets) { n -> sets += XSet(st.reps, st.lastAmrap && n == st.sets - 1, false, w, null, rest) }
                } else {
                    val w = weightOf(p, s, de, load, exerciseId, settings, addKg)
                    val amrap = weekly?.amrap ?: spec.amrap
                    val repsMax = (weekly?.repsMax ?: spec.repsMax)?.takeIf { !amrap }
                    repeat(weekly?.count ?: spec.count) { sets += XSet(weekly?.reps ?: spec.reps, amrap, spec.warmup, w, repsMax, rest) }
                }
            }
            if (sets.isEmpty()) null else XEx(de, ei, exerciseId, sets)
        }

    private fun overrideValue(load: Load, value: Double?): Load = when {
        value == null -> load
        load is Load.PercentTm -> load.copy(value = value)
        load is Load.Working -> load.copy(value = value)
        else -> load
    }

    private fun weightOf(p: ProgramDefinition, s: ProgramState, de: DayExercise, load: Load, exerciseId: String, settings: EngineSettings, addKg: Double = 0.0): Double? {
        val barbell = exerciseId in settings.barbellExerciseIds
        return when (load) {
            is Load.PercentTm -> {
                val key = stateKey(p, de.lift, load.of)
                val base = checkNotNull(s.tm[key]) { "missing tm for key: $key" }
                roundWeight(base * load.value + addKg, p.roundingKg, p.barKg, barbell)
            }
            is Load.Working -> {
                val key = stateKey(p, de.lift, load.of)
                val base = s.working[key]
                    ?: if (p.progression[key] is Rule.Double) return null else error("missing working for key: $key")
                roundWeight(base * load.value + addKg, p.roundingKg, p.barKg, barbell)
            }
            is Load.Fixed -> load.kg + addKg
            Load.Bodyweight -> 0.0
            Load.NoLoad -> null
        }
    }

    /** 하중이 가리키는 실제 상태 키: of ?: 종목 키, 그리고 tmFrom 을 따라간다 */
    private fun stateKey(p: ProgramDefinition, lift: String, of: String?): String {
        var key = of ?: lift
        var guard = 0
        while (guard++ < 8) key = p.lifts[key]?.tmFrom ?: break
        return key
    }

    /** AMRAP_TABLE 이 볼 세트의 펼친 뒤 인덱스(amrapSet, 없으면 첫 AMRAP 세트). 없으면 -1 */
    private fun amrapIndex(x: XEx): Int =
        x.de.amrapSet ?: x.sets.indexOfFirst { it.amrap && !it.warmup }

    // ------------------------------------------------------------ 이벤트 적용

    private class M(s: ProgramState) {
        val tm = s.tm.toMutableMap()
        val working = s.working.toMutableMap()
        val stage = s.stage.toMutableMap()
        val failStreak = s.failStreak.toMutableMap()
        val pending = s.pendingTmDelta.toMutableMap()
        var week = s.week
        var cycle = s.cycle
        var nextDayIndex = s.nextDayIndex
        var seq = s.seq

        fun toState() = ProgramState(tm, working, stage, failStreak, pending, week, cycle, nextDayIndex, seq)
    }

    override fun apply(program: ProgramDefinition, state: ProgramState, event: ProgramEvent, settings: EngineSettings): ProgramState {
        val m = M(state)
        when (event) {
            is ProgramEvent.Adjusted -> {
                event.tm.forEach { (k, v) -> m.tm[k] = r2(v) }
                event.working.forEach { (k, v) -> m.working[k] = r2(v) }
            }
            is ProgramEvent.Skipped -> {
                m.seq += 1
                if (event.policy == SkipPolicy.FIXED_DATE) advanceDay(program, m)
            }
            is ProgramEvent.Completed -> {
                judge(program, state, event, settings, m)
                m.seq += 1
                advanceDay(program, m)
            }
        }
        return m.toState()
    }

    private fun judge(p: ProgramDefinition, s: ProgramState, event: ProgramEvent.Completed, settings: EngineSettings, m: M) {
        val day = p.days[s.nextDayIndex]
        val expanded = expandDay(p, s, day, settings)
        // plannedSetKey -> 실제 횟수(워밍업 제외, 같은 키가 여럿이면 최대)
        val performed = HashMap<String, Int>()
        for (pe in event.exercises) for (ps in pe.sets) {
            val key = ps.plannedSetKey ?: continue
            if (ps.isWarmup) continue
            performed.merge(key, ps.reps ?: 0, ::maxOf)
        }
        val weights = HashMap<String, Double>()
        for (pe in event.exercises) for (ps in pe.sets) {
            val key = ps.plannedSetKey ?: continue
            if (ps.isWarmup) continue
            ps.weightKg?.let { weights[key] = it }
        }
        fun repsOf(x: XEx, si: Int): Int = performed["${day.key}.${x.index}.$si"] ?: 0
        fun setOk(x: XEx, si: Int): Boolean = repsOf(x, si) >= x.sets[si].reps
        fun allOk(xs: List<XEx>): Boolean = xs.all { x -> x.sets.indices.all { si -> x.sets[si].warmup || setOk(x, si) } }

        val counted = expanded.filter { !it.de.accessory && it.de.countsForProgression }
        for ((key, rule) in p.progression) {
            val xs = counted.filter { it.de.lift == key }
            if (xs.isEmpty()) continue
            when (rule) {
                is Rule.NoRule -> {}
                is Rule.Linear -> {
                    val w = m.working[key] ?: continue
                    if (allOk(xs)) {
                        m.working[key] = r2(w + rule.incrementKg)
                        m.failStreak[key] = 0
                    } else {
                        val fs = (m.failStreak[key] ?: 0) + 1
                        if (fs >= rule.failuresBeforeDeload) {
                            m.working[key] = r2(w * (1 - rule.deloadPercent))
                            m.failStreak[key] = 0
                        } else m.failStreak[key] = fs
                    }
                }
                is Rule.Double -> {
                    val judged = xs.flatMap { x -> x.sets.indices.filter { !x.sets[it].warmup }.map { x to it } }
                    if (judged.isEmpty()) continue
                    val w = m.working[key] ?: judged
                        .mapNotNull { (x, si) -> weights["${day.key}.${x.index}.$si"]?.takeIf { it > 0.0 } }
                        .minOrNull()?.let { r2(it) } ?: continue
                    m.working[key] = w
                    if (judged.all { (x, si) -> repsOf(x, si) >= (x.sets[si].repsMax ?: x.sets[si].reps) }) {
                        m.working[key] = r2(w + rule.incrementKg)
                        m.failStreak[key] = 0
                    } else if (judged.any { (x, si) -> repsOf(x, si) < x.sets[si].reps }) {
                        val fs = (m.failStreak[key] ?: 0) + 1
                        if (fs >= rule.failuresBeforeDeload) {
                            m.working[key] = r2(w * (1 - rule.deloadPercent))
                            m.failStreak[key] = 0
                        } else m.failStreak[key] = fs
                    } else m.failStreak[key] = 0
                }
                is Rule.Stages -> {
                    val w = m.working[key] ?: continue
                    if (allOk(xs)) {
                        m.working[key] = r2(w + rule.incrementKg)
                    } else {
                        val cur = (m.stage[key] ?: 0).coerceIn(0, rule.stages.lastIndex)
                        if (cur < rule.stages.lastIndex) {
                            m.stage[key] = cur + 1
                        } else {
                            m.stage[key] = 0
                            m.working[key] = r2(w * (1 - rule.deloadPercent))
                        }
                    }
                }
                is Rule.AmrapTable -> {
                    val x = xs.first()
                    val idx = amrapIndex(x)
                    if (idx < 0 || idx >= x.sets.size) continue
                    val reps = repsOf(x, idx)
                    val row = rule.table
                        .filter { reps >= it.minReps && (it.maxReps == null || reps <= it.maxReps) }
                        .maxByOrNull { it.minReps }
                    val delta = row?.incrementKg ?: 0.0
                    m.pending[key] = r2((m.pending[key] ?: 0.0) + delta)
                    val fs = if (delta == 0.0) (m.failStreak[key] ?: 0) + 1 else 0
                    m.failStreak[key] = fs
                    if (rule.applyAt == ApplyAt.SESSION) {
                        val tm = m.tm[key] ?: continue
                        var next = tm + (m.pending[key] ?: 0.0)
                        m.pending.remove(key)
                        if (fs >= rule.failuresBeforeDeload) {
                            next *= (1 - rule.deloadPercent)
                            m.failStreak[key] = 0
                        }
                        m.tm[key] = r2(next)
                    }
                }
                is Rule.Cycle -> {
                    // 사이클의 마지막 주는 제외하고 AMRAP 세트 목표 미달을 센다
                    if (p.cycleWeeks != null && s.week >= p.cycleWeeks) continue
                    val miss = xs.any { x -> x.sets.indices.any { si -> x.sets[si].amrap && !x.sets[si].warmup && !setOk(x, si) } }
                    if (miss) m.failStreak[key] = (m.failStreak[key] ?: 0) + 1
                }
            }
        }
    }

    /** 다음 날로 넘긴다. 마지막 날 다음이면 주(필요하면 사이클)를 넘기고 주·사이클 끝 처리를 한다 */
    private fun advanceDay(p: ProgramDefinition, m: M) {
        m.nextDayIndex += 1
        if (m.nextDayIndex < p.days.size) return
        m.nextDayIndex = 0
        m.week += 1
        weekEnd(p, m)
        if (p.cycleWeeks != null && m.week > p.cycleWeeks) {
            m.week = 1
            m.cycle += 1
            cycleEnd(p, m)
        }
    }

    private fun weekEnd(p: ProgramDefinition, m: M) {
        for ((key, rule) in p.progression) {
            if (rule !is Rule.AmrapTable || rule.applyAt != ApplyAt.WEEK_END) continue
            val tm = m.tm[key] ?: continue
            var next = tm + (m.pending[key] ?: 0.0)
            m.pending.remove(key)
            if ((m.failStreak[key] ?: 0) >= rule.failuresBeforeDeload) {
                next *= (1 - rule.deloadPercent)
                m.failStreak[key] = 0
            }
            m.tm[key] = r2(next)
        }
    }

    private fun cycleEnd(p: ProgramDefinition, m: M) {
        for ((key, rule) in p.progression) {
            if (rule !is Rule.Cycle) continue
            val tm = m.tm[key] ?: continue
            val missed = (m.failStreak[key] ?: 0) > 0
            m.tm[key] = r2(if (missed) tm * (1 - rule.deloadPercent) else tm + rule.incrementKg)
            m.failStreak[key] = 0
        }
    }

    // ------------------------------------------------------------ 1RM·반올림

    override fun estimateOneRm(formula: E1rmFormula, weightKg: Double?, reps: Int?): Double? {
        if (weightKg == null || reps == null || weightKg <= 0.0 || reps !in 1..10) return null
        val v = when (formula) {
            E1rmFormula.EPLEY -> if (reps == 1) weightKg else weightKg * (1 + reps / 30.0)
            E1rmFormula.BRZYCKI -> weightKg * 36.0 / (37 - reps)
            E1rmFormula.LOMBARDI -> weightKg * reps.toDouble().pow(0.10)
        }
        return r2(v)
    }

    override fun roundWeight(kg: Double, roundingKg: Double, barKg: Double?, barbell: Boolean): Double {
        val x = BigDecimal(kg.toString()).setScale(6, RoundingMode.HALF_UP)
        val step = BigDecimal(roundingKg.toString())
        // 가장 가까운 배수, 동률은 내림(양수에서 HALF_DOWN)
        val q = x.divide(step, 12, RoundingMode.HALF_UP).setScale(0, RoundingMode.HALF_DOWN)
        var result = q.multiply(step).toDouble()
        if (barbell && barKg != null && result < barKg) result = barKg
        return result
    }

    private fun r2(x: Double): Double = BigDecimal(x.toString()).setScale(2, RoundingMode.HALF_UP).toDouble()
}
