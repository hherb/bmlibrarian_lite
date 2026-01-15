package com.bmlibrarian.factchecker.data.remote.europepmc

import com.bmlibrarian.factchecker.data.local.entity.DocumentEntity
import com.bmlibrarian.factchecker.domain.model.EuropePMCError
import com.bmlibrarian.factchecker.util.Constants
import com.bmlibrarian.factchecker.util.NetworkRetry
import javax.inject.Inject
import javax.inject.Singleton

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
     * Search Europe PMC for articles.
     *
     * @param query Search query (supports Europe PMC syntax)
     * @param sessionId Session ID for the documents
     * @param cursor Cursor for pagination (null or "*" for first page)
     * @param batchSize Number of results per page
     * @param includePreprints Whether to include preprints in results
     * @return Result containing search results or error
     */
    suspend fun search(
        query: String,
        sessionId: String,
        cursor: String? = null,
        batchSize: Int = EuropePMCApi.DEFAULT_PAGE_SIZE,
        includePreprints: Boolean = false
    ): Result<EuropePMCSearchResult> {
        return try {
            NetworkRetry.withExponentialBackoff(
                maxRetries = Constants.NETWORK_MAX_RETRIES,
                shouldRetry = { e -> shouldRetryError(e) }
            ) {
                performSearch(query, cursor, batchSize, includePreprints)
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
     * Perform the actual search operation.
     */
    private suspend fun performSearch(
        query: String,
        cursor: String?,
        batchSize: Int,
        includePreprints: Boolean
    ): Result<EuropePMCSearchResult> {
        // Build query with optional source filter
        val fullQuery = if (!includePreprints) {
            "($query) AND (SRC:MED OR SRC:PMC)"
        } else {
            query
        }

        val response = api.search(
            query = fullQuery,
            pageSize = batchSize,
            cursorMark = cursor ?: EuropePMCApi.INITIAL_CURSOR
        )

        if (!response.isSuccessful) {
            throw EuropePMCError.fromHttpError(
                response.code(),
                response.message()
            )
        }

        val body = response.body()
            ?: throw EuropePMCError.SearchError(
                message = "Empty response from Europe PMC",
                query = query
            )

        val articles = body.resultList?.result ?: emptyList()
        val totalResults = body.hitCount ?: 0

        // nextCursorMark equals cursorMark when no more results
        val nextCursor = body.nextCursorMark?.takeIf {
            it != cursor && it != EuropePMCApi.INITIAL_CURSOR && articles.isNotEmpty()
        }

        return Result.success(
            EuropePMCSearchResult(
                articles = articles,
                totalResults = totalResults,
                nextCursor = nextCursor,
                hasMore = nextCursor != null
            )
        )
    }

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
            abstractText = abstractText,
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
}
