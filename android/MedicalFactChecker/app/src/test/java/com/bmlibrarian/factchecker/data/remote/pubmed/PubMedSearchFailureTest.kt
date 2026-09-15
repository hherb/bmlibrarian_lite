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

import android.util.Log
import com.bmlibrarian.factchecker.domain.model.NcbiCredentials
import com.bmlibrarian.factchecker.domain.model.NcbiCredentialsUnavailableException
import com.bmlibrarian.factchecker.domain.model.RequestFailure
import com.bmlibrarian.factchecker.domain.model.RequestFailureKind
import com.bmlibrarian.factchecker.domain.model.RetrievalShortfall
import com.bmlibrarian.factchecker.domain.model.SearchProvider
import com.bmlibrarian.factchecker.domain.model.SourceRequestException
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.mockk
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.JsonPrimitive
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import retrofit2.Response
import java.io.IOException
import java.net.SocketTimeoutException

/**
 * A failed PubMed search is never an empty one (#252, #255).
 *
 * E-utilities reports some failures inside an HTTP 200, and an answer can hold
 * less than it counts. Each case is a failure the search returns, or a shortfall
 * it records beside what it did retrieve; none reads as a search that matched
 * nothing. The contract is `doc/cross_platform/search_failure_reporting.md`.
 */
class PubMedSearchFailureTest {

    private lateinit var api: PubMedApi
    private lateinit var service: PubMedService

    /** What the credential source answers. */
    private var savedCredentials = NcbiCredentials.of(apiKey = null, email = null)

    @Before
    fun setUp() {
        api = mockk()
        service = PubMedService(api) { savedCredentials }
        Log.clear()
    }

    // ==================== A search that failed ====================

    @Test
    fun `an esearch ERROR inside an HTTP 200 is a service error, not zero results`() = runTest {
        answerSearch(ESearchResult(error = JsonPrimitive("Search Backend failed: <SERVER_TEXT>")))

        val failure = failureOf(service.search(query = "(("))

        assertEquals(RequestFailure(RequestFailureKind.SERVICE_ERROR), failure)
        coVerify(exactly = 1) { api.search(any(), any(), any(), any(), any(), any(), any(), any()) }
        assertNothingLogged("SERVER_TEXT")
    }

    @Test
    fun `an esearch answer without a count cannot be read`() = runTest {
        answerSearch(ESearchResult(idList = emptyList()))

        assertEquals(MALFORMED, failureOf(service.search(query = "aspirin")))
    }

    @Test
    fun `a count that is no whole number cannot be read`() = runTest {
        for (count in listOf("", "abc", "-1", "5.0", "99999999999999999999")) {
            answerSearch(ESearchResult(count = count, idList = emptyList()))

            assertEquals("count $count", MALFORMED, failureOf(service.search(query = "aspirin")))
        }
    }

    @Test
    fun `an esearch answer without a list of PMIDs cannot be read`() = runTest {
        answerSearch(ESearchResult(count = "5"))

        assertEquals(MALFORMED, failureOf(service.search(query = "aspirin")))
    }

    @Test
    fun `an answer without an esearchresult object cannot be read`() = runTest {
        coEvery { api.search(any(), any(), any(), any(), any(), any(), any(), any()) } returns
            Response.success(ESearchResponse(esearchResult = null))

        assertEquals(MALFORMED, failureOf(service.search(query = "aspirin")))
    }

    @Test
    fun `a body the converter could not read is malformed, not retried, and not quoted`() = runTest {
        coEvery { api.search(any(), any(), any(), any(), any(), any(), any(), any()) } throws
            SerializationException("Unexpected JSON token at offset 0: <html>BODY_TEXT</html>")

        val result = service.search(query = "aspirin")

        assertEquals(MALFORMED, failureOf(result))
        assertFalse(result.exceptionOrNull()?.message.orEmpty().contains("BODY_TEXT"))
        coVerify(exactly = 1) { api.search(any(), any(), any(), any(), any(), any(), any(), any()) }
        assertNothingLogged("BODY_TEXT")
    }

