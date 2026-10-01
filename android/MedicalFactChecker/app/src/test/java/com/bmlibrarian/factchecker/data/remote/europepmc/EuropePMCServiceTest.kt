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

import com.bmlibrarian.factchecker.domain.model.RequestFailure
import com.bmlibrarian.factchecker.domain.model.RequestFailureKind
import com.bmlibrarian.factchecker.domain.model.SourceRequestException
import com.bmlibrarian.factchecker.util.Constants
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.mockk
import kotlinx.coroutines.test.runTest
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
 * Unit tests for EuropePMCService.
 *
 * Tests cover:
 * - Search operations with cursor-based pagination
 * - Full text XML retrieval
 * - Error handling for various failure modes
 * - Preprint filtering
 * - Retry logic for transient failures
 * - Document entity conversion
 */
class EuropePMCServiceTest {

    private lateinit var api: EuropePMCApi
    private lateinit var service: EuropePMCService

    @Before
    fun setup() {
        api = mockk()
        service = EuropePMCService(api)
    }

    // ==================== Search Success Tests ====================

    @Test
    fun `search returns articles on successful response`() = runTest {
        // Arrange
        coEvery {
            api.search(any(), any(), any(), any(), any())
        } returns Response.success(
            EuropePMCSearchResponse(
                hitCount = 100,
                nextCursorMark = "cursor123",
                resultList = EuropePMCResultList(
                    result = listOf(
                        createSampleArticle("12345", "Test Article 1"),
                        createSampleArticle("67890", "Test Article 2")
                    )
                )
            )
        )

        // Act
        val result = service.search(query = "aspirin cardiovascular", resultsReceived = 0)

        // Assert
        assertTrue(result.isSuccess)
        val searchResult = result.getOrNull()!!
        assertEquals(2, searchResult.articles.size)
        assertEquals(100, searchResult.totalResults)
        assertEquals("cursor123", searchResult.nextCursor)
        assertTrue(searchResult.hasMore)
    }

    @Test
    fun `search returns empty result when no articles found`() = runTest {
        // Arrange
        coEvery {
            api.search(any(), any(), any(), any(), any())
        } returns Response.success(
            EuropePMCSearchResponse(
                hitCount = 0,
                nextCursorMark = "*",
                resultList = EuropePMCResultList(result = emptyList())
            )
        )

        // Act
        val result = service.search(query = "nonexistent query", resultsReceived = 0)

        // Assert
        assertTrue(result.isSuccess)
        val searchResult = result.getOrNull()!!
        assertTrue(searchResult.articles.isEmpty())
        assertEquals(0, searchResult.totalResults)
        assertFalse(searchResult.hasMore)
    }

    @Test
    fun `search uses initial cursor for first page`() = runTest {
        // Arrange
        coEvery {
            api.search(
                query = any(),
                resultType = any(),
                pageSize = any(),
                cursorMark = EuropePMCApi.INITIAL_CURSOR,
                format = any()
            )
        } returns Response.success(
            EuropePMCSearchResponse(
                hitCount = 10,
                resultList = EuropePMCResultList(
                    result = listOf(createSampleArticle("12345", "Test"))
                )
            )
        )

        // Act
        service.search(query = "test", cursor = null, resultsReceived = 0)

        // Assert
        coVerify {
            api.search(any(), any(), any(), cursorMark = "*", any())
        }
    }

    @Test
    fun `search uses provided cursor for pagination`() = runTest {
        // Arrange
        val cursor = "AoJwpOH4xgE="
        coEvery {
            api.search(
                query = any(),
                resultType = any(),
                pageSize = any(),
                cursorMark = cursor,
                format = any()
            )
        } returns Response.success(
            EuropePMCSearchResponse(
                hitCount = 100,
                nextCursorMark = "nextCursor",
                resultList = EuropePMCResultList(
                    result = listOf(createSampleArticle("12345", "Test"))
                )
            )
        )

        // Act
        service.search(query = "test", cursor = cursor, resultsReceived = 0)

        // Assert
        coVerify {
            api.search(any(), any(), any(), cursorMark = cursor, any())
        }
    }

