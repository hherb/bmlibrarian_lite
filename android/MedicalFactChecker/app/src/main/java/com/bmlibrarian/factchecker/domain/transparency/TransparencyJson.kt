package com.bmlibrarian.factchecker.domain.transparency

import kotlinx.serialization.json.Json

/**
 * Reads and writes a stored [TransparencyResult] as JSON.
 *
 * The format is the one the iOS/macOS app stores (Swift `Codable`, `.iso8601`
 * dates). Unknown keys are ignored, so JSON written by a newer build — or by
 * Swift carrying a field Android does not model — still loads.
 */
object TransparencyJson {

    /** The configured JSON format; also usable directly with `TransparencyResult.serializer()`. */
    val format: Json = Json { ignoreUnknownKeys = true }

    /**
     * Encode a result as stored JSON.
     *
     * @param result The result to store.
     * @return The JSON text.
     */
    fun encode(result: TransparencyResult): String =
        format.encodeToString(TransparencyResult.serializer(), result)

    /**
     * Decode stored JSON.
     *
     * @param json JSON written by [encode] or by the Swift app.
     * @return The decoded result.
     * @throws kotlinx.serialization.SerializationException if the JSON is malformed or lacks a
     *   field every stored result carries (the same objects Swift would refuse).
     * @throws IllegalArgumentException if the JSON is not of the expected shape.
     */
    fun decode(json: String): TransparencyResult =
        format.decodeFromString(TransparencyResult.serializer(), json)
}
