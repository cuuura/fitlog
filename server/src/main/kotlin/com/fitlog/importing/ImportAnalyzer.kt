package com.fitlog.importing

import com.fitlog.core.ApiException
import com.fitlog.core.AppJson
import com.fitlog.core.BodyMeasurements
import com.fitlog.core.ErrorCode
import com.fitlog.core.ErrorDetail
import com.fitlog.core.Exercises
import com.fitlog.core.Kg
import com.fitlog.core.OneRmMeasurements
import com.fitlog.core.ProgramInstances
import com.fitlog.core.Programs
import com.fitlog.core.ScheduledWorkouts
import com.fitlog.core.SessionExercises
import com.fitlog.core.Times
import com.fitlog.core.UserSettingsTable
import com.fitlog.core.WorkoutSessions
import com.fitlog.core.WorkoutSets
import com.fitlog.engine.E1rmFormula
import com.fitlog.engine.Needs
import com.fitlog.engine.ProgramDefinition
import com.fitlog.engine.ProgramEngine
import com.fitlog.engine.ProgramState
import com.fitlog.program.catalog.ExerciseIndex
import com.fitlog.program.schema.ExerciseResolver
import com.fitlog.program.schema.ProgramValidator
import com.fitlog.program.schema.ResolveResult
import com.fitlog.program.schema.ValidationResult
import com.fitlog.scheduled.ScheduledItem
import com.fitlog.scheduled.ScheduledWorkout
import com.fitlog.scheduled.findScheduled
import com.fitlog.scheduled.toScheduled
import com.fitlog.session.WorkoutSet
import com.fitlog.session.checkSet
import com.fitlog.session.loadSession
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject
import org.jetbrains.exposed.sql.ResultRow
import org.jetbrains.exposed.sql.SortOrder
import org.jetbrains.exposed.sql.SqlExpressionBuilder.eq
import org.jetbrains.exposed.sql.SqlExpressionBuilder.greaterEq
import org.jetbrains.exposed.sql.SqlExpressionBuilder.inList
import org.jetbrains.exposed.sql.SqlExpressionBuilder.isNotNull
import org.jetbrains.exposed.sql.SqlExpressionBuilder.isNull
import org.jetbrains.exposed.sql.SqlExpressionBuilder.lessEq
import org.jetbrains.exposed.sql.SqlExpressionBuilder.neq
import org.jetbrains.exposed.sql.and
import org.jetbrains.exposed.sql.or
import org.jetbrains.exposed.sql.transactions.TransactionManager
import org.jetbrains.exposed.sql.selectAll
import java.math.BigDecimal
import java.math.RoundingMode
import java.time.Duration
import java.time.Instant
import java.time.ZoneId
import java.util.UUID

internal const val DEFAULT_TZ = "Asia/Seoul"
private val ACTIONS = setOf("SKIP", "KEEP_BOTH", "REPLACE", "MAP_TO", "CREATE", "UNLINK", "SET")

private class ExRow(val id: UUID, val ownerId: UUID?, val nameKo: String, val nameEn: String?, val type: String)

private sealed interface ExRes {
    class Found(val row: ExRow) : ExRes
    data object Skipped : ExRes
    data object Pending : ExRes
}

private enum class Out { NEW, UNCHANGED, SKIP, UNRESOLVED }

/** id 충돌 판정 결과. inPlace = ID_EXISTS REPLACE(같은 id 에 덮어씀), keepBoth = ID_EXISTS KEEP_BOTH(새 id) */
private class Cls(val id: UUID, val out: Out, val inPlace: Boolean = false, val keepBoth: Boolean = false, val remapped: Boolean = false)

private class Ex(val mine: Boolean, val deleted: Boolean, val shared: Boolean = false, val same: () -> Boolean)

private class Cand(
    val s: PSession, val ws: WSession, val cls: Cls, val replaces: List<Old>,
)

private fun norm(s: String) = ProgramValidator.normalizeName(s)

/**
 * 검증·이름 해석·충돌 탐지·해결 적용을 한 번에 한다(쓰기 없음). 호출자는 DB 트랜잭션 안에서 부르고,
 * 저장할 때는 먼저 lockUser 를 호출해야 한다.
 */
internal class Analyzer(private val ctx: ImportContext, private val req: ImportRequest) {
    private val uid = ctx.userId
    val errors = mutableListOf<ErrorDetail>()
    val conflicts = mutableListOf<Conflict>()
    val unresolved = mutableListOf<String>()
    val counts = linkedMapOf<String, MutableMap<String, Int>>()
    val plan = WritePlan()
    lateinit var bundle: ParsedBundle
    lateinit var hash: String
    private lateinit var fallbackTz: String

    private val visible = mutableListOf<ExRow>()
    private val bundleEx = mutableMapOf<String, ExRow>()
    private val bundleExIds = mutableMapOf<UUID, ExRow>()
    private val skippedBundleExIds = mutableSetOf<UUID>()
    private val unknownMemo = mutableMapOf<String, ExRes>()

    /** 다른 사용자 행과 겹쳐 바꾼 id (원래 id 문자열 -> 새 id 문자열) */
    private val remap = mutableMapOf<String, String>()

    private class PEff(val id: UUID, val def: ProgramDefinition)

    private val progByRef = mutableMapOf<String, PEff?>()
    private val progById = mutableMapOf<UUID, PEff?>()
    private val instInfos = mutableMapOf<UUID, InstInfo?>()

    private fun tx() = TransactionManager.current()

    private fun count(kind: String, what: String) {
        counts.getOrPut(kind) { linkedMapOf() }.merge(what, 1, Int::plus)
    }

    private fun err(path: String, msg: String) {
        errors += ErrorDetail(path, msg)
    }

    fun preview() = ImportPreview(valid = true, counts = counts, conflicts = conflicts, unresolved = unresolved)

    private fun eid(ptr: String, explicit: UUID?) = explicit ?: detId(uid, hash, ptr)

    private fun validTz(tz: String) = tz in ZoneId.getAvailableZoneIds()

    // ================================================================ 진입점

    fun run(): Analyzer {
        hash = bundleHash(req.bundle)
        if (req.onConflict != "ASK" && req.onConflict != "SKIP_ALL") err("/onConflict", "must be ASK or SKIP_ALL")
        if (req.tz != null && !validTz(req.tz)) err("/tz", "must be a valid IANA time zone")
        if ((req.clientName?.length ?: 0) > 40) err("/clientName", "must be at most 40 characters")
        req.resolutions.forEach { (k, r) ->
            if (r.action !in ACTIONS) err("/resolutions/${escPtr(k)}/action", "must be one of ${ACTIONS.joinToString(", ")}")
        }
        bundle = ImportSchema.parse(req.bundle, errors)

        loadVisibleExercises()
        fallbackTz = req.tz?.takeIf { validTz(it) } ?: recentSessionTz() ?: DEFAULT_TZ

        if (errors.isNotEmpty()) {
            // 스키마 위반: 저장하지 않는다. 프로그램 정의는 그래도 검사해 에러를 한 번에 돌려준다
            val rows = bundle.exercises.map { ExerciseIndex.Row(detId(uid, hash, it.ptr).toString(), uid, it.nameKo, it.nameEn) }
            validatePrograms(resolverFor(rows))
            throw invalid()
        }

        exercises()
        programs()
        startPrograms()
        scheduledWorkouts()
        sessions()
        bodies()
        if (errors.isNotEmpty()) throw invalid()
        return this
    }