    @Test
    fun `search respects batch size parameter`() = runTest {
        // Arrange
        val batchSize = 50
        coEvery {
            api.search(
                query = any(),
                resultType = any(),
                pageSize = batchSize,
                cursorMark = any(),
                format = any()
            )
        } returns Response.success(
            EuropePMCSearchResponse(
                hitCount = 100,
                resultList = EuropePMCResultList(
                    result = listOf(createSampleArticle("12345", "Test"))
                )
            )
        )

        // Act
        service.search(query = "test", batchSize = batchSize, resultsReceived = 0)

        // Assert
        coVerify {
            api.search(any(), any(), pageSize = batchSize, any(), any())
        }
    }

    // ==================== Preprint Filtering Tests ====================

    @Test
    fun `search filters preprints by default`() = runTest {
        // Arrange
        coEvery {
            api.search(
                query = match { it.contains("(SRC:MED OR SRC:PMC)") },
                resultType = any(),
                pageSize = any(),
                cursorMark = any(),
                format = any()
            )
        } returns Response.success(
            EuropePMCSearchResponse(
                hitCount = 10,
                resultList = EuropePMCResultList(
                    result = listOf(createSampleArticle("12345", "Test"))
                )
            )
        )

        // Act
        service.search(query = "aspirin", includePreprints = false, resultsReceived = 0)

        // Assert
        coVerify {
            api.search(
                query = "(aspirin) AND (SRC:MED OR SRC:PMC)",
                resultType = any(),
                pageSize = any(),
                cursorMark = any(),
                format = any()
            )
        }
    }

    @Test
    fun `search includes preprints when specified`() = runTest {
        // Arrange
        coEvery {
            api.search(
                query = "aspirin",
                resultType = any(),
                pageSize = any(),
                cursorMark = any(),
                format = any()
            )
        } returns Response.success(
            EuropePMCSearchResponse(
                hitCount = 10,
                resultList = EuropePMCResultList(
                    result = listOf(createSampleArticle("12345", "Test", source = "PPR"))
                )
            )
        )

        // Act
        service.search(query = "aspirin", includePreprints = true, resultsReceived = 0)

        // Assert
        coVerify {
            api.search(
                query = "aspirin",
                resultType = any(),
                pageSize = any(),
                cursorMark = any(),
                format = any()
            )
        }
    }

    // ==================== Pagination Tests ====================

    @Test
    fun `search sets hasMore false when cursor repeats`() = runTest {
        // Arrange
        val currentCursor = "sameCursor"
        coEvery {
            api.search(any(), any(), any(), cursorMark = currentCursor, any())
        } returns Response.success(
            EuropePMCSearchResponse(
                hitCount = 100,
                nextCursorMark = currentCursor, // Same cursor indicates end
                resultList = EuropePMCResultList(
                    result = listOf(createSampleArticle("12345", "Test"))
                )
            )
        )

        // Act
        val result = service.search(query = "test", cursor = currentCursor, resultsReceived = 0)

        // Assert
        assertTrue(result.isSuccess)
        assertFalse(result.getOrNull()!!.hasMore)
        assertNull(result.getOrNull()!!.nextCursor)
    }

    @Test
    fun `search sets hasMore false when nextCursor is initial cursor`() = runTest {
        // Arrange
        coEvery {
            api.search(any(), any(), any(), any(), any())
        } returns Response.success(
            EuropePMCSearchResponse(
                hitCount = 1,
                nextCursorMark = "*", // Initial cursor indicates no more
                resultList = EuropePMCResultList(
                    result = listOf(createSampleArticle("12345", "Test"))
                )
            )
        )

        // Act
        val result = service.search(query = "test", resultsReceived = 0)

        // Assert
        assertTrue(result.isSuccess)
        assertFalse(result.getOrNull()!!.hasMore)
    }

    @Test
    fun `search sets hasMore false when result list is empty`() = runTest {
        // Arrange: an empty page is the end only when no hits remain; an empty
        // page the hit count promised results for is a failed request (#252)
        coEvery {
            api.search(any(), any(), any(), any(), any())
        } returns Response.success(
            EuropePMCSearchResponse(
                hitCount = 20,
                nextCursorMark = "nextCursor",
                resultList = EuropePMCResultList(result = emptyList())
            )
        )

        // Act
        val result = service.search(query = "test", cursor = "AoJ", batchSize = 20, resultsReceived = 20)

        // Assert
        assertTrue(result.isSuccess)
        assertFalse(result.getOrNull()!!.hasMore)
    }

