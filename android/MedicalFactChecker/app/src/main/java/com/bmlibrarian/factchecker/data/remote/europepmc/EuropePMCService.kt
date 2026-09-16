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
import com.bmlibrarian.factchecker.data.local.entity.DocumentEntity
import com.bmlibrarian.factchecker.data.remote.sendSourceRequest
import com.bmlibrarian.factchecker.data.remote.unreadableSourceAnswer
import com.bmlibrarian.factchecker.data.remote.withSourceRetries
import com.bmlibrarian.factchecker.domain.model.EuropePMCError
import com.bmlibrarian.factchecker.domain.model.RequestFailure
import com.bmlibrarian.factchecker.domain.model.RequestFailureKind
import com.bmlibrarian.factchecker.domain.model.SearchFailureReporting
import com.bmlibrarian.factchecker.domain.model.SearchPaging
import com.bmlibrarian.factchecker.domain.model.SearchProvider
import com.bmlibrarian.factchecker.domain.model.SourceRequestException
import com.bmlibrarian.factchecker.util.Constants
import com.bmlibrarian.factchecker.util.NetworkRetry
import javax.inject.Inject
import javax.inject.Singleton

/** Log tag for Europe PMC search diagnostics. */
private const val TAG = "EuropePMCService"

/**
 * Service for Europe PMC API interactions.
 *
 * Provides search and full-text retrieval with:
 * - Cursor-based pagination
 * - Retry logic with exponential backoff
 * - Preprint filtering
 */
