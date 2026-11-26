package com.fitlog.core

import java.security.SecureRandom
import java.util.UUID

/** UUIDv7 (RFC 9562). 서버가 ID를 만들 때 쓴다 */
object Ids {
    private val random = SecureRandom()

    fun newId(): UUID {
        val ts = System.currentTimeMillis()
        val rand = ByteArray(10).also { random.nextBytes(it) }
        val msb = (ts shl 16) or (0x7000L) or ((rand[0].toLong() and 0x0F) shl 8) or (rand[1].toLong() and 0xFF)
        var lsb = 0L
        for (i in 2 until 10) lsb = (lsb shl 8) or (rand[i].toLong() and 0xFF)
        lsb = (lsb and 0x3FFFFFFFFFFFFFFFL) or Long.MIN_VALUE // variant 10
        return UUID(msb, lsb)
    }

    /** 요청 값 파싱. 잘못된 형식이면 400 */
    fun parse(value: String?, field: String = "id"): UUID =
        try {
            UUID.fromString(value ?: validation("$field is required", field))
        } catch (e: IllegalArgumentException) {
            validation("$field must be a UUID", field)
        }
}
