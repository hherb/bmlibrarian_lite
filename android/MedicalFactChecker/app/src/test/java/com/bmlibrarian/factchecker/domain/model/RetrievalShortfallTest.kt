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

package com.bmlibrarian.factchecker.domain.model

import kotlinx.serialization.SerializationException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException
import java.io.InterruptedIOException
import java.net.ConnectException
import java.net.SocketTimeoutException
import java.net.UnknownHostException

/**
 * The failure record a search carries from the HTTP layer to the reader (#252).
 *
 * Mirrors `tests/test_retrieval_shortfall.py`: the strings are the
 * cross-platform contract in `doc/cross_platform/search_failure_reporting.md`.
 */
class RetrievalShortfallTest {

    // ==================== The kinds ====================

    @Test
    fun `the persisted values are the contract's`() {
        // Renaming one would make stored shortfalls read as a failed request
        assertEquals(
            setOf(
                "timeout", "connection", "http_status", "redirect_refused",
                "service_error", "malformed_response", "incomplete_response", "request_failed"
            ),
            RequestFailureKind.entries.map { it.persistedValue }.toSet()
        )
    }

    @Test
    fun `every kind has a reason`() {
        for (kind in RequestFailureKind.entries) {
            assertTrue("$kind has no reason", RequestFailure(kind).describe().isNotBlank())
        }
    }

    @Test
    fun `a persisted value reads back as its kind, and nothing else does`() {
        for (kind in RequestFailureKind.entries) {
            assertEquals(kind, RequestFailureKind.fromPersisted(kind.persistedValue))
        }
        assertNull(RequestFailureKind.fromPersisted("TIMEOUT"))
        assertNull(RequestFailureKind.fromPersisted("from-a-newer-build"))
        assertNull(RequestFailureKind.fromPersisted(null))
    }

    // ==================== Describing a failure ====================

    @Test
    fun `each kind has its own reason`() {
        val expected = listOf(
            RequestFailure(RequestFailureKind.HTTP_STATUS, 429) to "HTTP 429 Too Many Requests",
            RequestFailure(RequestFailureKind.HTTP_STATUS, 503) to "HTTP 503 Service Unavailable",
            RequestFailure(RequestFailureKind.HTTP_STATUS, 599) to "HTTP 599",
            RequestFailure(RequestFailureKind.HTTP_STATUS) to "an HTTP error",
            RequestFailure(RequestFailureKind.REDIRECT_REFUSED, 307) to "a redirect (HTTP 307) was refused",
            RequestFailure(RequestFailureKind.REDIRECT_REFUSED) to "a redirect was refused",
            RequestFailure(RequestFailureKind.TIMEOUT) to "the request timed out",
            RequestFailure(RequestFailureKind.CONNECTION) to "the connection failed",
            RequestFailure(RequestFailureKind.SERVICE_ERROR) to "the service reported an error",
            RequestFailure(RequestFailureKind.MALFORMED_RESPONSE) to "the response could not be read",
            RequestFailure(RequestFailureKind.INCOMPLETE_RESPONSE) to "the response was incomplete",
            RequestFailure(RequestFailureKind.REQUEST_FAILED) to "the request failed",
        )

        for ((failure, reason) in expected) {
            assertEquals(reason, failure.describe())
        }
    }

    @Test
    fun `the reason phrases are the contract's, not a library's`() {
        // Python 3.13 renamed 413 and 414; the contract fixes the wording
        assertEquals("HTTP 413 Content Too Large", RequestFailure(RequestFailureKind.HTTP_STATUS, 413).describe())
        assertEquals("HTTP 414 URI Too Long", RequestFailure(RequestFailureKind.HTTP_STATUS, 414).describe())
        assertEquals("HTTP 422", RequestFailure(RequestFailureKind.HTTP_STATUS, 422).describe())
        assertEquals("HTTP 401 Unauthorized", RequestFailure(RequestFailureKind.HTTP_STATUS, 401).describe())
    }

    // ==================== Constructing a failure ====================

    @Test
    fun `a status on a failure that is no HTTP answer is refused`() {
        val error = assertThrows(IllegalArgumentException::class.java) {
            RequestFailure(RequestFailureKind.TIMEOUT, 429)
        }
        assertTrue(error.message.orEmpty().contains("carries no HTTP status"))
    }