    @Test
    fun `a page that lists none of the PMIDs it counts is a failed request`() = runTest {
        answerSearch(ESearchResult(count = "57", idList = emptyList()))

        assertEquals(
            RequestFailure(RequestFailureKind.INCOMPLETE_RESPONSE),
            failureOf(service.search(query = "aspirin", offset = 40, batchSize = 20))
        )
    }

    @Test
    fun `a count of zero with no PMIDs is a search that matched nothing`() = runTest {
        answerSearch(ESearchResult(count = "0", idList = emptyList()))

        val searched = service.search(query = "aspirin").getOrThrow()

        assertTrue(searched.articles.isEmpty())
        assertTrue(searched.shortfalls.isEmpty())
        assertFalse(searched.hasMore)
    }

    @Test
    fun `an HTTP error keeps only its status, never the body that echoes the key`() = runTest {
        val apiKey = "rejected-key-0123456789"
        savedCredentials = NcbiCredentials.of(apiKey = apiKey, email = null)
        coEvery { api.search(any(), any(), any(), any(), any(), any(), any(), any()) } returns
            Response.error(400, """{"error":"API key invalid","api-key":"$apiKey"}""".toResponseBody(null))

        val result = service.search(query = "aspirin")

        val error = result.exceptionOrNull() as SourceRequestException
        assertEquals(SearchProvider.PUBMED, error.provider)
        assertEquals(RequestFailure(RequestFailureKind.HTTP_STATUS, 400), error.failure)
        assertNull(error.cause)
        assertFalse(error.message.orEmpty().contains(apiKey))
        assertNothingLogged(apiKey)
    }

    @Test
    fun `a rate limit that outlasts the retries is an HTTP 429`() = runTest {
        coEvery { api.search(any(), any(), any(), any(), any(), any(), any(), any()) } returns
            Response.error(429, "".toResponseBody(null))

        assertEquals(RequestFailure(RequestFailureKind.HTTP_STATUS, 429), failureOf(service.search(query = "aspirin")))
        coVerify(atLeast = 2) { api.search(any(), any(), any(), any(), any(), any(), any(), any()) }
    }

    @Test
    fun `a connection that keeps failing is a connection failure, and a timeout a timeout`() = runTest {
        coEvery { api.search(any(), any(), any(), any(), any(), any(), any(), any()) } throws IOException("reset")
        assertEquals(RequestFailure(RequestFailureKind.CONNECTION), failureOf(service.search(query = "aspirin")))

        coEvery { api.search(any(), any(), any(), any(), any(), any(), any(), any()) } throws SocketTimeoutException()
        assertEquals(RequestFailure(RequestFailureKind.TIMEOUT), failureOf(service.search(query = "aspirin")))
    }

    @Test
    fun `unreadable saved credentials stop the search with what to do, sending nothing`() = runTest {
        // A broken keystore is not a failure of PubMed's: retrying cannot help, fixing Settings can
        val failing = PubMedService(api) { throw java.security.GeneralSecurityException("KEYSTORE_TEXT") }

        val thrown = runCatching { failing.search(query = "aspirin") }.exceptionOrNull()

        assertTrue("got $thrown", thrown is NcbiCredentialsUnavailableException)
        assertTrue(thrown?.message.orEmpty().contains("Settings"))
        assertNull("the error kept the keystore's exception", thrown?.cause)
        assertFalse(thrown?.message.orEmpty().contains("KEYSTORE_TEXT"))
        coVerify(exactly = 0) { api.search(any(), any(), any(), any(), any(), any(), any(), any()) }
    }

    @Test
    fun `a page past what PubMed can list is never asked for`() = runTest {
        // retstart can be at most 9998 (checked live 2026-09-15)
        val thrown = runCatching { service.search(query = "aspirin", offset = 9_999) }.exceptionOrNull()

        assertTrue("got $thrown", thrown is IllegalArgumentException)
        coVerify(exactly = 0) { api.search(any(), any(), any(), any(), any(), any(), any(), any()) }
    }

    // ==================== A search that retrieved less than it found ====================

