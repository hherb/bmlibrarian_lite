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

import com.bmlibrarian.factchecker.domain.model.OpenAccessSource
import com.bmlibrarian.factchecker.util.Constants
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** OpenAlex's helpers against the shared contract (#480). */
class OpenAlexContractTest {
    private fun contractFile(): File {
        var candidate: File? = File("").absoluteFile
        while (candidate != null) {
            val file = File(candidate, "doc/cross_platform/fulltext_parity/openalex_locations.json")
            if (file.isFile) return file
            candidate = candidate.parentFile
        }
        error("openalex_locations.json not found")
    }

    private val contract: JsonObject by lazy {
        Json.parseToJsonElement(contractFile().readText()).jsonObject
    }

    /**
     * A contract table's rows, at least [minimum] of them: an emptied table
     * would otherwise pass every row loop vacuously.
     */
    private fun table(name: String, minimum: Int): List<JsonObject> {
        val rows = contract.getValue(name).jsonArray.map { it.jsonObject }
        assertTrue("$name has ${rows.size} rows; an emptied table would pass vacuously", rows.size >= minimum)
        return rows
    }

    private fun JsonObject.string(key: String) =
        (this[key] as? JsonPrimitive)?.takeUnless { it is JsonNull }?.contentOrNull

    @Test
    fun `every contract table is read here`() {
        assertEquals(
            setOf(
                "schema_version", "description", "service_name", "pdf_service_name", "source",
                "base_url", "work_url", "pdf_urls", "status"
            ),
            contract.keys
        )
    }

    @Test
    fun `the names are the contract's`() {
        assertEquals(contract.string("service_name"), OpenAccessSource.OPENALEX.serviceName)
        assertEquals(contract.string("pdf_service_name"), OpenAccessSource.OPENALEX_PDF.serviceName)
        assertEquals(contract.string("base_url"), Constants.OPENALEX_BASE_URL)
        assertEquals(contract.string("source"), Constants.FULLTEXT_SOURCE_OPENALEX)
        assertEquals(Constants.OPENALEX_SERVICE_NAME, OpenAccessSource.OPENALEX.serviceName)
    }

    @Test
    fun `each work_url row`() {
        for (row in table("work_url", MIN_WORK_URL_ROWS)) {
            assertEquals(row.string("name"), row.string("url"), OpenAlex.workUrl(row.string("doi")!!, row.string("mailto")))
        }
    }

    @Test
    fun `each pdf_urls row`() {
        for (row in table("pdf_urls", MIN_PDF_URLS_ROWS)) {
            val name = row.string("name")
            val work = row.getValue("work")
            if ((row["malformed"] as? JsonPrimitive)?.booleanOrNull == true) {
                assertThrows(name, IllegalArgumentException::class.java) { OpenAlex.pdfUrls(work) }
                continue
            }
            val tried = row.getValue("tried").jsonArray.map { it.jsonPrimitive.content }
            assertEquals(
                name,
                row.getValue("expected").jsonArray.map { it.jsonPrimitive.content },
                OpenAlex.untried(OpenAlex.pdfUrls(work), tried)
            )
        }
    }

    /** The status table is walked by `OpenAlexServiceTest`; its floor is checked here too. */
    @Test
    fun `the status table is not empty`() {
        table("status", MIN_STATUS_ROWS)
    }

    private companion object {
        /** The contract's row counts when these tests were written (#480). */
        const val MIN_WORK_URL_ROWS = 6
        const val MIN_PDF_URLS_ROWS = 9
        const val MIN_STATUS_ROWS = 8
    }
}
