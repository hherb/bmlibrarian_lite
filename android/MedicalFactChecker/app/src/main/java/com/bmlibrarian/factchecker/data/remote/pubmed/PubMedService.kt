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
import org.xml.sax.Attributes
import org.xml.sax.InputSource
import org.xml.sax.helpers.DefaultHandler
import java.io.StringReader
import javax.inject.Inject
import javax.inject.Singleton
import javax.xml.parsers.SAXParserFactory

/**
 * SAX feature flags that disable external DTD loading and entity expansion.
 *
 * Applied defensively (parser implementations that do not recognise a given
 * feature simply skip it). Together with a no-op entity resolver, these prevent
 * the parser from fetching the remote NLM PubMed DTD referenced by the EFetch
 * `<!DOCTYPE>` and guard against XML external-entity (XXE) attacks.
 */
private val SAFE_SAX_FEATURES: List<Pair<String, Boolean>> = listOf(
    "http://apache.org/xml/features/nonvalidating/load-external-dtd" to false,
    "http://xml.org/sax/features/external-general-entities" to false,
    "http://xml.org/sax/features/external-parameter-entities" to false,
)

/**
 * Element names whose text content the SAX handler extracts.
 *
 * The handler resets and snapshots its character buffer only at the boundaries
 * of these elements. Character data inside inline-markup children (e.g. `<i>`,
 * `<sup>`, `<sub>` within an `ArticleTitle` or `AbstractText` — common for gene
 * or species names, exponents and subscripts) is therefore preserved as part of
 * the enclosing element's text rather than discarded when the child opens. In
 * PubMed XML these elements never nest one another, so a single flat buffer is
 * sufficient.
 */