    // ==================== Error Handling Tests ====================

    @Test
    fun `search returns error on HTTP failure`() = runTest {
        // Arrange
        coEvery {
            api.search(any(), any(), any(), any(), any())
        } returns Response.error(500, "Server error".toResponseBody(null))

        // Act
        val result = service.search(query = "test", resultsReceived = 0)

        // Assert
        assertEquals(RequestFailure(RequestFailureKind.HTTP_STATUS, 500), (result.exceptionOrNull() as SourceRequestException).failure)
    }

    @Test
    fun `search returns error on invalid request`() = runTest {
        // Arrange
        coEvery {
            api.search(any(), any(), any(), any(), any())
        } returns Response.error(400, "Bad request".toResponseBody(null))

        // Act
        val result = service.search(query = "invalid query", resultsReceived = 0)

        // Assert
        assertEquals(RequestFailure(RequestFailureKind.HTTP_STATUS, 400), (result.exceptionOrNull() as SourceRequestException).failure)
    }

    @Test
    fun `search returns error when response body is null`() = runTest {
        // Arrange
        coEvery {
            api.search(any(), any(), any(), any(), any())
        } returns Response.success(null)

        // Act
        val result = service.search(query = "test", resultsReceived = 0)

        // Assert
        assertEquals(
            RequestFailure(RequestFailureKind.MALFORMED_RESPONSE),
            (result.exceptionOrNull() as SourceRequestException).failure
        )
    }

    // ==================== Retry Logic Tests ====================

    @Test
    fun `search retries on network failure and succeeds`() = runTest {
        // Arrange
        var callCount = 0
        coEvery {
            api.search(any(), any(), any(), any(), any())
        } answers {
            callCount++
            if (callCount < 3) {
                throw IOException("Network error")
            }
            Response.success(
                EuropePMCSearchResponse(
                    hitCount = 1,
                    resultList = EuropePMCResultList(
                        result = listOf(createSampleArticle("12345", "Test"))
                    )
                )
            )
        }

        // Act
        val result = service.search(query = "test", resultsReceived = 0)

        // Assert
        assertTrue(result.isSuccess)
        assertEquals(3, callCount)
    }

    @Test
    fun `search retries on server error and succeeds`() = runTest {
        // Arrange
        var callCount = 0
        coEvery {
            api.search(any(), any(), any(), any(), any())
        } answers {
            callCount++
            if (callCount < 2) {
                Response.error(503, "Service unavailable".toResponseBody(null))
            } else {
                Response.success(
                    EuropePMCSearchResponse(
                        hitCount = 1,
                        resultList = EuropePMCResultList(
                            result = listOf(createSampleArticle("12345", "Test"))
                        )
                    )
                )
            }
        }

        // Act
        val result = service.search(query = "test", resultsReceived = 0)

        // Assert
        assertTrue(result.isSuccess)
        assertEquals(2, callCount)
    }

    // ==================== Full Text Retrieval Tests (#434) ====================

    @Test
    fun `fetchFullTextXml serves the XML`() = runTest {
        val xml = "<article><body><p>Full text</p></body></article>"
        coEvery { api.getFullTextXml("PMC12345") } returns Response.success(xml)

        assertEquals(FullTextXmlFetch.Served(xml), service.fetchFullTextXml("PMC12345"))
    }

    @Test
    fun `fetchFullTextXml normalizes a PMC ID whatever its prefix case`() = runTest {
        coEvery { api.getFullTextXml("PMC12345") } returns Response.success("<article/>")

        // pmc12345 used to become PMCpmc12345, which Europe PMC answers 404
        for (identifier in listOf("12345", "PMC12345", "pmc12345", " PMC12345 ")) {
            service.fetchFullTextXml(identifier)
        }

        coVerify(exactly = 4) { api.getFullTextXml("PMC12345") }
    }

