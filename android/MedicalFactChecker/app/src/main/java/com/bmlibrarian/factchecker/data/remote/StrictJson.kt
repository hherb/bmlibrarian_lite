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
import kotlinx.serialization.json.JsonElement
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
 * the report as text. This converter refuses an answer that is not UTF-8 or starts
 * with a BOM (as the desktop does), or that holds `NaN`, `Infinity`, a number past
 * binary64 or a lone surrogate ([ResponseParser.holdsRefusedValue]). It refuses as a
 * [SerializationException], which every caller already reads as a malformed answer.
 * The parse itself stays the app's lenient one: unquoted words and nesting past
 * serde_json's 127 levels are still read.
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
            body.use { json.decodeFromJsonElement(serializer, strictJsonElement(json, it.bytes())) }
        }
    }
}

/**
 * Parse an answer's bytes, refusing what bmlib refuses (#781).
 *
 * @param json The `Json` that parses the text
 * @param bytes The answer as served
 * @return The parsed answer
 * @throws SerializationException when the bytes are not UTF-8, start with a BOM, do
 *   not parse, or hold a value JSON does not define; the message never quotes the body
 */
internal fun strictJsonElement(json: Json, bytes: ByteArray): JsonElement {
    val text = try {
        Charsets.UTF_8.newDecoder().decode(ByteBuffer.wrap(bytes)).toString()
    } catch (_: CharacterCodingException) {
        throw SerializationException("the answer is not UTF-8")
    }
    if (text.startsWith(BYTE_ORDER_MARK)) throw SerializationException("the answer starts with a BOM")
    val element = try {
        json.parseToJsonElement(text)
    } catch (_: SerializationException) {
        throw SerializationException("the answer is not JSON")
    }
    if (ResponseParser.holdsRefusedValue(element)) {
        throw SerializationException("the answer holds a value JSON does not define")
    }
    return element
}

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
