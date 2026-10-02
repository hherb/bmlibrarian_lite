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

import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

/**
 * Which URL the Unpaywall tier tries, and the PDF a landing page declares (#464),
 * read from the contract all three platforms share:
 * `doc/cross_platform/fulltext_parity/unpaywall_landing_page.json`.
 *
 * A case belongs in that file, not here: a row added there is asserted on every
 * platform, a test added here on one.
 */
class UnpaywallLandingPageContractTest {

    private val contract: JsonObject by lazy {
        Json.parseToJsonElement(contractFile().readText()).jsonObject
    }

    /**
     * The contract, found by walking up from the Gradle working directory. Read
     * from the repository, never copied into test resources: every platform must
     * read the same bytes.
     */
    private fun contractFile(): File {
        val relative = "doc/cross_platform/fulltext_parity/unpaywall_landing_page.json"
        var candidate: File? = File("").absoluteFile
        while (candidate != null) {
            val found = File(candidate, relative)
            if (found.isFile) return found
            candidate = candidate.parentFile
        }
        error("could not locate $relative above ${File("").absolutePath}")
    }

    /** A table of the contract, which must not be empty: an empty table asserts nothing. */
    private fun table(name: String): List<JsonObject> {
        val rows = requireNotNull(contract[name]) { "the contract has no '$name' table" }
            .jsonArray.map { it.jsonObject }
        assertFalse("'$name' is empty", rows.isEmpty())
        return rows
    }

    /** A string field of a row; absent and JSON null are both null. */
    private fun JsonObject.string(key: String): String? =
        (this[key] as? JsonPrimitive)?.takeUnless { it is JsonNull }?.contentOrNull

    /** One Unpaywall location as the contract writes it; absent fields are null. */
    private fun location(json: JsonObject) = UnpaywallOaLocation(
        url = json.string("url"),
        url_for_pdf = json.string("url_for_pdf"),
        url_for_landing_page = json.string("url_for_landing_page"),
        license = json.string("license"),
        version = json.string("version"),
        host_type = json.string("host_type"),
        is_best = null
    )

    /**
     * Unpaywall's answer as the contract writes it, built field by field rather
     * than decoded, so this test pins the rules whatever the decoder does.
     */
    private fun response(json: JsonObject) = UnpaywallResponse(
        doi = json.string("doi"),
        is_oa = (json["is_oa"] as? JsonPrimitive)?.contentOrNull?.toBooleanStrictOrNull(),
        best_oa_location = (json["best_oa_location"] as? JsonObject)?.let(::location),
        oa_locations = (json["oa_locations"] as? JsonArray)?.map { location(it.jsonObject) },
        title = null,
        year = null,
        publisher = null
    )

    @Test
    fun `each unpaywall_choice row`() {
        for (row in table("unpaywall_choice")) {
            val name = row.string("name")
            val choice = UnpaywallLandingPage.chooseUrl(response(row.getValue("response").jsonObject))
            assertEquals(
                "$name",
                UnpaywallChoice(pdfUrl = row.string("pdf_url"), landingPage = row.string("landing_page")),
                choice
            )
        }
    }

    @Test
    fun `each citation_pdf_url row`() {
        for (row in table("citation_pdf_url")) {
            assertEquals(
                "${row.string("name")}",
                row.string("expected"),
                UnpaywallLandingPage.citationPdfUrl(
                    html = row.getValue("html").jsonPrimitive.content,
                    pageUrl = row.getValue("page_url").jsonPrimitive.content
                )
            )
        }
    }

    @Test
    fun `each character_references row`() {
        for (row in table("character_references")) {
            assertEquals(
                "${row.string("name")}",
                row.string("expected"),
                UnpaywallLandingPage.decodeCharacterReferences(row.getValue("raw").jsonPrimitive.content)
            )
        }
    }

    @Test
    fun `each landing_page_status row`() {
        for (row in table("landing_page_status")) {
            val status = row.getValue("status").jsonPrimitive.int
            assertEquals(
                "HTTP $status",
                row.getValue("unsettled").jsonPrimitive.boolean,
                UnpaywallLandingPage.webPageStatusUnsettled(status)
            )
        }
    }

    /** A table added to the contract and asserted nowhere would pin nothing. */
    @Test
    fun `every contract table is read here`() {
        assertEquals(
            setOf(
                "schema_version", "description", "unpaywall_choice", "citation_pdf_url",
                "character_references", "landing_page_status"
            ),
            contract.keys
        )
    }

    @Test(expected = IllegalArgumentException::class)
    fun `a choice cannot offer both a PDF and a landing page`() {
        UnpaywallChoice(pdfUrl = "https://r.org/a.pdf", landingPage = "https://r.org/a")
    }
}
