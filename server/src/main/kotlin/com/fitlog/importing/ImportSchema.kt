package com.fitlog.importing

import com.fitlog.core.ErrorDetail
import com.fitlog.scheduled.ScheduledItem
import com.fitlog.scheduled.ScheduledSet
import com.fitlog.scheduled.ScheduledWorkout
import com.fitlog.scheduled.validateScheduled
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.math.BigDecimal
import java.time.Instant
import java.time.LocalDate
import java.time.OffsetDateTime
import java.util.UUID

/*
 * import.schema.json 검증기(순수). 에러는 모두 모으고 경로는 JSON 포인터.
 * 프로그램 정의(programs[].definition)의 내용 검증은 파이프라인이 v0.2 검증기로 한다.
 */

internal sealed interface PExRef {
    data class ById(val id: UUID) : PExRef
    data class ByName(val name: String) : PExRef
}

internal sealed interface PProgRef {
    data class ById(val id: UUID) : PProgRef
    data class Template(val key: String) : PProgRef
    data class Ref(val ref: String) : PProgRef
}

internal class PExercise(
    val ptr: String, val id: UUID?, val nameKo: String, val nameEn: String?, val type: String,
    val primaryMuscle: String, val secondary: List<String>,
)

internal class PProgram(val ptr: String, val index: Int, val id: UUID?, val ref: String?, val definition: JsonElement)

internal class PStart(
    val ptr: String, val id: UUID?, val program: PProgRef, val startDate: LocalDate, val tz: String?,
    val skipPolicy: String, val tm: Map<String, Double>, val working: Map<String, Double>,
)

internal class PSet(
    val ptr: String, val id: UUID?, val isWarmup: Boolean, val weightKg: Double?, val addedWeightKg: Double?,
    val reps: Int?, val durationSec: Int?, val distanceM: Double?, val rpe: Double?, val rir: Int?,
    val restSec: Int?, val note: String?,
)

internal class PSessionEx(val ptr: String, val ref: PExRef, val note: String?, val sets: List<PSet>)

internal class PSession(
    val ptr: String, val id: UUID?, val startedAt: Instant, val endedAt: Instant?, val tz: String?, val note: String?,
    val instanceId: UUID?, val planSeq: Int?, val exercises: List<PSessionEx>, val scheduledWorkoutId: UUID? = null,
)

internal class PSchedItem(val ptr: String, val ref: PExRef, val note: String?, val restSec: Int?, val sets: List<ScheduledSet>)

internal class PScheduled(
    val ptr: String, val id: UUID?, val plannedDate: LocalDate, val title: String, val note: String?, val tz: String?,
    val items: List<PSchedItem>,
)

internal class PBody(val ptr: String, val id: UUID?, val measuredAt: Instant, val weightKg: Double)

internal class ParsedBundle(
    val note: String?,
    val exercises: List<PExercise>,
    val programs: List<PProgram>,
    val starts: List<PStart>,
    val sessions: List<PSession>,
    val bodies: List<PBody>,
    val scheduled: List<PScheduled> = emptyList(),
)

internal val EXERCISE_TYPE_NAMES = listOf("BARBELL", "DUMBBELL", "MACHINE", "BODYWEIGHT", "BAND", "CARDIO")
internal val MUSCLE_NAMES = listOf(
    "CHEST", "BACK", "LATS", "TRAPS", "SHOULDERS", "REAR_DELTS", "BICEPS", "TRICEPS", "FOREARMS",
    "QUADS", "HAMSTRINGS", "GLUTES", "CALVES", "ADDUCTORS", "ABS", "OBLIQUES", "LOWER_BACK", "FULL_BODY", "CARDIO",
)

internal fun escPtr(k: String) = k.replace("~", "~0").replace("/", "~1")

private val UUID_RE = Regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
private val REF_RE = Regex("^[a-z0-9_-]{1,32}$")

internal object ImportSchema {
    const val MAX_PROGRAMS = 10
    const val MAX_STARTS = 5
    const val MAX_SESSIONS = 200
    const val MAX_SETS_TOTAL = 5000
    const val MAX_EXERCISES = 100
    const val MAX_BODIES = 1000
    const val MAX_SCHEDULED = 30

    fun parse(root: JsonElement, errors: MutableList<ErrorDetail>): ParsedBundle = Run(errors).bundle(root)
}

private class Run(val errors: MutableList<ErrorDetail>) {
    fun err(path: String, msg: String) {
        errors += ErrorDetail(path, msg)
    }