    private fun invalid() = ApiException(ErrorCode.VALIDATION_FAILED, "bundle is invalid", details = errors.toList())

    private fun rewriteIds(el: JsonElement): JsonElement = when {
        remap.isEmpty() -> el
        el is JsonObject -> JsonObject(el.mapValues { rewriteIds(it.value) })
        el is JsonArray -> JsonArray(el.map { rewriteIds(it) })
        el is JsonPrimitive && el.isString -> remap[el.content.lowercase()]?.let { JsonPrimitive(it) } ?: el
        else -> el
    }

    private fun validatePrograms(resolver: ExerciseResolver): Map<Int, ProgramDefinition> {
        val out = mutableMapOf<Int, ProgramDefinition>()
        for (p in bundle.programs) {
            when (val v = ProgramValidator.validate(rewriteIds(p.definition), resolver)) {
                is ValidationResult.Valid -> out[p.index] = v.definition
                is ValidationResult.Invalid -> v.errors.forEach { errors += ErrorDetail("${p.ptr}/definition${it.path}", it.message) }
            }
        }
        return out
    }

    private fun resolverFor(bundleRows: List<ExerciseIndex.Row>): ExerciseResolver {
        val base = ExerciseIndex(visible.map { ExerciseIndex.Row(it.id.toString(), it.ownerId, it.nameKo, it.nameEn) })
        val extra = ExerciseIndex(bundleRows)
        return { ref ->
            val r = base.resolve(ref)
            if (r is ResolveResult.Failed) extra.resolve(ref).let { r2 -> if (r2 is ResolveResult.Found) r2 else r } else r
        }
    }

    // ================================================================ 공용 판정

    /** 충돌 하나를 기록하고 해결을 돌려준다. 해결이 없으면 null(unresolved 에 추가) */
    private fun decide(
        code: String, ptr: String, message: String, allowed: List<String>, existing: JsonObject? = null,
        candidates: List<ExerciseCandidate>? = null, suggested: JsonObject? = null,
    ): Resolution? {
        val c = Conflict("$code:$ptr", code, ptr, message, allowed, existing, candidates, suggested)
        conflicts += c
        val r = req.resolutions[c.conflictId]
        if (r != null) {
            if (r.action !in allowed) {
                err("/resolutions/${escPtr(c.conflictId)}/action", "must be one of ${allowed.joinToString(", ")}")
                return Resolution("SKIP")
            }
            return r
        }
        if (req.onConflict == "SKIP_ALL") return Resolution("SKIP")
        unresolved += c.conflictId
        return null
    }

    /** 같은 id 가 이미 있는지 보고 UNCHANGED / ID_EXISTS 충돌 / 새로 만들기를 정한다 */
    private fun classify(
        ptr: String, explicit: UUID?, allowReplace: Boolean, lookup: (UUID) -> Ex?, summary: (UUID) -> JsonObject?,
    ): Cls {
        var id = eid(ptr, explicit)
        var ex = lookup(id)
        var remapped = false
        if (ex != null && !ex.mine && !ex.shared) {
            // 다른 사용자의 행과 id 가 겹침: 알리지 않고 결정적 새 id 로 바꾼다(묶음 안 참조도 같이 바뀐다)
            val old = id
            id = detId(uid, hash, "$ptr#remap")
            ex = lookup(id)
            remapped = true
            remap[old.toString()] = id.toString()
        }
        if (ex != null && ex.mine && !ex.deleted && ex.same()) return Cls(id, Out.UNCHANGED, remapped = remapped)
        if (ex != null && !(ex.mine && ex.deleted)) {
            val allowed = if (ex.mine && allowReplace) listOf("SKIP", "REPLACE", "KEEP_BOTH") else listOf("SKIP", "KEEP_BOTH")
            val r = decide("ID_EXISTS", ptr, "an item with this id already exists with different content", allowed, if (ex.mine) summary(id) else null)
            return when (r?.action) {
                null -> Cls(id, Out.UNRESOLVED)
                "SKIP" -> Cls(id, Out.SKIP)
                "REPLACE" -> Cls(id, Out.NEW, inPlace = true, remapped = remapped)
                else -> {
                    id = detId(uid, hash, "$ptr#2")
                    val again = lookup(id)
                    if (again != null && again.mine && !again.deleted && again.same()) Cls(id, Out.UNCHANGED, keepBoth = true)
                    else Cls(id, Out.NEW, keepBoth = true)
                }
            }
        }
        return Cls(id, Out.NEW, remapped = remapped)
    }

    private fun kindWhat(c: Cls) = if (c.inPlace) "REPLACE" else "NEW"

    // ================================================================ 종목

    private fun loadVisibleExercises() {
        Exercises.selectAll().where { Exercises.deletedAt.isNull() and (Exercises.ownerId.isNull() or (Exercises.ownerId eq uid)) }
            .forEach { visible += ExRow(it[Exercises.id], it[Exercises.ownerId], it[Exercises.nameKo], it[Exercises.nameEn], it[Exercises.type]) }
    }

    private fun recentSessionTz(): String? =
        WorkoutSessions.selectAll().where { (WorkoutSessions.userId eq uid) and WorkoutSessions.deletedAt.isNull() }
            .orderBy(WorkoutSessions.startedAt to SortOrder.DESC).limit(1).firstOrNull()?.get(WorkoutSessions.tz)

    private fun matchesName(r: ExRow, key: String) = norm(r.nameKo) == key || (r.nameEn != null && norm(r.nameEn) == key)

    private fun registerBundleEx(row: ExRow) {
        bundleExIds[row.id] = row
        bundleEx.putIfAbsent(norm(row.nameKo), row)
        row.nameEn?.let { bundleEx.putIfAbsent(norm(it), row) }
    }

    private fun exerciseSummary(r: ResultRow) = buildJsonObject {
        put("id", r[Exercises.id].toString())
        put("nameKo", r[Exercises.nameKo])
        put("type", r[Exercises.type])
        put("primaryMuscle", r[Exercises.primaryMuscle])
    }

