package com.fitlog.importing

import com.fitlog.core.Times
import com.fitlog.core.validation
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.math.BigDecimal
import java.math.RoundingMode
import java.time.Instant
import java.time.LocalDateTime
import java.time.OffsetDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import java.util.UUID

/*
 * Strong·Hevy CSV → import.schema 묶음(순수 변환). 계약 contracts/v1.2/edit.md 6절·9.5절.
 * DB 조회는 하지 않는다: 사용자·기본 종목은 [CsvKnownExercises] 로 받는다.
 */

@Serializable
data class CsvSkippedRow(val line: Int, val reason: String)

@Serializable
data class CsvSummary(
    val format: String,
    val sessions: Int,
    val sets: Int,
    val matchedExercises: Int,
    val newExercises: List<String>,
    val skippedRows: List<CsvSkippedRow>,
)

@Serializable
data class CsvChunk(val bundle: JsonObject, val preview: ImportPreview)

@Serializable
data class CsvPreviewResponse(val csv: CsvSummary, val chunks: List<CsvChunk>)

@Serializable
data class CsvPreviewRequest(val format: String, val csv: String, val weightUnit: String? = null, val tz: String)

internal const val CSV_MAX_BYTES = 4 * 1024 * 1024

/** 이미 있는 종목: 정규화 키(전체 이름) → id. 내 종목이 기본 종목보다 먼저 쓰인다 */
internal class CsvKnownExercises(
    val own: Map<String, UUID>,
    val builtIn: Map<String, UUID>,
    val types: Map<UUID, String>,
)

internal class CsvRecord(val line: Int, val fields: List<String>)

internal class CsvConversion(
    val format: String,
    val bundles: List<JsonObject>,
    val summary: CsvSummary,
)

internal object CsvImport {
    // ------------------------------------------------------------ 토큰화

    /** BOM·CRLF·따옴표(""), 필드 안 줄바꿈을 처리한다. 쉼표와 세미콜론은 첫 줄로 정한다 */
    fun tokenize(raw: String): List<CsvRecord> {
        val text = raw.removePrefix("﻿")
        val delim = detectDelimiter(text)
        val out = mutableListOf<CsvRecord>()
        var fields = mutableListOf<String>()
        val cur = StringBuilder()
        var inQuotes = false
        var line = 1
        var recStart = 1
        var i = 0
        fun endField() { fields.add(cur.toString()); cur.setLength(0) }
        fun endRecord() {
            endField()
            if (!(fields.size == 1 && fields[0].isEmpty())) out += CsvRecord(recStart, fields)
            fields = mutableListOf()
        }
        while (i < text.length) {
            val c = text[i]
            when {
                inQuotes -> when {
                    c == '"' && i + 1 < text.length && text[i + 1] == '"' -> { cur.append('"'); i++ }
                    c == '"' -> inQuotes = false
                    else -> { if (c == '\n') line++; cur.append(c) }
                }
                c == '"' && cur.isEmpty() -> inQuotes = true
                c == delim -> endField()
                c == '\r' -> {
                    if (i + 1 < text.length && text[i + 1] == '\n') i++
                    endRecord(); line++; recStart = line
                }
                c == '\n' -> { endRecord(); line++; recStart = line }
                else -> cur.append(c)
            }
            i++
        }
        if (cur.isNotEmpty() || fields.isNotEmpty()) endRecord()
        return out
    }

    private fun detectDelimiter(text: String): Char {
        var commas = 0
        var semis = 0
        var q = false
        for (c in text) {
            if (c == '"') q = !q
            else if (!q) {
                if (c == '\n' || c == '\r') break
                if (c == ',') commas++ else if (c == ';') semis++
            }
        }
        return if (semis > commas) ';' else ','
    }

    // ------------------------------------------------------------ 형식 판별

    private fun headerKey(h: String): String =
        h.trim().lowercase().replace(Regex("\\(.*?\\)"), "").trim().replace(Regex("[\\s_]+"), "_")

    fun detect(header: List<String>): String? {
        val keys = header.map(::headerKey).toSet()
        return when {
            "exercise_title" in keys && "start_time" in keys -> "HEVY"
            "exercise_name" in keys && "set_order" in keys -> "STRONG"
            else -> null
        }
    }

