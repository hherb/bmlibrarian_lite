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

package com.bmlibrarian.factchecker.data.remote.fulltext

import android.content.Context
import android.util.Log
import com.bmlibrarian.factchecker.data.remote.europepmc.EuropePMCArticle
import com.bmlibrarian.factchecker.data.remote.europepmc.EuropePMCService
import com.bmlibrarian.factchecker.data.remote.europepmc.FullTextAccession
import com.bmlibrarian.factchecker.data.remote.europepmc.FullTextXmlFetch
import com.bmlibrarian.factchecker.domain.model.RequestFailure
import com.bmlibrarian.factchecker.domain.model.SourceRequestException
import com.bmlibrarian.factchecker.util.Constants
import com.bmlibrarian.factchecker.util.NetworkRetry
import com.bmlibrarian.factchecker.util.jats.JATSParseError
import com.bmlibrarian.factchecker.util.jats.JATSXMLParser
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerializationException
import kotlin.coroutines.cancellation.CancellationException
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Service for fetching full-text content from multiple sources.
 *
 * Implements a fallback chain:
 * 1. Europe PMC XML (JATS format) - preferred, machine-readable
 * 2. Europe PMC PDF render - a free PDF Europe PMC offers
 * 3. Unpaywall PDF - open access PDFs, or the PDF an open-access landing page declares
 * 4. DOI Resolution - link to publisher website
 *
 * Full-text content is cached locally after first retrieval.
 */
