package com.fitlog.program.schema

import com.fitlog.core.ApiException
import com.fitlog.core.ErrorCode
import com.fitlog.core.ErrorDetail
import com.fitlog.engine.ApplyAt
import com.fitlog.engine.Day
import com.fitlog.engine.DayExercise
import com.fitlog.engine.ExerciseRef
import com.fitlog.engine.Lift
import com.fitlog.engine.Load
import com.fitlog.engine.ProgramDefinition
import com.fitlog.engine.ProgramRules
import com.fitlog.engine.Rule
import com.fitlog.engine.SetSpec
import com.fitlog.engine.Stage
import com.fitlog.engine.TableRow
import com.fitlog.engine.WeeklyOverride
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** 종목 참조 풀기 결과 */
sealed interface ResolveResult {
    data class Found(val exerciseId: String) : ResolveResult
    data class Failed(val message: String) : ResolveResult
}

/** DB 조회를 검증기 밖에 두기 위한 함수. ref 는 id 또는 name 중 하나만 채워져 있다 */
typealias ExerciseResolver = (ExerciseRef) -> ResolveResult

sealed interface ValidationResult {
    data class Valid(val definition: ProgramDefinition) : ValidationResult
    data class Invalid(val errors: List<ErrorDetail>) : ValidationResult
}

/** 실패면 400 VALIDATION_FAILED(details = 에러 목록)로 던진다 */
fun ValidationResult.orThrow(): ProgramDefinition = when (this) {
    is ValidationResult.Valid -> definition
    is ValidationResult.Invalid ->
        throw ApiException(ErrorCode.VALIDATION_FAILED, "program definition is invalid", details = errors)
}

/**
 * program.schema.json 검증기(순수). 모든 에러를 모아서 돌려준다. 경로는 JSON 포인터.
 * 성공하면 이름 종목 참조가 id 로 풀린 [ProgramDefinition] 을 준다.
 */
object ProgramValidator {
    fun validate(json: JsonElement, resolver: ExerciseResolver): ValidationResult {
        val v = Run(resolver)
        val def = v.program(json)
        return if (v.errors.isEmpty() && def != null) ValidationResult.Valid(def)
        else ValidationResult.Invalid(v.errors.toList())
    }

    /** 이름 비교용: 모든 공백 제거 + 소문자 */
    fun normalizeName(s: String): String = s.filter { !it.isWhitespace() }.lowercase()
}

private val KEY_RE = Regex("^[a-z][a-z0-9_]{0,31}$")
private val DAY_KEY_RE = Regex("^[A-Za-z0-9_]{1,16}$")
private val UUID_RE = Regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
private val PROGRAM_CATEGORIES = listOf("BODYBUILDING", "POWERBUILDING", "POWERLIFTING", "GENERAL_STRENGTH", "BODYWEIGHT")
private val PROGRAM_LEVELS = listOf("BEGINNER", "INTERMEDIATE", "ADVANCED")
private val FAMILY_RE = Regex("^[a-z0-9-]{1,40}$")
private val ROUNDING = listOf(0.5, 1.0, 1.25, 2.5, 5.0)
private val WEEKDAYS = listOf("MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN")

private fun esc(k: String) = k.replace("~", "~0").replace("/", "~1")

private class SetInfo(val exPath: String, val lift: String, val index: Int, val amrap: Boolean, val load: Load, val warmup: Boolean)

private class Run(val resolver: ExerciseResolver) {
    val errors = mutableListOf<ErrorDetail>()
    var cycleWeeks: Int? = null
    var liftKeys: Set<String> = emptySet()
    val setInfos = mutableListOf<SetInfo>()
    val dayKeys = mutableMapOf<String, Int>()

    fun err(path: String, msg: String) {
        errors += ErrorDetail(path, msg)
    }

    // ------------------------------------------------------------ 기본형

    fun obj(el: JsonElement?, path: String): JsonObject? {
        if (el is JsonObject) return el
        err(path, "must be an object")
        return null
    }

    fun checkKeys(o: JsonObject, path: String, allowed: Set<String>, required: Set<String>) {
        for (k in o.keys) if (k !in allowed) err("$path/${esc(k)}", "unknown property")
        for (k in required) if (k !in o) err(path, "missing required property '$k'")
    }