    @Test
    fun `a page that lists fewer PMIDs than it counts records the rest as missing`() = runTest {
        answerSearch(ESearchResult(count = "57", idList = listOf("1", "2", "3")))
        answerFetch(sampleXml(listOf("1", "2", "3")))

        val searched = service.search(query = "aspirin", offset = 0, batchSize = 20).getOrThrow()

        assertEquals(3, searched.articles.size)
        assertEquals(
            listOf(RetrievalShortfall(SearchProvider.PUBMED, RequestFailure(RequestFailureKind.INCOMPLETE_RESPONSE), 17)),
            searched.shortfalls
        )
        assertEquals("the unlisted PMIDs are not asked for again", 20, searched.nextOffset)
    }

    @Test
    fun `a failed fetch keeps the search and records the PMIDs it could not retrieve`() = runTest {
        answerSearch(ESearchResult(count = "2", idList = listOf("1", "2")))
        coEvery { api.fetch(any(), any(), any(), any(), any(), any()) } returns
            Response.error(503, "".toResponseBody(null))

        val searched = service.search(query = "aspirin").getOrThrow()

        assertTrue(searched.articles.isEmpty())
        assertEquals(
            listOf(RetrievalShortfall(SearchProvider.PUBMED, RequestFailure(RequestFailureKind.HTTP_STATUS, 503), 2)),
            searched.shortfalls
        )
        assertEquals(2, searched.nextOffset)
        coVerify(exactly = 1) { api.search(any(), any(), any(), any(), any(), any(), any(), any()) }
    }

    @Test
    fun `a fetch is retried on its own, without searching again`() = runTest {
        answerSearch(ESearchResult(count = "1", idList = listOf("1")))
        var fetches = 0
        coEvery { api.fetch(any(), any(), any(), any(), any(), any()) } answers {
            fetches++
            if (fetches == 1) throw IOException("reset") else Response.success(sampleXml(listOf("1")))
        }

        val searched = service.search(query = "aspirin").getOrThrow()

        assertEquals(1, searched.articles.size)
        assertEquals(2, fetches)
        coVerify(exactly = 1) { api.search(any(), any(), any(), any(), any(), any(), any(), any()) }
    }

    @Test
    fun `an efetch error document inside an HTTP 200 is a service error for its PMIDs`() = runTest {
        answerSearch(ESearchResult(count = "2", idList = listOf("1", "2")))
        answerFetch("<?xml version=\"1.0\"?>\n<eFetchResult><ERROR>SERVER_TEXT</ERROR></eFetchResult>")

        val searched = service.search(query = "aspirin").getOrThrow()

        assertTrue(searched.articles.isEmpty())
        assertEquals(
            listOf(RetrievalShortfall(SearchProvider.PUBMED, RequestFailure(RequestFailureKind.SERVICE_ERROR), 2)),
            searched.shortfalls
        )
        coVerify(exactly = 1) { api.fetch(any(), any(), any(), any(), any(), any()) }
        assertNothingLogged("SERVER_TEXT")
    }

    @Test
    fun `an efetch answer that is no article set cannot be read`() = runTest {
        for (body in listOf("<html><body>Service down</body></html>", "not xml at all", "")) {
            answerSearch(ESearchResult(count = "2", idList = listOf("1", "2")))
            answerFetch(body)

            val searched = service.search(query = "aspirin").getOrThrow()

            assertEquals(
                body,
                listOf(RetrievalShortfall(SearchProvider.PUBMED, MALFORMED, 2)),
                searched.shortfalls
            )
        }
    }

    @Test
    fun `an efetch answer without a body cannot be read`() = runTest {
        answerSearch(ESearchResult(count = "1", idList = listOf("1")))
        coEvery { api.fetch(any(), any(), any(), any(), any(), any()) } returns Response.success(null)

        val searched = service.search(query = "aspirin").getOrThrow()

        assertEquals(listOf(RetrievalShortfall(SearchProvider.PUBMED, MALFORMED, 1)), searched.shortfalls)
    }

