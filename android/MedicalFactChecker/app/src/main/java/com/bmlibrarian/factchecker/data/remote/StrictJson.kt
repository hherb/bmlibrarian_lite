/*
 * BMLibrarian Lite - Biomedical Literature Research Tool
 * Copyright (C) 2024-2025 Dr Horst Herb
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU Affero General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

package com.bmlibrarian.factchecker.data.remote

import com.bmlibrarian.factchecker.util.ResponseParser
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.serializer
import okhttp3.OkHttpClient
import okhttp3.ResponseBody
import retrofit2.Converter
import retrofit2.Retrofit
import retrofit2.converter.scalars.ScalarsConverterFactory
import java.lang.reflect.Type
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException

/**
 * Retrofit's JSON converter for a service's answer, refusing the values bmlib refuses (#781).
 *
 * The app's lenient `Json` keeps a lone surrogate escape in a string, and OkHttp's
 * `string()` turns bytes that are not UTF-8 into U+FFFD, so either reached Room and
 * the report as text. This converter reads the answer through [strictJsonElement]
 * and refuses as a [SerializationException], which every caller already reads as a
 * malformed answer. Only what passed is decoded, by the app's `Json`.
 *
 * It declines `String`, so a raw answer (full-text XML) is never read as JSON,
 * whatever the order of the converters.
 *
 * @param json The app's `Json`, which decodes what is read
 */
class StrictJsonConverterFactory(private val json: Json) : Converter.Factory() {
    override fun responseBodyConverter(
        type: Type,
        annotations: Array<out Annotation>,
        retrofit: Retrofit
    ): Converter<ResponseBody, *>? {
        if (type == String::class.java) return null
        val serializer = json.serializersModule.serializer(type)
        return Converter<ResponseBody, Any?> { body ->
            body.use { json.decodeFromJsonElement(serializer, strictJsonElement(it.bytes())) }
        }
    }
}

/**
 * Parse an answer's bytes, refusing what bmlib refuses (#781, #784).
 *
 * @param bytes The answer as served
 * @return The parsed answer
 * @throws SerializationException when the bytes are not UTF-8, or the text is refused
 *   by [strictJsonElement]; the message never quotes the body
 */
internal fun strictJsonElement(bytes: ByteArray): JsonElement {
    val text = try {
        Charsets.UTF_8.newDecoder().decode(ByteBuffer.wrap(bytes)).toString()
    } catch (_: CharacterCodingException) {
        throw SerializationException("the answer is not UTF-8")
    }
    return strictJsonElement(text)
}

/**
 * Parse an answer's text as bmlib's `strict_json_loads` and serde_json do (#781, #784).
 *
 * Refused: a leading BOM; what strict JSON does not parse (an unquoted key, a
 * trailing comma, a comment); a bare word (`abc`, `'abc'`), which kotlinx reads as a
 * literal even when not lenient; `NaN`, `Infinity`, a number past binary64 and a lone
 * surrogate ([ResponseParser.holdsRefusedValue]); arrays and objects nested deeper
 * than [SERDE_MAX_DEPTH].
 *
 * @param text The answer, already decoded as strict UTF-8
 * @return The parsed answer
 * @throws SerializationException for any of those; the message never quotes the body
 */
internal fun strictJsonElement(text: String): JsonElement {
    if (text.startsWith(BYTE_ORDER_MARK)) throw SerializationException("the answer starts with a BOM")
    // Before the parse: kotlinx recurses per level and overflows the stack on deep nesting
    if (nestsTooDeep(text)) throw SerializationException("the answer nests deeper than $SERDE_MAX_DEPTH levels")
    val element = try {
        Json.parseToJsonElement(text)
    } catch (_: SerializationException) {
        throw SerializationException("the answer is not JSON")
    }
    if (breaksStrictGrammar(element)) {
        throw SerializationException("the answer is not JSON as serde_json reads it")
    }
    if (ResponseParser.holdsRefusedValue(element)) {
        throw SerializationException("the answer holds a value JSON does not define")
    }
    return element
}

/** serde_json's nesting limit: 127 levels of arrays or objects parse, 128 do not (bmlib's `SERDE_MAX_DEPTH`). */
internal const val SERDE_MAX_DEPTH = 127

private val JSON_NUMBER = Regex("""-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?""")

/** Whether arrays and objects open more than [SERDE_MAX_DEPTH] deep, outside strings; text that does not parse is the parser's. */
private fun nestsTooDeep(text: String): Boolean {
    var depth = 0
    var inString = false
    var escaped = false
    for (c in text) {
        when {
            escaped -> escaped = false
            inString -> if (c == '\\') escaped = true else if (c == '"') inString = false
            c == '"' -> inString = true
            c == '[' || c == '{' -> if (++depth > SERDE_MAX_DEPTH) return true
            c == ']' || c == '}' -> depth--
        }
    }
    return false
}

/** Whether a literal outside every string is not `true`, `false`, `null` or a JSON number. */
private fun breaksStrictGrammar(element: JsonElement): Boolean = when (element) {
    is JsonObject -> element.values.any(::breaksStrictGrammar)
    is JsonArray -> element.any(::breaksStrictGrammar)
    is JsonPrimitive -> !element.isString && element.content !in JSON_WORDS && !JSON_NUMBER.matches(element.content)
}

private val JSON_WORDS = setOf("true", "false", "null")

private const val BYTE_ORDER_MARK = '\uFEFF'

/**
 * A Retrofit for a service whose JSON is read strictly: Europe PMC and Unpaywall (#781).
 *
 * Built on its own `Retrofit.Builder`, as `createPubMedApi` is: the shared builder is
 * a mutable singleton, so a converter added to it would reach the LLM APIs built from it.
 *
 * @param client The app's shared client
 * @param json The app's `Json`
 * @param baseUrl The service's base URL, ending in a slash
 * @return The Retrofit, scalars first for raw string answers (full-text XML)
 */
fun strictJsonRetrofit(client: OkHttpClient, json: Json, baseUrl: String): Retrofit =
    Retrofit.Builder()
        .client(client)
        .baseUrl(baseUrl)
        .addConverterFactory(ScalarsConverterFactory.create())
        .addConverterFactory(StrictJsonConverterFactory(json))
        .build()