    fun str(o: JsonObject, key: String, path: String, min: Int = 0, max: Int = Int.MAX_VALUE, pattern: Regex? = null): String? {
        val el = o[key] ?: return null
        val p = "$path/$key"
        if (el !is JsonPrimitive || !el.isString) { err(p, "must be a string"); return null }
        val s = el.content
        if (s.length < min) { err(p, "must be at least $min characters"); return null }
        if (s.length > max) { err(p, "must be at most $max characters"); return null }
        if (pattern != null && !pattern.matches(s)) { err(p, "must match pattern ${pattern.pattern}"); return null }
        return s
    }

    fun bool(o: JsonObject, key: String, path: String): Boolean? {
        val el = o[key] ?: return null
        val p = el as? JsonPrimitive
        if (p == null || p.isString || p.content != "true" && p.content != "false") {
            err("$path/$key", "must be a boolean"); return null
        }
        return p.content == "true"
    }

    private fun numberOrNull(el: JsonElement?): Double? =
        (el as? JsonPrimitive)?.takeIf { !it.isString && it !is JsonNull }?.content?.toDoubleOrNull()
            ?.takeIf { !it.isNaN() && !it.isInfinite() }

    fun num(o: JsonObject, key: String, path: String, min: Double? = null, max: Double? = null, exclMin: Double? = null): Double? {
        val el = o[key] ?: return null
        val p = "$path/$key"
        val d = numberOrNull(el)
        if (d == null) { err(p, "must be a number"); return null }
        if (exclMin != null && d <= exclMin) { err(p, "must be greater than ${fmt(exclMin)}"); return null }
        if (min != null && d < min) { err(p, "must be at least ${fmt(min)}"); return null }
        if (max != null && d > max) { err(p, "must be at most ${fmt(max)}"); return null }
        return d
    }

    fun int(o: JsonObject, key: String, path: String, min: Int? = null, max: Int? = null): Int? {
        val el = o[key] ?: return null
        val p = "$path/$key"
        val d = numberOrNull(el)
        if (d == null || d != Math.floor(d) || d > Int.MAX_VALUE || d < Int.MIN_VALUE) {
            err(p, "must be an integer"); return null
        }
        val i = d.toInt()
        if (min != null && i < min) { err(p, "must be at least $min"); return null }
        if (max != null && i > max) { err(p, "must be at most $max"); return null }
        return i
    }

    fun enum(o: JsonObject, key: String, path: String, values: List<String>): String? {
        val el = o[key] ?: return null
        val s = (el as? JsonPrimitive)?.takeIf { it.isString }?.content
        if (s == null || s !in values) { err("$path/$key", "must be one of ${values.joinToString(", ")}"); return null }
        return s
    }

    fun arr(o: JsonObject, key: String, path: String, min: Int = 0, max: Int = Int.MAX_VALUE): JsonArray? {
        val el = o[key] ?: return null
        val p = "$path/$key"
        if (el !is JsonArray) { err(p, "must be an array"); return null }
        if (el.size < min) { err(p, "must have at least $min item(s)"); return null }
        if (el.size > max) { err(p, "must have at most $max item(s)"); return null }
        return el
    }

    private fun fmt(d: Double) = if (d == Math.floor(d)) d.toLong().toString() else d.toString()

    // ------------------------------------------------------------ 최상위

