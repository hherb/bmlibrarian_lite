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

import android.util.Log
import com.bmlibrarian.factchecker.data.local.entity.DocumentEntity
import com.bmlibrarian.factchecker.domain.model.NcbiCredentialSource
import com.bmlibrarian.factchecker.domain.model.NcbiCredentials
import com.bmlibrarian.factchecker.domain.model.NcbiCredentialsUnavailableException
import com.bmlibrarian.factchecker.domain.model.RequestFailure
import com.bmlibrarian.factchecker.domain.model.RequestFailureKind
import com.bmlibrarian.factchecker.domain.model.RetrievalShortfall
import com.bmlibrarian.factchecker.domain.model.SearchFailureReporting
import com.bmlibrarian.factchecker.domain.model.SearchProvider
import com.bmlibrarian.factchecker.domain.model.SourceRequestException
import com.bmlibrarian.factchecker.util.Constants
import com.bmlibrarian.factchecker.util.NetworkRetry
import kotlinx.coroutines.delay
import org.xml.sax.Attributes
import org.xml.sax.InputSource
import org.xml.sax.SAXException
import org.xml.sax.SAXParseException
import org.xml.sax.helpers.DefaultHandler
import retrofit2.Response
import java.io.IOException
import java.io.StringReader
import javax.inject.Inject
import javax.inject.Singleton
import javax.xml.XMLConstants
import javax.xml.parsers.SAXParserFactory
import kotlin.coroutines.cancellation.CancellationException

/** Log tag for PubMed search diagnostics. */
private const val TAG = "PubMedService"

/**
 * SAX feature flags that disable external DTD loading and entity expansion.
 *
 * Applied defensively (parser implementations that do not recognise a given
 * feature simply skip it). Together with a no-op entity resolver, these prevent
 * the parser from fetching the remote NLM PubMed DTD referenced by the EFetch
 * `<!DOCTYPE>` and guard against XML external-entity (XXE) attacks.
 *
 * Secure processing additionally caps internal entity expansion, so a
 * "billion laughs" payload cannot exhaust memory. The JVM applies such a limit
 * by default, but Android's Expat-backed parser makes no such guarantee, so the
 * flag is requested explicitly rather than relied upon.
 */