    @Test
    fun `fetchFullTextXml asks for a preprint by its record ID`() = runTest {
        coEvery { api.getFullTextXml("PPR1316954") } returns Response.success("<article/>")

        service.fetchFullTextXml("ppr1316954")

        coVerify { api.getFullTextXml("PPR1316954") }
    }

    @Test
    fun `fetchFullTextXml never sends an identifier that is not an accession`() = runTest {
        val fetch = service.fetchFullTextXml("10.1234/example")

        assertEquals(
            FullTextXmlFetch.Unreachable(RequestFailure(RequestFailureKind.REQUEST_FAILED)),
            fetch
        )
        coVerify(exactly = 0) { api.getFullTextXml(any()) }
    }

    @Test
    fun `fetchFullTextXml reads a 404 as absent`() = runTest {
        coEvery { api.getFullTextXml(any()) } returns Response.error(404, "Not found".toResponseBody(null))

        assertEquals(FullTextXmlFetch.Absent, service.fetchFullTextXml("PMC99999"))
    }

    @Test
    fun `fetchFullTextXml reads a blank body as an incomplete response, not an absence`() = runTest {
        val incomplete = FullTextXmlFetch.Unreachable(RequestFailure(RequestFailureKind.INCOMPLETE_RESPONSE))
        for (body in listOf(null, "", "  \n\t ")) {
            coEvery { api.getFullTextXml(any()) } returns Response.success(body)
            assertEquals("body ${body?.length}", incomplete, service.fetchFullTextXml("PMC12345"))
        }
    }

    @Test
    fun `fetchFullTextXml keeps a throttle that outlasts its retries as a 429`() = runTest {
        var callCount = 0
        coEvery { api.getFullTextXml(any()) } answers {
            callCount++
            Response.error(429, "".toResponseBody(null))
        }

        val fetch = service.fetchFullTextXml("PMC12345")

        assertEquals(FullTextXmlFetch.Unreachable(RequestFailure(RequestFailureKind.HTTP_STATUS, 429)), fetch)
        assertEquals("retried before giving up", Constants.NETWORK_MAX_RETRIES + 1, callCount)
    }

    @Test
    fun `fetchFullTextXml reads a server error as unreachable, not absent`() = runTest {
        // What Europe PMC answered for non-open-access PMC IDs on 2026-09-28 (#432)
        coEvery { api.getFullTextXml(any()) } returns Response.error(500, "".toResponseBody(null))

        assertEquals(
            FullTextXmlFetch.Unreachable(RequestFailure(RequestFailureKind.HTTP_STATUS, 500)),
            service.fetchFullTextXml("PMC12345")
        )
    }

    @Test
    fun `fetchFullTextXml asks a preprint's 500 once`() = runTest {
        // Europe PMC's steady answer for a preprint it will not serve (#451)
        var callCount = 0
        coEvery { api.getFullTextXml(any()) } answers {
            callCount++
            Response.error(500, "".toResponseBody(null))
        }

        val fetch = service.fetchFullTextXml("PPR1316954")

        assertEquals(FullTextXmlFetch.Unreachable(RequestFailure(RequestFailureKind.HTTP_STATUS, 500)), fetch)
        assertEquals(1, callCount)
    }

    @Test
    fun `fetchFullTextXml still retries a preprint's throttle`() = runTest {
        var callCount = 0
        coEvery { api.getFullTextXml(any()) } answers {
            callCount++
            Response.error(429, "".toResponseBody(null))
        }

        service.fetchFullTextXml("PPR1316954")

        assertEquals(Constants.NETWORK_MAX_RETRIES + 1, callCount)
    }

    @Test
    fun `fetchFullTextXml keeps a preprint's 404 an absence asked once`() = runTest {
        var callCount = 0
        coEvery { api.getFullTextXml(any()) } answers {
            callCount++
            Response.error(404, "".toResponseBody(null))
        }

        assertEquals(FullTextXmlFetch.Absent, service.fetchFullTextXml("PPR1316954"))
        assertEquals(1, callCount)
    }