    fun program(json: JsonElement): ProgramDefinition? {
        val o = obj(json, "") ?: return null
        checkKeys(
            o, "",
            setOf("schemaVersion", "name", "description", "category", "level", "family", "variantLabel", "aka", "rules", "tmPercent", "workingPercent", "roundingKg", "barKg", "cycleWeeks", "lifts", "progression", "days"),
            setOf("schemaVersion", "name", "lifts", "days"),
        )
        if ("schemaVersion" in o && numberOrNull(o["schemaVersion"]) != 1.0) err("/schemaVersion", "must be 1")
        val name = str(o, "name", "", 1, 80)
        val description = str(o, "description", "", 0, 2000)
        val category = enum(o, "category", "", PROGRAM_CATEGORIES)
        val level = enum(o, "level", "", PROGRAM_LEVELS)
        val family = str(o, "family", "", pattern = FAMILY_RE)
        val variantLabel = str(o, "variantLabel", "", 1, 30)
        if ("family" in o && "variantLabel" !in o) err("/variantLabel", "required when 'family' is present")
        val aka = aka(o)
        val rules = rules(o)
        val tmPercent = num(o, "tmPercent", "", exclMin = 0.0, max = 1.0)
        val workingPercent = num(o, "workingPercent", "", exclMin = 0.0, max = 1.0)
        val roundingKg = if ("roundingKg" in o) {
            val d = numberOrNull(o["roundingKg"])
            if (d == null || d !in ROUNDING) { err("/roundingKg", "must be one of 0.5, 1, 1.25, 2.5, 5"); null } else d
        } else null
        val barKg = num(o, "barKg", "", min = 0.0)
        cycleWeeks = int(o, "cycleWeeks", "", 1, 52)

        // lifts 키 집합은 의미 검사용으로 먼저 모은다(형식이 틀린 키도 포함)
        val liftsEl = o["lifts"]
        if (liftsEl is JsonObject) liftKeys = liftsEl.keys.toSet()
        val lifts = lifts(o)
        val progression = progression(o)
        val days = days(o)
        crossChecks(progression)

        if (errors.isNotEmpty() || name == null || lifts == null || days == null) return null
        return ProgramDefinition(
            schemaVersion = 1,
            name = name,
            description = description,
            category = category,
            level = level,
            family = family,
            variantLabel = variantLabel,
            aka = aka,
            rules = rules,
            tmPercent = tmPercent ?: 0.9,
            workingPercent = workingPercent ?: 0.8,
            roundingKg = roundingKg ?: 2.5,
            barKg = barKg ?: 20.0,
            cycleWeeks = cycleWeeks,
            lifts = lifts,
            progression = progression ?: emptyMap(),
            days = days,
        )
    }

    fun aka(o: JsonObject): List<String>? {
        val a = arr(o, "aka", "", 0, 5) ?: return null
        val out = mutableListOf<String>()
        a.forEachIndexed { i, el ->
            if (el !is JsonPrimitive || !el.isString) { err("/aka/$i", "must be a string"); return@forEachIndexed }
            if (el.content.length !in 1..40) { err("/aka/$i", "must be 1 to 40 characters"); return@forEachIndexed }
            out += el.content
        }
        return out
    }

    fun rules(o: JsonObject): ProgramRules? {
        val el = o["rules"] ?: return null
        val r = obj(el, "/rules") ?: return null
        checkKeys(r, "/rules", setOf("progress", "failure", "deload"), setOf("progress", "failure", "deload"))
        val progress = str(r, "progress", "/rules", 1, 120)
        val failure = str(r, "failure", "/rules", 1, 120)
        val deload = str(r, "deload", "/rules", 1, 120)
        if (progress == null || failure == null || deload == null) return null
        return ProgramRules(progress, failure, deload)
    }

    // ------------------------------------------------------------ lifts

    fun lifts(top: JsonObject): Map<String, Lift>? {
        val el = top["lifts"] ?: return null
        val m = obj(el, "/lifts") ?: return null
        if (m.isEmpty()) { err("/lifts", "must have at least 1 property"); return null }
        val out = linkedMapOf<String, Lift>()
        for ((k, v) in m) {
            val p = "/lifts/${esc(k)}"
            if (!KEY_RE.matches(k)) err(p, "key must match pattern ${KEY_RE.pattern}")
            lift(v, p)?.let { out[k] = it }
        }
        return out
    }

    fun lift(el: JsonElement, path: String): Lift? {
        val o = obj(el, path) ?: return null
        checkKeys(o, path, setOf("exercise", "tmFrom"), setOf("exercise"))
        val ex = o["exercise"]?.let { exerciseRef(it, "$path/exercise") }
        val tmFrom = str(o, "tmFrom", path)
        if (tmFrom != null && tmFrom !in liftKeys) err("$path/tmFrom", "'$tmFrom' is not a key in lifts")
        return if (ex != null) Lift(ex, tmFrom) else null
    }