    // ------------------------------------------------------------ 행 → 세션

    private class RawSet(
        val line: Int, val isWarmup: Boolean, val setType: String, val weight: Double?, val reps: Int?,
        val durationSec: Int?, val distanceM: Double?, val rpe: Double?,
    )

    private class RawEx(val name: String, val norm: CsvExerciseDictionary.Norm) {
        var superset: String? = null
        var note: String? = null
        val sets = mutableListOf<RawSet>()
    }

    private class RawSession(val start: Instant, val title: String) {
        var end: Instant? = null
        var note: String? = null
        val exercises = LinkedHashMap<String, RawEx>()
    }

    private class Cols(header: List<String>) {
        val idx: Map<String, Int> = header.mapIndexed { i, h -> headerKey(h) to i }.toMap()
        val raw: List<String> = header
        fun get(row: List<String>, vararg keys: String): String? {
            for (k in keys) {
                val i = idx[k] ?: continue
                val v = row.getOrNull(i)?.trim()
                if (!v.isNullOrEmpty()) return v
            }
            return null
        }
        fun has(key: String) = key in idx
        fun rawHeader(key: String): String? = idx[key]?.let { raw[it].lowercase() }
    }

    private val strongDates = listOf("yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy/MM/dd HH:mm:ss")
        .map { DateTimeFormatter.ofPattern(it, Locale.ENGLISH) }
    private val hevyDates = listOf(
        "d MMM yyyy, HH:mm", "d MMM yyyy, H:mm", "MMM d, yyyy, h:mm a", "MMMM d, yyyy, h:mm a", "d MMM yyyy HH:mm",
        "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm:ss",
    ).map { DateTimeFormatter.ofPattern(it, Locale.ENGLISH) }

    private fun parseInstant(s: String, zone: ZoneId, extra: List<DateTimeFormatter>): Instant? {
        runCatching { return OffsetDateTime.parse(s).toInstant() }
        for (f in extra) runCatching { return LocalDateTime.parse(s, f).atZone(zone).toInstant() }
        return null
    }

    /** "1h 15m", "45m", "1h", "1h 2m 3s" 또는 초 */
    internal fun parseDuration(s: String?): Int? {
        if (s.isNullOrBlank()) return null
        val t = s.trim().lowercase()
        t.toDoubleOrNull()?.let { return it.toInt() }
        val m = Regex("^(?:(\\d+)\\s*h)?\\s*(?:(\\d+)\\s*m(?:in)?)?\\s*(?:(\\d+)\\s*s(?:ec)?)?$").matchEntire(t) ?: return null
        val (h, mi, se) = m.destructured
        if (h.isEmpty() && mi.isEmpty() && se.isEmpty()) return null
        return (h.toIntOrNull() ?: 0) * 3600 + (mi.toIntOrNull() ?: 0) * 60 + (se.toIntOrNull() ?: 0)
    }

    private fun num(s: String?): Double? {
        if (s == null) return null
        val t = s.trim().let { if ('.' !in it && ',' in it) it.replace(',', '.') else it.replace(",", "") }
        return t.toDoubleOrNull()?.takeIf { it.isFinite() }
    }

    private fun r2(d: Double) = BigDecimal.valueOf(d).setScale(2, RoundingMode.HALF_UP).toDouble()
    private fun r1(d: Double) = BigDecimal.valueOf(d).setScale(1, RoundingMode.HALF_UP).toDouble()
    private const val LB_TO_KG = 0.45359237

    private fun rpeOf(s: String?): Double? {
        val d = num(s) ?: return null
        val h = Math.round(d * 2) / 2.0
        return h.takeIf { it in 1.0..10.0 }
    }

    private fun supersetOf(s: String?): String? = s?.trim()?.takeIf { it.isNotEmpty() }?.let { if (it.length > 8) it.takeLast(8) else it }

    // ------------------------------------------------------------ 변환

