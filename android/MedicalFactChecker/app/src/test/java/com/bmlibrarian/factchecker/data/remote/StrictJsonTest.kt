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

import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Test

/**
 * Bodies a lenient read accepts and serde_json refuses (#781, #784), as the
 * desktop's `test_strict_service_json.py` lists them, plus the grammar kotlinx
 * reads even when not lenient.
 */
internal val REFUSED_JSON_BODIES: Map<String, String> = mapOf(
    "a BOM" to "\uFEFF{\"a\": 1}",
    "NaN" to """{"a": NaN}""",
    "Infinity" to """{"a": Infinity}""",
    "-Infinity" to """{"a": -Infinity}""",
    "a number past the largest float" to """{"a": 1e999}""",
    "a lone surrogate" to """{"a": "\ud800"}""",
    "nesting past 127 levels" to "[".repeat(200) + "]".repeat(200),
    "an unquoted key" to """{a: 1}""",
    "a bare word" to """{"a": abc}""",
    "a single-quoted string" to """{"a": 'abc'}""",
    "a leading zero" to """{"a": 01}""",
    "a plus sign" to """{"a": +1}""",
    "a trailing comma" to """{"a": 1,}""",
)

/**
 * Values each of which refuses an answer otherwise read (#784): a site's test puts
 * one where a field's value stands, so the refusal is the strict parse's, never the
 * answer's shape. The control puts `1` there.
 */
internal val REFUSED_JSON_VALUES: List<String> = listOf(
    "NaN", "Infinity", "1e999", "abc", "'abc'", "01", "\"\\ud800\"", "[".repeat(200) + "]".repeat(200),
)

class StrictJsonTest {

    private fun refused(name: String, body: String) {
        try {
            strictJsonElement(body)
            fail("$name was read")
        } catch (_: SerializationException) {
        }
    }

    @Test
    fun `every body serde_json refuses is refused`() {
        for ((name, body) in REFUSED_JSON_BODIES) refused(name, body)
    }

    @Test
    fun `a body that is not UTF-8 is refused`() {
        try {
            strictJsonElement(byteArrayOf(0x7B, 0xFF.toByte(), 0x7D))
            fail("read")
        } catch (_: SerializationException) {
        }
    }

    @Test
    fun `nesting far past the limit is refused without overflowing the stack`() {
        refused("deep", "[".repeat(100_000) + "]".repeat(100_000))
    }

    @Test
    fun `127 levels parse and 128 do not`() {
        assertEquals(1, strictJsonElement("[".repeat(SERDE_MAX_DEPTH) + "]".repeat(SERDE_MAX_DEPTH)).jsonArray.size)
        refused("128 levels", "[".repeat(SERDE_MAX_DEPTH + 1) + "]".repeat(SERDE_MAX_DEPTH + 1))
        refused("128 levels of objects", "{\"a\":".repeat(SERDE_MAX_DEPTH + 1) + "1" + "}".repeat(SERDE_MAX_DEPTH + 1))
    }

    @Test
    fun `every JSON value is read`() {
        val obj = strictJsonElement(
            """{"s": "😀 NaN", "t": true, "f": false, "n": null, "i": -0, "d": 1.5e-3, "e": 2E+10, "a": []}"""
                .toByteArray()
        ).jsonObject
        assertEquals("😀 NaN", obj.getValue("s").jsonPrimitive.content)
        assertEquals(listOf("true", "false", "null", "-0", "1.5e-3", "2E+10"),
            listOf("t", "f", "n", "i", "d", "e").map { obj.getValue(it).jsonPrimitive.content })
    }
}