    fun exerciseRef(el: JsonElement, path: String): ExerciseRef? {
        val o = obj(el, path) ?: return null
        for (k in o.keys) if (k != "id" && k != "name") err("$path/${esc(k)}", "unknown property")
        val hasId = "id" in o
        val hasName = "name" in o
        if (hasId == hasName) {
            err(path, "exactly one of 'id' or 'name' is required")
            return null
        }
        val ref: ExerciseRef = if (hasId) {
            val id = str(o, "id", path) ?: return null
            if (!UUID_RE.matches(id)) { err("$path/id", "must be a UUID"); return null }
            ExerciseRef(id = id.lowercase())
        } else {
            val name = str(o, "name", path, min = 1) ?: return null
            ExerciseRef(name = name)
        }
        return when (val r = resolver(ref)) {
            is ResolveResult.Found -> ExerciseRef(id = r.exerciseId)
            is ResolveResult.Failed -> { err(path + if (hasId) "/id" else "/name", r.message); null }
        }
    }

    // ------------------------------------------------------------ progression

    fun progression(top: JsonObject): Map<String, Rule>? {
        val el = top["progression"] ?: return null
        val m = obj(el, "/progression") ?: return null
        val out = linkedMapOf<String, Rule>()
        for ((k, v) in m) {
            val p = "/progression/${esc(k)}"
            if (!KEY_RE.matches(k)) err(p, "key must match pattern ${KEY_RE.pattern}")
            else if (k !in liftKeys) err(p, "'$k' is not a key in lifts")
            rule(v, p)?.let { out[k] = it }
        }
        return out
    }

    private val ruleTypes = listOf("LINEAR", "AMRAP_TABLE", "CYCLE", "STAGES", "DOUBLE", "NONE")

    fun rule(el: JsonElement, path: String): Rule? {
        val o = obj(el, path) ?: return null
        if ("type" !in o) { err(path, "missing required property 'type'"); return null }
        val type = enum(o, "type", path, ruleTypes) ?: return null
        when (type) {
            "LINEAR" -> {
                checkKeys(o, path, setOf("type", "incrementKg", "failuresBeforeDeload", "deloadPercent"), setOf("type", "incrementKg"))
                val inc = num(o, "incrementKg", path)
                val f = int(o, "failuresBeforeDeload", path, min = 1)
                val d = num(o, "deloadPercent", path, 0.0, 0.5)
                val ok = inc != null && (!o.containsKey("failuresBeforeDeload") || f != null) && (!o.containsKey("deloadPercent") || d != null)
                return if (ok) Rule.Linear(inc!!, f ?: 3, d ?: 0.1) else null
            }
            "AMRAP_TABLE" -> {
                checkKeys(o, path, setOf("type", "table", "applyAt", "failuresBeforeDeload", "deloadPercent"), setOf("type", "table"))
                val rows = arr(o, "table", path, min = 1)?.mapIndexed { i, r -> tableRow(r, "$path/table/$i") }
                val applyAt = enum(o, "applyAt", path, listOf("WEEK_END", "SESSION"))
                val f = int(o, "failuresBeforeDeload", path, min = 1)
                val d = num(o, "deloadPercent", path, 0.0, 0.5)
                val ok = rows != null && rows.all { it != null } && (!o.containsKey("applyAt") || applyAt != null) &&
                    (!o.containsKey("failuresBeforeDeload") || f != null) && (!o.containsKey("deloadPercent") || d != null)
                return if (ok) {
                    Rule.AmrapTable(rows!!.filterNotNull(), applyAt?.let { ApplyAt.valueOf(it) } ?: ApplyAt.WEEK_END, f ?: 2, d ?: 0.1)
                } else null
            }
            "DOUBLE" -> {
                checkKeys(o, path, setOf("type", "incrementKg", "failuresBeforeDeload", "deloadPercent"), setOf("type", "incrementKg"))
                val inc = num(o, "incrementKg", path)
                val f = int(o, "failuresBeforeDeload", path, min = 1)
                val d = num(o, "deloadPercent", path, 0.0, 0.5)
                val ok = inc != null && (!o.containsKey("failuresBeforeDeload") || f != null) && (!o.containsKey("deloadPercent") || d != null)
                return if (ok) Rule.Double(inc!!, f ?: 3, d ?: 0.1) else null
            }
            "CYCLE" -> {
                checkKeys(o, path, setOf("type", "incrementKg", "deloadPercent"), setOf("type", "incrementKg"))
                val inc = num(o, "incrementKg", path)
                val d = num(o, "deloadPercent", path, 0.0, 0.5)
                return if (inc != null && (!o.containsKey("deloadPercent") || d != null)) Rule.Cycle(inc, d ?: 0.1) else null
            }
            "STAGES" -> {
                checkKeys(o, path, setOf("type", "incrementKg", "stages", "deloadPercent"), setOf("type", "incrementKg", "stages"))
                val inc = num(o, "incrementKg", path)
                val stages = arr(o, "stages", path, min = 1)?.mapIndexed { i, s -> stage(s, "$path/stages/$i") }
                val d = num(o, "deloadPercent", path, 0.0, 0.5)
                val ok = inc != null && stages != null && stages.all { it != null } && (!o.containsKey("deloadPercent") || d != null)
                return if (ok) Rule.Stages(inc!!, stages!!.filterNotNull(), d ?: 0.15) else null
            }
            else -> {
                checkKeys(o, path, setOf("type"), setOf("type"))
                return Rule.NoRule
            }
        }
    }