    private fun exercises() {
        for (e in bundle.exercises) {
            val c = classify(
                e.ptr, e.id, true,
                lookup = { id ->
                    Exercises.selectAll().where { Exercises.id eq id }.singleOrNull()?.let { r ->
                        Ex(r[Exercises.ownerId] == uid, r[Exercises.deletedAt] != null, r[Exercises.ownerId] == null) {
                            r[Exercises.nameKo] == e.nameKo && r[Exercises.nameEn] == e.nameEn && r[Exercises.type] == e.type &&
                                r[Exercises.primaryMuscle] == e.primaryMuscle && r[Exercises.secondaryMuscles].toSet() == e.secondary.toSet()
                        }
                    }
                },
                summary = { id -> Exercises.selectAll().where { Exercises.id eq id }.singleOrNull()?.let(::exerciseSummary) },
            )
            when (c.out) {
                Out.UNCHANGED -> {
                    count("exercises", "UNCHANGED")
                    registerBundleEx(ExRow(c.id, uid, e.nameKo, e.nameEn, e.type))
                }
                Out.SKIP -> {
                    count("exercises", "SKIP")
                    skippedBundleExIds += c.id
                }
                Out.UNRESOLVED -> skippedBundleExIds += c.id
                Out.NEW -> {
                    // id 없이 보낸 종목이 이미 있는 종목과 이름이 같으면 새로 만들지 않고 그것을 쓴다
                    val reuse = if (e.id == null && !c.inPlace) {
                        val keys = listOfNotNull(norm(e.nameKo), e.nameEn?.let { norm(it) })
                        visible.filter { r -> keys.any { matchesName(r, it) } }
                            .sortedWith(compareBy<ExRow> { it.ownerId == null }.thenBy { it.id }).firstOrNull()
                    } else null
                    if (reuse != null) {
                        count("exercises", "UNCHANGED")
                        registerBundleEx(reuse)
                    } else {
                        plan.exercises += WExercise(c.id, e.nameKo, e.nameEn, e.type, e.primaryMuscle, e.secondary, c.inPlace)
                        count("exercises", kindWhat(c))
                        registerBundleEx(ExRow(c.id, uid, e.nameKo, e.nameEn, e.type))
                    }
                }
            }
        }
    }

    private fun candidatesFor(name: String): List<ExerciseCandidate> {
        val q = norm(name)
        fun n(r: ExRow) = norm(r.nameKo)
        fun m(r: ExRow, f: (String) -> Boolean) = f(n(r)) || (r.nameEn != null && f(norm(r.nameEn)))
        val hits = visible.filter { r -> m(r) { it.contains(q) } }.sortedWith(compareBy({ it.nameKo }, { it.id })).toMutableList()
        if (hits.size < 3) {
            visible.filter { r -> r !in hits && m(r) { it.length >= 2 && q.contains(it) } }
                .sortedWith(compareBy({ it.nameKo }, { it.id })).forEach { hits += it }
        }
        return hits.take(3).map { ExerciseCandidate(it.id.toString(), it.nameKo, it.nameEn) }
    }

    private fun resolveEx(ref: PExRef, exPtr: String): ExRes = when (ref) {
        is PExRef.ById -> {
            val rid = remap[ref.id.toString()]?.let { UUID.fromString(it) } ?: ref.id
            val row = bundleExIds[rid] ?: visible.firstOrNull { it.id == rid }
            when {
                row != null -> ExRes.Found(row)
                rid in skippedBundleExIds -> ExRes.Skipped
                else -> { err("$exPtr/exercise/id", "unknown exercise"); ExRes.Pending }
            }
        }
        is PExRef.ByName -> {
            val key = norm(ref.name)
            val mine = visible.filter { it.ownerId != null && matchesName(it, key) }
            val builtIn = visible.filter { it.ownerId == null && matchesName(it, key) }
            val inBundle = bundleEx[key]
            when {
                mine.size == 1 -> ExRes.Found(mine[0])
                mine.size > 1 -> unknown(key, ref.name, exPtr, "exercise name is ambiguous (${mine.size} of your exercises match)", mine)
                builtIn.size == 1 -> ExRes.Found(builtIn[0])
                builtIn.size > 1 -> unknown(key, ref.name, exPtr, "exercise name is ambiguous (${builtIn.size} exercises match)", builtIn)
                inBundle != null -> ExRes.Found(inBundle)
                else -> unknown(key, ref.name, exPtr, "no exercise named '${ref.name}'", null)
            }
        }
    }

    private fun unknown(key: String, name: String, exPtr: String, message: String, ambiguous: List<ExRow>?): ExRes =
        unknownMemo.getOrPut(key) {
            val ptr = "$exPtr/exercise"
            val cands = ambiguous?.take(3)?.map { ExerciseCandidate(it.id.toString(), it.nameKo, it.nameEn) } ?: candidatesFor(name)
            val r = decide("UNKNOWN_EXERCISE", ptr, message, listOf("MAP_TO", "CREATE", "SKIP"), candidates = cands)
            val cid = "UNKNOWN_EXERCISE:$ptr"
            val rp = "/resolutions/${escPtr(cid)}"
            if (r == null) ExRes.Pending else when (r.action) {
                "SKIP" -> ExRes.Skipped
                "MAP_TO" -> {
                    val id = runCatching { UUID.fromString(r.exerciseId) }.getOrNull()
                    val row = id?.let { i -> bundleExIds[i] ?: visible.firstOrNull { it.id == i } }
                    if (row == null) { err("$rp/exerciseId", "must be the id of an existing exercise"); ExRes.Pending } else ExRes.Found(row)
                }
                else -> { // CREATE
                    val o = r.exercise
                    val type = (o?.get("type") as? JsonPrimitive)?.takeIf { it.isString }?.content
                    val muscle = (o?.get("primaryMuscle") as? JsonPrimitive)?.takeIf { it.isString }?.content
                    val ko = ((o?.get("nameKo") as? JsonPrimitive)?.takeIf { it.isString }?.content ?: name).trim()
                    val en = (o?.get("nameEn") as? JsonPrimitive)?.takeIf { it.isString }?.content?.trim()?.ifEmpty { null }
                    val sec = (o?.get("secondaryMuscles") as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.content }.orEmpty()
                    var ok = true
                    if (type == null || type !in EXERCISE_TYPE_NAMES) { err("$rp/exercise/type", "must be one of ${EXERCISE_TYPE_NAMES.joinToString(", ")}"); ok = false }
                    if (muscle == null || muscle !in MUSCLE_NAMES) { err("$rp/exercise/primaryMuscle", "must be a valid muscle"); ok = false }
                    if (ko.isEmpty() || ko.length > 60) { err("$rp/exercise/nameKo", "must be 1..60 characters"); ok = false }
                    if (en != null && en.length > 60) { err("$rp/exercise/nameEn", "must be at most 60 characters"); ok = false }
                    sec.forEachIndexed { i, m -> if (m !in MUSCLE_NAMES) { err("$rp/exercise/secondaryMuscles/$i", "must be a valid muscle"); ok = false } }
                    if (!ok) ExRes.Pending else {
                        val id = detId(uid, hash, "$ptr#create")
                        plan.exercises += WExercise(id, ko, en, type!!, muscle!!, sec.distinct().filter { it != muscle }, false)
                        count("exercises", "NEW")
                        val row = ExRow(id, uid, ko, en, type)
                        registerBundleEx(row)
                        ExRes.Found(row)
                    }
                }
            }
        }