    // ------------------------------------------------------------ 기본형

    fun obj(el: JsonElement?, path: String): JsonObject? {
        if (el is JsonObject) return el
        err(path, "must be an object")
        return null
    }

    fun keys(o: JsonObject, path: String, allowed: Set<String>, required: Set<String>) {
        for (k in o.keys) if (k !in allowed) err("$path/${escPtr(k)}", "unknown property")
        for (k in required) if (k !in o) err(path, "missing required property '$k'")
    }

    private fun prim(el: JsonElement?): JsonPrimitive? = (el as? JsonPrimitive)?.takeIf { it !is JsonNull }

    fun str(o: JsonObject, key: String, path: String, min: Int = 0, max: Int = Int.MAX_VALUE): String? {
        val el = o[key] ?: return null
        val p = "$path/$key"
        val pr = prim(el)
        if (pr == null || !pr.isString) { err(p, "must be a string"); return null }
        val s = pr.content
        if (s.length < min) { err(p, "must be at least $min characters"); return null }
        if (s.length > max) { err(p, "must be at most $max characters"); return null }
        return s
    }

    fun bool(o: JsonObject, key: String, path: String): Boolean? {
        val el = o[key] ?: return null
        val pr = prim(el)
        if (pr == null || pr.isString || (pr.content != "true" && pr.content != "false")) {
            err("$path/$key", "must be a boolean"); return null
        }
        return pr.content == "true"
    }

    private fun decimal(el: JsonElement?): BigDecimal? {
        val pr = prim(el) ?: return null
        if (pr.isString) return null
        return pr.content.toBigDecimalOrNull()
    }

    fun num(o: JsonObject, key: String, path: String, min: Double? = null, max: Double? = null, exclMin: Double? = null): Double? {
        val el = o[key] ?: return null
        val p = "$path/$key"
        val b = decimal(el)
        if (b == null) { err(p, "must be a number"); return null }
        val d = b.toDouble()
        if (d.isNaN() || d.isInfinite()) { err(p, "must be a number"); return null }
        if (exclMin != null && d <= exclMin) { err(p, "must be greater than $exclMin"); return null }
        if (min != null && d < min) { err(p, "must be at least $min"); return null }
        if (max != null && d > max) { err(p, "must be at most $max"); return null }
        return d
    }

    fun int(o: JsonObject, key: String, path: String, min: Int? = null, max: Int? = null): Int? {
        val el = o[key] ?: return null
        val p = "$path/$key"
        val b = decimal(el)
        if (b == null || b.stripTrailingZeros().scale() > 0 || b.abs() > BigDecimal(Int.MAX_VALUE)) {
            err(p, "must be an integer"); return null
        }
        val i = b.toInt()
        if (min != null && i < min) { err(p, "must be at least $min"); return null }
        if (max != null && i > max) { err(p, "must be at most $max"); return null }
        return i
    }