    fun tableRow(el: JsonElement, path: String): TableRow? {
        val o = obj(el, path) ?: return null
        checkKeys(o, path, setOf("minReps", "maxReps", "incrementKg"), setOf("minReps", "incrementKg"))
        val min = int(o, "minReps", path, min = 0)
        val max = int(o, "maxReps", path, min = 0)
        val inc = num(o, "incrementKg", path)
        if (min != null && max != null && max < min) { err("$path/maxReps", "must be at least minReps"); return null }
        return if (min != null && inc != null && (!o.containsKey("maxReps") || max != null)) TableRow(min, max, inc) else null
    }

    fun stage(el: JsonElement, path: String): Stage? {
        val o = obj(el, path) ?: return null
        checkKeys(o, path, setOf("sets", "reps", "lastAmrap"), setOf("sets", "reps"))
        val sets = int(o, "sets", path, min = 1)
        val reps = int(o, "reps", path, min = 1)
        val last = bool(o, "lastAmrap", path)
        return if (sets != null && reps != null && (!o.containsKey("lastAmrap") || last != null)) Stage(sets, reps, last ?: false) else null
    }

    // ------------------------------------------------------------ days

    fun days(top: JsonObject): List<Day>? {
        val a = arr(top, "days", "", 1, 14) ?: return null
        val out = a.mapIndexed { i, d -> day(d, "/days/$i", i) }
        return if (out.all { it != null }) out.filterNotNull() else null
    }

    fun day(el: JsonElement, path: String, index: Int): Day? {
        val o = obj(el, path) ?: return null
        checkKeys(o, path, setOf("key", "name", "weekday", "exercises"), setOf("key", "name", "exercises"))
        val key = str(o, "key", path, pattern = DAY_KEY_RE)
        if (key != null) {
            val first = dayKeys[key]
            if (first != null) err("$path/key", "duplicate day key '$key' (also /days/$first/key)") else dayKeys[key] = index
        }
        val name = str(o, "name", path, 1, 40)
        val weekday = enum(o, "weekday", path, WEEKDAYS)
        val exs = arr(o, "exercises", path, 1, 20)?.mapIndexed { i, e -> dayExercise(e, "$path/exercises/$i") }
        val ok = key != null && name != null && exs != null && exs.all { it != null } && (!o.containsKey("weekday") || weekday != null)
        if (exs != null && exs.all { it != null }) {
            val dayExs = exs.filterNotNull()
            val weeks = dayExs.maxOf { de -> de.sets.maxOf { it.weekly?.size ?: 0 } }
            for (wi in 0 until weeks) {
                if (dayExs.all { de -> de.sets.all { it.weekly?.getOrNull(wi)?.skip == true } }) {
                    err("$path/exercises", "every exercise of this day is skipped in week ${wi + 1}")
                }
            }
        }
        return if (ok) Day(key!!, name!!, weekday, exs!!.filterNotNull()) else null
    }