@Singleton
class EuropePMCService @Inject constructor(
    private val api: EuropePMCApi
) {

    /**
     * Search Europe PMC for one page of articles.
     *
     * A failed source is not an empty one (#252): a request that failed after
     * its retries, an answer that cannot be read (such as the bare `version`
     * Europe PMC sends for an unknown cursor), and an empty page the hit count
     * promised results for all fail with a [SourceRequestException]. A page that
     * answered but holds less than it should (a cursor that ends before every hit
     * arrived, records that could not be read or have no title) succeeds, and says
     * what is missing in [EuropePMCSearchResult.shortfalls]. Cancellation is
     * rethrown, so a cancelled search stays cancelled.
     *
     * @param query Search query (supports Europe PMC syntax)
     * @param cursor Cursor for pagination (null or "*" for first page)
     * @param batchSize Number of results per page
     * @param includePreprints Whether to include preprints in results
     * @param resultsReceived How many records the search's earlier pages held,
     *   readable or not, 0 for a first page; with the hit count, it says how many
     *   this page should hold and, once the cursor ends, how many never arrived.
     *   Null when nobody counted (a session saved before #252): then an empty page
     *   ends the cursor, and nothing is expected of the page
     * @return The page, or a [SourceRequestException] carrying why the search failed
     */
    suspend fun search(
        query: String,
        cursor: String? = null,
        batchSize: Int = EuropePMCApi.DEFAULT_PAGE_SIZE,
        includePreprints: Boolean = false,
        resultsReceived: Int?
    ): Result<EuropePMCSearchResult> {
        return try {
            val page = withSourceRetries { requestSearchPage(query, cursor, batchSize, includePreprints) }
            Result.success(readSearchPage(page, cursor, batchSize, resultsReceived))
        } catch (e: SourceRequestException) {
            Log.w(TAG, "Europe PMC search failed: ${e.message}")
            Result.failure(e)
        }
    }

    /**
     * Get full text XML for a PMC article.
     *
     * @param pmcId PubMed Central ID (with or without "PMC" prefix)
     * @return Result containing XML string or error
     */
    suspend fun getFullTextXml(pmcId: String): Result<String> {
        return try {
            NetworkRetry.withExponentialBackoff(
                maxRetries = Constants.NETWORK_MAX_RETRIES,
                shouldRetry = { e -> shouldRetryError(e) }
            ) {
                performGetFullText(pmcId)
            }
        } catch (e: EuropePMCError) {
            Result.failure(e)
        } catch (e: Exception) {
            Result.failure(
                EuropePMCError.NetworkError(
                    message = "Network error: ${e.message}",
                    cause = e
                )
            )
        }
    }

    /**
     * Convert Europe PMC articles to DocumentEntity list.
     *
     * @param articles List of Europe PMC articles
     * @param sessionId Session ID for documents
     * @param batchNumber Batch number for these documents
     * @param startPosition Starting result position
     * @return List of DocumentEntity objects
     */
    fun toDocumentEntities(
        articles: List<EuropePMCArticle>,
        sessionId: String,
        batchNumber: Int = 1,
        startPosition: Int = 0
    ): List<DocumentEntity> {
        return articles.mapIndexedNotNull { index, article ->
            article.toDocumentEntity(sessionId, batchNumber, startPosition + index)
        }
    }

    // ==================== Private Implementation ====================

    /**
     * Request one search page and refuse an unsuccessful answer.
     *
     * @param query Search query
     * @param cursor Cursor for pagination, or null for the first page
     * @param batchSize Number of results per page
     * @param includePreprints Whether to include preprints in results
     * @return The decoded answer
     * @throws SourceRequestException if the request failed, the status is not
     *   2xx, or the answer has no body
     */
    private suspend fun requestSearchPage(
        query: String,
        cursor: String?,
        batchSize: Int,
        includePreprints: Boolean
    ): EuropePMCSearchResponse {
        // Build query with optional source filter
        val fullQuery = if (!includePreprints) {
            "($query) AND (SRC:MED OR SRC:PMC)"
        } else {
            query
        }

        val response = sendSourceRequest(
            SearchProvider.EUROPE_PMC,
            TAG,
            statusFailure = { status -> RequestFailure(RequestFailureKind.HTTP_STATUS, status) }
        ) {
            api.search(
                query = fullQuery,
                pageSize = batchSize,
                cursorMark = cursor ?: EuropePMCApi.INITIAL_CURSOR
            )
        }
        return response.body() ?: throw unreadableAnswer("answer has no body")
    }

    /**
     * Read a search page Europe PMC answered, checking it holds what it counts.
     *
     * @param page The decoded answer
     * @param cursor The cursor the page was requested with, or null for the first page
     * @param batchSize The page size asked for
     * @param resultsReceived How many records the search's earlier pages held, or null when unknown
     * @return The page's readable articles, its cursor and its shortfalls
     * @throws SourceRequestException if the hit count or result list is missing
     *   or unusable, or the page is empty although the hit count promised results
     */
    private fun readSearchPage(
        page: EuropePMCSearchResponse,
        cursor: String?,
        batchSize: Int,
        resultsReceived: Int?
    ): EuropePMCSearchResult {
        val hitCount = page.hitCount?.takeIf { it >= 0 }
            ?: throw unreadableAnswer("answer has no non-negative integer hitCount")
        val records = page.resultList?.result ?: throw unreadableAnswer("answer has no resultList.result list")

        // Unknown when nobody counted what came before: then nothing is expected of the page
        val expected = resultsReceived?.let { SearchPaging.expectedEuropePmcPage(hitCount, it, batchSize) } ?: 0
        if (records.isEmpty() && expected > 0) {
            Log.e(TAG, "Europe PMC sent an empty page after $resultsReceived of $hitCount results")
            throw SourceRequestException(SearchProvider.EUROPE_PMC, RequestFailure(RequestFailureKind.INCOMPLETE_RESPONSE))
        }

        // nextCursorMark repeats the cursor sent when there are no more results
        val nextCursor = page.nextCursorMark?.takeIf {
            it != cursor && it != EuropePMCApi.INITIAL_CURSOR && records.isNotEmpty()
        }
        // The cursor ends only once every hit was sent (checked live 2026-09-15). Nothing
        // past an ended cursor can be asked for, so every hit not received is missing,
        // including those an earlier page left out while its cursor went on
        val cutShort = if (nextCursor == null && resultsReceived != null) {
            maxOf(0, hitCount - (resultsReceived + records.size))
        } else {
            0
        }
        if (cutShort > 0) {
            Log.e(TAG, "Europe PMC's cursor ended after ${resultsReceived?.plus(records.size)} of $hitCount results")
        }

        val articles = records.filterNotNull().filter { !it.title.isNullOrBlank() }
        val unreadable = records.size - articles.size
        if (unreadable > 0) {
            Log.w(TAG, "Europe PMC sent $unreadable records that could not be read or have no title")
        }

        return EuropePMCSearchResult(
            articles = articles,
            totalResults = hitCount,
            nextCursor = nextCursor,
            resultsReceived = records.size,
            shortfalls = SearchFailureReporting.shortfallsForMissingRecords(
                SearchProvider.EUROPE_PMC,
                RequestFailure(RequestFailureKind.INCOMPLETE_RESPONSE),
                cutShort
            ) + SearchFailureReporting.shortfallsForMissingRecords(
                SearchProvider.EUROPE_PMC,
                RequestFailure(RequestFailureKind.MALFORMED_RESPONSE),
                unreadable
            )
        )
    }

    /**
     * Build the error for a search answer that cannot be read, and log why.
     *
     * @param reason What was wrong, naming fields only
     * @return The error to throw
     */
    private fun unreadableAnswer(reason: String): SourceRequestException =
        unreadableSourceAnswer(SearchProvider.EUROPE_PMC, TAG, reason)

    /**
     * Perform full text retrieval.
     */
    private suspend fun performGetFullText(pmcId: String): Result<String> {
        // Ensure PMC prefix
        val normalizedId = if (pmcId.startsWith("PMC")) pmcId else "PMC$pmcId"

        val response = api.getFullTextXml(normalizedId)

        if (!response.isSuccessful) {
            if (response.code() == 404) {
                throw EuropePMCError.FullTextUnavailableError(
                    message = "Full text not available for $normalizedId",
                    pmcId = normalizedId
                )
            }
            throw EuropePMCError.fromHttpError(
                response.code(),
                response.message()
            )
        }

        val xml = response.body()
            ?: throw EuropePMCError.FullTextUnavailableError(
                message = "Empty full text response for $normalizedId",
                pmcId = normalizedId
            )

        return Result.success(xml)
    }

    /**
     * Determine if an error should trigger a retry.
     */
    private fun shouldRetryError(e: Exception): Boolean {
        return when (e) {
            is EuropePMCError -> EuropePMCError.isRetryable(e)
            else -> NetworkRetry.isRetryableException(e)
        }
    }

    /**
     * Extension function to convert EuropePMCArticle to DocumentEntity.
     */
    private fun EuropePMCArticle.toDocumentEntity(
        sessionId: String,
        batchNumber: Int,
        position: Int
    ): DocumentEntity? {
        if (title.isNullOrBlank()) return null

        val isPreprint = source?.uppercase() in listOf("PPR", "PREPRINT")
        val sourceType = when {
            isPreprint -> Constants.SOURCE_PREPRINT
            else -> Constants.SOURCE_EUROPE_PMC
        }

        return DocumentEntity(
            sessionId = sessionId,
            pmid = pmid,
            pmcId = pmcid,
            doi = doi,
            title = title,
            abstractText = formatAbstractText(abstractText),
            authors = parseAuthors(),
            journal = journalTitle,
            publicationDate = pubDate ?: firstPublicationDate,
            publicationYear = pubYear?.toIntOrNull(),
            meshTerms = meshHeadingList?.meshHeading
                ?.mapNotNull { it.descriptorName }
                ?: emptyList(),
            source = sourceType,
            isPreprint = isPreprint,
            batchNumber = batchNumber,
            resultPosition = position
        )
    }

    /**
     * Parse author list from Europe PMC article.
     */
    private fun EuropePMCArticle.parseAuthors(): List<String> {
        // Prefer structured author list
        authorList?.author?.let { authors ->
            val names = authors.mapNotNull { author ->
                author.fullName ?: run {
                    val lastName = author.lastName ?: return@mapNotNull null
                    val firstName = author.firstName ?: author.initials
                    if (firstName != null) "$lastName $firstName" else lastName
                }
            }
            if (names.isNotEmpty()) return names
        }

        // Fall back to author string
        return authorString?.split(",")
            ?.map { it.trim() }
            ?.filter { it.isNotEmpty() }
            ?: emptyList()
    }

    /**
     * Format abstract text by detecting inline section headers.
     *
     * Detects common section headers like "BACKGROUND:", "Background:",
     * "METHODS:", etc. and formats them with markdown bold and line breaks.
     *
     * @param text The plain abstract text
     * @return Formatted text with bold section headers and line breaks, or null
     */
    private fun formatAbstractText(text: String?): String? {
        if (text.isNullOrBlank()) return text

        // Smart cast to non-null after the check
        val abstractText: String = text

        // Common section headers in abstracts (case-insensitive matching)
        val sectionHeaders = listOf(
            "BACKGROUND", "Background",
            "INTRODUCTION", "Introduction",
            "OBJECTIVE", "Objective", "OBJECTIVES", "Objectives",
            "AIM", "Aim", "AIMS", "Aims",
            "PURPOSE", "Purpose",
            "METHODS", "Methods", "METHODOLOGY", "Methodology",
            "MATERIALS AND METHODS", "Materials and Methods",
            "STUDY DESIGN", "Study Design",
            "RESULTS", "Results",
            "FINDINGS", "Findings",
            "CONCLUSIONS", "Conclusions", "CONCLUSION", "Conclusion",
            "DISCUSSION", "Discussion",
            "SIGNIFICANCE", "Significance",
            "IMPORTANCE", "Importance",
            "CONTEXT", "Context",
            "DESIGN", "Design",
            "SETTING", "Setting",
            "PARTICIPANTS", "Participants",
            "PATIENTS", "Patients",
            "INTERVENTIONS", "Interventions",
            "MAIN OUTCOME MEASURES", "Main Outcome Measures",
            "OUTCOME MEASURES", "Outcome Measures",
            "MEASUREMENTS", "Measurements",
            "TRIAL REGISTRATION", "Trial Registration"
        )

        // Build regex pattern that matches headers followed by colon
        val pattern = sectionHeaders.joinToString("|") { Regex.escape(it) }
        val regex = Regex("(?<=^|\\s)($pattern):\\s*", RegexOption.MULTILINE)

        // Check if any section headers are present
        if (!regex.containsMatchIn(abstractText)) {
            return abstractText
        }

        // Replace section headers with bold markdown and add line breaks before them
        var formatted = abstractText
        regex.findAll(abstractText).toList().reversed().forEach { match ->
            val header = match.groupValues[1]
            val replacement = if (match.range.first == 0) {
                "**$header:** "
            } else {
                "\n\n**$header:** "
            }
            formatted = formatted.replaceRange(match.range, replacement)
        }

        return formatted.trim()
    }
}
