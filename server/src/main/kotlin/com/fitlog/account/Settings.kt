package com.fitlog.account

import com.fitlog.core.Times
import com.fitlog.core.UserSettingsTable
import com.fitlog.core.validation
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.Serializable
import org.jetbrains.exposed.sql.Transaction
import org.jetbrains.exposed.sql.insertIgnore
import org.jetbrains.exposed.sql.selectAll
import org.jetbrains.exposed.sql.update
import java.math.BigDecimal
import java.math.RoundingMode
import java.util.UUID

@Serializable
data class Settings(
    val weightUnit: String? = null,
    val defaultRestSec: Int? = null,
    val keepScreenOn: Boolean? = null,
    val rpeInputEnabled: Boolean? = null,
    val heightCm: Double? = null,
    val sex: String? = null,
    val birthYear: Int? = null,
    val e1rmFormula: String? = null,
)

/** 설정 행이 없으면 기본값으로 만든다 (auth 패키지도 가입 시 사용) */
fun Transaction.ensureSettings(userId: UUID) {
    UserSettingsTable.insertIgnore {
        it[UserSettingsTable.userId] = userId
        it[weightUnit] = "KG"
        it[defaultRestSec] = 120
        it[keepScreenOn] = true
        it[rpeInputEnabled] = true
        it[updatedAt] = Times.now()
    }
}

internal fun Transaction.loadSettings(userId: UUID): Settings {
    ensureSettings(userId)
    val r = UserSettingsTable.selectAll().where { UserSettingsTable.userId eq userId }.single()
    return Settings(
        weightUnit = r[UserSettingsTable.weightUnit],
        defaultRestSec = r[UserSettingsTable.defaultRestSec],
        keepScreenOn = r[UserSettingsTable.keepScreenOn],
        rpeInputEnabled = r[UserSettingsTable.rpeInputEnabled],
        heightCm = r[UserSettingsTable.heightCm]?.toDouble(),
        sex = r[UserSettingsTable.sex],
        birthYear = r[UserSettingsTable.birthYear],
        e1rmFormula = r[UserSettingsTable.e1rmFormula],
    )
}

/** JSON merge-patch 의 필드 하나: present=false 면 키가 없음(유지), value=null 이면 비움 */
internal class Patch<T>(val present: Boolean, val value: T?) {
    companion object {
        fun <T> absent() = Patch<T>(false, null)
    }
}

/** PUT /me/settings 본문 해석 결과. 비울 수 있는 필드는 heightCm·sex·birthYear 뿐 */
internal class SettingsPatch(
    val weightUnit: String?,
    val defaultRestSec: Int?,
    val keepScreenOn: Boolean?,
    val rpeInputEnabled: Boolean?,
    val e1rmFormula: String?,
    val heightCm: Patch<Double>,
    val sex: Patch<String>,
    val birthYear: Patch<Int>,
) {
    /** 값 범위 검증용(비움은 제외) */
    fun asSettings() = Settings(weightUnit, defaultRestSec, keepScreenOn, rpeInputEnabled, heightCm.value, sex.value, birthYear.value, e1rmFormula)
}

private fun JsonElement.asString(field: String): String =
    (this as? JsonPrimitive)?.takeIf { it.isString }?.content ?: validation("$field must be a string", field)

private fun JsonElement.asInt(field: String): Int =
    (this as? JsonPrimitive)?.takeIf { !it.isString }?.intOrNull ?: validation("$field must be an integer", field)

private fun JsonElement.asDouble(field: String): Double =
    (this as? JsonPrimitive)?.takeIf { !it.isString }?.doubleOrNull ?: validation("$field must be a number", field)

private fun JsonElement.asBool(field: String): Boolean =
    (this as? JsonPrimitive)?.takeIf { !it.isString }?.booleanOrNull ?: validation("$field must be a boolean", field)

internal fun parseSettingsPatch(o: JsonObject): SettingsPatch {
    fun <T> required(field: String, conv: (JsonElement, String) -> T): T? {
        val e = o[field] ?: return null
        if (e is JsonNull) validation("$field cannot be null", field)
        return conv(e, field)
    }
    fun <T> nullable(field: String, conv: (JsonElement, String) -> T): Patch<T> {
        val e = o[field] ?: return Patch.absent()
        return if (e is JsonNull) Patch(true, null) else Patch(true, conv(e, field))
    }
    return SettingsPatch(
        weightUnit = required("weightUnit") { e, f -> e.asString(f) },
        defaultRestSec = required("defaultRestSec") { e, f -> e.asInt(f) },
        keepScreenOn = required("keepScreenOn") { e, f -> e.asBool(f) },
        rpeInputEnabled = required("rpeInputEnabled") { e, f -> e.asBool(f) },
        e1rmFormula = required("e1rmFormula") { e, f -> e.asString(f) },
        heightCm = nullable("heightCm") { e, f -> e.asDouble(f) },
        sex = nullable("sex") { e, f -> e.asString(f) },
        birthYear = nullable("birthYear") { e, f -> e.asInt(f) },
    )
}

internal fun Transaction.patchSettings(userId: UUID, s: SettingsPatch) {
    ensureSettings(userId)
    UserSettingsTable.update({ UserSettingsTable.userId eq userId }) {
        s.weightUnit?.let { v -> it[weightUnit] = v }
        s.defaultRestSec?.let { v -> it[defaultRestSec] = v }
        s.keepScreenOn?.let { v -> it[keepScreenOn] = v }
        s.rpeInputEnabled?.let { v -> it[rpeInputEnabled] = v }
        s.e1rmFormula?.let { v -> it[e1rmFormula] = v }
        if (s.heightCm.present) it[heightCm] = s.heightCm.value?.let { v -> BigDecimal.valueOf(v).setScale(1, RoundingMode.HALF_UP) }
        if (s.sex.present) it[sex] = s.sex.value
        if (s.birthYear.present) it[birthYear] = s.birthYear.value
        it[updatedAt] = Times.now()
    }
}