    @Test
    fun `a truncated article set keeps the whole articles and records the rest as unreadable`() = runTest {
        answerSearch(ESearchResult(count = "3", idList = listOf("1", "2", "3")))
        answerFetch(
            "<PubmedArticleSet>" + article("1", "Complete") +
                "<PubmedArticle><MedlineCitation><PMID>2</PMID><Article><ArticleTitle>Cut &undefined;"
        )

        val searched = service.search(query = "aspirin").getOrThrow()

        assertEquals(listOf("1"), searched.articles.map { it.pmid })
        assertEquals(listOf(RetrievalShortfall(SearchProvider.PUBMED, MALFORMED, 2)), searched.shortfalls)
        assertNothingLogged("undefined")
    }

    @Test
    fun `an article the parser cannot use is counted, not dropped silently`() = runTest {
        answerSearch(ESearchResult(count = "3", idList = listOf("1", "2", "3")))
        answerFetch(
            "<PubmedArticleSet>" + article("1", "Kept") +
                "<PubmedArticle><MedlineCitation><Article><ArticleTitle>No PMID</ArticleTitle></Article></MedlineCitation></PubmedArticle>" +
                "<PubmedArticle><MedlineCitation><PMID>3</PMID><Article></Article></MedlineCitation></PubmedArticle>" +
                "</PubmedArticleSet>"
        )

        val searched = service.search(query = "aspirin").getOrThrow()

        assertEquals(listOf("1"), searched.articles.map { it.pmid })
        assertEquals(listOf(RetrievalShortfall(SearchProvider.PUBMED, MALFORMED, 2)), searched.shortfalls)
    }

    @Test
    fun `PMIDs PubMed does not hold are not a shortfall`() = runTest {
        // An empty PubmedArticleSet is NCBI's answer for PMIDs it does not hold
        answerSearch(ESearchResult(count = "1", idList = listOf("1")))
        answerFetch("<PubmedArticleSet></PubmedArticleSet>")

        val searched = service.search(query = "aspirin").getOrThrow()

        assertTrue(searched.articles.isEmpty())
        assertTrue(searched.shortfalls.isEmpty())
    }

    @Test
    fun `the last listable page ends the paging`() = runTest {
        val pmids = (1..19).map { "$it" }
        answerSearch(ESearchResult(count = "25000", idList = pmids))
        answerFetch(sampleXml(pmids))

        val searched = service.search(query = "aspirin", offset = 9_980, batchSize = 20).getOrThrow()

        assertTrue(searched.shortfalls.isEmpty())
        assertEquals(9_999, searched.nextOffset)
        assertFalse(searched.hasMore)
    }

    // ==================== Helpers ====================

    /** Answer every esearch with this result. */
    private fun answerSearch(result: ESearchResult) {
        coEvery { api.search(any(), any(), any(), any(), any(), any(), any(), any()) } returns
            Response.success(ESearchResponse(esearchResult = result))
    }

    /** Answer every efetch with this body. */
    private fun answerFetch(body: String) {
        coEvery { api.fetch(any(), any(), any(), any(), any(), any()) } returns Response.success(body)
    }

    /** The failure a result carries, asserting it is a PubMed source failure without a cause. */
    private fun failureOf(result: Result<PubMedSearchResult>): RequestFailure {
        val error = result.exceptionOrNull()
        assertTrue("expected a SourceRequestException, got $error (${result.getOrNull()})", error is SourceRequestException)
        error as SourceRequestException
        assertEquals(SearchProvider.PUBMED, error.provider)
        assertNull("the failure kept its cause", error.cause)
        return error.failure
    }

    /** Assert that no logged line contains this text. */
    private fun assertNothingLogged(text: String) {
        for (line in Log.lines) {
            assertFalse("logged \"$text\": $line", line.contains(text))
        }
    }

    /** One complete article. */
    private fun article(pmid: String, title: String): String =
        "<PubmedArticle><MedlineCitation><PMID>$pmid</PMID><Article><ArticleTitle>$title</ArticleTitle>" +
            "</Article></MedlineCitation></PubmedArticle>"

    /** An article set holding one article per PMID. */
    private fun sampleXml(pmids: List<String>): String =
        "<PubmedArticleSet>" + pmids.joinToString("") { article(it, "Article $it") } + "</PubmedArticleSet>"

    private companion object {
        val MALFORMED = RequestFailure(RequestFailureKind.MALFORMED_RESPONSE)
    }
}