    @Test
    fun `fetchFullTextXml still retries a preprint's gateway faults`() = runTest {
        for (status in listOf(502, 503, 504)) {
            var callCount = 0
            coEvery { api.getFullTextXml(any()) } answers {
                callCount++
                Response.error(status, "".toResponseBody(null))
            }

            service.fetchFullTextXml("PPR1316954")

            assertEquals("status $status", Constants.NETWORK_MAX_RETRIES + 1, callCount)
        }
    }

    @Test
    fun `fetchFullTextXml asks a padded lowercase preprint accession's 500 once`() = runTest {
        var callCount = 0
        coEvery { api.getFullTextXml(any()) } answers {
            callCount++
            Response.error(500, "".toResponseBody(null))
        }

        service.fetchFullTextXml(" ppr1316954 ")

        assertEquals(1, callCount)
    }

    @Test
    fun `fetchFullTextXml still retries a PMC article's 500`() = runTest {
        var callCount = 0
        coEvery { api.getFullTextXml(any()) } answers {
            callCount++
            Response.error(500, "".toResponseBody(null))
        }

        service.fetchFullTextXml("PMC12345")

        assertEquals(Constants.NETWORK_MAX_RETRIES + 1, callCount)
    }

    @Test
    fun `fetchFullTextXml keeps a connection failure's kind`() = runTest {
        coEvery { api.getFullTextXml(any()) } throws IOException("Network error")

        assertEquals(
            FullTextXmlFetch.Unreachable(RequestFailure(RequestFailureKind.CONNECTION)),
            service.fetchFullTextXml("PMC12345")
        )
    }

    @Test
    fun `fetchFullTextXml retries a network failure`() = runTest {
        var callCount = 0
        coEvery { api.getFullTextXml(any()) } answers {
            callCount++
            if (callCount < 2) throw IOException("Network error")
            Response.success("<article>Content</article>")
        }

        assertEquals(FullTextXmlFetch.Served("<article>Content</article>"), service.fetchFullTextXml("PMC12345"))
        assertEquals(2, callCount)
    }

    @Test
    fun `fetchFullTextXml keeps a timeout's kind`() = runTest {
        coEvery { api.getFullTextXml(any()) } throws SocketTimeoutException("timed out")

        assertEquals(
            FullTextXmlFetch.Unreachable(RequestFailure(RequestFailureKind.TIMEOUT)),
            service.fetchFullTextXml("PMC12345")
        )
    }

    @Test
    fun `fetchFullTextXml does not retry a status it does not model`() = runTest {
        coEvery { api.getFullTextXml(any()) } returns Response.error(403, "".toResponseBody(null))

        assertEquals(
            FullTextXmlFetch.Unreachable(RequestFailure(RequestFailureKind.HTTP_STATUS, 403)),
            service.fetchFullTextXml("PMC12345")
        )
        coVerify(exactly = 1) { api.getFullTextXml(any()) }
    }

    /** A cancelled fetch is not a dead source: it must not become an Unreachable. */
    @Test
    fun `fetchFullTextXml lets a cancellation through`() = runTest {
        coEvery { api.getFullTextXml(any()) } throws CancellationException("cancelled")

        val thrown = runCatching { service.fetchFullTextXml("PMC12345") }.exceptionOrNull()

        assertTrue("$thrown", thrown is CancellationException)
    }

    // ==================== Document Entity Conversion Tests ====================

