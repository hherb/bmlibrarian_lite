package com.bmlibrarian.factchecker.domain.transparency

import java.time.Instant
import java.time.OffsetDateTime
import java.time.format.DateTimeFormatter
import java.time.format.DateTimeParseException
import java.time.temporal.ChronoUnit
import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerializationException
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder

/**
 * Serializes an [Instant] the way Swift's `JSONEncoder.DateEncodingStrategy.iso8601` does.
 *
 * The iOS app stores a `TransparencyResult` with the `.iso8601` strategy, which
 * writes whole seconds in UTC ("2024-03-15T10:20:30Z") and whose decoder
 * **rejects** fractional seconds. So this writes whole seconds only — an
 * [Instant] that carried a fraction would otherwise produce JSON the iOS app
 * cannot read. Reading accepts fractional seconds and UTC offsets as well.
 */
object Iso8601InstantSerializer : KSerializer<Instant> {

    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("TransparencyIso8601Instant", PrimitiveKind.STRING)

    override fun serialize(encoder: Encoder, value: Instant) {
        encoder.encodeString(format(value))
    }

    override fun deserialize(decoder: Decoder): Instant = parse(decoder.decodeString())

    /**
     * Format an instant as Swift's `.iso8601` strategy would.
     *
     * @param value The instant.
     * @return Whole-second UTC ISO-8601, e.g. "2024-03-15T10:20:30Z".
     */
    fun format(value: Instant): String =
        DateTimeFormatter.ISO_INSTANT.format(value.truncatedTo(ChronoUnit.SECONDS))

    /**
     * Parse an ISO-8601 instant, with or without fractional seconds or a UTC offset.
     *
     * @param text The date-time string.
     * @return The instant.
     * @throws SerializationException if [text] is not an ISO-8601 date-time.
     */
    fun parse(text: String): Instant =
        try {
            Instant.parse(text)
        } catch (e: DateTimeParseException) {
            try {
                OffsetDateTime.parse(text).toInstant()
            } catch (inner: DateTimeParseException) {
                throw SerializationException("Not an ISO-8601 date-time: '$text'")
            }
        }
}
