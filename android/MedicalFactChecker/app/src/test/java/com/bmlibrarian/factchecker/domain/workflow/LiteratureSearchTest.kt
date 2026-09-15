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

package com.bmlibrarian.factchecker.domain.workflow

import com.bmlibrarian.factchecker.data.remote.europepmc.EuropePMCApi
import com.bmlibrarian.factchecker.data.remote.europepmc.EuropePMCArticle
import com.bmlibrarian.factchecker.data.remote.europepmc.EuropePMCResultList
import com.bmlibrarian.factchecker.data.remote.europepmc.EuropePMCSearchResponse
import com.bmlibrarian.factchecker.data.remote.europepmc.EuropePMCService
import com.bmlibrarian.factchecker.data.remote.pubmed.ESearchResponse
import com.bmlibrarian.factchecker.data.remote.pubmed.ESearchResult
import com.bmlibrarian.factchecker.data.remote.pubmed.PubMedApi
import com.bmlibrarian.factchecker.data.remote.pubmed.PubMedService
import com.bmlibrarian.factchecker.domain.model.NcbiCredentials
import com.bmlibrarian.factchecker.domain.model.RequestFailure
import com.bmlibrarian.factchecker.domain.model.RequestFailureKind
import com.bmlibrarian.factchecker.domain.model.RetrievalShortfall
import com.bmlibrarian.factchecker.domain.model.SearchFailedException
import com.bmlibrarian.factchecker.domain.model.SearchProvider
import com.bmlibrarian.factchecker.domain.model.ShortfallQuery
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.mockk
import kotlinx.coroutines.test.runTest
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import retrofit2.Response

/**
 * One page of a fact-check's search, across its providers (#252).
 *
 * Runs the real PubMed and Europe PMC services over mocked APIs. A provider that
 * fails is recorded and the other still counts; a page that failures leave with
 * nothing is an error, never "No documents found", and changes no paging.
 */
class LiteratureSearchTest {

    private lateinit var pubMedApi: PubMedApi
    private lateinit var europePMCApi: EuropePMCApi
    private lateinit var search: LiteratureSearch

    @Before
    fun setUp() {
        pubMedApi = mockk()
        europePMCApi = mockk()
        search = LiteratureSearch(
            PubMedService(pubMedApi) { NcbiCredentials.of(apiKey = null, email = null) },
            EuropePMCService(europePMCApi)
        )
    }

    // ==================== A first page ====================

    @Test
    fun `a PubMed search that failed is an error, not a search that found nothing`() = runTest {
        pubMedFailsWith(429)

        val error = failedSearch(request(SearchProvider.PUBMED))

        assertEquals(listOf(RetrievalShortfall(SearchProvider.PUBMED, http(429))), error.shortfalls)
    }

    @Test
    fun `a PubMed search that matched nothing is an empty page`() = runTest {
        pubMedAnswers(count = 0, pmids = emptyList())

        val page = search.searchPage(request(SearchProvider.PUBMED))

        assertTrue(page.documents.isEmpty())
        assertTrue(page.shortfalls.isEmpty())
    }

    @Test
    fun `when one provider fails the other's documents proceed, and the failure is recorded`() = runTest {
        pubMedFailsWith(503)
        europePMCAnswers(hitCount = 40, cursor = "AoK", pmids = listOf("1", "2"))

        val page = search.searchPage(request(SearchProvider.BOTH, batchSize = 4))

        assertEquals(listOf("1", "2"), page.documents.map { it.pmid })
        assertEquals(listOf(RetrievalShortfall(SearchProvider.PUBMED, http(503))), page.shortfalls)
        assertNull("a PubMed search that failed has no paging to keep", page.pubMedPaging)
        assertEquals(EuropePMCPaging(cursor = "AoK", totalResults = 40, resultsReceived = 2), page.europePMCPaging)
    }