    // ================================================================ 프로그램

    private fun programSummary(r: ResultRow) = buildJsonObject {
        put("id", r[Programs.id].toString())
        put("name", r[Programs.name])
        put("dayCount", runCatching { AppJson.decodeFromString<ProgramDefinition>(r[Programs.definition]).days.size }.getOrDefault(0))
    }

    private fun programs() {
        val rows = bundleExIds.values.map { ExerciseIndex.Row(it.id.toString(), uid, it.nameKo, it.nameEn) }
        val defs = validatePrograms(resolverFor(rows))
        for (p in bundle.programs) {
            var def = defs[p.index] ?: continue
            val c = classify(
                p.ptr, p.id, true,
                lookup = { id ->
                    Programs.selectAll().where { Programs.id eq id }.singleOrNull()?.let { r ->
                        Ex(r[Programs.ownerId] == uid, r[Programs.deletedAt] != null, r[Programs.ownerId] == null) {
                            runCatching { AppJson.decodeFromString<ProgramDefinition>(r[Programs.definition]) }.getOrNull() == def
                        }
                    }
                },
                summary = { id -> Programs.selectAll().where { Programs.id eq id }.singleOrNull()?.let(::programSummary) },
            )
            var eff: PEff? = null
            when (c.out) {
                Out.UNCHANGED -> { count("programs", "UNCHANGED"); eff = PEff(c.id, def) }
                Out.SKIP -> {
                    count("programs", "SKIP")
                    eff = Programs.selectAll().where { (Programs.id eq c.id) and Programs.deletedAt.isNull() and (Programs.ownerId eq uid) }
                        .singleOrNull()?.let { r -> PEff(r[Programs.id], AppJson.decodeFromString(r[Programs.definition])) }
                }
                Out.UNRESOLVED -> {}
                Out.NEW -> {
                    var replace = c.inPlace
                    var skipped = false
                    if (!c.inPlace) {
                        val same = Programs.selectAll().where { (Programs.ownerId eq uid) and Programs.deletedAt.isNull() }
                            .filter { it[Programs.id] != c.id && it[Programs.name].trim().equals(def.name.trim(), ignoreCase = true) }
                        if (same.isNotEmpty()) {
                            val r = decide(
                                "PROGRAM_NAME_EXISTS", p.ptr, "you already have a program named '${def.name}'",
                                listOf("SKIP", "KEEP_BOTH", "REPLACE"), programSummary(same.first()),
                            )
                            when (r?.action) {
                                null -> { skipped = true }
                                "SKIP" -> {
                                    skipped = true
                                    count("programs", "SKIP")
                                    val r0 = same.first()
                                    eff = PEff(r0[Programs.id], AppJson.decodeFromString(r0[Programs.definition]))
                                }
                                "KEEP_BOTH" -> {
                                    val taken = Programs.selectAll().where { (Programs.ownerId eq uid) and Programs.deletedAt.isNull() }
                                        .map { it[Programs.name].trim().lowercase() }.toSet() + plan.programs.map { it.name.trim().lowercase() }
                                    var n = 2
                                    while ("${def.name} ($n)".lowercase() in taken) n++
                                    def = def.copy(name = "${def.name} ($n)")
                                }
                                else -> { // REPLACE
                                    same.forEach { old ->
                                        if (plan.replacedPrograms.none { it.id == old[Programs.id] }) {
                                            plan.replacedPrograms += Old(old[Programs.id], old[Programs.name])
                                        }
                                    }
                                    replace = true
                                }
                            }
                        }
                    }
                    if (!skipped) {
                        plan.programs += WProgram(c.id, def.name, def, c.inPlace)
                        count("programs", if (replace) "REPLACE" else "NEW")
                        eff = PEff(c.id, def)
                    }
                }
            }
            p.ref?.let { progByRef[it] = eff }
            progById[c.id] = eff
            p.id?.let { progById[it] = eff }
        }
    }

    // ================================================================ 인스턴스 시작

    private fun suggestValues(def: ProgramDefinition, needs: Map<String, Needs>): Map<String, Double> {
        val formula = UserSettingsTable.selectAll().where { UserSettingsTable.userId eq uid }.singleOrNull()
            ?.get(UserSettingsTable.e1rmFormula)?.let { runCatching { E1rmFormula.valueOf(it) }.getOrNull() } ?: E1rmFormula.EPLEY
        val since = Times.now().minus(Duration.ofDays(90))
        val out = linkedMapOf<String, Double>()
        for ((key, need) in needs) {
            val exId = def.lifts[key]?.exercise?.id?.let { runCatching { UUID.fromString(it) }.getOrNull() } ?: continue
            val measured = OneRmMeasurements.selectAll()
                .where { (OneRmMeasurements.userId eq uid) and (OneRmMeasurements.exerciseId eq exId) and OneRmMeasurements.deletedAt.isNull() }
                .orderBy(OneRmMeasurements.measuredAt to SortOrder.DESC).limit(1).firstOrNull()?.get(OneRmMeasurements.weightKg)?.toDouble()
            val oneRm = measured ?: WorkoutSets
                .join(SessionExercises, org.jetbrains.exposed.sql.JoinType.INNER, WorkoutSets.sessionExerciseId, SessionExercises.id)
                .join(WorkoutSessions, org.jetbrains.exposed.sql.JoinType.INNER, SessionExercises.sessionId, WorkoutSessions.id)
                .selectAll().where {
                    (WorkoutSessions.userId eq uid) and WorkoutSessions.deletedAt.isNull() and (WorkoutSessions.startedAt greaterEq since) and
                        SessionExercises.deletedAt.isNull() and (SessionExercises.exerciseId eq exId) and WorkoutSets.deletedAt.isNull() and
                        (WorkoutSets.isWarmup eq false) and WorkoutSets.completedAt.isNotNull()
                }.mapNotNull { ProgramEngine.estimateOneRm(formula, it[WorkoutSets.weightKg]?.toDouble(), it[WorkoutSets.reps]) }.maxOrNull()
                ?: continue
            val pct = if (need == Needs.TM) def.tmPercent else def.workingPercent
            out[key] = BigDecimal.valueOf(oneRm).multiply(BigDecimal.valueOf(pct)).setScale(2, RoundingMode.HALF_UP).toDouble()
        }
        return out
    }

    private fun parseWeights(o: JsonObject?, rp: String, field: String): Map<String, Double> {
        val m = o?.get(field) as? JsonObject ?: return emptyMap()
        val out = linkedMapOf<String, Double>()
        for ((k, v) in m) {
            val d = (v as? JsonPrimitive)?.takeIf { !it.isString }?.content?.toDoubleOrNull()
            if (d == null || d <= 0 || d > 9999.99) err("$rp/value/$field/${escPtr(k)}", "must be a number between 0 and 9999.99") else out[k] = d
        }
        return out
    }

    private sealed interface ProgRes {
        class Found(val p: PEff) : ProgRes
        data object Skipped : ProgRes
        data object Missing : ProgRes
    }

