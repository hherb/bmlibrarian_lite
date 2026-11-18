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
import org.junit.Test
import java.text.NumberFormat
import java.util.Locale

/**
 * Every query a session ran is kept, with the documents each found, so the
 * reader can see them all and how much each one found. Mirrors iOS's
 * `SearchQueryLogTests`.
 */
class SearchQueryLogTest {

    private fun record(
        kind: SearchQueryRecord.Kind,
        query: String,
        provider: SearchProvider = SearchProvider.PUBMED,
        ids: List<String>?,
        hits: Int? = null
    ) = SearchQueryRecord(kind, provider, query, documentIds = ids, totalHits = hits)

    @Test
    fun `a later page of a query adds to it, each document once`() {
        val log = SearchQueryLog.recording(
            record(SearchQueryRecord.Kind.INITIAL, "q", ids = listOf("b", "c"), hits = 40),
            listOf(record(SearchQueryRecord.Kind.INITIAL, "q", ids = listOf("a", "b"), hits = 30))
        )

        assertEquals(1, log.size)
        assertEquals(listOf("a", "b", "c"), log[0].documentIds)
        assertEquals(40, log[0].totalHits)
    }

    @Test
    fun `another query, or the same one asked of another provider, is listed after`() {
        var log = listOf(record(SearchQueryRecord.Kind.INITIAL, "q", ids = listOf("a")))
        log = SearchQueryLog.recording(record(SearchQueryRecord.Kind.ALTERNATIVE, "q2", ids = listOf("b")), log)
        log = SearchQueryLog.recording(
            record(SearchQueryRecord.Kind.INITIAL, "q", provider = SearchProvider.EUROPE_PMC, ids = listOf("c")), log
        )

        assertEquals(listOf("q", "q2", "q"), log.map { it.query })
        assertEquals(
            listOf("Initial query", "Alternative 1", "Initial query (2)"),
            log.indices.map { SearchQueryLog.label(it, log) }
        )
    }

    @Test
    fun `a query whose documents were not recorded is not given a partial count`() {
        val log = SearchQueryLog.recording(
            record(SearchQueryRecord.Kind.INITIAL, "q", ids = listOf("b")),
            listOf(record(SearchQueryRecord.Kind.INITIAL, "q", ids = null))
        )

        assertNull(log[0].documentIds)
        assertNull(SearchQueryLog.statistics(log[0], emptyMap(), minScore = 3))
    }

    @Test
    fun `found counts every document the query added, relevant those at or above the threshold`() {
        val stats = SearchQueryLog.statistics(
            record(SearchQueryRecord.Kind.INITIAL, "q", ids = listOf("a", "b", "c", "d")),
            mapOf("a" to 5, "b" to 3, "c" to 2, "z" to 5),
            minScore = 3
        )

        assertEquals(SearchQueryStatistics(found = 4, scored = 3, relevant = 2), stats)
    }

    @Test
    fun `the line names what is not scored yet, and the matches where known`() {
        val format = NumberFormat.getIntegerInstance(Locale.US)

        assertEquals(
            "12 found · 4 relevant · 2 not scored",
            SearchQueryLog.statisticsLine(SearchQueryStatistics(12, 10, 4), totalHits = null, numberFormat = format)
        )
        assertEquals(
            "3 found · 1 relevant · 1,234 matches",
            SearchQueryLog.statisticsLine(SearchQueryStatistics(3, 3, 1), totalHits = 1234, numberFormat = format)
        )
    }

    @Test
    fun `a query asked of both providers keeps the form Europe PMC was asked`() {
        val both = SearchQueryLog.forProvider(
            SearchQueryRecord.Kind.INITIAL, SearchProvider.BOTH, "pm", "epmc", documentIds = emptyList(), totalHits = null
        )
        val europePmc = SearchQueryLog.forProvider(
            SearchQueryRecord.Kind.INITIAL, SearchProvider.EUROPE_PMC, "pm", "epmc", documentIds = emptyList(), totalHits = null
        )

        assertEquals("pm" to "epmc", both.query to both.europePmcQuery)
        assertEquals("epmc" to null, europePmc.query to europePmc.europePmcQuery)
    }

    @Test
    fun `a log survives storage, and an unreadable one reads as none`() {
        val log = listOf(
            record(SearchQueryRecord.Kind.INITIAL, "q", ids = listOf("a"), hits = 7),
            record(SearchQueryRecord.Kind.ALTERNATIVE, "q2", provider = SearchProvider.BOTH, ids = null)
        )

        assertEquals(log, SearchQueryLog.decode(SearchQueryLog.encode(log)))
        assertNull(SearchQueryLog.decode("not json"))
        assertNull(SearchQueryLog.decode(null))
    }
}