private val TEXT_ELEMENTS: Set<String> = setOf(
    "PMID", "ArticleTitle", "AbstractText", "Title", "Year", "MedlineDate",
    "LastName", "ForeName", "DescriptorName", "PublicationType", "Keyword",
    "ELocationID", "ArticleId",
)

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
     * labels and proper line breaks. Falls back to detecting inline
     * section headers in plain text (e.g., "BACKGROUND:" or "Background:").
     *
     * @param article The parsed article
     * @return Formatted abstract text with section labels, or plain abstract
     */
    private fun formatAbstractText(article: ParsedArticle): String? {
        val sections = article.abstractSections
        if (!sections.isNullOrEmpty()) {
            return sections.joinToString("\n\n") { section ->
                if (section.label != null) {
                    "**${section.label}:** ${section.text}"
                } else {
                    section.text
                }
            }
        }

        // Fall back to detecting inline section headers in plain text
        val plainText = article.abstractText ?: return null
        return formatInlineSectionHeaders(plainText)
    }

    /**
     * Format inline section headers found in plain abstract text.
     *
     * Detects common section headers like "BACKGROUND:", "Background:",
     * "METHODS:", etc. and formats them with markdown bold and line breaks.
     *
     * @param text The plain abstract text
     * @return Formatted text with bold section headers and line breaks
     */
    private fun formatInlineSectionHeaders(text: String): String {
        // Common section headers in PubMed abstracts (case-insensitive matching)
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
        // e.g., "BACKGROUND:" or "Background:" at word boundaries
        val pattern = sectionHeaders.joinToString("|") { Regex.escape(it) }
        val regex = Regex("(?<=^|\\s)($pattern):\\s*", RegexOption.MULTILINE)

        // Check if any section headers are present
        if (!regex.containsMatchIn(text)) {
            return text
        }

        // Replace section headers with bold markdown and add line breaks before them
        var formatted = text
        regex.findAll(text).toList().reversed().forEach { match ->
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
     * Parse a PubMed EFetch XML response into [ParsedArticle] objects.
     *
     * Uses a JAXP SAX parser ([javax.xml.parsers.SAXParserFactory]) rather than
     * the Android-framework `XmlPullParser`, so the parsing logic is portable
     * and unit-testable on a plain JVM as well as on-device. External DTD and
     * entity resolution are disabled ([PubMedXmlHandler.resolveEntity] plus the
     * SAX feature flags), so the parser never fetches the NLM PubMed DTD over
     * the network and is not vulnerable to XXE.
     *
     * Parsing is resilient: any articles decoded before a malformed-input error
     * are still returned, matching the behaviour callers rely on.
     *
     * @param xml The raw EFetch XML payload.
     * @return The list of articles that carried at least a PMID and a title.
     */
    private fun parseArticleXml(xml: String): List<ParsedArticle> {
        val handler = PubMedXmlHandler()
        try {
            val factory = SAXParserFactory.newInstance()
            factory.isNamespaceAware = false
            // Harden against XXE and external-DTD network fetches. Not every SAX
            // implementation recognises every feature, so apply each defensively.
            for ((feature, enabled) in SAFE_SAX_FEATURES) {
                try {
                    factory.setFeature(feature, enabled)
                } catch (_: Exception) {
                    // Feature unsupported by this parser; resolveEntity still blocks fetches.
                }
            }
            factory.newSAXParser().parse(InputSource(StringReader(xml)), handler)
        } catch (e: Exception) {
            // Resilient: keep any articles parsed before the failure.
            e.printStackTrace()
        }
        return handler.articles
    }

    /**
     * SAX content handler that decodes PubMed EFetch XML into [ParsedArticle]s.
     *
     * Text content is buffered per element and consumed on the element's end
     * event, because SAX may split a single run of character data across
     * multiple [characters] callbacks. An element-name stack provides parent
     * context (used to distinguish the article PMID from reference PMIDs and the
     * journal `Title` from other titles).
     */
    private inner class PubMedXmlHandler : DefaultHandler() {

        /** Articles decoded so far; the parse result. */
        val articles = mutableListOf<ParsedArticle>()

        private val elementStack = ArrayDeque<String>()
        private val textBuffer = StringBuilder()
        private var currentArticle: ArticleBuilder? = null

        // Author parsing state
        private var inAuthor = false
        private var authorLastName = ""
        private var authorForeName = ""

        // Abstract parsing state
        private var inAbstract = false
        private var abstractLabel: String? = null

        // MeSH parsing state
        private var inMeshHeading = false

        // Attribute values captured on element open for use at element close
        private var eLocationIdType: String? = null
        private var articleIdType: String? = null

        override fun startElement(
            uri: String?,
            localName: String?,
            qName: String,
            attributes: Attributes
        ) {
            when (qName) {
                "PubmedArticle" -> currentArticle = ArticleBuilder()
                "Author" -> {
                    inAuthor = true
                    authorLastName = ""
                    authorForeName = ""
                }
                "Abstract" -> inAbstract = true
                "AbstractText" -> abstractLabel = attributes.getValue("Label")
                "MeshHeading" -> inMeshHeading = true
                "ELocationID" -> eLocationIdType = attributes.getValue("EIdType")
                "ArticleId" -> articleIdType = attributes.getValue("IdType")
            }
            elementStack.addLast(qName)
            // Start a fresh capture only for extracted elements, so inline-markup
            // children opening inside them do not discard the text already read.
            if (qName in TEXT_ELEMENTS) {
                textBuffer.setLength(0)
            }
        }

        override fun characters(ch: CharArray, start: Int, length: Int) {
            textBuffer.append(ch, start, length)
        }

        override fun endElement(uri: String?, localName: String?, qName: String) {
            consumeText(qName, textBuffer.toString().trim())
            closeElement(qName)
            if (elementStack.isNotEmpty()) {
                elementStack.removeLast()
            }
            // Clear only after an extracted element closes; an inline child's end
            // must leave the enclosing element's accumulated text intact.
            if (qName in TEXT_ELEMENTS) {
                textBuffer.setLength(0)
            }
        }

        /**
         * Block external DTD/entity resolution so parsing PubMed XML (which
         * carries a `<!DOCTYPE>` referencing the remote NLM DTD) never reaches
         * out to the network and cannot be used for XXE.
         */
        override fun resolveEntity(publicId: String?, systemId: String?): InputSource {
            return InputSource(StringReader(""))
        }

        /** Apply a leaf element's trimmed text to the article under construction. */
        private fun consumeText(name: String, value: String) {
            if (value.isEmpty()) return
            val article = currentArticle ?: return
            when (name) {
                "PMID" -> {
                    // Only capture the first PMID (article PMID, not reference PMIDs).
                    if (article.pmid == null && parentElement() != "CommentsCorrections") {
                        article.pmid = value
                    }
                }
                "ArticleTitle" -> article.title = cleanXmlText(value)
                "AbstractText" -> {
                    if (inAbstract) {
                        val label = abstractLabel
                        if (label != null) {
                            article.abstractSections.add(AbstractSection(label, cleanXmlText(value)))
                        }
                        article.abstractText.append(value).append(" ")
                    }
                }
                "Title" -> {
                    // Journal title - only if we don't have one yet.
                    if (article.journal == null && parentElement() == "Journal") {
                        article.journal = value
                    }
                }
                "Year" -> if (article.year == null) article.year = value.toIntOrNull()
                "MedlineDate" -> {
                    // Alternative date format (e.g., "2024 Jan-Feb").
                    if (article.year == null) {
                        article.year = value.take(4).toIntOrNull()
                        article.publicationDate = value
                    }
                }
                "LastName" -> if (inAuthor) authorLastName = value
                "ForeName" -> if (inAuthor) authorForeName = value
                "DescriptorName" -> if (inMeshHeading) article.meshTerms.add(value)
                "PublicationType" -> article.publicationTypes.add(value)
                "Keyword" -> article.keywords.add(value)
                "ELocationID" -> {
                    if (eLocationIdType == "doi" && article.doi == null) {
                        article.doi = value
                    } else if (eLocationIdType == "pmc" && article.pmcId == null) {
                        article.pmcId = value
                    }
                }
                "ArticleId" -> when (articleIdType) {
                    "doi" -> if (article.doi == null) article.doi = value
                    "pmc" -> if (article.pmcId == null) {
                        article.pmcId = if (value.startsWith("PMC")) value else "PMC$value"
                    }
                }
            }
        }

        /** Run element-close side effects (state resets, author assembly, article build). */
        private fun closeElement(name: String) {
            when (name) {
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
                "ELocationID" -> eLocationIdType = null
                "ArticleId" -> articleIdType = null
                "PubmedArticle" -> {
                    currentArticle?.build()?.let { articles.add(it) }
                    currentArticle = null
                }
            }
        }

        /** The element enclosing the one currently being closed, or "" at the root. */
        private fun parentElement(): String =
            if (elementStack.size >= 2) elementStack[elementStack.size - 2] else ""
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