@Singleton
class FullTextService @Inject constructor(
    @ApplicationContext private val context: Context,
    private val europePmcService: EuropePMCService,
    private val unpaywallApi: UnpaywallApi,
    private val httpClient: OkHttpClient
) {
    companion object {
        private const val TAG = "FullTextService"
        private const val PDF_CACHE_DIR = "fulltext_pdfs"

        /** The request header this client names itself in. */
        private const val USER_AGENT_HEADER = "User-Agent"

        /** How this client names itself to the sites it fetches pages and PDFs from. */
        private const val USER_AGENT = "BMLibrarian/1.0 (Medical Fact Checker)"

        /** The response header a page's media type is read from. */
        private const val CONTENT_TYPE_HEADER = "Content-Type"
    }

    /**
     * Result of a full-text retrieval attempt.
     *
     * @property hasContent Whether the result gives the reader the article or a
     *   link to it. Declared by every subtype rather than worked out by excluding
     *   the ones without, so a new subtype cannot count as a success by omission
     */
    sealed class FullTextResult(val hasContent: Boolean) {
        /**
         * Full text retrieved from Europe PMC as JATS XML.
         *
         * @param xml Raw XML content.
         * @param markdown Parsed markdown content.
         * @param html Parsed HTML content.
         */
        data class EuropePmcXml(
            val xml: String,
            val markdown: String,
            val html: String
        ) : FullTextResult(hasContent = true)

        /**
         * PDF available from Europe PMC render URL (when XML is unavailable).
         *
         * @param pdfUrl URL to the Europe PMC PDF.
         * @param localPath Local file path if downloaded, null otherwise.
         */
        data class EuropePmcPdf(
            val pdfUrl: String,
            val localPath: String? = null
        ) : FullTextResult(hasContent = true)

        /**
         * Full text available as PDF from Unpaywall.
         *
         * @param pdfUrl URL to the PDF.
         * @param localPath Local file path if downloaded, null otherwise.
         */
        data class UnpaywallPdf(
            val pdfUrl: String,
            val localPath: String? = null
        ) : FullTextResult(hasContent = true)

        /**
         * Fall back to DOI/publisher URL.
         *
         * @param url URL to the publisher page.
         */
        data class DoiUrl(val url: String) : FullTextResult(hasContent = true)

        /**
         * Full text is unavailable from all sources.
         *
         * A claim about the article: every source that could be asked was asked
         * and answered. Callers record it on the document for good. Not yet true
         * after a JATS parse failure, which still ends here when no later source
         * serves anything (#436).
         *
         * @param reason Explanation of why retrieval failed.
         */
        data class Unavailable(val reason: String) : FullTextResult(hasContent = false)

        /**
         * No source provided the full text, but Europe PMC did not settle whether
         * it exists (#434).
         *
         * Europe PMC answered without serving the article (an HTTP status such
         * as `fullTextXML`'s 404 for text that is not open access (#432), from
         * the fetch or the identifier search), or gave no answer at all (a
         * throttle (429), a 5xx that outlasted its retries (#445), a timeout, a
         * dropped connection, a blank body, an identifier never sent).
         * The reader's sentence follows the same split, by
         * [RequestFailure.isAnswer]: see [absenceNotEstablishedMessage].
         * Unlike [Unavailable], a claim about us: callers must not mark
         * the document unavailable for good on it, or a busy Europe PMC takes the
         * retry away.
         *
         * @param failure What Europe PMC's side of the chain got instead of the article's text
         */
        data class NotEstablished(val failure: RequestFailure) : FullTextResult(hasContent = false) {
            /** The sentence shown to the reader. */
            val reason: String
                get() = absenceNotEstablishedMessage(failure)
        }
    }

    /**
     * What an identifier search learned, including what it could not learn.
     *
     * The search used to swallow its failures and answer an empty resolution, so
     * "Europe PMC holds no record" and "we could not ask Europe PMC" were one
     * answer, and the chain went on to call the article unavailable for good.
     *
     * @property pmcId The PMC ID, when a matched record named one
     * @property preprintAccession The `PPR` record ID, when a matched record was a
     *   preprint, which has no PMC ID
     * @property pdfRenderUrl The free PDF render URL, when a matched record offered one
     * @property failure Why the first failed search failed, when one did
     * @property matchedARecord Whether any search matched a record for the article
     */
    internal data class PmcResolution(
        val pmcId: String? = null,
        val preprintAccession: String? = null,
        val pdfRenderUrl: String? = null,
        val failure: RequestFailure? = null,
        val matchedARecord: Boolean = false
    ) {
        /**
         * Whether a search failed and none answered about the article.
         *
         * A search that matched a record settles the question however the others
         * went, so a failure alone is not enough.
         */
        val lostTheSource: Boolean
            get() = failure != null && !matchedARecord

        /**
         * This resolution combined with a later search's: every field accumulates,
         * preferring the earlier answer for the values that can only be answered once.
         *
         * @param next What a later search learned
         * @return The two merged
         */
        fun merging(next: PmcResolution): PmcResolution = PmcResolution(
            pmcId = pmcId ?: next.pmcId,
            preprintAccession = preprintAccession ?: next.preprintAccession,
            pdfRenderUrl = pdfRenderUrl ?: next.pdfRenderUrl,
            failure = failure ?: next.failure,
            matchedARecord = matchedARecord || next.matchedARecord
        )

        companion object {
            /**
             * What one matched record says about the article.
             *
             * The preprint's record ID is taken only in its prefixed form, so an ID
             * that is not a `PPR` accession is never asked for as one.
             *
             * @param article The first record the search matched
             * @return The resolution it gives
             */
            fun fromArticle(article: EuropePMCArticle): PmcResolution {
                val isPreprint = article.source?.uppercase() in Constants.EUROPE_PMC_PREPRINT_SOURCES
                return PmcResolution(
                    pmcId = article.pmcid?.takeIf { it.isNotBlank() },
                    preprintAccession = if (isPreprint) {
                        article.id?.let { FullTextAccession.prefixed(it, FullTextAccession.PREPRINT_PREFIX) }
                    } else {
                        null
                    },
                    pdfRenderUrl = article.fullTextUrlList?.fullTextUrl
                        ?.firstOrNull { it.documentStyle == "pdf" && it.availability == "Free" }
                        ?.url,
                    matchedARecord = true
                )
            }
        }
    }

    /**
     * Fetch full text for a document using the fallback chain.
     *
     * @param pmcId PubMed Central ID (if available).
     * @param doi Digital Object Identifier (if available).
     * @param pmid PubMed ID (if available, used for caching).
     * @param email Email for Unpaywall API (required for Unpaywall lookup).
     * @return The full text or a link to it; [FullTextResult.Unavailable] when every
     *   source answered without it (callers record this); or
     *   [FullTextResult.NotEstablished] when Europe PMC did not settle it (never
     *   recorded). No path here returns a failed [Result].
     * @throws CancellationException if the caller cancelled.
     */
    suspend fun fetchFullText(
        pmcId: String?,
        doi: String?,
        pmid: String?,
        email: String = Constants.UNPAYWALL_DEFAULT_EMAIL
    ): Result<FullTextResult> = withContext(Dispatchers.IO) {
        // What Europe PMC's side of the chain got instead of the article's text,
        // if anything. Set by a lost identifier search, a failed fetch and
        // a fullTextXML 404; cleared by a fetch that was served. Read only at the
        // end: a chain that found nothing must not call the article's full text
        // absent while this is set (#434)
        var europePmcShortfall: RequestFailure? = null

        // Resolve PMC ID and PDF render URL from PMID or DOI if not already available
        var resolvedPmcId = pmcId
        var preprintAccession: String? = null
        var pdfRenderUrl: String? = null
        if (resolvedPmcId.isNullOrBlank()) {
            val resolution = resolvePmcIdAndPdfUrl(pmid = pmid, doi = doi)
            resolvedPmcId = resolution.pmcId
            preprintAccession = resolution.preprintAccession
            pdfRenderUrl = resolution.pdfRenderUrl
            if (resolution.lostTheSource) {
                europePmcShortfall = resolution.failure
            }
        }

        // Try Europe PMC XML first. A preprint has no PMC ID and is asked for by
        // its PPR record ID
        val accession = resolvedPmcId?.takeIf { it.isNotBlank() } ?: preprintAccession
        if (accession != null) {
            Log.d(TAG, "Attempting Europe PMC XML for $accession")
            when (val fetch = europePmcService.fetchFullTextXml(accession)) {
                is FullTextXmlFetch.Served -> {
                    // Europe PMC answered, so a lost identifier search did not cost this source
                    europePmcShortfall = null
                    parseEuropePmcXml(fetch.xml, accession)?.let { return@withContext Result.success(it) }
                }
                FullTextXmlFetch.Absent -> {
                    // Europe PMC's own answer, but not the article's absence:
                    // fullTextXML serves open-access text only, and a PMC or PPR
                    // accession names a record Europe PMC mirrors (#432)
                    Log.w(TAG, "Europe PMC did not serve full text for $accession (HTTP 404); trying other sources")
                    europePmcShortfall = RequestFailure.forHttpStatus(Constants.HTTP_NOT_FOUND)
                }
                is FullTextXmlFetch.Unreachable -> {
                    Log.w(TAG, "Europe PMC XML could not be retrieved for $accession (${fetch.failure.describe()})")
                    europePmcShortfall = fetch.failure
                }
            }
        }

        // Try Europe PMC PDF render URL (when XML unavailable but free PDF exists)
        if (!pdfRenderUrl.isNullOrEmpty()) {
            Log.d(TAG, "Using Europe PMC PDF render: $pdfRenderUrl")
            return@withContext Result.success(
                FullTextResult.EuropePmcPdf(pdfUrl = pdfRenderUrl)
            )
        }

        // Try Unpaywall if DOI is available
        if (!doi.isNullOrEmpty()) {
            Log.d(TAG, "Attempting Unpaywall PDF for $doi")
            val pdfResult = tryUnpaywallPdf(doi, email, pmid)
            if (pdfResult.isSuccess) {
                return@withContext pdfResult
            }
            Log.d(TAG, "Unpaywall PDF failed: ${pdfResult.exceptionOrNull()?.message}")
        }

        // Fall back to DOI URL if DOI is available
        if (!doi.isNullOrEmpty()) {
            Log.d(TAG, "Falling back to DOI URL for $doi")
            return@withContext Result.success(
                FullTextResult.DoiUrl("${Constants.DOI_URL_PREFIX}$doi")
            )
        }

        // Nothing was found, but Europe PMC did not settle the question. The
        // callers mark Unavailable on the document for good, so saying it here
        // would take the retry away from an article whose only fault was a busy
        // or closed Europe PMC (#434)
        europePmcShortfall?.let { failure ->
            Log.w(TAG, "No source served full text, and Europe PMC did not settle it (${failure.describe()})")
            return@withContext Result.success(FullTextResult.NotEstablished(failure))
        }

        // No full text available
        Result.success(
            FullTextResult.Unavailable("No full text source available")
        )
    }

    /**
     * Convert served JATS XML to markdown and HTML.
     *
     * @param xml The XML Europe PMC served.
     * @param accession The accession it was served under. Passed to the parser for
     *   figure URLs only when it is a PMC ID: a preprint's figures are not filed
     *   under its PPR ID.
     * @return The parsed content, or null when the XML could not be parsed (logged:
     *   a defect in us, and the chain goes on to the other sources).
     */
    private fun parseEuropePmcXml(xml: String, accession: String): FullTextResult.EuropePmcXml? {
        val knownPmcId = FullTextAccession.normalized(accession)
            ?.takeIf { it.startsWith(FullTextAccession.PMC_PREFIX) }
        return try {
            val parser = JATSXMLParser(
                xmlData = xml.toByteArray(Charsets.UTF_8),
                knownPmcId = knownPmcId
            )
            val markdown = parser.parseToMarkdown()

            // Create a new parser instance for HTML (parsers are single-use)
            val htmlParser = JATSXMLParser(
                xmlData = xml.toByteArray(Charsets.UTF_8),
                knownPmcId = knownPmcId
            )
            val html = htmlParser.parseToHTML()

            FullTextResult.EuropePmcXml(xml = xml, markdown = markdown, html = html)
        } catch (e: JATSParseError) {
            Log.e(TAG, "Europe PMC XML for $accession was retrieved but could not be parsed: ${e.message}")
            null
        } catch (e: Exception) {
            // Only parse() wraps its errors as JATSParseError; buildMarkdown() and
            // buildHTML() run outside it. A crash there is as much a defect in us
            // as a parse failure, and must not skip the PDF, Unpaywall and DOI
            // sources. Nothing here suspends, so there is no cancellation to catch
            Log.e(TAG, "Converting Europe PMC XML for $accession failed (a defect): $e")
            null
        }
    }

    /**
     * Try to fetch a PDF from Unpaywall.
     *
     * Unpaywall's answer is reduced to a choice by [UnpaywallLandingPage.chooseUrl]:
     * the first location's `url_for_pdf`, or failing that a landing page. A
     * location's `url` is never taken as the PDF: Unpaywall sets it to the landing
     * page when it has no PDF URL, and that page was downloaded as "the PDF" (#464).
     * A landing page is instead read for the PDF it declares ([readLandingPage]).
     *
     * A throttle or server fault from Unpaywall is retried with the transport
     * errors.
     *
     * @param doi Digital Object Identifier.
     * @param email Email for API identification.
     * @param pmid PubMed ID for caching.
     * @return Result containing the PDF URL, or the failure: a
     *   [FullTextUnavailableException] when Unpaywall or the landing page answered
     *   without a PDF (an expected miss, logged by the caller); an
     *   [OpenAccessUnsettledException] when Unpaywall or the landing page could not
     *   answer (logged here as a warning); any other exception when the lookup
     *   failed otherwise (logged here). Either way the chain goes on.
     * @throws CancellationException if the caller cancelled.
     */
    private suspend fun tryUnpaywallPdf(
        doi: String,
        email: String,
        pmid: String?
    ): Result<FullTextResult> {
        return try {
            val choice = try {
                NetworkRetry.withExponentialBackoff(
                    maxRetries = Constants.NETWORK_MAX_RETRIES,
                    shouldRetry = { NetworkRetry.isRetryableException(it) }
                ) {
                    val response = unpaywallApi.getWorkByDoi(doi, email)

                    if (!response.isSuccessful) {
                        if (response.code() == Constants.HTTP_NOT_FOUND) {
                            throw FullTextUnavailableException("DOI not found in Unpaywall: $doi")
                        }
                        if (NetworkRetry.isRetryableStatusCode(response.code())) {
                            throw RetryableStatusException(response.code())
                        }
                        throw FullTextException("Unpaywall API error: ${response.code()} ${response.message()}")
                    }

                    val body = response.body()
                        ?: throw FullTextException("Empty response from Unpaywall")

                    UnpaywallLandingPage.chooseUrl(body)
                }
            } catch (e: RetryableStatusException) {
                throw OpenAccessUnsettledException(RequestFailure.forHttpStatus(e.statusCode))
            } catch (e: IOException) {
                throw OpenAccessUnsettledException(RequestFailure.fromException(e))
            } catch (e: SerializationException) {
                // An answer we cannot read has told us nothing about the article
                throw OpenAccessUnsettledException(RequestFailure.fromException(e))
            }

            // Outside the retry above: a landing page that cannot be read must not
            // ask Unpaywall again
            val pdfUrl = choice.pdfUrl
                ?: choice.landingPage?.let { page ->
                    when (val read = readLandingPage(page)) {
                        is LandingPageRead.Declared -> read.pdfUrl
                        LandingPageRead.DeclaresNone -> null
                        is LandingPageRead.Unreachable -> throw OpenAccessUnsettledException(read.failure)
                    }
                }
                ?: throw FullTextUnavailableException("No PDF URL available for $doi")

            Result.success(
                FullTextResult.UnpaywallPdf(
                    pdfUrl = pdfUrl,
                    localPath = null  // Not downloaded yet
                )
            )
        } catch (e: CancellationException) {
            throw e
        } catch (e: FullTextUnavailableException) {
            Result.failure(e)
        } catch (e: OpenAccessUnsettledException) {
            Log.w(TAG, "The open-access copy of $doi went unassessed: ${e.message}")
            Result.failure(e)
        } catch (e: Exception) {
            Log.e(TAG, "Unpaywall lookup failed: ${e.message}")
            Result.failure(e)
        }
    }

    /**
     * Read the landing page Unpaywall names for the PDF it declares (#464).
     *
     * Called only when no Unpaywall location offers a `url_for_pdf`. The page is
     * fetched with GET, asking for HTML, redirects followed; transport errors and
     * the throttles and server faults [NetworkRetry.isRetryableStatusCode] names are
     * retried with backoff. What the page settled is then read by [landingPageRead].
     *
     * A page that could not be reached, or whose status
     * [UnpaywallLandingPage.webPageStatusUnsettled] calls unsettled after the
     * retries, is [LandingPageRead.Unreachable]: not the page's answer, so not a
     * page without a PDF. The landing page itself is returned only when it was
     * served as a PDF.
     *
     * @param pageUrl The landing page Unpaywall named.
     * @return What the read settled.
     * @throws CancellationException if the caller cancelled.
     */
    private suspend fun readLandingPage(pageUrl: String): LandingPageRead {
        val url = pageUrl.toHttpUrlOrNull()
        if (url == null) {
            Log.d(TAG, "Unpaywall's landing page is not an http(s) URL: $pageUrl")
            return LandingPageRead.DeclaresNone
        }
        val request = Request.Builder()
            .url(url)
            .header(Constants.HTTP_ACCEPT_HEADER, Constants.LANDING_PAGE_ACCEPT)
            .header(USER_AGENT_HEADER, USER_AGENT)
            .build()

        val read = try {
            NetworkRetry.withExponentialBackoff(
                maxRetries = Constants.NETWORK_MAX_RETRIES,
                shouldRetry = { NetworkRetry.isRetryableException(it) }
            ) {
                withContext(Dispatchers.IO) {
                    httpClient.newCall(request).execute().use { response ->
                        // Retried: a throttle or server fault is "not now"
                        if (NetworkRetry.isRetryableStatusCode(response.code)) {
                            throw RetryableStatusException(response.code)
                        }
                        landingPageRead(response)
                    }
                }
            }
        } catch (e: RetryableStatusException) {
            LandingPageRead.Unreachable(RequestFailure.forHttpStatus(e.statusCode))
        } catch (e: IOException) {
            LandingPageRead.Unreachable(RequestFailure.fromException(e))
        }
        when (read) {
            is LandingPageRead.Declared ->
                Log.d(TAG, "Unpaywall's landing page $pageUrl declares the PDF ${read.pdfUrl}")
            LandingPageRead.DeclaresNone ->
                Log.d(TAG, "Unpaywall's landing page $pageUrl declares no PDF")
            is LandingPageRead.Unreachable ->
                Log.w(TAG, "Unpaywall's landing page $pageUrl could not be read (${read.failure.describe()})")
        }
        return read
    }

    /**
     * What a landing page's response settled.
     *
     * A page served as a PDF is the PDF (a repository bitstream link). An HTML
     * page, or one of no stated type, is read for its `citation_pdf_url`, by its
     * declared charset or as UTF-8, and resolved against the URL it was served
     * from after redirects; no other body is read. Anything else is the page's
     * answer that it declares none.
     *
     * @param response The page's response, redirects already followed; its body
     *   is read here.
     * @return What the response settled.
     * @throws IOException if the body could not be read (retried by the caller).
     */
    private fun landingPageRead(response: Response): LandingPageRead {
        if (response.code >= Constants.HTTP_ERROR_STATUS_MIN) {
            return if (UnpaywallLandingPage.webPageStatusUnsettled(response.code)) {
                LandingPageRead.Unreachable(RequestFailure.forHttpStatus(response.code))
            } else {
                LandingPageRead.DeclaresNone
            }
        }
        val finalUrl = response.request.url.toString()
        // An absent Content-Type is read as the HTML it nearly always is
        val contentType = response.header(CONTENT_TYPE_HEADER).orEmpty().lowercase()
        if (Constants.LANDING_PAGE_PDF_MARKER in contentType) {
            return LandingPageRead.Declared(finalUrl)
        }
        if (contentType.isNotBlank() && Constants.LANDING_PAGE_HTML_MARKER !in contentType) {
            return LandingPageRead.DeclaresNone
        }
        val body = response.body ?: return LandingPageRead.DeclaresNone
        val html = UnpaywallLandingPage.pageText(body.bytes(), body.contentType()?.charset())
        return UnpaywallLandingPage.citationPdfUrl(html, finalUrl)
            ?.let { LandingPageRead.Declared(it) }
            ?: LandingPageRead.DeclaresNone
    }

    /**
     * Resolve a PMC ID, a preprint's record ID and a PDF render URL from a PMID or
     * DOI via Europe PMC search.
     *
     * Tries PMID first (more specific), then DOI, stopping once an accession is
     * found. Written as a fold so a failed first search is not forgotten when the
     * second answers nothing.
     *
     * @param pmid PubMed ID to resolve.
     * @param doi DOI to resolve.
     * @return What every attempted search learned, merged.
     */
    private suspend fun resolvePmcIdAndPdfUrl(pmid: String?, doi: String?): PmcResolution {
        val queries = listOfNotNull(
            pmid?.takeIf { it.isNotBlank() }?.let { "ext_id:$it src:med" },
            doi?.takeIf { it.isNotBlank() }?.let { "DOI:\"$it\"" }
        )
        var accumulated = PmcResolution()
        for (query in queries) {
            accumulated = accumulated.merging(searchForPmcIdAndPdfUrl(query))
            if (accumulated.pmcId != null || accumulated.preprintAccession != null) {
                Log.d(TAG, "Resolved '$query' to ${accumulated.pmcId ?: accumulated.preprintAccession}")
                return accumulated
            }
        }
        return accumulated
    }

    /**
     * Search Europe PMC and read what the first result says about the article.
     *
     * Preprints are included: the default search filters them out, and a DOI is
     * the only route a preprint document has to its record here.
     *
     * @param query The Europe PMC query.
     * @return What the first result carried; an empty resolution when the search
     *   matched nothing; the failure when it could not be asked.
     * @throws CancellationException if the caller cancelled.
     */
    private suspend fun searchForPmcIdAndPdfUrl(query: String): PmcResolution {
        val result = try {
            europePmcService.search(
                query = query,
                batchSize = 1,
                includePreprints = true,
                resultsReceived = 0
            )
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
        return result.fold(
            onSuccess = { page ->
                page.articles.firstOrNull()?.let(PmcResolution::fromArticle) ?: PmcResolution()
            },
            onFailure = { error ->
                val failure = (error as? SourceRequestException)?.failure ?: RequestFailure.fromException(error)
                Log.w(TAG, "PMC ID resolution failed for query '$query': ${failure.describe()}")
                PmcResolution(failure = failure)
            }
        )
    }

    /**
     * Download a PDF to local cache.
     *
     * @param pdfUrl URL of the PDF to download.
     * @param documentId Document ID for file naming.
     * @return Local file path or null if download failed.
     */
    suspend fun downloadPdf(pdfUrl: String, documentId: String): String? = withContext(Dispatchers.IO) {
        try {
            val cacheDir = File(context.cacheDir, PDF_CACHE_DIR).apply {
                if (!exists()) mkdirs()
            }

            val fileName = "${documentId}.pdf"
            val localFile = File(cacheDir, fileName)

            // Return existing file if already cached
            if (localFile.exists() && localFile.length() > 0) {
                Log.d(TAG, "Using cached PDF: ${localFile.absolutePath}")
                return@withContext localFile.absolutePath
            }

            Log.d(TAG, "Downloading PDF from: $pdfUrl")

            val request = Request.Builder()
                .url(pdfUrl)
                .header(USER_AGENT_HEADER, USER_AGENT)
                .build()

            httpClient.newCall(request).execute().use { response ->
                if (!response.isSuccessful) {
                    Log.e(TAG, "PDF download failed: ${response.code} ${response.message}")
                    return@withContext null
                }

                response.body?.let { body ->
                    FileOutputStream(localFile).use { output ->
                        body.byteStream().copyTo(output)
                    }
                    Log.d(TAG, "PDF downloaded to: ${localFile.absolutePath}")
                    return@withContext localFile.absolutePath
                }
            }

            null
        } catch (e: Exception) {
            Log.e(TAG, "PDF download error: ${e.message}")
            null
        }
    }

    /**
     * Get cached PDF path if it exists.
     *
     * @param documentId Document ID used for caching.
     * @return Local file path or null if not cached.
     */
    fun getCachedPdfPath(documentId: String): String? {
        val cacheDir = File(context.cacheDir, PDF_CACHE_DIR)
        val fileName = "${documentId}.pdf"
        val localFile = File(cacheDir, fileName)

        return if (localFile.exists() && localFile.length() > 0) {
            localFile.absolutePath
        } else {
            null
        }
    }

    /**
     * Clear all cached PDFs.
     *
     * @return Number of files deleted.
     */
    fun clearPdfCache(): Int {
        val cacheDir = File(context.cacheDir, PDF_CACHE_DIR)
        if (!cacheDir.exists()) return 0

        var deletedCount = 0
        cacheDir.listFiles()?.forEach { file ->
            if (file.delete()) deletedCount++
        }

        Log.d(TAG, "Cleared $deletedCount cached PDFs")
        return deletedCount
    }

    /**
     * Get the source constant for a FullTextResult.
     *
     * @param result Full text result.
     * @return Source constant string for storage.
     */
    fun getSourceConstant(result: FullTextResult): String? {
        return when (result) {
            is FullTextResult.EuropePmcXml -> Constants.FULLTEXT_SOURCE_EUROPE_PMC
            is FullTextResult.EuropePmcPdf -> Constants.FULLTEXT_SOURCE_EUROPE_PMC
            is FullTextResult.UnpaywallPdf -> Constants.FULLTEXT_SOURCE_UNPAYWALL
            is FullTextResult.DoiUrl -> Constants.FULLTEXT_SOURCE_DOI
            is FullTextResult.Unavailable -> null
            is FullTextResult.NotEstablished -> null
        }
    }
}

/**
 * Exception indicating full text is unavailable (expected case, not error).
 */
class FullTextUnavailableException(message: String) : Exception(message)

/**
 * Exception indicating a full text retrieval error.
 */
class FullTextException(message: String, cause: Throwable? = null) : Exception(message, cause)

/**
 * Unpaywall, or the landing page it named, could not answer: the open-access copy
 * went unassessed, which is not the same as there being none (#464).
 *
 * @property failure Why, by kind and status only
 */
class OpenAccessUnsettledException(val failure: RequestFailure) :
    Exception("the open-access copy could not be reached (${failure.describe()})")

/**
 * A throttle or server fault, thrown inside a retry block so the transport-error
 * retry policy ([NetworkRetry.isRetryableException]) retries it too.
 *
 * @property statusCode The status the source answered with
 */
class RetryableStatusException(val statusCode: Int) : IOException("HTTP $statusCode")

/**
 * The sentence for a chain that found nothing while Europe PMC did not settle
 * whether the full text exists (#434).
 *
 * The verb follows #435's decision: an HTTP status other than a throttle or a 5xx
 * (#445) was an answer, so Europe PMC "did not serve it"; those and any other
 * failure mean it "could not be asked" ([RequestFailure.isAnswer]). Worded as
 * BioMedLit's `FullTextError.absenceNotEstablished` (iOS and macOS).
 *
 * @param failure What Europe PMC's side of the chain got instead of the article's text
 * @return The sentence
 */
fun absenceNotEstablishedMessage(failure: RequestFailure): String =
    if (failure.isAnswer) {
        "No source provided this article's full text. Europe PMC (${failure.describe()}) " +
            "did not serve it, so it may still exist. Try again later."
    } else {
        "No source provided this article's full text. Europe PMC could not be asked " +
            "(${failure.describe()}), so it may still exist. Try again later."
    }
