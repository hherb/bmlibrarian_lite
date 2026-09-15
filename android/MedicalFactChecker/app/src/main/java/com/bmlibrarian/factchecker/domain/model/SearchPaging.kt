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

/**
 * How far each literature source's search can be paged, and what a page should hold (#252).
 *
 * The clients, the search and the session each ask these questions; one answer
 * for each keeps them from disagreeing about whether a next page exists or
 * whether a page came back short.
 */
object SearchPaging {

    /** The largest number of records PubMed lists for one search (checked live 2026-09-15). */
    const val PUBMED_LISTABLE_RECORDS = 9_999

    /**
     * How many PMIDs an esearch page should list.
     *
     * @param totalCount The search's `count`
     * @param retstart The page's offset
     * @param retmax The page size asked for
     * @return The PMIDs PubMed holds from [retstart] on, up to [retmax] and to
     *   the first [PUBMED_LISTABLE_RECORDS]; 0 past the end of what can be listed
     */
    fun expectedEsearchListing(totalCount: Int, retstart: Int, retmax: Int): Int =
        maxOf(0, minOf(retmax, totalCount - retstart, PUBMED_LISTABLE_RECORDS - retstart))

    /**
     * Whether PubMed has a page at an offset.
     *
     * @param offset The page's offset
     * @param totalCount The search's `count`
     * @return True while the offset is short of both the total and the records PubMed lists
     */
    fun pubMedHasNextPage(offset: Int, totalCount: Int): Boolean =
        offset < minOf(totalCount, PUBMED_LISTABLE_RECORDS)

    /**
     * How many records a Europe PMC page should hold.
     *
     * @param hitCount The search's `hitCount`
     * @param resultsReceived How many records the search's earlier pages held, readable or not
     * @param batchSize The page size asked for
     * @return The batch, or the hits not yet received if fewer; 0 once every hit arrived
     */
    fun expectedEuropePmcPage(hitCount: Int, resultsReceived: Int, batchSize: Int): Int =
        maxOf(0, minOf(batchSize, hitCount - resultsReceived))
}
