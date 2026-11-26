package com.fitlog.account

import com.fitlog.core.Times
import com.fitlog.core.UserSettingsTable
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
    )
}

internal fun Transaction.patchSettings(userId: UUID, s: Settings) {
    ensureSettings(userId)
    UserSettingsTable.update({ UserSettingsTable.userId eq userId }) {
        s.weightUnit?.let { v -> it[weightUnit] = v }
        s.defaultRestSec?.let { v -> it[defaultRestSec] = v }
        s.keepScreenOn?.let { v -> it[keepScreenOn] = v }
        s.rpeInputEnabled?.let { v -> it[rpeInputEnabled] = v }
        s.heightCm?.let { v -> it[heightCm] = BigDecimal.valueOf(v).setScale(1, RoundingMode.HALF_UP) }
        s.sex?.let { v -> it[sex] = v }
        s.birthYear?.let { v -> it[birthYear] = v }
        it[updatedAt] = Times.now()
    }
}