    private fun progFromDb(where: org.jetbrains.exposed.sql.Op<Boolean>): PEff? =
        Programs.selectAll().where { where and Programs.deletedAt.isNull() }.singleOrNull()
            ?.let { r -> PEff(r[Programs.id], AppJson.decodeFromString(r[Programs.definition])) }

    private fun resolveProgram(ref: PProgRef, ptr: String): ProgRes = when (ref) {
        is PProgRef.ById -> when {
            progById.containsKey(ref.id) -> progById[ref.id]?.let { ProgRes.Found(it) } ?: ProgRes.Skipped
            else -> progFromDb((Programs.id eq ref.id) and (Programs.ownerId.isNull() or (Programs.ownerId eq uid)))?.let { ProgRes.Found(it) }
                ?: run { err("$ptr/program/id", "unknown program"); ProgRes.Missing }
        }
        is PProgRef.Template ->
            progFromDb(Programs.templateKey eq ref.key)?.let { ProgRes.Found(it) }
                ?: run { err("$ptr/program/templateKey", "unknown template '${ref.key}'"); ProgRes.Missing }
        is PProgRef.Ref -> when {
            progByRef.containsKey(ref.ref) -> progByRef[ref.ref]?.let { ProgRes.Found(it) } ?: ProgRes.Skipped
            else -> { err("$ptr/program/ref", "no program with this ref in the bundle"); ProgRes.Missing }
        }
    }

    private fun instInfoOf(r: ResultRow) = InstInfo(
        r[ProgramInstances.id], AppJson.decodeFromString(r[ProgramInstances.definition]), r[ProgramInstances.stateSeq],
        AppJson.decodeFromString(r[ProgramInstances.state]),
    )

    private fun startPrograms() {
        for (sp in bundle.starts) {
            val prog = when (val r = resolveProgram(sp.program, sp.ptr)) {
                is ProgRes.Found -> r.p
                ProgRes.Skipped -> { sp.id?.let { instInfos[it] = null }; continue }
                ProgRes.Missing -> continue
            }
            val tz = sp.tz ?: fallbackTz
            if (!validTz(tz)) { err("${sp.ptr}/tz", "must be a valid IANA time zone"); continue }
            val c = classify(
                sp.ptr, sp.id, false,
                lookup = { id ->
                    ProgramInstances.selectAll().where { ProgramInstances.id eq id }.singleOrNull()?.let { r ->
                        Ex(r[ProgramInstances.userId] == uid, r[ProgramInstances.deletedAt] != null) {
                            r[ProgramInstances.programId] == prog.id && r[ProgramInstances.startDate] == sp.startDate &&
                                r[ProgramInstances.tz] == tz && r[ProgramInstances.skipPolicy] == sp.skipPolicy
                        }
                    }
                },
                summary = { id ->
                    ProgramInstances.selectAll().where { ProgramInstances.id eq id }.singleOrNull()?.let { r ->
                        buildJsonObject { put("id", id.toString()); put("startDate", r[ProgramInstances.startDate].toString()) }
                    }
                },
            )
            val key = sp.id ?: c.id
            when (c.out) {
                Out.UNCHANGED -> {
                    count("startPrograms", "UNCHANGED")
                    val row = ProgramInstances.selectAll().where { ProgramInstances.id eq c.id }.single()
                    val info = instInfoOf(row)
                    instInfos[c.id] = info; instInfos[key] = info
                }
                Out.SKIP -> { count("startPrograms", "SKIP"); instInfos[key] = null }
                Out.UNRESOLVED -> instInfos[key] = null
                Out.NEW -> {
                    val def = try {
                        com.fitlog.program.instance.applyWeekdays(prog.def, sp.weekdays)
                    } catch (e: com.fitlog.program.instance.WeekdayException) {
                        err("${sp.ptr}/${e.field.replace('.', '/')}", e.message ?: "invalid weekdays"); continue
                    }
                    if (sp.skipPolicy == "FIXED_DATE") {
                        val bad = def.days.indexOfFirst { d -> d.weekday == null }
                        if (bad >= 0) { err("${sp.ptr}/skipPolicy", "FIXED_DATE requires weekday on every day (days[$bad] has none)"); continue }
                    }
                    val needs = ProgramEngine.requiredInputs(def)
                    val tm = sp.tm.toMutableMap()
                    val working = sp.working.toMutableMap()
                    val optionalKeys = ProgramEngine.optionalInputs(def)
                    fun missing() = needs.filter { (k, n) -> k !in optionalKeys && (if (n == Needs.TM) k !in tm else k !in working) }
                    var skip = false
                    if (missing().isNotEmpty()) {
                        val sugg = suggestValues(def, missing())
                        sugg.forEach { (k, v) -> if (needs[k] == Needs.TM) tm.putIfAbsent(k, v) else working.putIfAbsent(k, v) }
                        val still = missing()
                        if (still.isNotEmpty()) {
                            val suggested = buildJsonObject {
                                putJsonObject("tm") {
                                    needs.filter { it.value == Needs.TM }.keys.forEach { k -> tm[k]?.let { put(k, it) } ?: put(k, JsonNull) }
                                }
                                putJsonObject("working") {
                                    needs.filter { it.value == Needs.WORKING }.keys.forEach { k -> working[k]?.let { put(k, it) } ?: put(k, JsonNull) }
                                }
                            }
                            val r = decide(
                                "INSTANCE_NEEDS_VALUE", sp.ptr, "start values are needed for: ${still.keys.joinToString(", ")}",
                                listOf("SET", "SKIP"), suggested = suggested,
                            )
                            when (r?.action) {
                                null -> { skip = true }
                                "SKIP" -> { skip = true; count("startPrograms", "SKIP") }
                                else -> {
                                    r!!
                                    val rp = "/resolutions/${escPtr("INSTANCE_NEEDS_VALUE:${sp.ptr}")}"
                                    tm += parseWeights(r.value, rp, "tm")
                                    working += parseWeights(r.value, rp, "working")
                                    if (missing().isNotEmpty()) { unresolved += "INSTANCE_NEEDS_VALUE:${sp.ptr}"; skip = true }
                                }
                            }
                        }
                    }
                    if (skip) { instInfos[key] = null; continue }
                    if (errors.isNotEmpty() && missing().isNotEmpty()) continue
                    val initial = try {
                        ProgramEngine.initialState(def, tm, working)
                    } catch (e: IllegalArgumentException) {
                        err(sp.ptr, e.message ?: "invalid initial values"); continue
                    }
                    plan.instances += WInstance(c.id, prog.id, def, sp.skipPolicy, sp.startDate, tz, initial, "${def.name} 시작")
                    count("startPrograms", "NEW")
                    val info = InstInfo(c.id, def, 0, initial)
                    instInfos[c.id] = info; instInfos[key] = info
                }
            }
        }
    }

    // ================================================================ 예정 운동

    /** 묶음 안 예정 id(원래 id) -> 최종 id. 저장·UNCHANGED 로 확정된 것만 들어간다 */
    private val schedMap = mutableMapOf<UUID, UUID>()