    fun enum(o: JsonObject, key: String, path: String, values: List<String>): String? {
        val el = o[key] ?: return null
        val s = prim(el)?.takeIf { it.isString }?.content
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

    fun uuid(o: JsonObject, key: String, path: String): UUID? {
        val s = str(o, key, path) ?: return null
        if (!UUID_RE.matches(s)) { err("$path/$key", "must be a UUID"); return null }
        return UUID.fromString(s)
    }

    fun dateTime(o: JsonObject, key: String, path: String): Instant? {
        val s = str(o, key, path) ?: return null
        return try {
            OffsetDateTime.parse(s).toInstant()
        } catch (e: Exception) {
            err("$path/$key", "must be an ISO-8601 date-time with offset"); null
        }
    }

    fun date(o: JsonObject, key: String, path: String): LocalDate? {
        val s = str(o, key, path) ?: return null
        return try {
            LocalDate.parse(s)
        } catch (e: Exception) {
            err("$path/$key", "must be a date (yyyy-MM-dd)"); null
        }
    }

    // ------------------------------------------------------------ 최상위

    fun bundle(root: JsonElement): ParsedBundle {
        val o = obj(root, "") ?: return ParsedBundle(null, emptyList(), emptyList(), emptyList(), emptyList(), emptyList())
        keys(o, "", setOf("schemaVersion", "note", "exercises", "programs", "startPrograms", "sessions", "bodyMeasurements", "scheduledWorkouts"), setOf("schemaVersion"))
        if ("schemaVersion" in o) {
            val b = decimal(o["schemaVersion"])
            if (b == null || b.compareTo(BigDecimal.ONE) != 0) err("/schemaVersion", "must be 1")
        }
        val note = str(o, "note", "", 0, 500)
        val exercises = arr(o, "exercises", "", 0, ImportSchema.MAX_EXERCISES)?.mapIndexedNotNull { i, el -> exercise(el, "/exercises/$i") }.orEmpty()
        val programs = arr(o, "programs", "", 0, ImportSchema.MAX_PROGRAMS)?.mapIndexedNotNull { i, el -> program(el, "/programs/$i", i) }.orEmpty()
        val starts = arr(o, "startPrograms", "", 0, ImportSchema.MAX_STARTS)?.mapIndexedNotNull { i, el -> start(el, "/startPrograms/$i") }.orEmpty()
        val sessions = arr(o, "sessions", "", 0, ImportSchema.MAX_SESSIONS)?.mapIndexedNotNull { i, el -> session(el, "/sessions/$i") }.orEmpty()
        val bodies = arr(o, "bodyMeasurements", "", 0, ImportSchema.MAX_BODIES)?.mapIndexedNotNull { i, el -> body(el, "/bodyMeasurements/$i") }.orEmpty()
        val scheduled = arr(o, "scheduledWorkouts", "", 0, ImportSchema.MAX_SCHEDULED)?.mapIndexedNotNull { i, el -> scheduled(el, "/scheduledWorkouts/$i") }.orEmpty()
        val sets = sessions.sumOf { s -> s.exercises.sumOf { it.sets.size } }
        if (sets > ImportSchema.MAX_SETS_TOTAL) err("/sessions", "too many sets (max ${ImportSchema.MAX_SETS_TOTAL} per bundle)")
        return ParsedBundle(note, exercises, programs, starts, sessions, bodies, scheduled)
    }

    fun exercise(el: JsonElement, path: String): PExercise? {
        val o = obj(el, path) ?: return null
        val before = errors.size
        keys(o, path, setOf("id", "nameKo", "nameEn", "type", "primaryMuscle", "secondaryMuscles"), setOf("nameKo", "type", "primaryMuscle"))
        val id = uuid(o, "id", path)
        val ko = str(o, "nameKo", path, 1, 60)
        val en = str(o, "nameEn", path, 0, 60)
        val type = enum(o, "type", path, EXERCISE_TYPE_NAMES)
        val muscle = enum(o, "primaryMuscle", path, MUSCLE_NAMES)
        val secondary = mutableListOf<String>()
        arr(o, "secondaryMuscles", path)?.forEachIndexed { i, m ->
            val s = prim(m)?.takeIf { it.isString }?.content
            when {
                s == null -> err("$path/secondaryMuscles/$i", "must be a string")
                s !in MUSCLE_NAMES -> err("$path/secondaryMuscles/$i", "must be one of ${MUSCLE_NAMES.joinToString(", ")}")
                else -> secondary += s
            }
        }
        if (errors.size > before || ko == null || type == null || muscle == null) return null
        return PExercise(path, id, ko.trim(), en?.trim()?.ifEmpty { null }, type, muscle, secondary.distinct().filter { it != muscle })
    }

    fun program(el: JsonElement, path: String, index: Int): PProgram? {
        val o = obj(el, path) ?: return null
        val before = errors.size
        keys(o, path, setOf("id", "ref", "definition"), setOf("definition"))
        val id = uuid(o, "id", path)
        val ref = str(o, "ref", path)
        if (ref != null && !REF_RE.matches(ref)) err("$path/ref", "must match pattern ${REF_RE.pattern}")
        val def = o["definition"]
        // definition 의 내용은 파이프라인이 검증한다. 여기서는 존재만 본다
        if (errors.size > before || def == null) return null
        return PProgram(path, index, id, ref, def)
    }

    fun start(el: JsonElement, path: String): PStart? {
        val o = obj(el, path) ?: return null
        val before = errors.size
        keys(o, path, setOf("id", "program", "startDate", "tz", "skipPolicy", "tm", "working"), setOf("program", "startDate"))
        val id = uuid(o, "id", path)
        var ref: PProgRef? = null
        o["program"]?.let { p ->
            val po = obj(p, "$path/program")
            if (po != null) {
                val pp = "$path/program"
                val k = po.keys.toSet()
                when {
                    k == setOf("id") -> uuid(po, "id", pp)?.let { ref = PProgRef.ById(it) }
                    k == setOf("templateKey") -> str(po, "templateKey", pp)?.let { ref = PProgRef.Template(it) }
                    k == setOf("ref") -> str(po, "ref", pp)?.let { ref = PProgRef.Ref(it) }
                    else -> err(pp, "must have exactly one of 'id', 'templateKey' or 'ref'")
                }
            }
        }
        val date = date(o, "startDate", path)
        val tz = str(o, "tz", path)
        val policy = enum(o, "skipPolicy", path, listOf("SHIFT", "FIXED_DATE")) ?: "SHIFT"
        val tm = weights(o, "tm", path)
        val working = weights(o, "working", path)
        if (errors.size > before || ref == null || date == null) return null
        return PStart(path, id, ref!!, date, tz, policy, tm, working)
    }

    private fun weights(o: JsonObject, key: String, path: String): Map<String, Double> {
        val el = o[key] ?: return emptyMap()
        val m = obj(el, "$path/$key") ?: return emptyMap()
        val out = linkedMapOf<String, Double>()
        for ((k, v) in m) {
            val b = decimal(v)
            if (b == null || b.signum() <= 0) err("$path/$key/${escPtr(k)}", "must be a number greater than 0") else out[k] = b.toDouble()
        }
        return out
    }

    fun set(el: JsonElement, path: String): PSet? {
        val o = obj(el, path) ?: return null
        val before = errors.size
        keys(
            o, path,
            setOf("id", "isWarmup", "weightKg", "addedWeightKg", "reps", "durationSec", "distanceM", "rpe", "rir", "restSec", "note"),
            emptySet(),
        )
        val id = uuid(o, "id", path)
        val warm = bool(o, "isWarmup", path) ?: false
        val w = num(o, "weightKg", path, min = 0.0)
        val aw = num(o, "addedWeightKg", path)
        val reps = int(o, "reps", path, min = 0)
        val dur = int(o, "durationSec", path, min = 0)
        val dist = num(o, "distanceM", path, min = 0.0)
        val rpe = num(o, "rpe", path, min = 1.0, max = 10.0)
        if (rpe != null && (rpe * 2) % 1.0 != 0.0) err("$path/rpe", "must be a multiple of 0.5")
        val rir = int(o, "rir", path, 0, 10)
        val rest = int(o, "restSec", path, min = 0)
        val note = str(o, "note", path)
        if (errors.size > before) return null
        return PSet(path, id, warm, w, aw, reps, dur, dist, rpe, rir, rest, note)
    }

    fun session(el: JsonElement, path: String): PSession? {
        val o = obj(el, path) ?: return null
        val before = errors.size
        keys(o, path, setOf("id", "startedAt", "endedAt", "tz", "note", "program", "exercises", "scheduledWorkoutId"), setOf("startedAt", "exercises"))
        val id = uuid(o, "id", path)
        val started = dateTime(o, "startedAt", path)
        val ended = dateTime(o, "endedAt", path)
        if (started != null && ended != null && ended.isBefore(started)) err("$path/endedAt", "must not be before startedAt")
        val tz = str(o, "tz", path)
        val note = str(o, "note", path)
        var instanceId: UUID? = null
        var planSeq: Int? = null
        o["program"]?.let { p ->
            val pp = "$path/program"
            obj(p, pp)?.let { po ->
                keys(po, pp, setOf("instanceId", "planSeq"), setOf("instanceId", "planSeq"))
                instanceId = uuid(po, "instanceId", pp)
                planSeq = int(po, "planSeq", pp, min = 0)
            }
        }
        val scheduledId = uuid(o, "scheduledWorkoutId", path)
        val exs = arr(o, "exercises", path, 1, 30)?.mapIndexedNotNull { i, e -> sessionEx(e, "$path/exercises/$i") }.orEmpty()
        if (errors.size > before || started == null) return null
        return PSession(path, id, started, ended, tz, note, instanceId, planSeq, exs, scheduledId)
    }

    private fun sessionEx(el: JsonElement, path: String): PSessionEx? {
        val o = obj(el, path) ?: return null
        val before = errors.size
        keys(o, path, setOf("exercise", "note", "sets"), setOf("exercise", "sets"))
        var ref: PExRef? = null
        o["exercise"]?.let { e ->
            val ep = "$path/exercise"
            obj(e, ep)?.let { eo ->
                val k = eo.keys.toSet()
                when {
                    k == setOf("id") -> uuid(eo, "id", ep)?.let { ref = PExRef.ById(it) }
                    k == setOf("name") -> str(eo, "name", ep, 1)?.let { ref = PExRef.ByName(it) }
                    else -> err(ep, "must have exactly one of 'id' or 'name'")
                }
            }
        }
        val note = str(o, "note", path)
        val sets = arr(o, "sets", path, 1, 50)?.mapIndexedNotNull { i, s -> set(s, "$path/sets/$i") }.orEmpty()
        if (errors.size > before || ref == null) return null
        return PSessionEx(path, ref!!, note, sets)
    }

    fun scheduledSet(el: JsonElement, path: String): ScheduledSet? {
        val o = obj(el, path) ?: return null
        val before = errors.size
        keys(o, path, setOf("isWarmup", "targetWeightKg", "targetReps", "targetRepsMax", "targetRir", "targetRpe", "targetDurationSec"), emptySet())
        val warm = bool(o, "isWarmup", path) ?: false
        val w = num(o, "targetWeightKg", path, min = 0.0)
        val reps = int(o, "targetReps", path, min = 0)
        val max = int(o, "targetRepsMax", path, min = 0)
        val rir = int(o, "targetRir", path, 0, 10)
        val rpe = num(o, "targetRpe", path, min = 1.0, max = 10.0)
        if (rpe != null && (rpe * 2) % 1.0 != 0.0) err("$path/targetRpe", "must be a multiple of 0.5")
        val dur = int(o, "targetDurationSec", path, min = 0)
        if (errors.size > before) return null
        return ScheduledSet(warm, w, reps, max, rir, rpe, dur)
    }

    private fun scheduledItem(el: JsonElement, path: String): PSchedItem? {
        val o = obj(el, path) ?: return null
        val before = errors.size
        keys(o, path, setOf("exercise", "note", "restSec", "sets"), setOf("exercise", "sets"))
        var ref: PExRef? = null
        o["exercise"]?.let { e ->
            val ep = "$path/exercise"
            obj(e, ep)?.let { eo ->
                val k = eo.keys.toSet()
                when {
                    k == setOf("id") -> uuid(eo, "id", ep)?.let { ref = PExRef.ById(it) }
                    k == setOf("name") -> str(eo, "name", ep, 1)?.let { ref = PExRef.ByName(it) }
                    else -> err(ep, "must have exactly one of 'id' or 'name'")
                }
            }
        }
        val note = str(o, "note", path)
        val rest = int(o, "restSec", path, 0, 3600)
        val sets = arr(o, "sets", path, 1, 50)?.mapIndexedNotNull { i, s -> scheduledSet(s, "$path/sets/$i") }.orEmpty()
        if (errors.size > before || ref == null) return null
        return PSchedItem(path, ref!!, note, rest, sets)
    }

    fun scheduled(el: JsonElement, path: String): PScheduled? {
        val o = obj(el, path) ?: return null
        val before = errors.size
        keys(o, path, setOf("id", "plannedDate", "title", "note", "tz", "items"), setOf("plannedDate", "title", "items"))
        val id = uuid(o, "id", path)
        val date = date(o, "plannedDate", path)
        val title = str(o, "title", path, 1, 100)
        val note = str(o, "note", path, 0, 1000)
        val tz = str(o, "tz", path)
        val items = arr(o, "items", path, 1, 30)?.mapIndexedNotNull { i, e -> scheduledItem(e, "$path/items/$i") }.orEmpty()
        if (errors.size > before || date == null || title == null) return null
        // 공용 검증(예: targetRepsMax 는 targetReps 이상이어야 한다). 종목 id 는 아직 모르므로 자리값을 쓴다
        val probe = ScheduledWorkout(
            id = UUID(0, 0), plannedDate = date.toString(), title = title, note = note,
            items = items.map { ScheduledItem(UUID(0, 0), it.note, it.restSec, it.sets) },
        )
        validateScheduled(probe, path).forEach { (p, m) -> err(p, m) }
        if (errors.size > before) return null
        return PScheduled(path, id, date, title.trim(), note, tz, items)
    }

    fun body(el: JsonElement, path: String): PBody? {
        val o = obj(el, path) ?: return null
        val before = errors.size
        keys(o, path, setOf("id", "measuredAt", "weightKg"), setOf("measuredAt", "weightKg"))
        val id = uuid(o, "id", path)
        val at = dateTime(o, "measuredAt", path)
        val w = num(o, "weightKg", path, 20.0, 400.0)
        if (errors.size > before || at == null || w == null) return null
        return PBody(path, id, at, w)
    }
}
