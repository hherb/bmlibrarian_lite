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

package com.bmlibrarian.factchecker.data.local.entity

import com.bmlibrarian.factchecker.domain.model.RequestFailure
import com.bmlibrarian.factchecker.domain.model.RequestFailureKind
import com.bmlibrarian.factchecker.domain.model.RetrievalShortfall
import com.bmlibrarian.factchecker.domain.model.SearchFailureReporting
import com.bmlibrarian.factchecker.domain.model.SearchProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * What a session says about its search's paging and its shortfalls (#252).
 */
class SessionEntityTest {

    @Test
    fun `PubMed has more only up to the records it can list`() {
        // PubMed lists the first 9,999 records of a search (checked live 2026-09-15)
        assertTrue(session(pubmedOffset = 9_980, pubmedTotalResults = 25_000).hasMoreDocuments)
        assertFalse(session(pubmedOffset = 9_999, pubmedTotalResults = 25_000).hasMoreDocuments)
        assertFalse(session(pubmedOffset = 57, pubmedTotalResults = 57).hasMoreDocuments)
        assertTrue(session(pubmedOffset = 40, pubmedTotalResults = 57).hasMoreDocuments)
    }

    @Test
    fun `a session reads back the shortfalls it stored`() {
        val shortfalls = listOf(
            RetrievalShortfall(SearchProvider.PUBMED, RequestFailure(RequestFailureKind.HTTP_STATUS, 429)),
            RetrievalShortfall(SearchProvider.EUROPE_PMC, RequestFailure(RequestFailureKind.TIMEOUT), 4),
        )

        val stored = session().copy(retrievalShortfallsJson = SearchFailureReporting.retrievalShortfallsToJson(shortfalls))

        assertEquals(shortfalls, stored.retrievalShortfalls())
        assertEquals(emptyList<RetrievalShortfall>(), session().retrievalShortfalls())
    }

    @Test
    fun `a damaged record of shortfalls is refused, not read as a complete search`() {
        assertThrows(IllegalArgumentException::class.java) {
            session().copy(retrievalShortfallsJson = "null").retrievalShortfalls()
        }
    }

    /** A PubMed session with this paging. */
    private fun session(pubmedOffset: Int = 0, pubmedTotalResults: Int = 0) = SessionEntity(
        claimText = "claim",
        searchProvider = SearchProvider.PUBMED,
        pubmedOffset = pubmedOffset,
        pubmedTotalResults = pubmedTotalResults
    )
}
