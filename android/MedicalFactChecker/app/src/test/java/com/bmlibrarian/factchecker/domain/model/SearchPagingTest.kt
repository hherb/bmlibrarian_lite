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
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * How far each source's search can be paged, and what a page should hold (#252).
 */
class SearchPagingTest {

    @Test
    fun `an esearch page lists at most what PubMed holds past its offset, and the first 9,999`() {
        assertEquals(20, SearchPaging.expectedEsearchListing(totalCount = 57, retstart = 0, retmax = 20))
        assertEquals(17, SearchPaging.expectedEsearchListing(totalCount = 57, retstart = 40, retmax = 20))
        assertEquals(0, SearchPaging.expectedEsearchListing(totalCount = 57, retstart = 60, retmax = 20))
        assertEquals(19, SearchPaging.expectedEsearchListing(totalCount = 25_000, retstart = 9_980, retmax = 20))
        assertEquals(0, SearchPaging.expectedEsearchListing(totalCount = 25_000, retstart = 9_999, retmax = 20))
    }

    @Test
    fun `PubMed has a next page until its offset reaches the total or the records it lists`() {
        assertTrue(SearchPaging.pubMedHasNextPage(offset = 40, totalCount = 57))
        assertFalse(SearchPaging.pubMedHasNextPage(offset = 57, totalCount = 57))
        assertTrue(SearchPaging.pubMedHasNextPage(offset = 9_998, totalCount = 25_000))
        assertFalse(SearchPaging.pubMedHasNextPage(offset = 9_999, totalCount = 25_000))
    }

    @Test
    fun `a Europe PMC page should hold the batch, or the hits not yet received`() {
        assertEquals(20, SearchPaging.expectedEuropePmcPage(hitCount = 57, resultsReceived = 20, batchSize = 20))
        assertEquals(17, SearchPaging.expectedEuropePmcPage(hitCount = 57, resultsReceived = 40, batchSize = 20))
        assertEquals(0, SearchPaging.expectedEuropePmcPage(hitCount = 57, resultsReceived = 60, batchSize = 20))
    }
}
