package com.fitlog.core

import org.jetbrains.exposed.sql.Sequence
import org.jetbrains.exposed.sql.Table
import org.jetbrains.exposed.sql.javatime.date
import org.jetbrains.exposed.sql.javatime.timestamp
import org.jetbrains.exposed.sql.nextLongVal

/*
 * V1__init.sql 과 1:1로 맞춘 Exposed 테이블 정의 (공용, 트랙 리드 소유).
 * 스키마는 Flyway가 만들고, 여기서는 SchemaUtils 를 쓰지 않는다.
 * 동기화 대상 테이블은 INSERT/UPDATE 때마다 serverSeq 에 ChangeSeq.next 를 넣는다.
 */

object ChangeSeq {
    private val seq = Sequence("change_seq")
    val next get() = seq.nextLongVal()
}

object AppUsers : Table("app_user") {
    val id = uuid("id")
    val googleSub = text("google_sub")
    val email = text("email")
    val displayName = text("display_name").nullable()
    val role = text("role")
    val createdAt = timestamp("created_at")
    val updatedAt = timestamp("updated_at")
    override val primaryKey = PrimaryKey(id)
}

object RefreshTokens : Table("refresh_token") {
    val id = uuid("id")
    val userId = uuid("user_id")
    val tokenHash = text("token_hash")
    val expiresAt = timestamp("expires_at")
    val revokedAt = timestamp("revoked_at").nullable()
    val createdAt = timestamp("created_at")
    override val primaryKey = PrimaryKey(id)
}

object Consents : Table("consent") {
    val id = uuid("id")
    val userId = uuid("user_id")
    val kind = text("kind")
    val version = text("version")
    val granted = bool("granted")
    val createdAt = timestamp("created_at")
    override val primaryKey = PrimaryKey(id)
}

object UserSettingsTable : Table("user_settings") {
    val userId = uuid("user_id")
    val weightUnit = text("weight_unit")
    val defaultRestSec = integer("default_rest_sec")
    val keepScreenOn = bool("keep_screen_on")
    val rpeInputEnabled = bool("rpe_input_enabled")
    val heightCm = decimal("height_cm", 5, 1).nullable()
    val sex = text("sex").nullable()
    val birthYear = integer("birth_year").nullable()
    val e1rmFormula = text("e1rm_formula").default("EPLEY")
    val updatedAt = timestamp("updated_at")
    override val primaryKey = PrimaryKey(userId)
}

object Exercises : Table("exercise") {
    val id = uuid("id")
    /** null = 기본 제공 종목 */
    val ownerId = uuid("owner_id").nullable()
    val nameKo = text("name_ko")
    val nameEn = text("name_en").nullable()
    val type = text("type")
    val primaryMuscle = text("primary_muscle")
    val secondaryMuscles = array<String>("secondary_muscles")
    val createdAt = timestamp("created_at")
    val updatedAt = timestamp("updated_at")
    val deletedAt = timestamp("deleted_at").nullable()
    val serverSeq = long("server_seq")
    override val primaryKey = PrimaryKey(id)
}

object WorkoutSessions : Table("workout_session") {
    val id = uuid("id")
    val userId = uuid("user_id")
    val startedAt = timestamp("started_at")
    val endedAt = timestamp("ended_at").nullable()
    val tz = text("tz")
    val note = text("note").nullable()
    val sourceCol = text("source")
    val createdAt = timestamp("created_at")
    val updatedAt = timestamp("updated_at")
    val deletedAt = timestamp("deleted_at").nullable()
    val serverSeq = long("server_seq")
    val programInstanceId = uuid("program_instance_id").nullable()
    val planSeq = integer("plan_seq").nullable()
    val planDayKey = text("plan_day_key").nullable()
    override val primaryKey = PrimaryKey(id)
}

object SessionExercises : Table("session_exercise") {
    val id = uuid("id")
    val sessionId = uuid("session_id")
    val exerciseId = uuid("exercise_id")
    val position = integer("position")
    val note = text("note").nullable()
    val updatedAt = timestamp("updated_at")
    val deletedAt = timestamp("deleted_at").nullable()
    val serverSeq = long("server_seq")
    val liftKey = text("lift_key").nullable()
    val accessory = bool("accessory").default(false)
    override val primaryKey = PrimaryKey(id)
}

