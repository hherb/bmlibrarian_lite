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

package com.bmlibrarian.factchecker.data.remote.pubmed

import com.bmlibrarian.factchecker.domain.model.NcbiCredentials
import io.mockk.coEvery
import io.mockk.mockk
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import retrofit2.Response

/**
 * A PubMed record's own identifiers, not those of the papers it cites (lite #404).
 *
 * The fixture is a trimmed real efetch body for PMID 33301246 (the Python
 * suite reads the same file): its own PMC ID and DOI differ from those of
 * the two papers in its `ReferenceList`.
 */
class PubMedArticleIdTest {

    private val body: String =
        requireNotNull(javaClass.classLoader?.getResource("pubmed/efetch_33301246.xml")) {
            "the efetch fixture is missing"
        }.readText()

    private suspend fun searchFor(xml: String): List<ParsedArticle> {
        val api: PubMedApi = mockk()
        val service = PubMedService(api) { NcbiCredentials.of(apiKey = null, email = null) }
        coEvery {
            api.search(any(), any(), any(), any(), any(), any(), any(), any())
        } returns Response.success(
            ESearchResponse(esearchResult = ESearchResult(count = "1", idList = listOf("33301246")))
        )
        coEvery {
            api.fetch(any(), any(), any(), any(), any(), any())
        } returns Response.success(xml)
        val result = service.search(query = "bnt162b2")
        assertTrue(result.isSuccess)
        return result.getOrNull()!!.articles
    }

    @Test
    fun `a reference id is never the articles`() = runTest {
        val article = searchFor(body).first()
        assertEquals("PMC7745181", article.pmcId)
        assertEquals("10.1056/NEJMoa2034577", article.doi)
    }

    @Test
    fun `an id only a reference carries is no id`() = runTest {
        val withoutOwnDoi = body
            .replace(
                "<ArticleId IdType=\"doi\">10.1056/NEJMoa2034577</ArticleId></ArticleIdList><ReferenceList>",
                "</ArticleIdList><ReferenceList>"
            )
            .replace(
                "<ELocationID EIdType=\"doi\" ValidYN=\"Y\">10.1056/NEJMoa2034577</ELocationID>",
                ""
            )
        assertTrue(withoutOwnDoi.length < body.length - 80)
        val article = searchFor(withoutOwnDoi).first()
        // The cited paper's DOI (10.1056/NEJMoa2027906) must not stand in for the missing one
        assertNull(article.doi)
        assertEquals("PMC7745181", article.pmcId)
    }

    @Test
    fun `a pmc id only a reference carries is no pmc id`() = runTest {
        val withoutOwnPmc = body.replace(
            "<ArticleId IdType=\"pmc\">PMC7745181</ArticleId>",
            ""
        )
        assertTrue(withoutOwnPmc != body)
        assertNull(searchFor(withoutOwnPmc).first().pmcId)
    }
}