    @Test
    fun `toDocumentEntities converts articles correctly`() {
        // Arrange
        val articles = listOf(
            EuropePMCArticle(
                pmid = "12345",
                pmcid = "PMC123",
                doi = "10.1234/test",
                title = "Test Article",
                abstractText = "This is the abstract",
                authorList = AuthorList(
                    author = listOf(
                        Author(fullName = "John Smith"),
                        Author(lastName = "Doe", firstName = "Jane")
                    )
                ),
                journalTitle = "Test Journal",
                pubYear = "2024",
                pubDate = "2024-01-15",
                meshHeadingList = MeshHeadingList(
                    meshHeading = listOf(
                        MeshHeading(descriptorName = "Term1"),
                        MeshHeading(descriptorName = "Term2")
                    )
                ),
                source = "MED"
            ),
            EuropePMCArticle(
                pmid = "67890",
                title = "Another Article",
                source = "PMC"
            )
        )

        // Act
        val entities = service.toDocumentEntities(
            articles = articles,
            sessionId = "session-123",
            batchNumber = 2,
            startPosition = 10
        )

        // Assert
        assertEquals(2, entities.size)

        val first = entities[0]
        assertEquals("session-123", first.sessionId)
        assertEquals("12345", first.pmid)
        assertEquals("PMC123", first.pmcId)
        assertEquals("10.1234/test", first.doi)
        assertEquals("Test Article", first.title)
        assertEquals("This is the abstract", first.abstractText)
        assertEquals(listOf("John Smith", "Doe Jane"), first.authors)
        assertEquals("Test Journal", first.journal)
        assertEquals(2024, first.publicationYear)
        assertEquals(listOf("Term1", "Term2"), first.meshTerms)
        assertEquals(Constants.SOURCE_EUROPE_PMC, first.source)
        assertFalse(first.isPreprint)
        assertEquals(2, first.batchNumber)
        assertEquals(10, first.resultPosition)

        val second = entities[1]
        assertEquals("67890", second.pmid)
        assertEquals(11, second.resultPosition)
    }

    @Test
    fun `toDocumentEntities handles preprint source`() {
        // Arrange
        val articles = listOf(
            EuropePMCArticle(
                pmid = "12345",
                title = "Preprint Article",
                source = "PPR"
            )
        )

        // Act
        val entities = service.toDocumentEntities(
            articles = articles,
            sessionId = "session-123"
        )

        // Assert
        val entity = entities.first()
        assertEquals(Constants.SOURCE_PREPRINT, entity.source)
        assertTrue(entity.isPreprint)
    }

    @Test
    fun `toDocumentEntities skips articles without title`() {
        // Arrange
        val articles = listOf(
            EuropePMCArticle(
                pmid = "12345",
                title = null
            ),
            EuropePMCArticle(
                pmid = "67890",
                title = ""
            ),
            EuropePMCArticle(
                pmid = "11111",
                title = "Valid Title"
            )
        )

        // Act
        val entities = service.toDocumentEntities(
            articles = articles,
            sessionId = "session-123"
        )

        // Assert
        assertEquals(1, entities.size)
        assertEquals("11111", entities.first().pmid)
    }

    @Test
    fun `toDocumentEntities parses author string fallback`() {
        // Arrange
        val articles = listOf(
            EuropePMCArticle(
                pmid = "12345",
                title = "Test Article",
                authorString = "Smith J, Doe J, Brown A"
            )
        )

        // Act
        val entities = service.toDocumentEntities(
            articles = articles,
            sessionId = "session-123"
        )

        // Assert
        assertEquals(listOf("Smith J", "Doe J", "Brown A"), entities.first().authors)
    }

    @Test
    fun `toDocumentEntities handles missing optional fields`() {
        // Arrange
        val articles = listOf(
            EuropePMCArticle(
                pmid = "12345",
                title = "Minimal Article"
            )
        )

        // Act
        val entities = service.toDocumentEntities(
            articles = articles,
            sessionId = "session-123"
        )

        // Assert
        val entity = entities.first()
        assertNull(entity.doi)
        assertNull(entity.pmcId)
        assertNull(entity.abstractText)
        assertTrue(entity.authors.isEmpty())
        assertTrue(entity.meshTerms.isEmpty())
    }

    @Test
    fun `toDocumentEntities uses firstPublicationDate as fallback`() {
        // Arrange
        val articles = listOf(
            EuropePMCArticle(
                pmid = "12345",
                title = "Test Article",
                pubDate = null,
                firstPublicationDate = "2024-03-15"
            )
        )

        // Act
        val entities = service.toDocumentEntities(
            articles = articles,
            sessionId = "session-123"
        )

        // Assert
        assertEquals("2024-03-15", entities.first().publicationDate)
    }

    // ==================== Helper Methods ====================

    /**
     * Creates a sample EuropePMCArticle for testing.
     */
    private fun createSampleArticle(
        pmid: String,
        title: String,
        source: String = "MED"
    ): EuropePMCArticle {
        return EuropePMCArticle(
            pmid = pmid,
            title = title,
            source = source,
            abstractText = "Abstract for $title"
        )
    }
}