    @Test
    fun `a status that is no HTTP status is refused`() {
        for (status in listOf(99, 1000, -429)) {
            val error = assertThrows(IllegalArgumentException::class.java) {
                RequestFailure(RequestFailureKind.HTTP_STATUS, status)
            }
            assertTrue(error.message.orEmpty().contains("HTTP status code"))
        }
    }

    @Test
    fun `an unsuccessful status is an HTTP error, and a redirect a refused one`() {
        assertEquals(RequestFailure(RequestFailureKind.HTTP_STATUS, 429), RequestFailure.forHttpStatus(429))
        assertEquals(RequestFailure(RequestFailureKind.HTTP_STATUS, 400), RequestFailure.forHttpStatus(400))
        for (status in listOf(300, 301, 302, 303, 307, 308, 399)) {
            assertEquals(
                RequestFailure(RequestFailureKind.REDIRECT_REFUSED, status),
                RequestFailure.forHttpStatus(status)
            )
        }
    }

    // ==================== Classifying a transport failure ====================

    @Test
    fun `a timeout is a timeout, however the transport raised it`() {
        // OkHttp's call timeout is a bare InterruptedIOException("timeout")
        assertEquals(RequestFailureKind.TIMEOUT, RequestFailure.fromException(SocketTimeoutException()).kind)
        assertEquals(RequestFailureKind.TIMEOUT, RequestFailure.fromException(InterruptedIOException("timeout")).kind)
    }

    @Test
    fun `a connection that could not be made or broke is a connection failure`() {
        for (error in listOf(ConnectException(), UnknownHostException(), IOException("unexpected end of stream"))) {
            assertEquals("$error", RequestFailureKind.CONNECTION, RequestFailure.fromException(error).kind)
        }
    }

    @Test
    fun `a body the converter could not read is malformed`() {
        val failure = RequestFailure.fromException(SerializationException("Unexpected JSON token"))

        assertEquals(RequestFailure(RequestFailureKind.MALFORMED_RESPONSE), failure)
    }

    @Test
    fun `any other error is a failed request`() {
        assertEquals(
            RequestFailure(RequestFailureKind.REQUEST_FAILED),
            RequestFailure.fromException(IllegalStateException("keystore"))
        )
    }

    // ==================== Retrying ====================

    @Test
    fun `only a transient failure is worth another attempt`() {
        val transient = listOf(
            RequestFailure(RequestFailureKind.TIMEOUT),
            RequestFailure(RequestFailureKind.CONNECTION),
            RequestFailure(RequestFailureKind.HTTP_STATUS, 429),
            RequestFailure(RequestFailureKind.HTTP_STATUS, 503),
        )
        val lasting = listOf(
            RequestFailure(RequestFailureKind.HTTP_STATUS, 400),
            RequestFailure(RequestFailureKind.HTTP_STATUS),
            RequestFailure(RequestFailureKind.REDIRECT_REFUSED, 307),
            RequestFailure(RequestFailureKind.SERVICE_ERROR),
            RequestFailure(RequestFailureKind.MALFORMED_RESPONSE),
            RequestFailure(RequestFailureKind.INCOMPLETE_RESPONSE),
            RequestFailure(RequestFailureKind.REQUEST_FAILED),
        )

        transient.forEach { assertTrue("$it", it.isRetryable) }
        lasting.forEach { assertFalse("$it", it.isRetryable) }
    }

    // ==================== Describing a shortfall ====================

    @Test
    fun `a source that could not be searched is named`() {
        assertEquals("PubMed could not be searched (HTTP 429 Too Many Requests)", PUBMED_DOWN.describe())
    }

    @Test
    fun `a partial retrieval counts what is missing, thousands grouped`() {
        val shortfall = RetrievalShortfall(SearchProvider.EUROPE_PMC, TIMED_OUT, recordsMissing = 1200)

        assertEquals("1,200 Europe PMC records could not be retrieved (the request timed out)", shortfall.describe())
    }