    fun dayExercise(el: JsonElement, path: String): DayExercise? {
        val o = obj(el, path) ?: return null
        checkKeys(o, path, setOf("lift", "accessory", "amrapSet", "sets", "countsForProgression", "restSec"), setOf("lift", "sets"))
        val lift = str(o, "lift", path)
        if (lift != null && lift !in liftKeys) err("$path/lift", "'$lift' is not a key in lifts")
        val accessory = bool(o, "accessory", path)
        val counts = bool(o, "countsForProgression", path)
        val amrapSet = int(o, "amrapSet", path, min = 0)
        val restSec = int(o, "restSec", path, 0, 3600)
        val sets = arr(o, "sets", path, 1, 30)?.mapIndexed { i, s -> set(s, "$path/sets/$i", lift, i, path) }
        val allSets = sets != null && sets.all { it != null }
        if (amrapSet != null && allSets) {
            val total = sets!!.sumOf { it!!.count }
            if (amrapSet >= total) err("$path/amrapSet", "must be less than the expanded set count ($total)")
        }
        val ok = lift != null && allSets && (!o.containsKey("accessory") || accessory != null) &&
            (!o.containsKey("countsForProgression") || counts != null) && (!o.containsKey("amrapSet") || amrapSet != null) &&
            (!o.containsKey("restSec") || restSec != null)
        return if (ok) DayExercise(lift!!, accessory ?: false, amrapSet, sets!!.filterNotNull(), counts ?: true, restSec) else null
    }

    fun set(el: JsonElement, path: String, lift: String?, index: Int, exPath: String): SetSpec? {
        val o = obj(el, path) ?: return null
        checkKeys(o, path, setOf("count", "reps", "amrap", "warmup", "load", "weekly", "repsMax", "restSec"), setOf("reps", "load"))
        val count = int(o, "count", path, 1, 20)
        val reps = int(o, "reps", path, 0, 100)
        val amrap = bool(o, "amrap", path)
        val warmup = bool(o, "warmup", path)
        val repsMax = int(o, "repsMax", path, 1, 100)
        val restSec = int(o, "restSec", path, 0, 3600)
        val load = o["load"]?.let { load(it, "$path/load") }
        val weekly = arr(o, "weekly", path)?.let { a ->
            val cw = cycleWeeks
            if (cw != null && a.size > cw) err("$path/weekly", "must not have more items than cycleWeeks ($cw)")
            a.mapIndexed { i, w -> weeklyOverride(w, "$path/weekly/$i") }
        }
        val ok = reps != null && load != null && (!o.containsKey("count") || count != null) &&
            (!o.containsKey("amrap") || amrap != null) && (!o.containsKey("warmup") || warmup != null) &&
            (weekly == null || weekly.all { it != null }) &&
            (!o.containsKey("repsMax") || repsMax != null) && (!o.containsKey("restSec") || restSec != null)
        if (!ok) return null
        if (repsMax != null) {
            if (repsMax < reps!!) err("$path/repsMax", "must be at least reps ($reps)")
            if (amrap == true) err("$path/repsMax", "cannot be used together with amrap")
        }
        weekly?.forEachIndexed { i, w ->
            if (w == null || (w.reps == null && w.repsMax == null && w.amrap == null)) return@forEachIndexed
            val er = w.reps ?: reps!!
            val em = w.repsMax ?: repsMax
            val ea = w.amrap ?: (amrap ?: false)
            if (em != null && em < er) err("$path/weekly/$i/${if (w.repsMax != null) "repsMax" else "reps"}", "repsMax ($em) must be at least reps ($er) in this week")
            if (em != null && ea && !(repsMax != null && amrap == true && w.amrap == null)) {
                err("$path/weekly/$i/${if (w.repsMax != null) "repsMax" else "amrap"}", "repsMax cannot be used together with amrap in this week")
            }
        }
        val spec = SetSpec(count ?: 1, reps!!, amrap ?: false, warmup ?: false, load!!, weekly?.filterNotNull(), repsMax, restSec)
        if (lift != null) {
            val anyAmrap = spec.amrap || spec.weekly?.any { it.amrap == true } == true
            setInfos += SetInfo(exPath, lift, index, anyAmrap, spec.load, spec.warmup)
        }
        return spec
    }