    fun convert(
        uid: UUID, requested: String, text: String, weightUnit: String, tz: String, known: CsvKnownExercises,
    ): CsvConversion {
        val records = tokenize(text)
        if (records.isEmpty()) validation("csv is empty", "csv")
        val header = records[0].fields
        val format = if (requested == "AUTO") detect(header) ?: validation("cannot detect CSV format from the header", "csv")
        else requested.also { if (detect(header) != it) validation("CSV header does not look like $it", "format") }
        val cols = Cols(header)
        val zone = ZoneId.of(tz)
        val skipped = mutableListOf<CsvSkippedRow>()
        val sessions = LinkedHashMap<String, RawSession>()

        for (rec in records.drop(1)) {
            val row = rec.fields
            fun skip(reason: String) { skipped += CsvSkippedRow(rec.line, reason) }
            val exName = cols.get(row, "exercise_name", "exercise_title")
            if (exName == null) { skip("missing exercise name"); continue }
            val dateStr = cols.get(row, "date", "start_time")
            if (dateStr == null) { skip("missing date"); continue }
            val start = parseInstant(dateStr, zone, if (format == "STRONG") strongDates else hevyDates)
            if (start == null) { skip("unparseable date '$dateStr'"); continue }
            val title = cols.get(row, "workout_name", "title") ?: ""

            var isWarmup = false
            var setType = "NORMAL"
            if (format == "STRONG") {
                val order = cols.get(row, "set_order") ?: ""
                when (order.uppercase()) {
                    "W" -> isWarmup = true
                    "D" -> setType = "DROP"
                    "F" -> setType = "FAILURE"
                    else -> if (order.toIntOrNull() == null && order.isNotEmpty()) {
                        skip("not a set row (Set Order '$order')"); continue
                    }
                }
            } else {
                when ((cols.get(row, "set_type") ?: "normal").lowercase().replace("_", "").replace(" ", "")) {
                    "warmup" -> isWarmup = true
                    "dropset", "drop" -> setType = "DROP"
                    "failure" -> setType = "FAILURE"
                    "normal", "" -> {}
                    else -> {}
                }
            }

            // 무게
            var weight: Double? = null
            if (format == "STRONG") {
                val wh = cols.rawHeader("weight") ?: ""
                val w = num(cols.get(row, "weight"))
                val lb = if ("lb" in wh) true else if ("kg" in wh) false else weightUnit == "LB"
                weight = w?.let { if (lb) r2(it * LB_TO_KG) else r2(it) }
            } else {
                val kg = num(cols.get(row, "weight_kg"))
                val lb = num(cols.get(row, "weight_lbs", "weight_lb"))
                weight = kg?.let { r2(it) } ?: lb?.let { r2(it * LB_TO_KG) }
            }
            val reps = num(cols.get(row, "reps"))?.toInt()
            val duration = if (format == "STRONG") num(cols.get(row, "seconds"))?.toInt() else num(cols.get(row, "duration_seconds"))?.toInt()
            val distance = if (format == "STRONG") num(cols.get(row, "distance"))?.let { r1(it) }
            else num(cols.get(row, "distance_km"))?.let { r1(it * 1000) } ?: num(cols.get(row, "distance_miles"))?.let { r1(it * 1609.344) }
            val rpe = rpeOf(cols.get(row, "rpe"))

            if (weight != null && weight < 0) { skip("negative weight"); continue }
            if ((reps ?: 0) < 0 || (duration ?: 0) < 0 || (distance ?: 0.0) < 0) { skip("negative value"); continue }
            val hasContent = (weight ?: 0.0) > 0 || (reps ?: 0) > 0 || (duration ?: 0) > 0 || (distance ?: 0.0) > 0
            if (!hasContent) { skip("empty set"); continue }

            val key = "${start.toEpochMilli()}|$title"
            val s = sessions.getOrPut(key) { RawSession(start, title) }
            if (format == "STRONG") {
                cols.get(row, "workout_notes")?.let { if (s.note == null) s.note = it }
                if (s.end == null) parseDuration(cols.get(row, "duration"))?.takeIf { it > 0 }?.let { s.end = start.plusSeconds(it.toLong()) }
            } else {
                cols.get(row, "description")?.let { if (s.note == null) s.note = it }
                if (s.end == null) cols.get(row, "end_time")?.let { e -> parseInstant(e, zone, hevyDates)?.takeIf { it > start }?.let { t -> s.end = t } }
            }
            val ex = s.exercises.getOrPut(exName.lowercase()) { RawEx(exName, CsvExerciseDictionary.normalize(exName)) }
            if (ex.superset == null) ex.superset = supersetOf(cols.get(row, "superset_id"))
            if (ex.note == null) ex.note = cols.get(row, "notes", "exercise_notes")
            ex.sets += RawSet(rec.line, isWarmup, setType, weight, reps, duration, distance, rpe)
        }
        return build(uid, format, sessions.values.sortedBy { it.start }, known, tz, skipped)
    }