    @Test
    fun `an empty provider does not speak for one that failed`() = runTest {
        pubMedAnswers(count = 0, pmids = emptyList())
        europePMCFailsWith(500)

        val error = failedSearch(request(SearchProvider.BOTH))

        assertEquals(listOf(RetrievalShortfall(SearchProvider.EUROPE_PMC, http(500))), error.shortfalls)
    }

    @Test
    fun `a page that answered carries what it failed to retrieve`() = runTest {
        pubMedAnswers(count = 2, pmids = listOf("1", "2"), fetchStatus = 500)
        europePMCAnswers(hitCount = 1, cursor = null, pmids = listOf("3"))

        val page = search.searchPage(request(SearchProvider.BOTH, batchSize = 4))

        assertEquals(listOf("3"), page.documents.map { it.pmid })
        assertEquals(listOf(RetrievalShortfall(SearchProvider.PUBMED, http(500), 2)), page.shortfalls)
        assertEquals(PubMedPaging(offset = 2, totalResults = 2), page.pubMedPaging)
    }

    @Test
    fun `both providers share the batch`() = runTest {
        pubMedAnswers(count = 0, pmids = emptyList())
        europePMCAnswers(hitCount = 0, cursor = null, pmids = emptyList())

        search.searchPage(request(SearchProvider.BOTH, batchSize = 20))

        coVerify { pubMedApi.search(any(), any(), any(), retMax = 10, retStart = 0, any(), any(), any()) }
        coVerify { europePMCApi.search(any(), any(), pageSize = 10, cursorMark = "*", any()) }
    }

    // ==================== A later page ====================

    @Test
    fun `a later PubMed page that failed skips its records and says how many`() = runTest {
        pubMedFailsWith(429)
        europePMCAnswers(hitCount = 40, cursor = "AoL", pmids = listOf("9"))

        val page = search.searchPage(
            request(
                SearchProvider.BOTH, batchSize = 20, isNextBatch = true,
                pubMed = PubMedPaging(offset = 50, totalResults = 57),
                europePMC = EuropePMCPaging(cursor = "AoK", totalResults = 40, resultsReceived = 10)
            )
        )

        // 57 - 50 = 7 records that page should have listed
        assertEquals(listOf(RetrievalShortfall(SearchProvider.PUBMED, http(429), 7)), page.shortfalls)
        assertEquals(PubMedPaging(offset = 57, totalResults = 57), page.pubMedPaging)
        assertEquals(EuropePMCPaging(cursor = "AoL", totalResults = 40, resultsReceived = 11), page.europePMCPaging)
    }

    @Test
    fun `a later Europe PMC page that failed ends its cursor and says how many`() = runTest {
        pubMedAnswers(count = 57, pmids = (21..30).map { "$it" })
        europePMCFailsWith(503)

        val page = search.searchPage(
            request(
                SearchProvider.BOTH, batchSize = 20, isNextBatch = true,
                pubMed = PubMedPaging(offset = 20, totalResults = 57),
                europePMC = EuropePMCPaging(cursor = "AoK", totalResults = 14, resultsReceived = 10)
            )
        )

        // A cursor cannot skip a page: min(10, 14 - 10) = 4 records, and no more pages
        assertEquals(listOf(RetrievalShortfall(SearchProvider.EUROPE_PMC, http(503), 4)), page.shortfalls)
        assertEquals(EuropePMCPaging(cursor = null, totalResults = 14, resultsReceived = 10), page.europePMCPaging)
        assertEquals(10, page.documents.size)
    }

    @Test
    fun `a later page that failed everywhere is an error that changes no paging`() = runTest {
        pubMedFailsWith(429)

        val error = failedSearch(
            request(
                SearchProvider.PUBMED, batchSize = 20, isNextBatch = true,
                pubMed = PubMedPaging(offset = 20, totalResults = 57)
            )
        )

        assertEquals(listOf(RetrievalShortfall(SearchProvider.PUBMED, http(429), 20)), error.shortfalls)
    }