    @Test
    fun `one missing record is singular`() {
        val shortfall = RetrievalShortfall(SearchProvider.PUBMED, TIMED_OUT, recordsMissing = 1)

        assertTrue(shortfall.describe().startsWith("1 PubMed record could not"))
    }

    @Test
    fun `an alternative search that could not be run says so, not that the source was never searched`() {
        // User's decision (2026-09-15): the original query's results are in the report
        val shortfall = RetrievalShortfall(SearchProvider.PUBMED, RATE_LIMITED, query = ShortfallQuery.ALTERNATIVE)

        assertEquals(
            "an alternative search of PubMed could not be completed (HTTP 429 Too Many Requests)",
            shortfall.describe()
        )
    }

    @Test
    fun `records an alternative search lost are counted as its own`() {
        val one = RetrievalShortfall(SearchProvider.EUROPE_PMC, TIMED_OUT, 1, ShortfallQuery.ALTERNATIVE)
        val many = RetrievalShortfall(SearchProvider.EUROPE_PMC, TIMED_OUT, 1200, ShortfallQuery.ALTERNATIVE)

        assertEquals(
            "1 Europe PMC record from an alternative search could not be retrieved (the request timed out)",
            one.describe()
        )
        assertEquals(
            "1,200 Europe PMC records from an alternative search could not be retrieved (the request timed out)",
            many.describe()
        )
    }

    @Test
    fun `a shortfall belongs to the search's own query unless it says otherwise`() {
        assertEquals(ShortfallQuery.ORIGINAL, PUBMED_DOWN.query)
    }

    // ==================== Constructing a shortfall ====================

    @Test
    fun `both providers is no source`() {
        val error = assertThrows(IllegalArgumentException::class.java) {
            RetrievalShortfall(SearchProvider.BOTH, RATE_LIMITED)
        }
        assertTrue(error.message.orEmpty().contains("PubMed or Europe PMC"))
    }

    @Test
    fun `nothing missing is not a shortfall`() {
        for (missing in listOf(0, -1)) {
            val error = assertThrows(IllegalArgumentException::class.java) {
                RetrievalShortfall(SearchProvider.PUBMED, RATE_LIMITED, recordsMissing = missing)
            }
            assertTrue(error.message.orEmpty().contains("at least one record"))
        }
    }

    // ==================== The errors ====================

    @Test
    fun `a source error names the source and the reason, and keeps no cause`() {
        val error = SourceRequestException(SearchProvider.EUROPE_PMC, TIMED_OUT)

        assertEquals("Europe PMC could not be searched (the request timed out)", error.message)
        assertNull(error.cause)
    }

    @Test
    fun `a source error names one source`() {
        assertThrows(IllegalArgumentException::class.java) {
            SourceRequestException(SearchProvider.BOTH, TIMED_OUT)
        }
    }

    @Test
    fun `a failed search's message names every shortfall`() {
        val error = SearchFailedException(
            listOf(PUBMED_DOWN, RetrievalShortfall(SearchProvider.EUROPE_PMC, TIMED_OUT))
        )

        assertEquals(
            "The search could not be completed: PubMed could not be searched " +
                "(HTTP 429 Too Many Requests); Europe PMC could not be searched " +
                "(the request timed out).",
            error.message
        )
    }

    @Test
    fun `a failed search naming nothing is refused`() {
        // "The search could not be completed: ." tells the user nothing
        val error = assertThrows(IllegalArgumentException::class.java) { SearchFailedException(emptyList()) }
        assertTrue(error.message.orEmpty().contains("at least one shortfall"))
    }

    @Test
    fun `a failed search keeps its own copy of the shortfalls`() {
        val shortfalls = mutableListOf(PUBMED_DOWN)
        val error = SearchFailedException(shortfalls)

        shortfalls.add(RetrievalShortfall(SearchProvider.EUROPE_PMC, TIMED_OUT))

        assertEquals(listOf(PUBMED_DOWN), error.shortfalls)
    }

    private companion object {
        val RATE_LIMITED = RequestFailure(RequestFailureKind.HTTP_STATUS, 429)
        val TIMED_OUT = RequestFailure(RequestFailureKind.TIMEOUT)
        val PUBMED_DOWN = RetrievalShortfall(SearchProvider.PUBMED, RATE_LIMITED)
    }
}