    // ------------------------------------------------------------ 종목 해석·묶음

    private class Resolved(val id: UUID, val type: String, val isNew: Boolean, val name: String, val muscle: String)

    private fun inferType(norm: CsvExerciseDictionary.Norm, all: List<RawSet>): String {
        val w = (norm.full.split(' ')).toSet()
        return when {
            "barbell" in w -> "BARBELL"
            "dumbbell" in w || "kettlebell" in w -> "DUMBBELL"
            "band" in w -> "BAND"
            "machine" in w || "cable" in w || "smith" in w || "lever" in w -> "MACHINE"
            "bodyweight" in w -> "BODYWEIGHT"
            all.none { (it.reps ?: 0) > 0 } && all.any { (it.durationSec ?: 0) > 0 || (it.distanceM ?: 0.0) > 0 } -> "CARDIO"
            all.any { (it.weight ?: 0.0) > 0 } -> "MACHINE"
            else -> "BODYWEIGHT"
        }
    }

    private fun build(
        uid: UUID, format: String, sessions: List<RawSession>, known: CsvKnownExercises, tz: String, skipped: MutableList<CsvSkippedRow>,
    ): CsvConversion {
        // 종목별 모든 세트(유형 추정용)
        val setsByName = HashMap<String, MutableList<RawSet>>()
        sessions.forEach { s -> s.exercises.values.forEach { e -> setsByName.getOrPut(e.norm.full) { mutableListOf() }.addAll(e.sets) } }
        val resolved = HashMap<String, Resolved>()
        fun resolve(e: RawEx): Resolved = resolved.getOrPut(e.norm.full) {
            val ownId = CsvExerciseDictionary.find(known.own, e.norm)
            val seed = CsvExerciseDictionary.seedFor(e.norm)?.let { CsvExerciseDictionary.seedId(it) }?.takeIf { it in known.types }
            val builtin = CsvExerciseDictionary.find(known.builtIn, e.norm)
            val id = ownId ?: seed ?: builtin
            if (id != null) Resolved(id, known.types[id] ?: "MACHINE", false, e.name, "")
            else {
                val type = inferType(e.norm, setsByName[e.norm.full].orEmpty())
                val muscle = if (type == "CARDIO") "CARDIO" else CsvExerciseDictionary.muscleFor(e.norm)
                Resolved(detId(uid, format, "csv-exercise:${e.norm.full}"), type, true, e.name.trim().take(60), muscle)
            }
        }

        class OutSession(val raw: RawSession, val id: UUID, val exercises: List<Triple<RawEx, Resolved, List<RawSet>>>, val setCount: Int)

        val out = mutableListOf<OutSession>()
        for (s in sessions) {
            val exs = mutableListOf<Triple<RawEx, Resolved, List<RawSet>>>()
            for (e in s.exercises.values) {
                if (exs.size >= 30) { e.sets.forEach { skipped += CsvSkippedRow(it.line, "session has more than 30 exercises; row dropped") }; continue }
                val r = resolve(e)
                val ok = mutableListOf<RawSet>()
                for (set in e.sets) {
                    val problem = when (r.type) {
                        "CARDIO" -> if (set.durationSec == null) "duration is required for a cardio exercise" else null
                        else -> if (set.reps == null) "reps are required" else null
                    }
                    when {
                        problem != null -> skipped += CsvSkippedRow(set.line, problem)
                        ok.size >= 50 -> skipped += CsvSkippedRow(set.line, "exercise has more than 50 sets in one session; row dropped")
                        else -> ok += set
                    }
                }
                if (ok.isNotEmpty()) exs += Triple(e, r, ok)
            }
            if (exs.isEmpty()) continue
            val sid = detId(uid, format, "csv-session:${s.start.toEpochMilli()}|${s.title.trim().lowercase()}")
            out += OutSession(s, sid, exs, exs.sumOf { it.third.size })
        }

        // 날짜순으로 한도 안에서 묶음을 나눈다
        val chunks = mutableListOf<MutableList<OutSession>>()
        var cur = mutableListOf<OutSession>()
        var curSets = 0
        var curNew = mutableSetOf<UUID>()
        for (o in out) {
            val newIds = o.exercises.filter { it.second.isNew }.map { it.second.id }.toSet()
            val tooMany = cur.size >= ImportSchema.MAX_SESSIONS || curSets + o.setCount > ImportSchema.MAX_SETS_TOTAL ||
                (curNew + newIds).size > ImportSchema.MAX_EXERCISES
            if (tooMany && cur.isNotEmpty()) { chunks += cur; cur = mutableListOf(); curSets = 0; curNew = mutableSetOf() }
            cur += o; curSets += o.setCount; curNew += newIds
        }
        if (cur.isNotEmpty()) chunks += cur

        val bundles = chunks.mapIndexed { ci, list ->
            val newInChunk = LinkedHashMap<UUID, Resolved>()
            list.forEach { o -> o.exercises.forEach { (_, r, _) -> if (r.isNew) newInChunk.putIfAbsent(r.id, r) } }
            buildJsonObject {
                put("schemaVersion", 1)
                put("note", "CSV import ($format) ${ci + 1}/${chunks.size}")
                if (newInChunk.isNotEmpty()) put("exercises", buildJsonArray {
                    newInChunk.values.forEach { r ->
                        add(buildJsonObject {
                            put("id", r.id.toString())
                            put("nameKo", r.name)
                            put("nameEn", r.name)
                            put("type", r.type)
                            put("primaryMuscle", r.muscle)
                        })
                    }
                })
                put("sessions", buildJsonArray {
                    list.forEach { o ->
                        add(buildJsonObject {
                            put("id", o.id.toString())
                            put("startedAt", Times.format(o.raw.start))
                            o.raw.end?.let { put("endedAt", Times.format(it)) }
                            put("tz", tz)
                            val note = listOfNotNull(o.raw.title.takeIf { it.isNotBlank() }, o.raw.note).joinToString("\n")
                            if (note.isNotEmpty()) put("note", note)
                            put("exercises", buildJsonArray {
                                o.exercises.forEach { (e, r, sets) ->
                                    add(buildJsonObject {
                                        put("exercise", buildJsonObject { put("id", r.id.toString()) })
                                        e.note?.let { put("note", it) }
                                        e.superset?.let { put("supersetGroup", it) }
                                        put("sets", buildJsonArray { sets.forEach { add(setJson(it, r.type)) } })
                                    })
                                }
                            })
                        })
                    }
                })
            }
        }

        val matched = out.flatMap { o -> o.exercises.map { it.second } }.filter { !it.isNew }.map { it.id }.toSet().size
        val newNames = out.flatMap { o -> o.exercises.map { it.second } }.filter { it.isNew }.distinctBy { it.id }.map { it.name }
        val summary = CsvSummary(format, out.size, out.sumOf { it.setCount }, matched, newNames, skipped.sortedBy { it.line })
        return CsvConversion(format, bundles, summary)
    }

    private fun setJson(s: RawSet, type: String): JsonObject = buildJsonObject {
        if (s.isWarmup) put("isWarmup", true)
        if (s.setType != "NORMAL") put("setType", s.setType)
        val w = s.weight
        if (type == "BODYWEIGHT" || type == "BAND") {
            if (w != null && w > 0) put("addedWeightKg", w)
        } else if (type != "CARDIO" || w != null) {
            put("weightKg", w ?: 0.0)
        }
        s.reps?.let { put("reps", it) }
        s.durationSec?.let { put("durationSec", it) }
        s.distanceM?.let { put("distanceM", it) }
        s.rpe?.let { put("rpe", it) }
    }
}
