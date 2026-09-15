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

import android.util.Log
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
import kotlin.coroutines.cancellation.CancellationException

/**
 * A failed Europe PMC search is never an empty one (#252).
 *
 * Europe PMC answers an unknown cursor with an HTTP 200 holding only a
 * `version`, and a page can hold less than its `hitCount` promised. Each case is
 * a failure the search returns, or a shortfall it records beside what it did
 * retrieve. The contract is `doc/cross_platform/search_failure_reporting.md`.
 */
class EuropePMCSearchFailureTest {

    private lateinit var api: EuropePMCApi
    private lateinit var service: EuropePMCService

    @Before
    fun setUp() {
        api = mockk()
        service = EuropePMCService(api)
        Log.clear()
    }

    // ==================== A search that failed ====================

    @Test
    fun `an HTTP error that outlasts the retries keeps only its status`() = runTest {
        coEvery { api.search(any(), any(), any(), any(), any()) } returns Response.error(500, "BODY_TEXT".toResponseBody(null))

        val result = service.search(query = "aspirin")

        assertEquals(RequestFailure(RequestFailureKind.HTTP_STATUS, 500), failureOf(result))
        assertFalse(result.exceptionOrNull()?.message.orEmpty().contains("BODY_TEXT"))
    }

    @Test
    fun `a rate limit is retried, then reported as HTTP 429`() = runTest {
        coEvery { api.search(any(), any(), any(), any(), any()) } returns Response.error(429, "".toResponseBody(null))

        assertEquals(RequestFailure(RequestFailureKind.HTTP_STATUS, 429), failureOf(service.search(query = "aspirin")))
        coVerify(atLeast = 2) { api.search(any(), any(), any(), any(), any()) }
    }

    @Test
    fun `a rejected query is an HTTP 400, not retried`() = runTest {
        coEvery { api.search(any(), any(), any(), any(), any()) } returns Response.error(400, "".toResponseBody(null))

        assertEquals(RequestFailure(RequestFailureKind.HTTP_STATUS, 400), failureOf(service.search(query = "((")))
        coVerify(exactly = 1) { api.search(any(), any(), any(), any(), any()) }
    }

    @Test
    fun `a connection that keeps failing is a connection failure, and a timeout a timeout`() = runTest {
        coEvery { api.search(any(), any(), any(), any(), any()) } throws IOException("reset")
        assertEquals(RequestFailure(RequestFailureKind.CONNECTION), failureOf(service.search(query = "aspirin")))

        coEvery { api.search(any(), any(), any(), any(), any()) } throws SocketTimeoutException()
        assertEquals(RequestFailure(RequestFailureKind.TIMEOUT), failureOf(service.search(query = "aspirin")))
    }

    @Test
    fun `a body the converter could not read is malformed, not retried, and not quoted`() = runTest {
        coEvery { api.search(any(), any(), any(), any(), any()) } throws
            SerializationException("Unexpected JSON token at offset 0: BODY_TEXT")

        val result = service.search(query = "aspirin")

        assertEquals(MALFORMED, failureOf(result))
        assertFalse(result.exceptionOrNull()?.message.orEmpty().contains("BODY_TEXT"))
        coVerify(exactly = 1) { api.search(any(), any(), any(), any(), any()) }
        assertNothingLogged("BODY_TEXT")
    }

    @Test
    fun `an answer without a body cannot be read`() = runTest {
        coEvery { api.search(any(), any(), any(), any(), any()) } returns Response.success(null)

        assertEquals(MALFORMED, failureOf(service.search(query = "aspirin")))
    }

    @Test
    fun `an answer without a usable hit count cannot be read`() = runTest {
        // An unknown cursor is answered with only a version (checked live 2026-09-14)
        for (hitCount in listOf(null, -1)) {
            answer(EuropePMCSearchResponse(hitCount = hitCount, resultList = EuropePMCResultList(result = emptyList())))

            assertEquals("hitCount $hitCount", MALFORMED, failureOf(service.search(query = "aspirin", cursor = "AoJ")))
        }
    }

    @Test
    fun `an answer without a result list cannot be read`() = runTest {
        for (resultList in listOf(null, EuropePMCResultList(result = null))) {
            answer(EuropePMCSearchResponse(hitCount = 5, resultList = resultList))

            assertEquals("$resultList", MALFORMED, failureOf(service.search(query = "aspirin")))
        }
    }

    @Test
    fun `an empty first page the hit count promised results for is a failed request`() = runTest {
        answer(EuropePMCSearchResponse(hitCount = 57, nextCursorMark = "AoJ", resultList = EuropePMCResultList(result = emptyList())))

        assertEquals(INCOMPLETE, failureOf(service.search(query = "aspirin")))
    }

    @Test
    fun `an empty later page with hits still to come is a failed request`() = runTest {
        answer(EuropePMCSearchResponse(hitCount = 57, nextCursorMark = "AoK", resultList = EuropePMCResultList(result = emptyList())))

        assertEquals(INCOMPLETE, failureOf(service.search(query = "aspirin", cursor = "AoJ", batchSize = 20, resultsReceived = 20)))
    }

    @Test
    fun `a cancelled search stays cancelled`() = runTest {
        coEvery { api.search(any(), any(), any(), any(), any()) } throws CancellationException("abandoned")

        val thrown = try {
            service.search(query = "aspirin")
            null
        } catch (e: CancellationException) {
            e
        }

        assertTrue("cancellation became a failed result instead", thrown != null)
    }

    // ==================== A search that answered ====================

