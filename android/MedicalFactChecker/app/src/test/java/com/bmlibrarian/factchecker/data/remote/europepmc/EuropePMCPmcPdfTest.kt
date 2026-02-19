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

package com.bmlibrarian.factchecker.data.remote.europepmc

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Tests for Europe PMC fullTextUrlList deserialization and PDF render URL extraction.
 *
 * Verifies that the new FullTextUrlList and FullTextUrlEntry models correctly
 * deserialize from Europe PMC API responses, enabling discovery of free PDF
 * URLs for articles where JATS XML is not available.
 */
class EuropePMCPmcPdfTest {

    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun `EuropePMCArticle deserializes fullTextUrlList with free PDF`() {
        val jsonString = """
        {
            "pmid": "31996627",
            "pmcid": "PMC7339914",
            "doi": "10.1212/CON.0000000000000816",
            "title": "Management of Orthostatic Hypotension",
            "hasPDF": "Y",
            "inPMC": "Y",
            "fullTextUrlList": {
                "fullTextUrl": [
                    {
                        "availability": "Subscription required",
                        "availabilityCode": "S",
                        "documentStyle": "doi",
                        "site": "DOI",
                        "url": "https://doi.org/10.1212/CON.0000000000000816"
                    },
                    {
                        "availability": "Free",
                        "availabilityCode": "F",
                        "documentStyle": "html",
                        "site": "Europe_PMC",
                        "url": "https://europepmc.org/articles/PMC7339914"
                    },
                    {
                        "availability": "Free",
                        "availabilityCode": "F",
                        "documentStyle": "pdf",
                        "site": "Europe_PMC",
                        "url": "https://europepmc.org/articles/PMC7339914?pdf=render"
                    }
                ]
            }
        }
        """.trimIndent()

        val article = json.decodeFromString<EuropePMCArticle>(jsonString)

        assertEquals("PMC7339914", article.pmcid)
        assertEquals("Y", article.hasPDF)
        assertNotNull(article.fullTextUrlList)

        val urls = article.fullTextUrlList?.fullTextUrl
        assertNotNull(urls)
        assertEquals(3, urls?.size)

        // Find the free PDF entry
        val freePdf = urls?.firstOrNull {
            it.documentStyle == "pdf" && it.availability == "Free"
        }
        assertNotNull(freePdf)
        assertEquals(
            "https://europepmc.org/articles/PMC7339914?pdf=render",
            freePdf?.url
        )
    }

    @Test
    fun `EuropePMCArticle without fullTextUrlList deserializes correctly`() {
        val jsonString = """
        {
            "pmid": "12345678",
            "title": "Test Article"
        }
        """.trimIndent()

        val article = json.decodeFromString<EuropePMCArticle>(jsonString)

        assertEquals("12345678", article.pmid)
        assertNull(article.fullTextUrlList)
        assertNull(article.hasPDF)
    }

    @Test
    fun `EuropePMCArticle with empty fullTextUrlList deserializes correctly`() {
        val jsonString = """
        {
            "pmid": "12345678",
            "title": "Test Article",
            "fullTextUrlList": {
                "fullTextUrl": []
            }
        }
        """.trimIndent()

        val article = json.decodeFromString<EuropePMCArticle>(jsonString)

        assertNotNull(article.fullTextUrlList)
        assertEquals(0, article.fullTextUrlList?.fullTextUrl?.size)
    }

    @Test
    fun `extracting free PDF URL from fullTextUrlList`() {
        val urls = listOf(
            FullTextUrlEntry(
                documentStyle = "doi",
                site = "DOI",
                url = "https://doi.org/10.1212/CON.0000000000000816",
                availability = "Subscription required"
            ),
            FullTextUrlEntry(
                documentStyle = "html",
                site = "Europe_PMC",
                url = "https://europepmc.org/articles/PMC7339914",
                availability = "Free"
            ),
            FullTextUrlEntry(
                documentStyle = "pdf",
                site = "Europe_PMC",
                url = "https://europepmc.org/articles/PMC7339914?pdf=render",
                availability = "Free"
            )
        )

        val freePdfUrl = urls
            .firstOrNull { it.documentStyle == "pdf" && it.availability == "Free" }
            ?.url

        assertEquals(
            "https://europepmc.org/articles/PMC7339914?pdf=render",
            freePdfUrl
        )
    }

    @Test
    fun `no free PDF URL when only subscription entries exist`() {
        val urls = listOf(
            FullTextUrlEntry(
                documentStyle = "pdf",
                site = "DOI",
                url = "https://doi.org/some-doi",
                availability = "Subscription required"
            )
        )

        val freePdfUrl = urls
            .firstOrNull { it.documentStyle == "pdf" && it.availability == "Free" }
            ?.url

        assertNull(freePdfUrl)
    }
}