    @Test
    fun `a provider with no next page is not asked for one`() = runTest {
        europePMCAnswers(hitCount = 40, cursor = "AoL", pmids = listOf("9"))

        search.searchPage(
            request(
                SearchProvider.BOTH, batchSize = 20, isNextBatch = true,
                pubMed = PubMedPaging(offset = 57, totalResults = 57),
                europePMC = EuropePMCPaging(cursor = "AoK", totalResults = 40, resultsReceived = 10)
            )
        )

        coVerify(exactly = 0) { pubMedApi.search(any(), any(), any(), any(), any(), any(), any(), any()) }
    }

    @Test
    fun `PubMed is not asked past the records it can list`() = runTest {
        europePMCAnswers(hitCount = 40, cursor = "AoL", pmids = listOf("9"))

        search.searchPage(
            request(
                SearchProvider.BOTH, batchSize = 20, isNextBatch = true,
                pubMed = PubMedPaging(offset = 9_999, totalResults = 25_000),
                europePMC = EuropePMCPaging(cursor = "AoK", totalResults = 40, resultsReceived = 10)
            )
        )

        coVerify(exactly = 0) { pubMedApi.search(any(), any(), any(), any(), any(), any(), any(), any()) }
    }

    @Test
    fun `an ended cursor is not asked for another page`() = runTest {
        pubMedAnswers(count = 57, pmids = (21..40).map { "$it" })

        search.searchPage(
            request(
                SearchProvider.BOTH, batchSize = 40, isNextBatch = true,
                pubMed = PubMedPaging(offset = 20, totalResults = 57),
                europePMC = EuropePMCPaging(cursor = null, totalResults = 14, resultsReceived = 14)
            )
        )

        coVerify(exactly = 0) { europePMCApi.search(any(), any(), any(), any(), any()) }
    }

    @Test
    fun `a session that never counted its Europe PMC records pages on without claiming any missing`() = runTest {
        pubMedAnswers(count = 0, pmids = emptyList())
        coEvery { europePMCApi.search(any(), any(), any(), any(), any()) } returns Response.success(
            EuropePMCSearchResponse(hitCount = 40, nextCursorMark = "AoK", resultList = EuropePMCResultList(result = emptyList()))
        )

        val page = search.searchPage(
            request(
                SearchProvider.EUROPE_PMC, batchSize = 20, isNextBatch = true,
                europePMC = EuropePMCPaging(cursor = "AoJ", totalResults = 40, resultsReceived = null)
            )
        )

        assertTrue(page.shortfalls.isEmpty())
        assertEquals(EuropePMCPaging(cursor = null, totalResults = 40, resultsReceived = null), page.europePMCPaging)
    }

    @Test
    fun `a later Europe PMC page of such a session that failed claims the most it could have held`() = runTest {
        pubMedAnswers(count = 57, pmids = (21..30).map { "$it" })
        europePMCFailsWith(503)

        val page = search.searchPage(
            request(
                SearchProvider.BOTH, batchSize = 20, isNextBatch = true,
                pubMed = PubMedPaging(offset = 20, totalResults = 57),
                europePMC = EuropePMCPaging(cursor = "AoJ", totalResults = 40, resultsReceived = null)
            )
        )

        assertEquals(listOf(RetrievalShortfall(SearchProvider.EUROPE_PMC, http(503), 10)), page.shortfalls)
        assertEquals(EuropePMCPaging(cursor = null, totalResults = 40, resultsReceived = null), page.europePMCPaging)
    }

    // ==================== An alternative query ====================

    @Test
    fun `an alternative search's losses are its own`() = runTest {
        pubMedFailsWith(429)
        europePMCAnswers(hitCount = 3, cursor = null, pmids = listOf("1", "2", "3"))

        val page = search.searchPage(
            request(SearchProvider.BOTH, batchSize = 6, query = ShortfallQuery.ALTERNATIVE, excludedPmids = setOf("2"))
        )

        assertEquals(listOf("1", "3"), page.documents.map { it.pmid })
        assertEquals(
            listOf(RetrievalShortfall(SearchProvider.PUBMED, http(429), query = ShortfallQuery.ALTERNATIVE)),
            page.shortfalls
        )
    }