    fun weeklyOverride(el: JsonElement, path: String): WeeklyOverride? {
        val o = obj(el, path) ?: return null
        checkKeys(o, path, setOf("reps", "amrap", "value", "repsMax", "count", "addKg", "skip"), emptySet())
        val reps = int(o, "reps", path, 0)
        val amrap = bool(o, "amrap", path)
        val value = num(o, "value", path, exclMin = 0.0, max = 1.5)
        val repsMax = int(o, "repsMax", path, 1, 100)
        val count = int(o, "count", path, 1, 20)
        val addKg = num(o, "addKg", path, -500.0, 500.0)
        val skip = bool(o, "skip", path)
        val ok = (!o.containsKey("reps") || reps != null) && (!o.containsKey("amrap") || amrap != null) &&
            (!o.containsKey("value") || value != null) && (!o.containsKey("repsMax") || repsMax != null) &&
            (!o.containsKey("count") || count != null) && (!o.containsKey("addKg") || addKg != null) &&
            (!o.containsKey("skip") || skip != null)
        return if (ok) WeeklyOverride(reps, amrap, value, repsMax, count, addKg, skip) else null
    }

    private val loadTypes = listOf("PERCENT_TM", "WORKING", "FIXED", "BODYWEIGHT", "NONE")

    fun load(el: JsonElement, path: String): Load? {
        val o = obj(el, path) ?: return null
        if ("type" !in o) { err(path, "missing required property 'type'"); return null }
        val type = enum(o, "type", path, loadTypes) ?: return null
        fun of(): String? {
            val s = str(o, "of", path)
            if (s != null && s !in liftKeys) err("$path/of", "'$s' is not a key in lifts")
            return s
        }
        when (type) {
            "PERCENT_TM" -> {
                checkKeys(o, path, setOf("type", "value", "of"), setOf("type", "value"))
                val v = num(o, "value", path, exclMin = 0.0, max = 1.5)
                val of = of()
                return if (v != null && (!o.containsKey("of") || of != null)) Load.PercentTm(v, of) else null
            }
            "WORKING" -> {
                checkKeys(o, path, setOf("type", "value", "of"), setOf("type"))
                val v = num(o, "value", path, exclMin = 0.0, max = 1.5)
                val of = of()
                return if ((!o.containsKey("value") || v != null) && (!o.containsKey("of") || of != null)) Load.Working(v ?: 1.0, of) else null
            }
            "FIXED" -> {
                checkKeys(o, path, setOf("type", "kg"), setOf("type", "kg"))
                val kg = num(o, "kg", path, min = 0.0)
                return if (kg != null) Load.Fixed(kg) else null
            }
            "BODYWEIGHT" -> {
                checkKeys(o, path, setOf("type"), setOf("type"))
                return Load.Bodyweight
            }
            else -> {
                checkKeys(o, path, setOf("type"), setOf("type"))
                return Load.NoLoad
            }
        }
    }

    // ------------------------------------------------------------ 키 간 의미 검사

    fun crossChecks(progression: Map<String, Rule>?) {
        if (progression == null) return
        for ((key, rule) in progression) {
            val p = "/progression/${esc(key)}"
            when (rule) {
                is Rule.AmrapTable -> {
                    if (setInfos.none { it.lift == key && it.amrap }) {
                        err(p, "AMRAP_TABLE for '$key' requires at least one AMRAP set on that lift")
                    }
                }
                is Rule.Stages -> {
                    for (s in setInfos) {
                        if (s.lift == key && !s.warmup && s.load !is Load.Working) {
                            err("${s.exPath}/sets/${s.index}/load", "sets of a STAGES lift ('$key') must use a WORKING load")
                        }
                    }
                }
                is Rule.Double -> {
                    for (s in setInfos) {
                        if (s.lift == key && s.load is Load.PercentTm) {
                            err("${s.exPath}/sets/${s.index}/load", "sets of a DOUBLE lift ('$key') must not use a PERCENT_TM load")
                        }
                    }
                }
                else -> {}
            }
        }
    }
}
