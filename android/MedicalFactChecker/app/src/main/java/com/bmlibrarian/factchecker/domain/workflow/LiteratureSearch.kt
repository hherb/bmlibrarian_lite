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

import com.bmlibrarian.factchecker.data.local.entity.DocumentEntity
import com.bmlibrarian.factchecker.data.remote.europepmc.EuropePMCService
import com.bmlibrarian.factchecker.data.remote.pubmed.PubMedService
import com.bmlibrarian.factchecker.domain.model.RequestFailure
import com.bmlibrarian.factchecker.domain.model.RetrievalShortfall
import com.bmlibrarian.factchecker.domain.model.SearchFailedException
import com.bmlibrarian.factchecker.domain.model.SearchFailureReporting
import com.bmlibrarian.factchecker.domain.model.SearchProvider
import com.bmlibrarian.factchecker.domain.model.ShortfallQuery
import com.bmlibrarian.factchecker.domain.model.SourceRequestException
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Where a session's PubMed paging stands.
 *
 * @property offset The offset of the next page to list
 * @property totalResults The search's total, as PubMed last counted it
 */
data class PubMedPaging(val offset: Int, val totalResults: Int)

/**
 * Where a session's Europe PMC paging stands.
 *
 * @property cursor The cursor of the next page, or null when there is none
 * @property totalResults The search's hit count, as Europe PMC last counted it
 * @property resultsReceived How many records the search's pages held so far, readable or
 *   not; null for a session saved before the count was kept, which stays unknown
 */
data class EuropePMCPaging(val cursor: String?, val totalResults: Int, val resultsReceived: Int?)

/**
 * One page of a fact-check's literature search.
 *
 * @property provider Which providers to search; [SearchProvider.BOTH] halves the batch between them
 * @property pubMedQuery The query in PubMed syntax; empty to leave PubMed out
 * @property europePMCQuery The query in Europe PMC syntax; empty to leave Europe PMC out
 * @property batchSize How many results to ask for in all
 * @property includePreprints Whether Europe PMC may return preprints
 * @property isNextBatch False for a search's first page; true to continue from the session's paging
 * @property pubMedPaging Where the session's PubMed paging stands; read only for a next batch
 * @property europePMCPaging Where the session's Europe PMC paging stands; read only for a next batch
 * @property query Whether this is the claim's own query or an alternative one smart search generated
 * @property sessionId The session the documents belong to
 * @property batchNumber The batch number the documents are stored with
 * @property existingDocumentCount How many documents the session holds, where new positions start
 * @property excludedPmids PMIDs the session already holds, left out of the documents
 */
data class SearchPageRequest(
    val provider: SearchProvider,
    val pubMedQuery: String,
    val europePMCQuery: String,
    val batchSize: Int,
    val includePreprints: Boolean,
    val isNextBatch: Boolean,
    val pubMedPaging: PubMedPaging,
    val europePMCPaging: EuropePMCPaging,
    val query: ShortfallQuery,
    val sessionId: String,
    val batchNumber: Int,
    val existingDocumentCount: Int,
    val excludedPmids: Set<String> = emptySet()
)

/**
 * What one page of a search retrieved.
 *
 * @property documents The new documents, not yet saved
 * @property shortfalls What the page failed to retrieve, the same failure of the same source once
 * @property pubMedPaging Where PubMed's paging goes next, or null to leave it as it was
 * @property europePMCPaging Where Europe PMC's paging goes next, or null to leave it as it was
 */
data class SearchPageOutcome(
    val documents: List<DocumentEntity>,
    val shortfalls: List<RetrievalShortfall>,
    val pubMedPaging: PubMedPaging?,
    val europePMCPaging: EuropePMCPaging?
)

/**
 * Searches the providers a fact-check uses, one page at a time (#252).
 *
 * A failed source is not an empty one. A provider that fails is recorded as a
 * [RetrievalShortfall] and the other provider's documents still count:
 *
 * - on a first page, the source could not be searched, and its paging stays
 *   where it was, so it is not paged later;
 * - on a later PubMed page, the page's records are recorded as missing and the
 *   paging moves past them;
 * - on a later Europe PMC page, the page's records are recorded as missing and
 *   the cursor ends, since a cursor cannot skip a page.
 *
 * A page that failures leave with no document fails with a
 * [SearchFailedException] instead of returning, so the caller changes no
 * paging and saves nothing, and asking again asks for the same page.
 *
 * @param pubMedService The PubMed client
 * @param europePMCService The Europe PMC client
 */
