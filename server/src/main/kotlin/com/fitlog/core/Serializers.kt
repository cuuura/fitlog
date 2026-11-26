package com.fitlog.core

import kotlinx.serialization.KSerializer
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import java.math.BigDecimal
import java.math.RoundingMode
import java.time.Instant
import java.time.format.DateTimeParseException
import java.util.UUID

/** ISO-8601 UTC. 응답은 항상 Z 형식 (밀리초까지) */
object InstantSerializer : KSerializer<Instant> {
    override val descriptor = PrimitiveSerialDescriptor("Instant", PrimitiveKind.STRING)
    override fun serialize(encoder: Encoder, value: Instant) = encoder.encodeString(Times.format(value))
    override fun deserialize(decoder: Decoder): Instant = Times.parse(decoder.decodeString())
}

object UUIDSerializer : KSerializer<UUID> {
    override val descriptor = PrimitiveSerialDescriptor("UUID", PrimitiveKind.STRING)
    override fun serialize(encoder: Encoder, value: UUID) = encoder.encodeString(value.toString())
    override fun deserialize(decoder: Decoder): UUID = Ids.parse(decoder.decodeString())
}

object Times {
    /** DB timestamptz는 마이크로초까지라 밀리초로 잘라 비교·전송한다 */
    fun now(): Instant = Instant.ofEpochMilli(System.currentTimeMillis())
    fun format(i: Instant): String = Instant.ofEpochMilli(i.toEpochMilli()).toString()
    fun parse(s: String, field: String = "time"): Instant = try {
        Instant.parse(s)
    } catch (e: DateTimeParseException) {
        validation("$field must be ISO-8601 UTC", field)
    }
}

/** 무게 kg: 소수점 둘째 자리 */
object Kg {
    fun of(d: Double): BigDecimal = BigDecimal.valueOf(d).setScale(2, RoundingMode.HALF_UP)
}