    private fun schedKey(s: String) = s.filterNot { it.isWhitespace() }.lowercase()

    private fun scheduledSummary(r: ResultRow) = buildJsonObject {
        put("id", r[ScheduledWorkouts.id].toString())
        put("plannedDate", r[ScheduledWorkouts.plannedDate].toString())
        put("title", r[ScheduledWorkouts.title])
        put("itemCount", runCatching { com.fitlog.scheduled.decodeItems(r[ScheduledWorkouts.items]).size }.getOrDefault(0))
    }

    private fun scheduledWorkouts() {
        if (bundle.scheduled.isEmpty()) return
        bundle.scheduled.filter { it.id != null }.groupBy { it.id }.filter { it.value.size > 1 }.values
            .forEach { l -> l.forEach { err("${it.ptr}/id", "duplicate id in bundle") } }
        for (w in bundle.scheduled) {
            if (w.tz != null && !validTz(w.tz)) { err("${w.ptr}/tz", "must be a valid IANA time zone"); continue }
            val resolved = mutableListOf<Pair<PSchedItem, ExRow>>()
            var skippedAny = false
            for (it in w.items) when (val r = resolveEx(it.ref, it.ptr)) {
                is ExRes.Found -> resolved += it to r.row
                ExRes.Skipped -> skippedAny = true
                ExRes.Pending -> {}
            }
            if (resolved.isEmpty()) {
                if (skippedAny) count("scheduledWorkouts", "SKIP")
                continue
            }
            val items = resolved.map { (it, row) -> ScheduledItem(row.id, it.note, it.restSec, it.sets) }
            val label = "${w.plannedDate} ${w.title}"
            val c = classify(
                w.ptr, w.id, true,
                lookup = { id ->
                    ScheduledWorkouts.selectAll().where { ScheduledWorkouts.id eq id }.singleOrNull()?.let { r ->
                        Ex(r[ScheduledWorkouts.userId] == uid, r[ScheduledWorkouts.deletedAt] != null) {
                            val old = r.toScheduled()
                            old.plannedDate == w.plannedDate.toString() && old.title == w.title && blankNull(old.note) == blankNull(w.note) &&
                                old.items == items
                        }
                    }
                },
                summary = { id -> ScheduledWorkouts.selectAll().where { ScheduledWorkouts.id eq id }.singleOrNull()?.let(::scheduledSummary) },
            )
            when (c.out) {
                Out.UNCHANGED -> { count("scheduledWorkouts", "UNCHANGED"); w.id?.let { schedMap[it] = c.id }; continue }
                Out.SKIP -> { count("scheduledWorkouts", "SKIP"); continue }
                Out.UNRESOLVED -> continue
                Out.NEW -> {}
            }
            val replaces = mutableListOf<Old>()
            if (!c.inPlace) {
                val key = schedKey(w.title)
                val same = ScheduledWorkouts.selectAll().where {
                    (ScheduledWorkouts.userId eq uid) and ScheduledWorkouts.deletedAt.isNull() and
                        (ScheduledWorkouts.plannedDate eq w.plannedDate) and (ScheduledWorkouts.id neq c.id)
                }.filter { schedKey(it[ScheduledWorkouts.title]) == key }
                if (same.isNotEmpty()) {
                    val r = decide(
                        "SCHEDULED_DUPLICATE", w.ptr, "a scheduled workout titled '${w.title}' already exists on ${w.plannedDate}",
                        listOf("SKIP", "KEEP_BOTH", "REPLACE"),
                        scheduledSummary(same.first()).let { j -> JsonObject(j + ("matches" to JsonPrimitive(same.size))) },
                    )
                    when (r?.action) {
                        null -> continue
                        "SKIP" -> { count("scheduledWorkouts", "SKIP"); continue }
                        "REPLACE" -> same.forEach { replaces += Old(it[ScheduledWorkouts.id], "${it[ScheduledWorkouts.plannedDate]} ${it[ScheduledWorkouts.title]}") }
                        else -> {}
                    }
                }
            }
            replaces.forEach { o -> if (plan.replacedScheduled.none { it.id == o.id }) plan.replacedScheduled += o }
            val saved = ScheduledWorkout(c.id, w.plannedDate.toString(), w.title, w.note, items)
            plan.scheduled += WScheduled(c.id, saved, label, c.inPlace)
            w.id?.let { schedMap[it] = c.id }
            count("scheduledWorkouts", if (c.inPlace || replaces.isNotEmpty()) "REPLACE" else "NEW")
        }
    }

    /** 세션이 가리킬 예정: 묶음 안 id(바뀐 id 포함) 또는 내 살아 있는 예정. 없으면 null(연결 없이 저장) */
    private fun scheduledTarget(raw: UUID?): UUID? {
        if (raw == null) return null
        val id = remap[raw.toString()]?.let { UUID.fromString(it) } ?: raw
        return schedMap[raw] ?: schedMap[id]
            ?: tx().findScheduled(uid, id)?.id?.takeIf { _ -> plan.replacedScheduled.none { it.id == id } }
    }

    // ================================================================ 세션

    private class ExistingSession(val id: UUID, val startedAt: Instant, val endedAt: Instant?, val tz: String)

    private fun sessionSummary(id: UUID, matches: Int): JsonObject {
        val s = tx().loadSession(uid, id)
        return buildJsonObject {
            put("id", id.toString())
            if (s != null) {
                put("startedAt", Times.format(s.startedAt))
                s.endedAt?.let { put("endedAt", Times.format(it)) }
                put("tz", s.tz)
                put("exerciseCount", s.exercises.size)
                put("setCount", s.exercises.sumOf { it.sets.size })
                val names = Exercises.selectAll().where { Exercises.id inList s.exercises.map { it.exerciseId } }
                    .associate { it[Exercises.id] to it[Exercises.nameKo] }
                put("exercises", JsonArray(s.exercises.mapNotNull { names[it.exerciseId] }.map { JsonPrimitive(it) }))
            }
            put("matches", matches)
        }
    }

    private fun fpOfDb(s: com.fitlog.session.Session) = FpSession(
        s.startedAt.toEpochMilli(), s.endedAt?.toEpochMilli(), s.tz, blankNull(s.note),
        s.exercises.sortedBy { it.position }.map { e ->
            FpEx(
                e.exerciseId, blankNull(e.note),
                e.sets.sortedBy { it.position }.map { fpSet(it.isWarmup, it.weightKg, it.addedWeightKg, it.reps, it.durationSec, it.distanceM, it.rpe, it.rir, it.restSec, it.note) },
            )
        },
    )

    private fun setCore(ps: PSet, type: String, startedAt: Instant): WorkoutSet? {
        val dto = WorkoutSet(
            id = UUID(0, 0), position = 0, isWarmup = ps.isWarmup, weightKg = ps.weightKg, addedWeightKg = ps.addedWeightKg,
            reps = ps.reps, durationSec = ps.durationSec, distanceM = ps.distanceM, rpe = ps.rpe, rir = ps.rir, restSec = ps.restSec,
            note = ps.note, completedAt = startedAt,
        )
        return try {
            checkSet(dto, type, "")
        } catch (e: ApiException) {
            err(if (e.field != null) "${ps.ptr}/${e.field}" else ps.ptr, e.message)
            null
        }
    }