@Singleton
class LiteratureSearch @Inject constructor(
    private val pubMedService: PubMedService,
    private val europePMCService: EuropePMCService
) {

    /**
     * Search one page from each provider the request names.
     *
     * A provider with no next page is not asked for one.
     *
     * @param request The page to search
     * @return The documents, what the page failed to retrieve and where paging goes next
     * @throws SearchFailedException if failures left the page with no document
     */
    suspend fun searchPage(request: SearchPageRequest): SearchPageOutcome {
        val batchSize = if (request.provider == SearchProvider.BOTH) request.batchSize / 2 else request.batchSize
        val pubMed = if (request.provider.includesPubMed() && request.pubMedQuery.isNotEmpty()) {
            searchPubMed(request, batchSize)
        } else {
            ProviderPage.NOT_SEARCHED
        }
        val pubMedPmids = pubMed.documents.mapNotNull { it.pmid }.toSet()
        val europePMC = if (request.provider.includesEuropePMC() && request.europePMCQuery.isNotEmpty()) {
            searchEuropePMC(request, batchSize, excludedPmids = request.excludedPmids + pubMedPmids)
        } else {
            ProviderPage.NOT_SEARCHED
        }

        val documents = pubMed.documents + europePMC.documents
        val shortfalls = SearchFailureReporting.combinedShortfalls(
            (pubMed.shortfalls + europePMC.shortfalls).map { it.copy(query = request.query) }
        )
        if (documents.isEmpty() && shortfalls.isNotEmpty()) {
            throw SearchFailedException(shortfalls)
        }
        return SearchPageOutcome(documents, shortfalls, pubMed.pubMedPaging, europePMC.europePMCPaging)
    }

    /** What one provider contributed to a page. */
    private data class ProviderPage(
        val documents: List<DocumentEntity>,
        val shortfalls: List<RetrievalShortfall>,
        val pubMedPaging: PubMedPaging? = null,
        val europePMCPaging: EuropePMCPaging? = null
    ) {
        companion object {
            /** A provider the page did not ask. */
            val NOT_SEARCHED = ProviderPage(emptyList(), emptyList())
        }
    }

    /**
     * Search PubMed's page of the request.
     *
     * @param request The page to search
     * @param batchSize PubMed's share of the batch
     * @return PubMed's documents, shortfalls and paging
     */
    private suspend fun searchPubMed(request: SearchPageRequest, batchSize: Int): ProviderPage {
        val paging = request.pubMedPaging
        val offset = if (request.isNextBatch) paging.offset else 0
        if (request.isNextBatch &&
            SearchFailureReporting.expectedEsearchListing(paging.totalResults, offset, batchSize) == 0
        ) {
            return ProviderPage.NOT_SEARCHED
        }

        val result = pubMedService.search(query = request.pubMedQuery, offset = offset, batchSize = batchSize)
        val page = result.getOrElse { error ->
            val failure = sourceFailure(error)
            if (!request.isNextBatch) {
                return ProviderPage(emptyList(), listOf(RetrievalShortfall(SearchProvider.PUBMED, failure)))
            }
            // Asked only for a page that lists something, so at least one record is missing
            val missing = SearchFailureReporting.expectedEsearchListing(paging.totalResults, offset, batchSize)
            return ProviderPage(
                emptyList(),
                listOf(RetrievalShortfall(SearchProvider.PUBMED, failure, missing)),
                pubMedPaging = PubMedPaging(offset + missing, paging.totalResults)
            )
        }

        val startPosition = if (request.query == ShortfallQuery.ORIGINAL) offset else request.existingDocumentCount
        val documents = pubMedService.toDocumentEntities(
            articles = page.articles,
            sessionId = request.sessionId,
            batchNumber = request.batchNumber,
            startPosition = startPosition
        ).filter { it.pmid !in request.excludedPmids }
        return ProviderPage(documents, page.shortfalls, pubMedPaging = PubMedPaging(page.nextOffset, page.totalResults))
    }

    /**
     * Search Europe PMC's page of the request.
     *
     * @param request The page to search
     * @param batchSize Europe PMC's share of the batch
     * @param excludedPmids PMIDs to leave out: the session's, and PubMed's on this page
     * @return Europe PMC's documents, shortfalls and paging
     */
    private suspend fun searchEuropePMC(
        request: SearchPageRequest,
        batchSize: Int,
        excludedPmids: Set<String>
    ): ProviderPage {
        val paging = request.europePMCPaging
        val cursor = if (request.isNextBatch) paging.cursor ?: return ProviderPage.NOT_SEARCHED else null
        val received = if (request.isNextBatch) paging.resultsReceived else 0

        val result = europePMCService.search(
            query = request.europePMCQuery,
            cursor = cursor,
            batchSize = batchSize,
            includePreprints = request.includePreprints,
            resultsReceived = received
        )
        val page = result.getOrElse { error ->
            val failure = sourceFailure(error)
            if (!request.isNextBatch) {
                return ProviderPage(emptyList(), listOf(RetrievalShortfall(SearchProvider.EUROPE_PMC, failure)))
            }
            // The cursor promised more, so at least one record is missing; not knowing
            // how many came before claims the most the page could have held
            val missing = maxOf(1, minOf(batchSize, paging.totalResults - (received ?: 0)))
            return ProviderPage(
                emptyList(),
                listOf(RetrievalShortfall(SearchProvider.EUROPE_PMC, failure, missing)),
                europePMCPaging = EuropePMCPaging(cursor = null, totalResults = paging.totalResults, resultsReceived = received)
            )
        }

        val documents = europePMCService.toDocumentEntities(
            articles = page.articles,
            sessionId = request.sessionId,
            batchNumber = request.batchNumber,
            startPosition = request.existingDocumentCount
        ).filter { it.pmid !in excludedPmids }
        return ProviderPage(
            documents,
            page.shortfalls,
            europePMCPaging = EuropePMCPaging(page.nextCursor, page.totalResults, received?.plus(page.resultsReceived))
        )
    }

    /**
     * The failure a client's failed result carries.
     *
     * @param error What the client's result failed with
     * @return Its failure
     * @throws Throwable the error itself, if it is not a source failure: a defect, not a search result
     */
    private fun sourceFailure(error: Throwable): RequestFailure =
        (error as? SourceRequestException)?.failure ?: throw error
}
