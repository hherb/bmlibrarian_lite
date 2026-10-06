/*
 * BMLibrarian Lite - Biomedical Literature Research Tool
 * Copyright (C) 2024-2026 Dr Horst Herb
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
package com.bmlibrarian.factchecker.data.remote.fulltext

import com.bmlibrarian.factchecker.domain.model.OpenAccessShortfall
import com.bmlibrarian.factchecker.domain.model.OpenAccessSource
import com.bmlibrarian.factchecker.util.Constants
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** CORE's pure rules against the shared contract (#480, stage C). */
class CoreContractTest {
    private fun contractFile(): File {
        var candidate: File? = File("").absoluteFile
        while (candidate != null) {
            val file = File(candidate, "doc/cross_platform/fulltext_parity/core_fulltext.json")
            if (file.isFile) return file
            candidate = candidate.parentFile
        }
        error("core_fulltext.json not found")
    }

    private val contract: JsonObject by lazy {
        Json.parseToJsonElement(contractFile().readText()).jsonObject
    }

    /** A contract table's rows, at least [minimum] of them: an emptied table would pass every loop vacuously. */
    private fun table(name: String, minimum: Int): List<JsonObject> {
        val rows = contract.getValue(name).jsonArray.map { it.jsonObject }
        assertTrue("$name has ${rows.size} rows; an emptied table would pass vacuously", rows.size >= minimum)
        return rows
    }

    private fun JsonObject.string(key: String): String = this[key]!!.jsonPrimitive.content

    @Test
    fun `every contract table is read here`() {
        assertEquals(
            setOf(
                "schema_version", "description", "service_name", "source", "source_label",
                "desktop_source_type", "base_url", "min_fulltext_chars",
                "pause_after_consecutive_429", "key_refused_status", "key_refused_reason", "key_refusal_scope",
                "search_url", "full_text", "status", "bodies"
            ),
            contract.keys
        )
    }

    @Test
    fun `the names are the contract's`() {
        assertEquals(Constants.CORE_SERVICE_NAME, contract.string("service_name"))
        assertEquals(Constants.FULLTEXT_SOURCE_CORE, contract.string("source"))
        assertEquals(OpenAccessSource.CORE.persistedValue, contract.string("source"))
        assertEquals(Constants.FULLTEXT_SOURCE_CORE_LABEL, contract.string("source_label"))
        assertEquals(Constants.CORE_BASE_URL, contract.string("base_url"))
        assertEquals(Constants.CORE_MIN_FULLTEXT_CHARS, contract["min_fulltext_chars"]!!.jsonPrimitive.int)
        assertEquals(
            Constants.CORE_PAUSE_AFTER_CONSECUTIVE_429,
            contract["pause_after_consecutive_429"]!!.jsonPrimitive.int
        )
        assertEquals(Constants.CORE_KEY_REFUSED_STATUS, contract["key_refused_status"]!!.jsonPrimitive.int)
        assertEquals(Constants.CORE_KEY_REFUSED_REASON, contract.string("key_refused_reason"))
        // The refusal is scoped to the key refused (#498): a corrected key is asked again
        assertEquals("the refused key", contract.string("key_refusal_scope"))
    }

    @Test
    fun `each search_url row`() {
        for (row in table("search_url", MIN_SEARCH_URL_ROWS)) {
            val base = row["base_url"]?.jsonPrimitive?.contentOrNull ?: Constants.CORE_BASE_URL
            assertEquals(row.string("name"), row.string("url"), Core.searchUrl(row.string("doi"), base))
        }
    }

    @Test
    fun `each full_text row`() {
        for (row in table("full_text", MIN_FULL_TEXT_ROWS)) {
            val name = row.string("name")
            val min = row["min_chars"]!!.jsonPrimitive.int
            val answer = row["answer"]!!
            if (row.string("outcome") == "malformed") {
                assertThrows(name, IllegalArgumentException::class.java) {
                    Core.fullText(answer, row.string("doi"), min)
                }
            } else {
                assertEquals(
                    name,
                    row["text"]?.jsonPrimitive?.contentOrNull,
                    Core.fullText(answer, row.string("doi"), min)
                )
            }
        }
    }

    @Test
    fun `each unreadable body throws`() {
        for (row in table("bodies", MIN_BODY_ROWS)) {
            assertThrows(row.string("name"), IllegalArgumentException::class.java) {
                Core.fullText(row.string("body"), "10.1/x")
            }
        }
    }

    /** The status table is walked by CoreServiceTest; its floor is checked here too. */
    @Test
    fun `the status table is not empty`() {
        table("status", MIN_STATUS_ROWS)
    }

    @Test
    fun `CORE is last in chain order`() {
        assertEquals(OpenAccessSource.CORE, OpenAccessShortfall.CHAIN_ORDER.last())
    }

    private companion object {
        /** The contract's row counts when these tests were written (#480). */
        const val MIN_SEARCH_URL_ROWS = 7
        const val MIN_FULL_TEXT_ROWS = 24
        const val MIN_BODY_ROWS = 4
        const val MIN_STATUS_ROWS = 9
    }
}