    @Test
    fun `no hits and an empty page is a search that matched nothing`() = runTest {
        answer(EuropePMCSearchResponse(hitCount = 0, nextCursorMark = "*", resultList = EuropePMCResultList(result = emptyList())))

        val searched = service.search(query = "aspirin").getOrThrow()

        assertTrue(searched.articles.isEmpty())
        assertTrue(searched.shortfalls.isEmpty())
        assertFalse(searched.hasMore)
        assertEquals(0, searched.resultsReceived)
    }

    @Test
    fun `a cursor that ends before the page's hits arrived records the rest as missing`() = runTest {
        // The cursor ends only once every hit was sent (checked live 2026-09-15)
        answer(EuropePMCSearchResponse(hitCount = 50, nextCursorMark = null, resultList = results(5)))

        val searched = service.search(query = "aspirin", batchSize = 20).getOrThrow()

        assertEquals(5, searched.articles.size)
        assertEquals(listOf(RetrievalShortfall(SearchProvider.EUROPE_PMC, INCOMPLETE, 15)), searched.shortfalls)
        assertNull(searched.nextCursor)
        assertFalse(searched.hasMore)
    }

    @Test
    fun `a cursor that repeats the one sent has ended`() = runTest {
        answer(EuropePMCSearchResponse(hitCount = 50, nextCursorMark = "AoJ", resultList = results(5)))

        val searched = service.search(query = "aspirin", cursor = "AoJ", batchSize = 20, resultsReceived = 20).getOrThrow()

        assertEquals(listOf(RetrievalShortfall(SearchProvider.EUROPE_PMC, INCOMPLETE, 15)), searched.shortfalls)
        assertFalse(searched.hasMore)
    }

    @Test
    fun `the last page ends the cursor with nothing missing`() = runTest {
        answer(EuropePMCSearchResponse(hitCount = 45, nextCursorMark = "AoK", resultList = results(5)))

        val searched = service.search(query = "aspirin", cursor = "AoJ", batchSize = 20, resultsReceived = 40).getOrThrow()

        // A cursor may still be offered on the last page; nothing was promised beyond it
        assertTrue(searched.shortfalls.isEmpty())
        assertEquals(5, searched.resultsReceived)
    }

    @Test
    fun `a short page with a cursor that goes on loses nothing yet`() = runTest {
        answer(EuropePMCSearchResponse(hitCount = 50, nextCursorMark = "AoK", resultList = results(5)))

        val searched = service.search(query = "aspirin", batchSize = 20).getOrThrow()

        assertTrue(searched.shortfalls.isEmpty())
        assertEquals("AoK", searched.nextCursor)
        assertTrue(searched.hasMore)
    }

    @Test
    fun `when how many records came before is unknown, an empty later page ends the cursor as it always did`() = runTest {
        // A session saved before #252 kept a cursor but no count of what it received
        answer(EuropePMCSearchResponse(hitCount = 57, nextCursorMark = "AoK", resultList = EuropePMCResultList(result = emptyList())))

        val searched = service.search(query = "aspirin", cursor = "AoJ", batchSize = 20, resultsReceived = null).getOrThrow()

        assertTrue(searched.shortfalls.isEmpty())
        assertFalse(searched.hasMore)
    }

    @Test
    fun `when how many records came before is unknown, a short last page loses nothing`() = runTest {
        answer(EuropePMCSearchResponse(hitCount = 57, nextCursorMark = null, resultList = results(5)))

        val searched = service.search(query = "aspirin", cursor = "AoJ", batchSize = 20, resultsReceived = null).getOrThrow()

        assertTrue(searched.shortfalls.isEmpty())
        assertEquals(5, searched.resultsReceived)
    }

    @Test
    fun `records that could not be read or have no title are counted, not dropped silently`() = runTest {
        val page = listOf(article("1", "Kept"), null, article("3", " "), article("4", null), article("5", "Also kept"))
        answer(EuropePMCSearchResponse(hitCount = 5, nextCursorMark = "AoK", resultList = EuropePMCResultList(result = page)))

        val searched = service.search(query = "aspirin", batchSize = 20).getOrThrow()

        assertEquals(listOf("1", "5"), searched.articles.map { it.pmid })
        assertEquals(listOf(RetrievalShortfall(SearchProvider.EUROPE_PMC, MALFORMED, 3)), searched.shortfalls)
        assertEquals("every record Europe PMC sent counts as received", 5, searched.resultsReceived)
    }

    // ==================== Helpers ====================

    /** Answer every search with this response. */
    private fun answer(response: EuropePMCSearchResponse) {
        coEvery { api.search(any(), any(), any(), any(), any()) } returns Response.success(response)
    }

    /** A result list of readable articles. */
    private fun results(count: Int): EuropePMCResultList =
        EuropePMCResultList(result = (1..count).map { article("$it", "Article $it") })

    /** One article. */
    private fun article(pmid: String, title: String?): EuropePMCArticle =
        EuropePMCArticle(pmid = pmid, title = title, source = "MED")

    /** The failure a result carries, asserting it is a Europe PMC source failure without a cause. */
    private fun failureOf(result: Result<EuropePMCSearchResult>): RequestFailure {
        val error = result.exceptionOrNull()
        assertTrue("expected a SourceRequestException, got $error (${result.getOrNull()})", error is SourceRequestException)
        error as SourceRequestException
        assertEquals(SearchProvider.EUROPE_PMC, error.provider)
        assertNull("the failure kept its cause", error.cause)
        return error.failure
    }

    /** Assert that no logged line contains this text. */
    private fun assertNothingLogged(text: String) {
        for (line in Log.lines) {
            assertFalse("logged \"$text\": $line", line.contains(text))
        }
    }

    private companion object {
        val MALFORMED = RequestFailure(RequestFailureKind.MALFORMED_RESPONSE)
        val INCOMPLETE = RequestFailure(RequestFailureKind.INCOMPLETE_RESPONSE)
    }
}
