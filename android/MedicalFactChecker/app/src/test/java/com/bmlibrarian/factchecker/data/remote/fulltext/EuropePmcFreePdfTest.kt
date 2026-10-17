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

import android.util.Log
import com.bmlibrarian.factchecker.data.remote.europepmc.EuropePMCArticle
import com.bmlibrarian.factchecker.util.Constants
import io.mockk.every
import io.mockk.mockkStatic
import io.mockk.unmockkAll
import io.mockk.verify
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File

/**
 * Europe PMC's free-PDF allow-list against the shared contract (bmlib#79),
 * through the same path the app takes: an article's entries to the render URL
 * [FullTextService.PmcResolution] carries.
 */
class EuropePmcFreePdfTest {
    private val json = Json { ignoreUnknownKeys = true }

    private fun contractFile(): File {
        var candidate: File? = File("").absoluteFile
        while (candidate != null) {
            val file = File(candidate, "doc/cross_platform/fulltext_parity/europepmc_free_pdf.json")
            if (file.isFile) return file
            candidate = candidate.parentFile
        }
        error("europepmc_free_pdf.json not found")
    }

    private val contract: JsonObject by lazy {
        Json.parseToJsonElement(contractFile().readText()).jsonObject
    }

    private fun strings(key: String): Set<String> =
        contract.getValue(key).jsonArray.map { (it as JsonPrimitive).content }.toSet()

    /** The article a contract case describes: no list at all when `fullTextUrl` is null. */
    private fun article(entries: JsonArray?): EuropePMCArticle {
        val list = if (entries == null) {
            JsonObject(emptyMap())
        } else {
            JsonObject(mapOf("fullTextUrlList" to JsonObject(mapOf("fullTextUrl" to entries))))
        }
        return json.decodeFromString(EuropePMCArticle.serializer(), list.toString())
    }

    @Before
    fun setUp() {
        mockkStatic(Log::class)
        every { Log.w(any<String>(), any<String>()) } returns 0
        every { Log.d(any<String>(), any<String>()) } returns 0
    }

    @After
    fun tearDown() {
        unmockkAll()
    }

    @Test
    fun `every contract key is read here`() {
        assertEquals(
            setOf(
                "schema_version", "description", "source", "free_codes", "free_labels",
                "known_unavailable_codes", "cases"
            ),
            contract.keys
        )
    }

    @Test
    fun `the constants are the contract's`() {
        assertEquals(strings("free_codes"), Constants.EUROPE_PMC_FREE_PDF_CODES)
        assertEquals(strings("free_labels"), Constants.EUROPE_PMC_FREE_PDF_LABELS)
        assertEquals(strings("known_unavailable_codes"), Constants.EUROPE_PMC_UNAVAILABLE_PDF_CODES)
    }

    @Test
    fun `each contract case`() {
        val cases = contract.getValue("cases").jsonArray.map { it.jsonObject }
        assertTrue("an emptied table would pass vacuously", cases.size >= 12)
        for (case in cases) {
            val name = (case.getValue("name") as JsonPrimitive).content
            val entries = case.getValue("fullTextUrl").let { if (it is JsonNull) null else it.jsonArray }
            val expected = (case.getValue("expected_url") as? JsonPrimitive)
                ?.takeUnless { it is JsonNull }?.contentOrNull
            assertEquals(name, expected, EuropePmcFreePdf.extractUrl(article(entries).fullTextUrlList?.fullTextUrl))
            assertEquals(
                name,
                expected,
                FullTextService.PmcResolution.fromArticle(article(entries)).pdfRenderUrl
            )
        }
    }

    private fun single(code: String?, label: String?): JsonArray = JsonArray(
        listOf(
            JsonObject(
                buildMap {
                    put("documentStyle", JsonPrimitive("pdf"))
                    put("url", JsonPrimitive("https://example.org/x.pdf"))
                    if (code != null) put("availabilityCode", JsonPrimitive(code))
                    if (label != null) put("availability", JsonPrimitive(label))
                }
            )
        )
    )

    @Test
    fun `an unrecognised code is logged at warning with its label`() {
        assertNull(EuropePmcFreePdf.extractUrl(article(single("Z", "Free")).fullTextUrlList?.fullTextUrl))
        verify(exactly = 1) {
            Log.w(any<String>(), match<String> { it.contains("'Z'") && it.contains("'Free'") })
        }
    }

    @Test
    fun `a routine rejection is not a warning`() {
        for (entries in listOf(single("S", "Subscription required"), single(null, "Subscription required"), single("", null))) {
            EuropePmcFreePdf.extractUrl(article(entries).fullTextUrlList?.fullTextUrl)
        }
        verify(exactly = 0) { Log.w(any<String>(), any<String>()) }
    }

    @Test
    fun `an accepted entry is not a warning`() {
        assertEquals(
            "https://example.org/x.pdf",
            EuropePmcFreePdf.extractUrl(article(single("OA", "Open access")).fullTextUrlList?.fullTextUrl)
        )
        verify(exactly = 0) { Log.w(any<String>(), any<String>()) }
    }
}