    @Test
    fun `an alternative search that found only what the session holds, and lost nothing, is no error`() = runTest {
        pubMedAnswers(count = 1, pmids = listOf("7"))

        val page = search.searchPage(
            request(SearchProvider.PUBMED, query = ShortfallQuery.ALTERNATIVE, excludedPmids = setOf("7"))
        )

        assertTrue(page.documents.isEmpty())
        assertTrue(page.shortfalls.isEmpty())
    }

    // ==================== Helpers ====================

    /** A page request with the defaults a first search uses. */
    private fun request(
        provider: SearchProvider,
        batchSize: Int = 20,
        isNextBatch: Boolean = false,
        pubMed: PubMedPaging = PubMedPaging(offset = 0, totalResults = 0),
        europePMC: EuropePMCPaging = EuropePMCPaging(cursor = null, totalResults = 0, resultsReceived = 0),
        query: ShortfallQuery = ShortfallQuery.ORIGINAL,
        excludedPmids: Set<String> = emptySet()
    ) = SearchPageRequest(
        provider = provider,
        pubMedQuery = "aspirin[tiab]",
        europePMCQuery = "aspirin",
        batchSize = batchSize,
        includePreprints = false,
        isNextBatch = isNextBatch,
        pubMedPaging = pubMed,
        europePMCPaging = europePMC,
        query = query,
        sessionId = "session",
        batchNumber = 1,
        existingDocumentCount = 0,
        excludedPmids = excludedPmids
    )

    /** Run a search that must fail, and return its error. */
    private suspend fun failedSearch(request: SearchPageRequest): SearchFailedException {
        val thrown = runCatching { search.searchPage(request) }.exceptionOrNull()
        assertTrue("expected a failed search, got $thrown", thrown is SearchFailedException)
        return thrown as SearchFailedException
    }

    /** Answer esearch with this listing and efetch with its articles, or with an HTTP error. */
    private fun pubMedAnswers(count: Int, pmids: List<String>, fetchStatus: Int? = null) {
        coEvery { pubMedApi.search(any(), any(), any(), any(), any(), any(), any(), any()) } returns
            Response.success(ESearchResponse(ESearchResult(count = "$count", idList = pmids)))
        coEvery { pubMedApi.fetch(any(), any(), any(), any(), any(), any()) } returns if (fetchStatus != null) {
            Response.error(fetchStatus, "".toResponseBody(null))
        } else {
            Response.success(
                "<PubmedArticleSet>" + pmids.joinToString("") {
                    "<PubmedArticle><MedlineCitation><PMID>$it</PMID><Article><ArticleTitle>T$it</ArticleTitle>" +
                        "</Article></MedlineCitation></PubmedArticle>"
                } + "</PubmedArticleSet>"
            )
        }
    }

    /** Answer esearch with an HTTP error. */
    private fun pubMedFailsWith(status: Int) {
        coEvery { pubMedApi.search(any(), any(), any(), any(), any(), any(), any(), any()) } returns
            Response.error(status, "".toResponseBody(null))
    }

    /** Answer Europe PMC's search with these articles. */
    private fun europePMCAnswers(hitCount: Int, cursor: String?, pmids: List<String>) {
        coEvery { europePMCApi.search(any(), any(), any(), any(), any()) } returns Response.success(
            EuropePMCSearchResponse(
                hitCount = hitCount,
                nextCursorMark = cursor,
                resultList = EuropePMCResultList(result = pmids.map { EuropePMCArticle(pmid = it, title = "E$it", source = "MED") })
            )
        )
    }

    /** Answer Europe PMC's search with an HTTP error. */
    private fun europePMCFailsWith(status: Int) {
        coEvery { europePMCApi.search(any(), any(), any(), any(), any()) } returns Response.error(status, "".toResponseBody(null))
    }

    /** An HTTP error failure. */
    private fun http(status: Int) = RequestFailure(RequestFailureKind.HTTP_STATUS, status)
}