object WorkoutSets : Table("workout_set") {
    val id = uuid("id")
    val sessionExerciseId = uuid("session_exercise_id")
    val position = integer("position")
    val isWarmup = bool("is_warmup")
    val weightKg = decimal("weight_kg", 6, 2).nullable()
    val addedWeightKg = decimal("added_weight_kg", 6, 2).nullable()
    val reps = integer("reps").nullable()
    val durationSec = integer("duration_sec").nullable()
    val distanceM = decimal("distance_m", 8, 1).nullable()
    val bandLevel = text("band_level").nullable()
    val rpe = decimal("rpe", 3, 1).nullable()
    val rir = integer("rir").nullable()
    val restSec = integer("rest_sec").nullable()
    val note = text("note").nullable()
    val completedAt = timestamp("completed_at").nullable()
    val updatedAt = timestamp("updated_at")
    val deletedAt = timestamp("deleted_at").nullable()
    val serverSeq = long("server_seq")
    val plannedSetKey = text("planned_set_key").nullable()
    val targetReps = integer("target_reps").nullable()
    val targetWeightKg = decimal("target_weight_kg", 6, 2).nullable()
    val isAmrap = bool("is_amrap").default(false)
    override val primaryKey = PrimaryKey(id)
}

object BodyMeasurements : Table("body_measurement") {
    val id = uuid("id")
    val userId = uuid("user_id")
    val measuredAt = timestamp("measured_at")
    val weightKg = decimal("weight_kg", 5, 2)
    val sourceCol = text("source")
    val updatedAt = timestamp("updated_at")
    val deletedAt = timestamp("deleted_at").nullable()
    val serverSeq = long("server_seq")
    override val primaryKey = PrimaryKey(id)
}

// ---------------------------------------------------------------- v0.2 (V3__programs.sql)
// 기존 테이블에 추가된 컬럼(e1rm_formula, program_instance_id, lift_key, planned_set_key 등)은 위 객체에 추가했다.

object Programs : Table("program") {
    val id = uuid("id")
    val ownerId = uuid("owner_id").nullable()
    val templateKey = text("template_key").nullable()
    val name = text("name")
    /** program.schema.json (이름 참조는 id 로 풀린 상태). jsonb */
    val definition = jsonbText("definition")
    val sourceCol = text("source")
    val createdAt = timestamp("created_at")
    val updatedAt = timestamp("updated_at")
    val deletedAt = timestamp("deleted_at").nullable()
    override val primaryKey = PrimaryKey(id)
}

object ProgramInstances : Table("program_instance") {
    val id = uuid("id")
    val userId = uuid("user_id")
    val programId = uuid("program_id")
    val definition = jsonbText("definition")
    val status = text("status")
    val skipPolicy = text("skip_policy")
    val startDate = date("start_date")
    val tz = text("tz")
    val initialState = jsonbText("initial_state")
    val state = jsonbText("state")
    val stateSeq = integer("state_seq")
    val createdAt = timestamp("created_at")
    val updatedAt = timestamp("updated_at")
    val deletedAt = timestamp("deleted_at").nullable()
    override val primaryKey = PrimaryKey(id)
}

object ProgramSkips : Table("program_skip") {
    val id = uuid("id")
    val instanceId = uuid("instance_id")
    val planSeq = integer("plan_seq")
    val dayIndex = integer("day_index")
    val skippedOn = date("skipped_on")
    val auto = bool("auto")
    val createdAt = timestamp("created_at")
    override val primaryKey = PrimaryKey(id)
}

object ProgramAccessories : Table("program_accessory") {
    val id = uuid("id")
    val instanceId = uuid("instance_id")
    val dayKey = text("day_key")
    val exerciseId = uuid("exercise_id")
    val position = integer("position")
    val sets = integer("sets")
    val reps = integer("reps")
    val weightKg = decimal("weight_kg", 6, 2).nullable()
    val updatedAt = timestamp("updated_at")
    val deletedAt = timestamp("deleted_at").nullable()
    override val primaryKey = PrimaryKey(id)
}

object ProgramAdjustments : Table("program_adjustment") {
    val id = uuid("id")
    val instanceId = uuid("instance_id")
    val afterSeq = integer("after_seq")
    val tm = jsonbText("tm")
    val working = jsonbText("working")
    val createdAt = timestamp("created_at")
    override val primaryKey = PrimaryKey(id)
}

object OneRmMeasurements : Table("one_rm_measurement") {
    val id = uuid("id")
    val userId = uuid("user_id")
    val exerciseId = uuid("exercise_id")
    val weightKg = decimal("weight_kg", 6, 2)
    val measuredAt = timestamp("measured_at")
    val note = text("note").nullable()
    val createdAt = timestamp("created_at")
    val deletedAt = timestamp("deleted_at").nullable()
    override val primaryKey = PrimaryKey(id)
}
