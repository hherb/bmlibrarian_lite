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

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * What the reader is told about a search that failures left incomplete (#252).
 *
 * Mirrors `tests/test_retrieval_shortfall.py` and
 * `tests/test_search_shortfall_reporting.py`; the sentences are the contract's.
 */
class SearchFailureReportingTest {

    // ==================== Building shortfalls ====================

    @Test
    fun `nothing is recorded without a loss`() {
        assertEquals(emptyList<RetrievalShortfall>(), SearchFailureReporting.shortfallsForMissingRecords(SearchProvider.PUBMED, null, 0))
        assertEquals(emptyList<RetrievalShortfall>(), SearchFailureReporting.shortfallsForMissingRecords(SearchProvider.PUBMED, RATE_LIMITED, 0))
        assertEquals(emptyList<RetrievalShortfall>(), SearchFailureReporting.shortfallsForMissingRecords(SearchProvider.PUBMED, RATE_LIMITED, -2))
    }

    @Test
    fun `a loss without a reason is still recorded`() {
        // The count degrades to a failed request; it is never dropped
        assertEquals(
            listOf(RetrievalShortfall(SearchProvider.PUBMED, RequestFailure(RequestFailureKind.REQUEST_FAILED), 5)),
            SearchFailureReporting.shortfallsForMissingRecords(SearchProvider.PUBMED, null, 5)
        )
    }

    @Test
    fun `a loss is recorded with its count`() {
        assertEquals(
            listOf(RetrievalShortfall(SearchProvider.EUROPE_PMC, UNAVAILABLE, 3)),
            SearchFailureReporting.shortfallsForMissingRecords(SearchProvider.EUROPE_PMC, UNAVAILABLE, 3)
        )
    }

    @Test
    fun `the same failure of the same source is reported once`() {
        val shortfalls = listOf(
            RetrievalShortfall(SearchProvider.PUBMED, RATE_LIMITED, 100),
            RetrievalShortfall(SearchProvider.PUBMED, UNAVAILABLE, 7),
            RetrievalShortfall(SearchProvider.PUBMED, RATE_LIMITED, 50),
            RetrievalShortfall(SearchProvider.EUROPE_PMC, RATE_LIMITED, 1),
        )

        assertEquals(
            listOf(
                RetrievalShortfall(SearchProvider.PUBMED, RATE_LIMITED, 150),
                RetrievalShortfall(SearchProvider.PUBMED, UNAVAILABLE, 7),
                RetrievalShortfall(SearchProvider.EUROPE_PMC, RATE_LIMITED, 1),
            ),
            SearchFailureReporting.combinedShortfalls(shortfalls)
        )
    }

    @Test
    fun `a source that could not be searched is not merged into a count`() {
        // "Could not be searched" and "N records missing" are different statements
        val shortfalls = listOf(PUBMED_DOWN, RetrievalShortfall(SearchProvider.PUBMED, RATE_LIMITED, 4))

        assertEquals(shortfalls, SearchFailureReporting.combinedShortfalls(shortfalls))
    }

    @Test
    fun `a source that could not be searched is reported once, however often it failed`() {
        val unavailable = RetrievalShortfall(SearchProvider.PUBMED, UNAVAILABLE)
        val shortfalls = listOf(PUBMED_DOWN, RetrievalShortfall(SearchProvider.PUBMED, RATE_LIMITED, 4), PUBMED_DOWN, unavailable)

        assertEquals(
            listOf(PUBMED_DOWN, RetrievalShortfall(SearchProvider.PUBMED, RATE_LIMITED, 4), unavailable),
            SearchFailureReporting.combinedShortfalls(shortfalls)
        )
    }

    @Test
    fun `an alternative search that could not be completed is reported once, however many queries failed`() {
        val lost = RetrievalShortfall(SearchProvider.EUROPE_PMC, RequestFailure(RequestFailureKind.CONNECTION), query = ShortfallQuery.ALTERNATIVE)

        assertEquals(
            listOf(PUBMED_DOWN, lost),
            SearchFailureReporting.combinedShortfalls(listOf(PUBMED_DOWN, lost, lost, lost))
        )
    }

    @Test
    fun `counts too large to add are kept apart, neither overflowing nor cut short`() {
        // A stored count can be any whole number a count holds
        val stored = RetrievalShortfall(SearchProvider.PUBMED, RATE_LIMITED, Int.MAX_VALUE)
        val more = RetrievalShortfall(SearchProvider.PUBMED, RATE_LIMITED, 5)

        assertEquals(listOf(stored, more), SearchFailureReporting.combinedShortfalls(listOf(stored, more)))
    }

    @Test
    fun `the warning an incomplete search shows names what failed`() {
        assertEquals(
            "Incomplete search: PubMed could not be searched (HTTP 429 Too Many Requests).",
            SearchFailureReporting.incompleteSearchWarning(listOf(PUBMED_DOWN))
        )
        assertNull(SearchFailureReporting.incompleteSearchWarning(emptyList()))
    }

    @Test
    fun `a report's notice is split from its text as plain text`() {
        val report = SearchFailureReporting.withSearchShortfallNotice("## Analysis", listOf(PUBMED_DOWN))

        assertEquals(
            "Incomplete search: PubMed could not be searched (HTTP 429 Too Many Requests). " +
                "Everything below rests only on the records that were retrieved." to "## Analysis",
            SearchFailureReporting.splitPlainSearchShortfallNotice(report)
        )
        assertEquals(null to "## Analysis", SearchFailureReporting.splitPlainSearchShortfallNotice("## Analysis"))
    }

    @Test
    fun `an alternative search's loss is not merged into the original query's`() {
        val shortfalls = listOf(
            RetrievalShortfall(SearchProvider.PUBMED, RATE_LIMITED, 20),
            RetrievalShortfall(SearchProvider.PUBMED, RATE_LIMITED, 10, ShortfallQuery.ALTERNATIVE),
            RetrievalShortfall(SearchProvider.PUBMED, RATE_LIMITED, 5, ShortfallQuery.ALTERNATIVE),
        )

        assertEquals(
            listOf(
                RetrievalShortfall(SearchProvider.PUBMED, RATE_LIMITED, 20),
                RetrievalShortfall(SearchProvider.PUBMED, RATE_LIMITED, 15, ShortfallQuery.ALTERNATIVE),
            ),
            SearchFailureReporting.combinedShortfalls(shortfalls)
        )
    }

    @Test
    fun `the combined description keeps every shortfall, in order`() {
        val shortfalls = listOf(PUBMED_DOWN, RetrievalShortfall(SearchProvider.EUROPE_PMC, TIMED_OUT, 5))

        assertEquals(
            "PubMed could not be searched (HTTP 429 Too Many Requests); " +
                "5 Europe PMC records could not be retrieved (the request timed out)",
            SearchFailureReporting.describeSearchShortfalls(shortfalls)
        )
    }

    // ==================== The notice ====================

    @Test
    fun `no shortfall adds no notice`() {
        assertEquals("", SearchFailureReporting.formatSearchShortfallNotice(emptyList()))
        assertEquals("Report.", SearchFailureReporting.withSearchShortfallNotice("Report.", emptyList()))
    }

    @Test
    fun `the notice says the search was incomplete and why`() {
        assertEquals(
            "> **Incomplete search:** PubMed could not be searched (HTTP 429 Too Many Requests). " +
                "Everything below rests only on the records that were retrieved.",
            SearchFailureReporting.formatSearchShortfallNotice(listOf(PUBMED_DOWN))
        )
    }

    @Test
    fun `the notice is followed by a blank line and the text`() {
        assertEquals(
            SearchFailureReporting.formatSearchShortfallNotice(listOf(PUBMED_DOWN)) + "\n\nReport.",
            SearchFailureReporting.withSearchShortfallNotice("Report.", listOf(PUBMED_DOWN))
        )
    }

    @Test
    fun `the notice and the text behind it can be told apart`() {
        val text = "## Evidence Report\n\nNo relevant evidence was found."
        val withNotice = SearchFailureReporting.withSearchShortfallNotice(text, listOf(PUBMED_DOWN))

        val (notice, rest) = SearchFailureReporting.splitSearchShortfallNotice(withNotice)

        assertEquals(SearchFailureReporting.formatSearchShortfallNotice(listOf(PUBMED_DOWN)), notice)
        assertEquals(text, rest)
    }

    @Test
    fun `a text without the notice is left alone`() {
        for (text in listOf("A report.\n\nWith paragraphs.", "> **Incomplete search:** with no blank line after")) {
            val (notice, rest) = SearchFailureReporting.splitSearchShortfallNotice(text)

            assertNull(notice)
            assertEquals(text, rest)
        }
    }

    @Test
    fun `the notice reads as plain text for a screen or a PDF`() {
        val notice = SearchFailureReporting.formatSearchShortfallNotice(listOf(PUBMED_DOWN))

        assertEquals(
            "Incomplete search: PubMed could not be searched (HTTP 429 Too Many Requests). " +
                "Everything below rests only on the records that were retrieved.",
            SearchFailureReporting.plainNotice(notice)
        )
    }

    // ==================== The report ====================

    @Test
    fun `the methodology records what is missing`() {
        assertEquals(
            "## Methodology\n\n- **Search Completeness:** Incomplete: " +
                "PubMed could not be searched (HTTP 429 Too Many Requests)",
            SearchFailureReporting.searchCompletenessMethodology(listOf(PUBMED_DOWN))
        )
    }

    @Test
    fun `a complete search adds no methodology`() {
        // Android's report has no Methodology section of its own (user's decision, 2026-09-15)
        assertEquals("", SearchFailureReporting.searchCompletenessMethodology(emptyList()))
    }

    // ==================== Failing ====================

    @Test
    fun `the failure message adds the advice after a blank line`() {
        val message = SearchFailureReporting.formatSearchFailureMessage(SearchFailedException(listOf(PUBMED_DOWN)))

        assertEquals(
            "The search could not be completed: PubMed could not be searched " +
                "(HTTP 429 Too Many Requests).\n\n$RATE_LIMIT_ADVICE $PUBMED_KEY_ADVICE",
            message
        )
    }

    @Test
    fun `the advice fits the failure`() {
        val cases = listOf(
            listOf(PUBMED_DOWN) to "$RATE_LIMIT_ADVICE $PUBMED_KEY_ADVICE",
            listOf(RetrievalShortfall(SearchProvider.EUROPE_PMC, RATE_LIMITED)) to RATE_LIMIT_ADVICE,
            listOf(RetrievalShortfall(SearchProvider.PUBMED, TIMED_OUT)) to CONNECTIVITY_ADVICE,
            listOf(RetrievalShortfall(SearchProvider.EUROPE_PMC, CONNECTION_FAILED)) to CONNECTIVITY_ADVICE,
            listOf(RetrievalShortfall(SearchProvider.PUBMED, BAD_REQUEST)) to PUBMED_REFUSED_KEY_ADVICE,
            listOf(RetrievalShortfall(SearchProvider.EUROPE_PMC, BAD_REQUEST)) to FALLBACK_ADVICE,
            listOf(RetrievalShortfall(SearchProvider.EUROPE_PMC, SERVICE_ERROR)) to SERVICE_ERROR_ADVICE,
            listOf(RetrievalShortfall(SearchProvider.PUBMED, UNAVAILABLE)) to FALLBACK_ADVICE,
            listOf(
                RetrievalShortfall(SearchProvider.EUROPE_PMC, TIMED_OUT),
                RetrievalShortfall(SearchProvider.PUBMED, SERVICE_ERROR, 2),
                RetrievalShortfall(SearchProvider.PUBMED, RequestFailure(RequestFailureKind.HTTP_STATUS, 403), 9),
                PUBMED_DOWN,
            ) to "$RATE_LIMIT_ADVICE $PUBMED_KEY_ADVICE $PUBMED_REFUSED_KEY_ADVICE $SERVICE_ERROR_ADVICE $CONNECTIVITY_ADVICE",
            listOf(
                PUBMED_DOWN,
                RetrievalShortfall(SearchProvider.EUROPE_PMC, RATE_LIMITED),
                RetrievalShortfall(SearchProvider.PUBMED, RATE_LIMITED, 4),
                RetrievalShortfall(SearchProvider.PUBMED, TIMED_OUT, 1),
                RetrievalShortfall(SearchProvider.EUROPE_PMC, CONNECTION_FAILED),
            ) to "$RATE_LIMIT_ADVICE $PUBMED_KEY_ADVICE $CONNECTIVITY_ADVICE",
        )

        for ((shortfalls, advice) in cases) {
            assertEquals("$shortfalls", advice, SearchFailureReporting.searchFailureAdvice(shortfalls))
        }
    }

    // ==================== The persisted form ====================

    @Test
    fun `shortfalls survive the round trip`() {
        val shortfalls = listOf(PUBMED_DOWN, RetrievalShortfall(SearchProvider.EUROPE_PMC, TIMED_OUT, 40))

        assertEquals(
            shortfalls,
            SearchFailureReporting.retrievalShortfallsFromJson(SearchFailureReporting.retrievalShortfallsToJson(shortfalls))
        )
    }

    @Test
    fun `the stored form is the contract's`() {
        val stored = SearchFailureReporting.retrievalShortfallsToJson(
            listOf(RetrievalShortfall(SearchProvider.EUROPE_PMC, RATE_LIMITED, 3), PUBMED_TIMED_OUT)
        )

        assertEquals(
            """[{"provider":"europepmc","failure":{"kind":"http_status","status_code":429},"records_missing":3},""" +
                """{"provider":"pubmed","failure":{"kind":"timeout","status_code":null},"records_missing":null}]""",
            stored
        )
    }

    @Test
    fun `an alternative search's shortfall is marked, and the original query's is not`() {
        val stored = SearchFailureReporting.retrievalShortfallsToJson(
            listOf(RetrievalShortfall(SearchProvider.PUBMED, RATE_LIMITED, query = ShortfallQuery.ALTERNATIVE), PUBMED_DOWN)
        )

        assertEquals(
            """[{"provider":"pubmed","failure":{"kind":"http_status","status_code":429},"records_missing":null,"query":"alternative"},""" +
                """{"provider":"pubmed","failure":{"kind":"http_status","status_code":429},"records_missing":null}]""",
            stored
        )
        assertEquals(
            listOf(RetrievalShortfall(SearchProvider.PUBMED, RATE_LIMITED, query = ShortfallQuery.ALTERNATIVE), PUBMED_DOWN),
            SearchFailureReporting.retrievalShortfallsFromJson(stored)
        )
    }

    @Test
    fun `a query marker this build does not know reads as the original query`() {
        // The original query's clause claims more is missing, never less
        for (marker in listOf("\"from-a-newer-build\"", "true", "null", "{}")) {
            val stored = """[{"provider":"pubmed","failure":{"kind":"timeout"},"records_missing":null,"query":$marker}]"""

            assertEquals(marker, listOf(PUBMED_TIMED_OUT), SearchFailureReporting.retrievalShortfallsFromJson(stored))
        }
    }

    @Test
    fun `a complete search stores nothing, and nothing stored reads as complete`() {
        // A session saved before #252 has no value at all
        assertNull(SearchFailureReporting.retrievalShortfallsToJson(emptyList()))
        assertEquals(emptyList<RetrievalShortfall>(), SearchFailureReporting.retrievalShortfallsFromJson(null))
    }

    @Test
    fun `an unreadable field degrades but the shortfall stays`() {
        // A count degrades to null, which claims more is missing, never less
        val cases = listOf(
            """{"provider":"pubmed","failure":{"kind":"from-a-newer-build","status_code":429},"records_missing":-3}"""
                to RetrievalShortfall(SearchProvider.PUBMED, RequestFailure(RequestFailureKind.REQUEST_FAILED)),
            """{"provider":"pubmed","failure":"x","records_missing":0}"""
                to RetrievalShortfall(SearchProvider.PUBMED, RequestFailure(RequestFailureKind.REQUEST_FAILED)),
            """{"provider":"pubmed","records_missing":2}"""
                to RetrievalShortfall(SearchProvider.PUBMED, RequestFailure(RequestFailureKind.REQUEST_FAILED), 2),
            """{"provider":"europepmc","failure":{"kind":"http_status","status_code":true},"records_missing":true}"""
                to RetrievalShortfall(SearchProvider.EUROPE_PMC, RequestFailure(RequestFailureKind.HTTP_STATUS)),
            """{"provider":"pubmed","failure":{"kind":"http_status","status_code":1000000000000000000000000000000},"records_missing":2}"""
                to RetrievalShortfall(SearchProvider.PUBMED, RequestFailure(RequestFailureKind.HTTP_STATUS), 2),
            """{"provider":"pubmed","failure":{"kind":"http_status","status_code":"429"},"records_missing":"2"}"""
                to RetrievalShortfall(SearchProvider.PUBMED, RequestFailure(RequestFailureKind.HTTP_STATUS)),
            """{"provider":"pubmed","failure":{"kind":"http_status","status_code":429.0},"records_missing":2.5}"""
                to RetrievalShortfall(SearchProvider.PUBMED, RequestFailure(RequestFailureKind.HTTP_STATUS)),
            """{"provider":"pubmed","failure":{"kind":"timeout","status_code":429},"records_missing":null}"""
                to PUBMED_TIMED_OUT,
        )

        for ((entry, expected) in cases) {
            assertEquals(entry, listOf(expected), SearchFailureReporting.retrievalShortfallsFromJson("[$entry]"))
        }
    }

    @Test
    fun `a malformed entry is refused, not dropped`() {
        // Skipping it would let the report claim a complete search
        val stored = listOf(
            """[{"provider":"nowhere","failure":{"kind":"timeout"}}]""",
            """[{"provider":"both","failure":{"kind":"timeout"}}]""",
            """[{"provider":"PUBMED","failure":{"kind":"timeout"}}]""",
            """[{"failure":{"kind":"timeout"}}]""",
            """["not an object"]""",
            """"not a list"""",
            "null",
            "{not json",
        )

        for (value in stored) {
            val error = assertThrows(value, IllegalArgumentException::class.java) {
                SearchFailureReporting.retrievalShortfallsFromJson(value)
            }
            assertTrue("$value: ${error.message}", error.message.orEmpty().contains("retrieval shortfall"))
        }
    }

    private companion object {
        val RATE_LIMITED = RequestFailure(RequestFailureKind.HTTP_STATUS, 429)
        val UNAVAILABLE = RequestFailure(RequestFailureKind.HTTP_STATUS, 503)
        val BAD_REQUEST = RequestFailure(RequestFailureKind.HTTP_STATUS, 400)
        val TIMED_OUT = RequestFailure(RequestFailureKind.TIMEOUT)
        val CONNECTION_FAILED = RequestFailure(RequestFailureKind.CONNECTION)
        val SERVICE_ERROR = RequestFailure(RequestFailureKind.SERVICE_ERROR)
        val PUBMED_DOWN = RetrievalShortfall(SearchProvider.PUBMED, RATE_LIMITED)
        val PUBMED_TIMED_OUT = RetrievalShortfall(SearchProvider.PUBMED, TIMED_OUT)

        const val RATE_LIMIT_ADVICE =
            "The service is limiting how often it can be searched: wait a minute and try again."
        const val PUBMED_KEY_ADVICE = "An NCBI API key, set in Settings, raises PubMed's limit."
        const val PUBMED_REFUSED_KEY_ADVICE =
            "If an NCBI API key is set in Settings, check that it is correct: " +
                "PubMed refuses a request whose key it does not accept."
        const val SERVICE_ERROR_ADVICE =
            "If it happens again, rephrase the question: the service may be unable to process the query."
        const val CONNECTIVITY_ADVICE = "Check the internet connection and try again."
        const val FALLBACK_ADVICE = "Try again later."
    }
}