    private fun sessions() {
        if (bundle.sessions.isEmpty()) return
        // 겹침 검사용: 번들 시각 범위 앞뒤 2일의 내 살아있는 세션
        val lo = bundle.sessions.minOf { it.startedAt }.minus(Duration.ofDays(2))
        val hi = bundle.sessions.maxOf { it.endedAt ?: it.startedAt }.plus(Duration.ofDays(2)).plus(Duration.ofHours(12))
        val existing = WorkoutSessions.selectAll().where {
            (WorkoutSessions.userId eq uid) and WorkoutSessions.deletedAt.isNull() and
                (WorkoutSessions.startedAt greaterEq lo) and (WorkoutSessions.startedAt lessEq hi)
        }.map { ExistingSession(it[WorkoutSessions.id], it[WorkoutSessions.startedAt], it[WorkoutSessions.endedAt], it[WorkoutSessions.tz]) }

        val explicitIds = bundle.sessions.mapNotNull { it.id }
        explicitIds.groupBy { it }.filter { it.value.size > 1 }.keys.forEach { dup ->
            bundle.sessions.filter { it.id == dup }.forEach { err("${it.ptr}/id", "duplicate id in bundle") }
        }

        val cands = mutableListOf<Cand>()
        for (s in bundle.sessions) {
            val tz = s.tz ?: fallbackTz
            if (!validTz(tz)) { err("${s.ptr}/tz", "must be a valid IANA time zone"); continue }
            val resolved = mutableListOf<Pair<PSessionEx, ExRow>>()
            var skippedAny = false
            for (ex in s.exercises) when (val r = resolveEx(ex.ref, ex.ptr)) {
                is ExRes.Found -> resolved += ex to r.row
                ExRes.Skipped -> skippedAny = true
                ExRes.Pending -> {}
            }
            if (resolved.isEmpty()) {
                if (skippedAny) count("sessions", "SKIP")
                continue
            }
            // 세트 검증·정규화
            var bad = false
            val sets: List<List<WorkoutSet>> = resolved.map { (ex, row) ->
                ex.sets.map { ps -> setCore(ps, row.type, s.startedAt) ?: run { bad = true; WorkoutSet(UUID(0, 0), 0) } }
            }
            if (bad) continue
            val total = sets.sumOf { it.size }
            val endedAt = s.endedAt ?: s.startedAt.plus(Duration.ofMinutes(3L * total))

            fun build(suffix: String, sid: UUID): WSession {
                var si = 0
                val exs = resolved.mapIndexed { ei, (ex, row) ->
                    WSessionEx(
                        detId(uid, hash, ex.ptr + suffix), row.id, ei, ex.note,
                        sets[ei].mapIndexed { k, w ->
                            val ps = ex.sets[k]
                            si++
                            WSet(
                                (if (suffix.isEmpty()) ps.id else null) ?: detId(uid, hash, ps.ptr + suffix), k, ps.isWarmup,
                                w.weightKg, w.addedWeightKg, w.reps, w.durationSec, w.distanceM, w.rpe, w.rir, w.restSec, ps.note,
                            )
                        },
                    )
                }
                val first = resolved.first().second.nameKo
                val label = "${s.startedAt.atZone(ZoneId.of(tz)).toLocalDate()} $first" + if (resolved.size > 1) " 외 ${resolved.size - 1}" else ""
                return WSession(sid, s.startedAt, endedAt, tz, s.note, null, s.planSeq, exs, label, false)
            }

            val firstWs = build("", eid(s.ptr, s.id))
            val fp = fpOf(firstWs)
            val c = classify(
                s.ptr, s.id, true,
                lookup = { id ->
                    WorkoutSessions.selectAll().where { WorkoutSessions.id eq id }.singleOrNull()?.let { r ->
                        Ex(r[WorkoutSessions.userId] == uid, r[WorkoutSessions.deletedAt] != null) {
                            tx().loadSession(uid, id)?.let { fpOfDb(it) } == fp
                        }
                    }
                },
                summary = { id -> sessionSummary(id, 1) },
            )
            when (c.out) {
                Out.UNCHANGED -> { count("sessions", "UNCHANGED"); continue }
                Out.SKIP -> { count("sessions", "SKIP"); continue }
                Out.UNRESOLVED -> continue
                Out.NEW -> {}
            }
            val ws = (if (c.keepBoth) build("#2", c.id) else if (c.remapped) build("#remap", c.id) else firstWs).let {
                WSession(c.id, it.startedAt, it.endedAt, it.tz, it.note, null, it.planSeq, it.exercises, it.label, c.inPlace)
            }

            // 지원 검사: 명시한 세트 id 가 다른 세션 것이면 거절
            val setIds = ws.exercises.flatMap { e -> e.sets.map { it.id } }
            var ws2 = ws
            if (setIds.isNotEmpty() && !c.keepBoth && !c.remapped) {
                val clash = WorkoutSets
                    .join(SessionExercises, org.jetbrains.exposed.sql.JoinType.INNER, WorkoutSets.sessionExerciseId, SessionExercises.id)
                    .select(WorkoutSets.id, SessionExercises.sessionId).where { WorkoutSets.id inList setIds }
                    .firstOrNull { it[SessionExercises.sessionId] != ws.id }
                if (clash != null) {
                    ws2 = build("#remap", ws.id).let {
                        WSession(ws.id, it.startedAt, it.endedAt, it.tz, it.note, null, it.planSeq, it.exercises, it.label, ws.replace)
                    }
                }
            }

            // SESSION_OVERLAP
            val replaces = mutableListOf<Old>()
            var skip = false
            if (!c.inPlace) {
                val zone = ZoneId.of(tz)
                val day = s.startedAt.atZone(zone).toLocalDate()
                val matches = existing.filter { e ->
                    e.id != ws.id && e.startedAt.atZone(zone).toLocalDate() == day && run {
                        val eEnd = e.endedAt ?: e.startedAt
                        (e.startedAt < endedAt && s.startedAt < eEnd) ||
                            Duration.between(e.startedAt, s.startedAt).abs() <= Duration.ofHours(3)
                    }
                }.sortedBy { it.startedAt }
                if (matches.isNotEmpty()) {
                    val r = decide(
                        "SESSION_OVERLAP", s.ptr, "a session already exists around this time on ${day}",
                        listOf("SKIP", "KEEP_BOTH", "REPLACE"), sessionSummary(matches.first().id, matches.size),
                    )
                    when (r?.action) {
                        null -> skip = true
                        "SKIP" -> { skip = true; count("sessions", "SKIP") }
                        "REPLACE" -> matches.forEach { m ->
                            val label = tx().loadSession(uid, m.id)?.let { "${it.startedAt.atZone(zone).toLocalDate()} 세션" } ?: "세션"
                            replaces += Old(m.id, label)
                        }
                        else -> {}
                    }
                }
            }
            if (skip) continue
            cands += Cand(s, ws2, c, replaces)
        }

        // PLAN_MISMATCH: 인스턴스마다 planSeq 순으로 다음 회차부터 이어지는지 본다
        val mismatch = mutableSetOf<Cand>()
        val linked = cands.filter { it.s.instanceId != null }
        for ((iid, list) in linked.groupBy { it.s.instanceId!! }) {
            val info: InstInfo? = if (instInfos.containsKey(iid)) instInfos[iid] else
                ProgramInstances.selectAll().where {
                    (ProgramInstances.id eq iid) and (ProgramInstances.userId eq uid) and ProgramInstances.deletedAt.isNull()
                }.singleOrNull()?.let { instInfoOf(it) }.also { instInfos[iid] = it }
            if (info == null) {
                if (!instInfos.containsKey(iid) || iid !in bundle.starts.mapNotNull { it.id }) {
                    list.forEach { err("${it.s.ptr}/program/instanceId", "unknown program instance") }
                } else {
                    mismatch += list
                }
                continue
            }
            var expected = info.baseSeq + 1
            for (c in list.sortedBy { it.s.planSeq }) {
                if (c.s.planSeq == expected) { expected++; c.ws.link = info } else mismatch += c
            }
        }
        for (c in cands) {
            if (c in mismatch) {
                val iid = c.s.instanceId!!
                val info = instInfos[iid]
                val existingJson = buildJsonObject {
                    put("instanceId", iid.toString())
                    put("planSeq", c.s.planSeq ?: 0)
                    if (info != null) put("expectedPlanSeq", info.baseSeq + 1)
                }
                val r = decide(
                    "PLAN_MISMATCH", c.s.ptr, "planSeq does not match the next workout of the program instance",
                    listOf("UNLINK", "SKIP"), existingJson,
                )
                when (r?.action) {
                    null -> continue
                    "SKIP" -> { count("sessions", "SKIP"); continue }
                    else -> {} // UNLINK: 연결 없이 저장
                }
            }
            c.ws.scheduledId = scheduledTarget(c.s.scheduledWorkoutId)?.takeIf { sid ->
                // 한 예정에는 살아 있는 세션이 하나. 이미 다른 살아 있는 세션이 쓰고 있으면(이번에 지우는 것 제외) 연결하지 않는다
                val replacedIds = (plan.replacedSessions.map { it.id } + c.replaces.map { it.id }).toSet()
                val takenInDb = WorkoutSessions.selectAll().where {
                    (WorkoutSessions.scheduledWorkoutId eq sid) and WorkoutSessions.deletedAt.isNull() and (WorkoutSessions.id neq c.ws.id)
                }.any { it[WorkoutSessions.id] !in replacedIds }
                !takenInDb && plan.sessions.none { it.scheduledId == sid }
            }
            plan.sessions += c.ws
            count("sessions", if (c.cls.inPlace || c.replaces.isNotEmpty()) "REPLACE" else "NEW")
            c.replaces.forEach { o -> if (plan.replacedSessions.none { it.id == o.id }) plan.replacedSessions += o }
        }
    }