private val SAFE_SAX_FEATURES: List<Pair<String, Boolean>> = listOf(
    "http://apache.org/xml/features/nonvalidating/load-external-dtd" to false,
    "http://xml.org/sax/features/external-general-entities" to false,
    "http://xml.org/sax/features/external-parameter-entities" to false,
    XMLConstants.FEATURE_SECURE_PROCESSING to true,
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

/** The root element of an efetch answer that holds articles. */
private const val EFETCH_ARTICLE_SET_ROOT = "PubmedArticleSet"

/** The root element of efetch's error document, which E-utilities can send with HTTP 200 (#255). */
private const val EFETCH_ERROR_ROOT = "eFetchResult"

/** Stops a parse at a root element that is not an article set, before any of its text is read. */
private class UnexpectedRootException : SAXException("unexpected root element")

/**
 * Service for PubMed/NCBI E-utilities API interactions.
 *
 * Provides search and article fetching with:
 * - Automatic rate limiting (respects NCBI guidelines)
 * - Retry logic with exponential backoff
 * - XML parsing for article metadata
 *
 * The API key and email come from [credentialSource], read at the start of each
 * search, so no caller passes them and none can forget to. [PubMedApi] sends
 * them in a POST body; [api] must come from [createPubMedApi], whose client
 * refuses redirects.
 *
 * The app's Hilt graph builds this with `NetworkModule.providePubMedService`,
 * passing `SettingsRepository` as the credential source; nothing binds
 * [NcbiCredentialSource] for the `@Inject` constructor on its own.
 *
 * @param api PubMed API interface, built by [createPubMedApi]
 * @param credentialSource Where the NCBI API key and email are read from
 */
@Singleton
class PubMedService @Inject constructor(
    private val api: PubMedApi,
    private val credentialSource: NcbiCredentialSource
) {

    /**
     * Search PubMed for one page of articles.
     *
     * Performs a two-step process:
     * 1. ESearch to list the page's PMIDs
     * 2. EFetch to get article details for those PMIDs
     *
     * The NCBI API key and email are read from the credential source once per
     * search and sent with both of its requests. Each request is retried on its
     * own, so a failed fetch does not search again.
     *
     * A failed source is not an empty one (#252): a search that could not list
     * its PMIDs, whether its request failed or its answer reported an error, could
     * not be read or listed none of what it counted, fails with a
     * [SourceRequestException]. A page that answered but retrieved less than it
     * listed (PMIDs left unlisted, a fetch that failed, articles that could not
     * be read) succeeds, and says what is missing in
     * [PubMedSearchResult.shortfalls]. Cancellation is rethrown, so a cancelled
     * search stays cancelled.
     *
     * @param query PubMed search query
     * @param offset Starting position for pagination, from 0 to 9998: PubMed lists
     *   no more of a search
     * @param batchSize Number of results to fetch
     * @return The page, or a [SourceRequestException] carrying why the search failed
     * @throws IllegalArgumentException if [offset] is past what PubMed can list;
     *   a caller never asks for a page past the end
     * @throws NcbiCredentialsUnavailableException if the saved NCBI API key or
     *   email cannot be read: nothing is sent, and the user must fix Settings
     */
    suspend fun search(
        query: String,
        offset: Int = 0,
        batchSize: Int = PubMedApi.DEFAULT_BATCH_SIZE
    ): Result<PubMedSearchResult> {
        require(offset in 0 until SearchFailureReporting.PUBMED_LISTABLE_RECORDS) {
            "PubMed lists a search's records from offset 0 to " +
                "${SearchFailureReporting.PUBMED_LISTABLE_RECORDS - 1}, not $offset"
        }

        // The saved key lives in encrypted preferences, which throw on a broken
        // keystore: not PubMed's failure, and not a crash, but a settings problem
        val credentials = try {
            credentialSource.ncbiCredentials()
        } catch (e: Exception) {
            Log.e(TAG, "Could not read the saved NCBI API key or email (${e.javaClass.simpleName})")
            throw NcbiCredentialsUnavailableException()
        }

        val listing = try {
            withRetries { listPmids(query, offset, batchSize, credentials) }
        } catch (e: SourceRequestException) {
            return failure(e.failure)
        }

        val fetched = if (listing.pmids.isEmpty()) {
            FetchedArticles(emptyList(), emptyList())
        } else {
            fetchArticles(listing.pmids, credentials)
        }
        // The unlisted PMIDs are recorded as missing, so the next page starts after them
        val nextOffset = offset + maxOf(listing.expected, listing.pmids.size)

        return Result.success(
            PubMedSearchResult(
                articles = fetched.articles,
                totalResults = listing.totalCount,
                nextOffset = nextOffset,
                hasMore = nextOffset < minOf(listing.totalCount, SearchFailureReporting.PUBMED_LISTABLE_RECORDS),
                shortfalls = SearchFailureReporting.shortfallsForMissingRecords(
                    SearchProvider.PUBMED,
                    RequestFailure(RequestFailureKind.INCOMPLETE_RESPONSE),
                    listing.unlisted
                ) + fetched.shortfalls
            )
        )
    }

    /**
     * Log a failed search and return it as a failed result.
     *
     * The message names the source and the failure's reason only: no body, no
     * request, and so no key.
     *
     * @param failure Why the search failed
     * @return The failed result
     */
    private fun failure(failure: RequestFailure): Result<PubMedSearchResult> {
        val error = SourceRequestException(SearchProvider.PUBMED, failure)
        Log.w(TAG, "PubMed search failed: ${error.message}")
        return Result.failure(error)
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

    /** The PMIDs one esearch page listed, and what it should have listed. */
    private data class PmidListing(
        /** The search's total, from `count`. */
        val totalCount: Int,
        /** The PMIDs the page listed, in PubMed's order. */
        val pmids: List<String>,
        /** How many PMIDs the page should have listed. */
        val expected: Int,
        /** How many of [expected] it left out. */
        val unlisted: Int
    )

    /** The articles fetched for a page's PMIDs, and what the fetch failed to retrieve. */
    private data class FetchedArticles(
        val articles: List<ParsedArticle>,
        val shortfalls: List<RetrievalShortfall>
    )

    /** An efetch article set as parsed. */
    private data class ParsedArticleSet(
        /** The articles that carried a PMID and a title. */
        val articles: List<ParsedArticle>,
        /** `PubmedArticle` records that closed without a PMID or a title. */
        val unreadable: Int,
        /** False when the XML broke off, so records after the break were never seen. */
        val wellFormed: Boolean
    )

    /**
     * Run one E-utilities request, retrying it while its failure is transient.
     *
     * @param block The request, failing with a [SourceRequestException]
     * @return What the request returned
     * @throws SourceRequestException when it failed and retrying would not help, or the retries ran out
     */
    private suspend fun <T> withRetries(block: suspend () -> T): T =
        NetworkRetry.withExponentialBackoff(
            maxRetries = Constants.NETWORK_MAX_RETRIES,
            shouldRetry = { e -> e is SourceRequestException && e.failure.isRetryable }
        ) { block() }

    /**
     * Send one E-utilities request and refuse an unsuccessful answer.
     *
     * An error the transport raised is reduced to its [RequestFailure] and not
     * kept. An unsuccessful status is read from the status line only: the body
     * is never read, because NCBI's 400 for a bad key repeats the key in it. The
     * PubMed client follows no redirect ([pubMedHttpClient]), so a 3xx arrives
     * here too, as a refused redirect.
     *
     * @param request The Retrofit call
     * @return The successful response
     * @throws SourceRequestException if the request failed or the status is not 2xx
     */
    private suspend fun <T> send(request: suspend () -> Response<T>): Response<T> {
        val response = try {
            request()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            val failure = RequestFailure.fromException(e)
            // The class only: a converter's message quotes the body
            Log.w(TAG, "E-utilities request failed: ${failure.describe()} (${e.javaClass.simpleName})")
            throw SourceRequestException(SearchProvider.PUBMED, failure)
        }
        if (!response.isSuccessful) {
            throw SourceRequestException(SearchProvider.PUBMED, RequestFailure.forHttpStatus(response.code()))
        }
        return response
    }

    /**
     * Build the error for an E-utilities answer that cannot be read, and log why.
     *
     * @param reason What was wrong, naming fields only, never their values
     * @return The error to throw
     */
    private fun unreadableAnswer(reason: String): SourceRequestException {
        Log.e(TAG, "Unreadable E-utilities answer: $reason")
        return SourceRequestException(SearchProvider.PUBMED, RequestFailure(RequestFailureKind.MALFORMED_RESPONSE))
    }

    /**
     * List one page of a search's PMIDs with esearch.
     *
     * E-utilities reports some failures inside an HTTP 200, as an `ERROR` field
     * and no `count` (#255): that answer is a failed search, not a search that
     * matched nothing, and its text is neither logged nor shown. A `count` that is
     * missing or no whole number is an answer that cannot be read, not a total of
     * nothing.
     *
     * @param query PubMed search query
     * @param offset The page's offset
     * @param batchSize The page size asked for
     * @param credentials The API key and email to send
     * @return The listing
     * @throws SourceRequestException if the request failed, the answer reports an
     *   error or cannot be read, or it lists none of the PMIDs it counts
     */
    private suspend fun listPmids(
        query: String,
        offset: Int,
        batchSize: Int,
        credentials: NcbiCredentials
    ): PmidListing {
        val response = send {
            api.search(
                term = query,
                retMax = batchSize,
                retStart = offset,
                apiKey = credentials.apiKey,
                email = credentials.email
            )
        }

        val result = response.body()?.esearchResult
            ?: throw unreadableAnswer("esearch answer has no esearchresult object")
        if (result.error != null) {
            Log.e(
                TAG,
                "E-utilities esearch answered with an ERROR instead of a result " +
                    "(its text is not logged: it can repeat the request)"
            )
            throw SourceRequestException(SearchProvider.PUBMED, RequestFailure(RequestFailureKind.SERVICE_ERROR))
        }
        val totalCount = result.count
            ?.takeIf { count -> count.isNotEmpty() && count.all { it in '0'..'9' } }
            ?.toIntOrNull()
            ?: throw unreadableAnswer("esearch result has no numeric count")
        val pmids = result.idList ?: throw unreadableAnswer("esearch result has no idlist")

        val expected = SearchFailureReporting.expectedEsearchListing(totalCount, offset, batchSize)
        if (expected > 0 && pmids.isEmpty()) {
            Log.e(TAG, "Incomplete E-utilities answer: esearch listed 0 of $expected PMIDs")
            throw SourceRequestException(SearchProvider.PUBMED, RequestFailure(RequestFailureKind.INCOMPLETE_RESPONSE))
        }
        val unlisted = maxOf(0, expected - pmids.size)
        if (unlisted > 0) {
            Log.w(TAG, "esearch listed ${pmids.size} of $expected PMIDs")
        }
        return PmidListing(totalCount, pmids, expected, unlisted)
    }

    /**
     * Fetch the articles for a page's PMIDs with efetch.
     *
     * A fetch that fails after its retries costs its PMIDs, not the search: they
     * are recorded as missing, as are the records of an answer that broke off
     * and the articles that could not be read (#252, #255).
     *
     * @param pmids The PMIDs to fetch
     * @param credentials The API key and email to send
     * @return The articles, and what the fetch failed to retrieve
     */
    private suspend fun fetchArticles(pmids: List<String>, credentials: NcbiCredentials): FetchedArticles {
        val delayMs = if (credentials.apiKey != null) {
            PubMedApi.RATE_LIMIT_DELAY_WITH_KEY_MS
        } else {
            PubMedApi.RATE_LIMIT_DELAY_MS
        }
        delay(delayMs)

        val parsed = try {
            withRetries {
                val response = send {
                    api.fetch(ids = pmids.joinToString(","), apiKey = credentials.apiKey, email = credentials.email)
                }
                parseArticleSet(response.body() ?: throw unreadableAnswer("efetch answer has no body"))
            }
        } catch (e: SourceRequestException) {
            Log.w(TAG, "PubMed articles for ${pmids.size} PMIDs could not be fetched: ${e.failure.describe()}")
            return FetchedArticles(
                emptyList(),
                SearchFailureReporting.shortfallsForMissingRecords(SearchProvider.PUBMED, e.failure, pmids.size)
            )
        }

        val unreadable = if (parsed.wellFormed) parsed.unreadable else pmids.size - parsed.articles.size
        if (unreadable > 0) {
            Log.w(TAG, "efetch delivered ${parsed.articles.size} readable articles for ${pmids.size} PMIDs")
        }
        return FetchedArticles(
            parsed.articles,
            SearchFailureReporting.shortfallsForMissingRecords(
                SearchProvider.PUBMED,
                RequestFailure(RequestFailureKind.MALFORMED_RESPONSE),
                unreadable
            )
        )
    }

    /**
     * Parse an EFetch answer into [ParsedArticle] objects.
     *
     * Uses a JAXP SAX parser ([javax.xml.parsers.SAXParserFactory]) rather than
     * the Android-framework `XmlPullParser`, so the parsing logic is portable
     * and unit-testable on a plain JVM as well as on-device. External DTD and
     * entity resolution are disabled ([PubMedXmlHandler.resolveEntity] plus the
     * SAX feature flags), so the parser never fetches the NLM PubMed DTD over
     * the network and is not vulnerable to XXE.
     *
     * An article set that breaks off keeps the articles that closed before the
     * break; the caller counts the rest as missing. Only a parse error's
     * position is logged: its message can quote the body, such as the name of an
     * undefined entity.
     *
     * @param xml The raw EFetch XML payload
     * @return The article set
     * @throws SourceRequestException if the answer is efetch's `eFetchResult` error
     *   document, which E-utilities can send with HTTP 200 (#255), or has any other
     *   root than `PubmedArticleSet`, or no root at all. Neither the error's text
     *   nor the root's name is logged.
     */
    private fun parseArticleSet(xml: String): ParsedArticleSet {
        val handler = PubMedXmlHandler()
        var wellFormed = true
        val parser = try {
            // Built per call rather than cached in a field: SAXParserFactory is not
            // thread-safe, and this service is a @Singleton whose parse can be
            // entered concurrently. Do not "optimise" this into a shared instance.
            val factory = SAXParserFactory.newInstance()
            factory.isNamespaceAware = false
            // Deliberately NOT calling setXIncludeAware: JAXP's base implementation
            // throws UnsupportedOperationException unless an implementation
            // overrides it, and Android's Expat-backed factory is not guaranteed
            // to. That would fail every on-device parse while JVM unit tests
            // stayed green - the #119 failure mode, silent before #252 and now
            // every fetch reported as unreadable. XInclude is off by default and
            // requires namespace awareness (disabled above), so there is nothing
            // to disable.
            // Harden against XXE and external-DTD network fetches. Not every SAX
            // implementation recognises every feature, so apply each defensively.
            for ((feature, enabled) in SAFE_SAX_FEATURES) {
                try {
                    factory.setFeature(feature, enabled)
                } catch (_: Exception) {
                    // resolveEntity still blocks external fetches; the feature name is a constant
                    Log.w(TAG, "This XML parser does not support $feature")
                }
            }
            factory.newSAXParser()
        } catch (e: Exception) {
            // Not the answer's fault, and not to be reported as NCBI's: the parser cannot be built here
            Log.e(TAG, "The efetch XML parser could not be built (${e.javaClass.simpleName})")
            throw IllegalStateException("The PubMed article parser could not be built on this device")
        }

        try {
            parser.parse(InputSource(StringReader(xml)), handler)
        } catch (_: UnexpectedRootException) {
            // Stopped at the root on purpose; judged below
        } catch (e: SAXParseException) {
            Log.e(TAG, "efetch answer is not well-formed XML (line ${e.lineNumber}, column ${e.columnNumber})")
            wellFormed = false
        } catch (e: SAXException) {
            Log.e(TAG, "efetch answer could not be parsed (${e.javaClass.simpleName})")
            wellFormed = false
        } catch (e: IOException) {
            Log.e(TAG, "efetch answer could not be read (${e.javaClass.simpleName})")
            wellFormed = false
        }
        // Any other exception is a defect in the handler, not a damaged answer: it propagates

        when (handler.rootElement) {
            EFETCH_ARTICLE_SET_ROOT -> return ParsedArticleSet(handler.articles, handler.unreadable, wellFormed)
            EFETCH_ERROR_ROOT -> {
                Log.e(
                    TAG,
                    "E-utilities efetch answered with an error document instead of articles " +
                        "(its text is not logged: it can repeat the request)"
                )
                throw SourceRequestException(SearchProvider.PUBMED, RequestFailure(RequestFailureKind.SERVICE_ERROR))
            }
            null -> throw unreadableAnswer("efetch answer has no XML root element")
            else -> throw unreadableAnswer("efetch answer has an unexpected root element")
        }
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

        /** `PubmedArticle` records that closed without a PMID or a title. */
        var unreadable = 0
            private set

        /** The document's root element, once it has opened. */
        var rootElement: String? = null
            private set

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
            if (rootElement == null) {
                rootElement = qName
                // Nothing but an article set is read, and an error document's text least of all
                if (qName != EFETCH_ARTICLE_SET_ROOT) throw UnexpectedRootException()
            }
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
            // Snapshot the buffer only for extracted elements. Inline-markup
            // children (`<i>`, `<sup>`, …) close without consuming or clearing it,
            // leaving the enclosing element's accumulated text intact.
            val isExtracted = qName in TEXT_ELEMENTS
            if (isExtracted) {
                // Before the pop, so consumeText's parentElement() sees the parent.
                consumeText(qName, textBuffer.toString().trim())
            }
            closeElement(qName)
            // SAX pairs every startElement with exactly one endElement, so the
            // stack cannot be empty here; the guard is cheap insurance against a
            // non-conformant parser aborting a parse of real user data.
            if (elementStack.isNotEmpty()) {
                elementStack.removeLast()
            }
            if (isExtracted) {
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
                    val built = currentArticle?.build()
                    if (built != null) articles.add(built) else unreadable++
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
