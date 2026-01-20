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

package com.bmlibrarian.factchecker.data.remote.pubmed

import com.bmlibrarian.factchecker.data.local.entity.DocumentEntity
import com.bmlibrarian.factchecker.domain.model.PubMedError
import com.bmlibrarian.factchecker.util.Constants
import com.bmlibrarian.factchecker.util.NetworkRetry
import kotlinx.coroutines.delay
import org.xmlpull.v1.XmlPullParser
import org.xmlpull.v1.XmlPullParserFactory
import java.io.StringReader
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Service for PubMed/NCBI E-utilities API interactions.
 *
 * Provides search and article fetching with:
 * - Automatic rate limiting (respects NCBI guidelines)
 * - Retry logic with exponential backoff
 * - XML parsing for article metadata
 */
@Singleton
class PubMedService @Inject constructor(
    private val api: PubMedApi
) {

    /**
     * Search PubMed and fetch article details.
     *
     * Performs a two-step process:
     * 1. ESearch to get PMIDs matching the query
     * 2. EFetch to get article details for those PMIDs
     *
     * @param query PubMed search query
     * @param offset Starting position for pagination
     * @param batchSize Number of results to fetch
     * @param apiKey Optional NCBI API key (increases rate limit)
     * @param email Email for NCBI identification (recommended)
     * @return Result containing search results or error
     */
    suspend fun search(
        query: String,
        offset: Int = 0,
        batchSize: Int = PubMedApi.DEFAULT_BATCH_SIZE,
        apiKey: String? = null,
        email: String? = null
    ): Result<PubMedSearchResult> {
        // Validate offset
        if (offset > PubMedApi.MAX_OFFSET) {
            return Result.failure(
                PubMedError.InvalidOffsetError(
                    message = "Offset cannot exceed ${PubMedApi.MAX_OFFSET}",
                    offset = offset
                )
            )
        }

        return try {
            NetworkRetry.withExponentialBackoff(
                maxRetries = Constants.NETWORK_MAX_RETRIES,
                shouldRetry = { e -> shouldRetryError(e) }
            ) {
                performSearch(query, offset, batchSize, apiKey, email)
            }
        } catch (e: PubMedError) {
            Result.failure(e)
        } catch (e: Exception) {
            Result.failure(
                PubMedError.NetworkError(
                    message = "Network error: ${e.message}",
                    cause = e
                )
            )
        }
    }

    /**
     * Convert parsed articles to DocumentEntity list.
     *
     * @param articles List of parsed articles
     * @param sessionId Session ID for documents
     * @param batchNumber Batch number for these documents
     * @param startPosition Starting result position
     * @return List of DocumentEntity objects
     */
    fun toDocumentEntities(
        articles: List<ParsedArticle>,
        sessionId: String,
        batchNumber: Int = 1,
        startPosition: Int = 0
    ): List<DocumentEntity> {
        return articles.mapIndexed { index, article ->
            DocumentEntity(
                sessionId = sessionId,
                pmid = article.pmid,
                doi = article.doi,
                pmcId = article.pmcId,
                title = article.title,
                abstractText = formatAbstractText(article),
                authors = article.authors,
                journal = article.journal,
                publicationDate = article.publicationDate,
                publicationYear = article.publicationYear,
                meshTerms = article.meshTerms,
                source = Constants.SOURCE_PUBMED,
                isPreprint = false,
                batchNumber = batchNumber,
                resultPosition = startPosition + index
            )
        }
    }

    /**
     * Format abstract text with section labels for structured abstracts.
     *
     * If the article has structured abstract sections (with labels like
     * "Background", "Methods", etc.), formats them with bold markdown
     * labels and proper line breaks. Falls back to plain abstract text
     * if no structured sections are available.
     *
     * @param article The parsed article
     * @return Formatted abstract text with section labels, or plain abstract
     */
    private fun formatAbstractText(article: ParsedArticle): String? {
        val sections = article.abstractSections
        if (sections.isNullOrEmpty()) {
            return article.abstractText
        }

        return sections.joinToString("\n\n") { section ->
            if (section.label != null) {
                "**${section.label}:** ${section.text}"
            } else {
                section.text
            }
        }
    }

    // ==================== Private Implementation ====================

    /**
     * Perform the actual search operation.
     */
    private suspend fun performSearch(
        query: String,
        offset: Int,
        batchSize: Int,
        apiKey: String?,
        email: String?
    ): Result<PubMedSearchResult> {
        // Step 1: Search for PMIDs
        val searchResponse = api.search(
            term = query,
            retMax = batchSize,
            retStart = offset,
            apiKey = apiKey,
            email = email
        )

        if (!searchResponse.isSuccessful) {
            throw PubMedError.fromHttpError(
                searchResponse.code(),
                searchResponse.message()
            )
        }

        val searchResult = searchResponse.body()?.esearchResult
            ?: throw PubMedError.SearchError(
                message = "Empty search response",
                query = query
            )

        val pmids = searchResult.idList ?: emptyList()
        val totalResults = searchResult.count?.toIntOrNull() ?: 0

        if (pmids.isEmpty()) {
            return Result.success(
                PubMedSearchResult(
                    articles = emptyList(),
                    totalResults = totalResults,
                    nextOffset = offset,
                    hasMore = false
                )
            )
        }

        // Rate limit delay before fetch
        val delayMs = if (apiKey != null) {
            PubMedApi.RATE_LIMIT_DELAY_WITH_KEY_MS
        } else {
            PubMedApi.RATE_LIMIT_DELAY_MS
        }
        delay(delayMs)

        // Step 2: Fetch article details
        val fetchResponse = api.fetch(
            ids = pmids.joinToString(","),
            apiKey = apiKey,
            email = email
        )

        if (!fetchResponse.isSuccessful) {
            throw PubMedError.fromHttpError(
                fetchResponse.code(),
                fetchResponse.message()
            )
        }

        val xml = fetchResponse.body()
            ?: throw PubMedError.FetchError(
                message = "Empty fetch response",
                pmids = pmids
            )

        // Step 3: Parse XML to articles
        val articles = parseArticleXml(xml)

        return Result.success(
            PubMedSearchResult(
                articles = articles,
                totalResults = totalResults,
                nextOffset = offset + pmids.size,
                hasMore = (offset + pmids.size) < totalResults && (offset + pmids.size) <= PubMedApi.MAX_OFFSET
            )
        )
    }

    /**
     * Parse PubMed XML response into ParsedArticle objects.
     */
    private fun parseArticleXml(xml: String): List<ParsedArticle> {
        val articles = mutableListOf<ParsedArticle>()

        try {
            val factory = XmlPullParserFactory.newInstance()
            factory.isNamespaceAware = false
            val parser = factory.newPullParser()
            parser.setInput(StringReader(xml))

            var eventType = parser.eventType
            var currentArticle: ArticleBuilder? = null
            var currentTag = ""
            var parentTag = ""

            // Author parsing state
            var inAuthor = false
            var authorLastName = ""
            var authorForeName = ""

            // Abstract parsing state
            var inAbstract = false
            var abstractLabel: String? = null

            // MeSH parsing state
            var inMeshHeading = false

            while (eventType != XmlPullParser.END_DOCUMENT) {
                when (eventType) {
                    XmlPullParser.START_TAG -> {
                        parentTag = currentTag
                        currentTag = parser.name

                        when (currentTag) {
                            "PubmedArticle" -> currentArticle = ArticleBuilder()
                            "Author" -> inAuthor = true
                            "Abstract" -> inAbstract = true
                            "AbstractText" -> {
                                abstractLabel = parser.getAttributeValue(null, "Label")
                            }
                            "MeshHeading" -> inMeshHeading = true
                        }
                    }

                    XmlPullParser.TEXT -> {
                        val text = parser.text?.trim() ?: ""
                        if (text.isNotEmpty() && currentArticle != null) {
                            when (currentTag) {
                                "PMID" -> {
                                    // Only capture the first PMID (article PMID, not reference PMIDs)
                                    if (currentArticle.pmid == null && parentTag != "CommentsCorrections") {
                                        currentArticle.pmid = text
                                    }
                                }
                                "ArticleTitle" -> currentArticle.title = cleanXmlText(text)
                                "AbstractText" -> {
                                    if (inAbstract) {
                                        if (abstractLabel != null) {
                                            currentArticle.abstractSections.add(
                                                AbstractSection(abstractLabel, cleanXmlText(text))
                                            )
                                        }
                                        currentArticle.abstractText.append(text).append(" ")
                                    }
                                }
                                "Title" -> {
                                    // Journal title - only if we don't have one yet
                                    if (currentArticle.journal == null && parentTag == "Journal") {
                                        currentArticle.journal = text
                                    }
                                }
                                "Year" -> {
                                    if (currentArticle.year == null) {
                                        currentArticle.year = text.toIntOrNull()
                                    }
                                }
                                "MedlineDate" -> {
                                    // Alternative date format (e.g., "2024 Jan-Feb")
                                    if (currentArticle.year == null) {
                                        currentArticle.year = text.take(4).toIntOrNull()
                                        currentArticle.publicationDate = text
                                    }
                                }
                                "LastName" -> if (inAuthor) authorLastName = text
                                "ForeName" -> if (inAuthor) authorForeName = text
                                "DescriptorName" -> {
                                    if (inMeshHeading) {
                                        currentArticle.meshTerms.add(text)
                                    }
                                }
                                "PublicationType" -> currentArticle.publicationTypes.add(text)
                                "Keyword" -> currentArticle.keywords.add(text)
                                "ELocationID" -> {
                                    val idType = parser.getAttributeValue(null, "EIdType")
                                    if (idType == "doi" && currentArticle.doi == null) {
                                        currentArticle.doi = text
                                    } else if (idType == "pmc" && currentArticle.pmcId == null) {
                                        currentArticle.pmcId = text
                                    }
                                }
                                "ArticleId" -> {
                                    val idType = parser.getAttributeValue(null, "IdType")
                                    when (idType) {
                                        "doi" -> if (currentArticle.doi == null) currentArticle.doi = text
                                        "pmc" -> if (currentArticle.pmcId == null) {
                                            currentArticle.pmcId = if (text.startsWith("PMC")) text else "PMC$text"
                                        }
                                    }
                                }
                            }
                        }
                    }

                    XmlPullParser.END_TAG -> {
                        when (parser.name) {
                            "Author" -> {
                                if (authorLastName.isNotEmpty()) {
                                    val fullName = if (authorForeName.isNotEmpty()) {
                                        "$authorLastName $authorForeName"
                                    } else {
                                        authorLastName
                                    }
                                    currentArticle?.authors?.add(fullName)
                                }
                                inAuthor = false
                                authorLastName = ""
                                authorForeName = ""
                            }
                            "Abstract" -> inAbstract = false
                            "AbstractText" -> abstractLabel = null
                            "MeshHeading" -> inMeshHeading = false
                            "PubmedArticle" -> {
                                currentArticle?.let { builder ->
                                    builder.build()?.let { article ->
                                        articles.add(article)
                                    }
                                }
                                currentArticle = null
                            }
                        }
                        currentTag = parentTag
                        parentTag = ""
                    }
                }
                eventType = parser.next()
            }
        } catch (e: Exception) {
            // Log but continue with what we have
            e.printStackTrace()
        }

        return articles
    }

    /**
     * Clean XML text by removing extra whitespace.
     */
    private fun cleanXmlText(text: String): String {
        return text.replace(Regex("\\s+"), " ").trim()
    }

    /**
     * Determine if an error should trigger a retry.
     */
    private fun shouldRetryError(e: Exception): Boolean {
        return when (e) {
            is PubMedError -> PubMedError.isRetryable(e)
            else -> NetworkRetry.isRetryableException(e)
        }
    }

    /**
     * Builder class for constructing articles during XML parsing.
     */
    private class ArticleBuilder {
        var pmid: String? = null
        var doi: String? = null
        var pmcId: String? = null
        var title: String? = null
        val abstractText = StringBuilder()
        val abstractSections = mutableListOf<AbstractSection>()
        var journal: String? = null
        var publicationDate: String? = null
        var year: Int? = null
        val authors = mutableListOf<String>()
        val meshTerms = mutableListOf<String>()
        val publicationTypes = mutableListOf<String>()
        val keywords = mutableListOf<String>()

        /**
         * Build a ParsedArticle if we have minimum required data.
         */
        fun build(): ParsedArticle? {
            val pmidValue = pmid ?: return null
            val titleValue = title ?: return null

            return ParsedArticle(
                pmid = pmidValue,
                doi = doi,
                pmcId = pmcId,
                title = titleValue,
                abstractText = abstractText.toString().trim().ifEmpty { null },
                abstractSections = abstractSections.ifEmpty { null },
                authors = authors.toList(),
                journal = journal,
                publicationDate = publicationDate,
                publicationYear = year,
                meshTerms = meshTerms.toList(),
                publicationTypes = publicationTypes.toList(),
                keywords = keywords.toList()
            )
        }
    }
}