    // ================================================================ 체중

    private fun bodies() {
        if (bundle.bodies.isEmpty()) return
        val lo = bundle.bodies.minOf { it.measuredAt }.minus(Duration.ofDays(2))
        val hi = bundle.bodies.maxOf { it.measuredAt }.plus(Duration.ofDays(2))
        val existing = BodyMeasurements.selectAll().where {
            (BodyMeasurements.userId eq uid) and BodyMeasurements.deletedAt.isNull() and
                (BodyMeasurements.measuredAt greaterEq lo) and (BodyMeasurements.measuredAt lessEq hi)
        }.toList()
        val zone = ZoneId.of(fallbackTz)
        bundle.bodies.filter { it.id != null }.groupBy { it.id }.filter { it.value.size > 1 }.values
            .forEach { l -> l.forEach { err("${it.ptr}/id", "duplicate id in bundle") } }
        for (b in bundle.bodies) {
            val w = Kg.of(b.weightKg)
            val c = classify(
                b.ptr, b.id, true,
                lookup = { id ->
                    BodyMeasurements.selectAll().where { BodyMeasurements.id eq id }.singleOrNull()?.let { r ->
                        Ex(r[BodyMeasurements.userId] == uid, r[BodyMeasurements.deletedAt] != null) {
                            r[BodyMeasurements.measuredAt].toEpochMilli() == b.measuredAt.toEpochMilli() && r[BodyMeasurements.weightKg].compareTo(w) == 0
                        }
                    }
                },
                summary = { id ->
                    BodyMeasurements.selectAll().where { BodyMeasurements.id eq id }.singleOrNull()?.let {
                        buildJsonObject {
                            put("id", id.toString()); put("measuredAt", Times.format(it[BodyMeasurements.measuredAt]))
                            put("weightKg", it[BodyMeasurements.weightKg].toDouble())
                        }
                    }
                },
            )
            when (c.out) {
                Out.UNCHANGED -> { count("bodyMeasurements", "UNCHANGED"); continue }
                Out.SKIP -> { count("bodyMeasurements", "SKIP"); continue }
                Out.UNRESOLVED -> continue
                Out.NEW -> {}
            }
            val day = b.measuredAt.atZone(zone).toLocalDate()
            val replaces = mutableListOf<Old>()
            if (!c.inPlace) {
                val same = existing.filter { it[BodyMeasurements.id] != c.id && it[BodyMeasurements.measuredAt].atZone(zone).toLocalDate() == day }
                if (same.isNotEmpty()) {
                    val first = same.first()
                    val r = decide(
                        "BODY_SAME_DAY", b.ptr, "a weight record already exists on $day",
                        listOf("SKIP", "KEEP_BOTH", "REPLACE"),
                        buildJsonObject {
                            put("id", first[BodyMeasurements.id].toString())
                            put("measuredAt", Times.format(first[BodyMeasurements.measuredAt]))
                            put("weightKg", first[BodyMeasurements.weightKg].toDouble())
                            put("matches", same.size)
                        },
                    )
                    when (r?.action) {
                        null -> continue
                        "SKIP" -> { count("bodyMeasurements", "SKIP"); continue }
                        "REPLACE" -> same.forEach { replaces += Old(it[BodyMeasurements.id], "$day ${it[BodyMeasurements.weightKg]}kg") }
                        else -> {}
                    }
                }
            }
            replaces.forEach { o -> if (plan.replacedBodies.none { it.id == o.id }) plan.replacedBodies += o }
            plan.bodies += WBody(c.id, b.measuredAt, b.weightKg, "$day ${w}kg", c.inPlace)
            count("bodyMeasurements", if (c.inPlace || replaces.isNotEmpty()) "REPLACE" else "NEW")
        }
    }
}
