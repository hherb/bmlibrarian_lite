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
import com.bmlibrarian.factchecker.domain.model.OpenAccessShortfall
import com.bmlibrarian.factchecker.domain.model.OpenAccessSource
import com.bmlibrarian.factchecker.domain.model.RequestFailure
import com.bmlibrarian.factchecker.domain.model.RequestFailureKind
import com.bmlibrarian.factchecker.domain.model.SourceRequestException
import com.bmlibrarian.factchecker.domain.model.UnpaywallContact
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
import java.io.IOException
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Service for fetching full-text content from multiple sources.
 *
 * Implements a fallback chain:
 * 1. Europe PMC XML (JATS format) - preferred, machine-readable
 * 2. PMC's open-data bucket (JATS, by PMC ID) - when Europe PMC's XML gave no text (#480)
 * 3. Europe PMC PDF render - a free PDF Europe PMC offers
 * 4. Unpaywall PDFs - every PDF its locations name, tried in order when downloaded,
 *    or the PDF an open-access landing page declares
 * 5. DOI Resolution - link to publisher website
 *
 * Full-text content is cached locally after first retrieval.
 */
@Singleton
class FullTextService @Inject constructor(
    @ApplicationContext private val context: Context,
    private val europePmcService: EuropePMCService,
    private val unpaywallApi: UnpaywallApi,
    private val httpClient: OkHttpClient,
    private val pmcOpenData: PmcOpenDataService
) {
    companion object {
        private const val TAG = "FullTextService"
        private const val PDF_CACHE_DIR = "fulltext_pdfs"

        /** Appended to a PDF's cache name while its download is in progress. */
        private const val PDF_PARTIAL_SUFFIX = ".part"

        /** Appended to a cached file that is not a PDF, kept aside for whoever investigates. */
        private const val PDF_CORRUPT_SUFFIX = ".corrupt"

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
         * Full text retrieved from PMC's open-data bucket as JATS XML (#480),
         * parsed as Europe PMC's is. Asked only when Europe PMC's XML gave no
         * text; holds the author manuscripts Europe PMC does not serve.
         *
         * @param xml Raw XML content.
         * @param markdown Parsed markdown content.
         * @param html Parsed HTML content.
         */
        data class PmcOpenDataXml(
            val xml: String,
            val markdown: String,
            val html: String
        ) : FullTextResult(hasContent = true)

        /**
         * PDF available from Europe PMC render URL (when XML is unavailable),
         * not yet downloaded: where it is saved is recorded on the document.
         *
         * @param pdfUrl URL to the Europe PMC PDF.
         */
        data class EuropePmcPdf(
            val pdfUrl: String
        ) : FullTextResult(hasContent = true)

        /**
         * The open-access PDFs to try, in chain order, with any lookup that went
         * unsettled before them (#480, stage B). Downloaded by
         * [recordingFullTextFetch], which resolves this to an [OpenAccessPdf] or,
         * when none could be obtained, the DOI link carrying every shortfall met.
         *
         * A PDF named that the source does not then serve is refused, not offered
         * as a link (#478); one the source served that could not be saved is a
         * fault of ours, kept as a link with a caching note ([PdfDownload.NotSaved]).
         *
         * @property steps In chain order; at least one [OpenAccessStep.Candidate]
         * @property doi The DOI they were found for, for the link a refused PDF
         *   falls back to
         * @property openAlexAsked Whether OpenAlex's steps are already among them
         */
        data class OpenAccessPdfs(
            val steps: List<OpenAccessStep>,
            val doi: String,
            val openAlexAsked: Boolean = false
        ) : FullTextResult(hasContent = true) {
            init {
                require(steps.any { it is OpenAccessStep.Candidate }) { "nothing to try is not a PDF result" }
            }
        }

        /**
         * The open-access PDF obtained, or served but not saved (its link kept,
         * with a caching note).
         *
         * @property pdfUrl The PDF's address
         * @property doi The DOI it was found for
         * @property namedBy Who named it, which decides the source it is recorded under
         * @property notSaved Whether it was served and could not be saved here
         */
        data class OpenAccessPdf(
            val pdfUrl: String,
            val doi: String,
            val namedBy: PdfNamer,
            val notSaved: Boolean = false
        ) : FullTextResult(hasContent = true)

        /**
         * Fall back to DOI/publisher URL.
         *
         * @param url URL to the publisher page.
         * @param openAccessShortfall Why the open-access copy went unassessed when
         *   Unpaywall, the landing page it named, or the PDF it named could not
         *   settle whether a free copy exists; null when nothing was left unsettled. Stored on the document and shown to the
         *   reader (#466): the link alone reads as "no free copy".
         */
        data class DoiUrl(
            val url: String,
            val openAccessShortfall: OpenAccessShortfall? = null
        ) : FullTextResult(hasContent = true)

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
         * No source provided the full text, but Europe PMC or PMC's open-data
         * bucket did not settle whether it exists (#434, #480).
         *
         * Europe PMC answered without serving the article (an HTTP status such
         * as `fullTextXML`'s 404 for text that is not open access (#432), from
         * the fetch or the identifier search), or gave no answer at all (a
         * throttle (429), a 5xx that outlasted its retries (#445), a timeout, a
         * dropped connection, a blank body, an identifier never sent).
         * The reader's sentence follows the same split, by
         * [RequestFailure.isAnswer]: see [notEstablishedMessage].
         * Unlike [Unavailable], a claim about us: callers must not mark
         * the document unavailable for good on it, or a busy Europe PMC takes the
         * retry away.
         *
         * Europe PMC's shortfall is named first; the bucket's only when Europe
         * PMC left nothing unsettled, as Python and BioMedLit do.
         *
         * @param failure What the named source got instead of the article's text
         * @param source The source that did not settle it, and that the sentence
         *   names; always given, so no source is named by default
         */
        data class NotEstablished(
            val failure: RequestFailure,
            val source: NotEstablishedSource
        ) : FullTextResult(hasContent = false) {
            /** The sentence shown to the reader. */
            val reason: String
                get() = notEstablishedMessage(source.serviceName, failure)
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
     * @param email Email to ask Unpaywall with ([UnpaywallContact.emailFor]); null,
     *   blank or the placeholder skips Unpaywall as not configured.
     * @return The full text or a link to it; [FullTextResult.Unavailable] when every
     *   source answered without it (callers record this); or
     *   [FullTextResult.NotEstablished] when Europe PMC, or failing that PMC's
     *   open-data bucket, did not settle it (never recorded). No path here returns a failed [Result].
     * @throws CancellationException if the caller cancelled.
     */
    suspend fun fetchFullText(
        pmcId: String?,
        doi: String?,
        pmid: String?,
        email: String? = null
    ): Result<FullTextResult> = withContext(Dispatchers.IO) {
        // What Europe PMC's side of the chain got instead of the article's text,
        // if anything. Set by a lost identifier search, a failed fetch and
        // a fullTextXML 404; cleared by a fetch that was served. Read only at the
        // end: a chain that found nothing must not call the article's full text
        // absent while this is set (#434)
        var europePmcShortfall: RequestFailure? = null

        // What PMC's open-data bucket got instead of the article's JATS, when it
        // could not be read or its XML would not parse (#480). Named only when
        // Europe PMC left nothing unsettled
        var pmcOpenDataShortfall: RequestFailure? = null

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
                    parseJats(fetch.xml, accession)?.let { parsed ->
                        return@withContext Result.success(
                            FullTextResult.EuropePmcXml(xml = fetch.xml, markdown = parsed.markdown, html = parsed.html)
                        )
                    }
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

        // PMC's open-data bucket (#480), by PMC ID, when Europe PMC's XML gave no
        // text. Before Europe PMC's PDF render, which answers 403 to every
        // client (#453). `resolvedPmcId` is the caller's PMC ID or the one the
        // search resolved; a PPR preprint accession is never asked, because the
        // bucket files by PMC ID only
        val bucketPmcId = resolvedPmcId?.let(FullTextAccession::normalized)
            ?.takeIf { it.startsWith(FullTextAccession.PMC_PREFIX) }
        if (bucketPmcId != null) {
            Log.d(TAG, "Attempting PMC's open-access collection for $bucketPmcId")
            when (val fetch = pmcOpenData.fetchXml(bucketPmcId)) {
                is PmcOpenDataFetch.Served -> {
                    val parsed = parseJats(fetch.xml, bucketPmcId)
                    if (parsed != null) {
                        Log.d(TAG, "Retrieved full text for $bucketPmcId from PMC's open-access collection")
                        return@withContext Result.success(
                            FullTextResult.PmcOpenDataXml(xml = fetch.xml, markdown = parsed.markdown, html = parsed.html)
                        )
                    }
                    // Python and Swift record an unconvertible bucket XML as a
                    // malformed answer, so the chain does not call the full text
                    // absent on it
                    pmcOpenDataShortfall = RequestFailure(RequestFailureKind.MALFORMED_RESPONSE)
                }
                // The bucket's own answer about itself: nothing to record
                PmcOpenDataFetch.Absent -> Unit
                is PmcOpenDataFetch.Unreachable -> {
                    Log.w(
                        TAG,
                        "PMC's open-access collection could not be read for $bucketPmcId " +
                            "(${fetch.failure.describe()}); trying other sources"
                    )
                    pmcOpenDataShortfall = fetch.failure
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

        // Try Unpaywall if DOI is available: every PDF it names is a step, tried
        // in order when the PDFs are downloaded (#480, stage B). A lookup that
        // could not settle whether a free copy exists is carried on the
        // fallback, so the reader is told so rather than shown the DOI link as
        // though there were none (#466)
        var openAccessShortfall: OpenAccessShortfall? = null
        if (!doi.isNullOrEmpty()) {
            Log.d(TAG, "Attempting Unpaywall PDF for $doi")
            val steps = unpaywallSteps(doi, email, pmid)
            if (steps.any { it is OpenAccessStep.Candidate }) {
                return@withContext Result.success(FullTextResult.OpenAccessPdfs(steps, doi))
            }
            openAccessShortfall = steps.filterIsInstance<OpenAccessStep.Unsettled>()
                .fold(null as OpenAccessShortfall?) { held, step -> OpenAccessShortfall.adding(step.shortfall, held) }
            Log.d(TAG, "Unpaywall named no PDF to try for $doi")
        }

        // Fall back to DOI URL if DOI is available
        if (!doi.isNullOrEmpty()) {
            Log.d(TAG, "Falling back to DOI URL for $doi")
            return@withContext Result.success(
                FullTextResult.DoiUrl(doiLink(doi), openAccessShortfall)
            )
        }

        // Nothing was found, but Europe PMC did not settle the question. The
        // callers mark Unavailable on the document for good, so saying it here
        // would take the retry away from an article whose only fault was a busy
        // or closed Europe PMC (#434)
        europePmcShortfall?.let { failure ->
            Log.w(TAG, "No source served full text, and Europe PMC did not settle it (${failure.describe()})")
            return@withContext Result.success(
                FullTextResult.NotEstablished(failure, NotEstablishedSource.EUROPE_PMC)
            )
        }

        // The same for PMC's open-data bucket, which holds the author manuscripts
        // Europe PMC does not serve: one it could not read may have held the
        // article (#480)
        pmcOpenDataShortfall?.let { failure ->
            Log.w(
                TAG,
                "No source served full text, and PMC's open-access collection could not be read " +
                    "(${failure.describe()})"
            )
            return@withContext Result.success(
                FullTextResult.NotEstablished(failure, NotEstablishedSource.PMC_OPEN_DATA)
            )
        }

        // No full text available
        Result.success(
            FullTextResult.Unavailable("No full text source available")
        )
    }

    /**
     * Markdown and HTML converted from served JATS XML.
     *
     * @property markdown The article as markdown
     * @property html The article as HTML (body content only)
     */
    private data class ParsedJats(val markdown: String, val html: String)

    /**
     * Convert served JATS XML to markdown and HTML.
     *
     * Shared by Europe PMC's XML and PMC's open-data bucket (#480), whose JATS is
     * the same format.
     *
     * @param xml The XML the source served.
     * @param accession The accession it was served under. Passed to the parser for
     *   figure URLs only when it is a PMC ID: a preprint's figures are not filed
     *   under its PPR ID.
     * @return The parsed content, or null when the XML could not be parsed (logged:
     *   a defect in us, and the chain goes on to the other sources).
     */
    private fun parseJats(xml: String, accession: String): ParsedJats? {
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

            ParsedJats(markdown = markdown, html = html)
        } catch (e: JATSParseError) {
            Log.e(TAG, "JATS XML for $accession was retrieved but could not be parsed: ${e.message}")
            null
        } catch (e: Exception) {
            // Only parse() wraps its errors as JATSParseError; buildMarkdown() and
            // buildHTML() run outside it. A crash there is as much a defect in us
            // as a parse failure, and must not skip the PDF, Unpaywall and DOI
            // sources. Nothing here suspends, so there is no cancellation to catch
            Log.e(TAG, "Converting JATS XML for $accession failed (a defect): $e")
            null
        }
    }

    /**
     * Ask Unpaywall for the PDFs it names, as open-access steps (#480, stage B).
     *
     * Every location's `url_for_pdf` is a step, best location first, each once
     * ([UnpaywallLandingPage.pdfUrls]). A location's `url` is never taken as the
     * PDF: Unpaywall sets it to the landing page when it has no PDF URL, and that
     * page was downloaded as "the PDF" (#464). Only when no location names a PDF
     * is a landing page ([UnpaywallLandingPage.chooseUrl]) read for the PDF it
     * declares ([readLandingPage]).
     *
     * A throttle or server fault from Unpaywall is retried with the transport
     * errors.
     *
     * @param doi Digital Object Identifier.
     * @param email Email for API identification; with no usable one
     *   ([UnpaywallContact.usableEmail]) Unpaywall is not asked at all.
     * @param pmid PubMed ID for caching.
     * @return The steps in chain order: a [OpenAccessStep.Candidate] for each PDF
     *   to download, and an [OpenAccessStep.Unsettled] for an address that cannot
     *   be requested (#478) or a lookup that left the copy unassessed (logged
     *   here): Unpaywall not configured, its answer lost, unreadable or an error
     *   status other than 404, the landing page unread, or an unexpected error.
     *   Empty when Unpaywall answered 404 or neither it nor the landing page
     *   declared a PDF: an expected miss.
     * @throws CancellationException if the caller cancelled.
     */
    private suspend fun unpaywallSteps(
        doi: String,
        email: String?,
        pmid: String?
    ): List<OpenAccessStep> {
        val contact = UnpaywallContact.usableEmail(email)
        if (contact == null) {
            // Unpaywall refuses a missing or placeholder address with 422 for
            // every article; asking anyway blamed the article for our settings
            Log.w(TAG, "Unpaywall not asked for $doi: no usable contact email is configured")
            return listOf(OpenAccessStep.Unsettled(OpenAccessShortfall.UNPAYWALL_NOT_CONFIGURED))
        }
        return try {
            val body = try {
                NetworkRetry.withExponentialBackoff(
                    maxRetries = Constants.NETWORK_MAX_RETRIES,
                    shouldRetry = { NetworkRetry.isRetryableException(it) }
                ) {
                    val response = unpaywallApi.getWorkByDoi(doi, contact)

                    if (!response.isSuccessful) {
                        if (response.code() == Constants.HTTP_NOT_FOUND) {
                            throw FullTextUnavailableException("DOI not found in Unpaywall: $doi")
                        }
                        if (NetworkRetry.isRetryableStatusCode(response.code())) {
                            throw RetryableStatusException(response.code())
                        }
                        // Any other error status leaves the copy unassessed too: only a
                        // 404 says Unpaywall holds no record of the DOI. Python records
                        // every such status as a failed lookup, and the reader is told
                        // so in the same words (#466)
                        throw OpenAccessUnsettledException(
                            OpenAccessShortfall(
                                OpenAccessSource.UNPAYWALL,
                                RequestFailure(RequestFailureKind.HTTP_STATUS, response.code())
                            )
                        )
                    }

                    // An empty answer has told us nothing about the article
                    response.body()
                        ?: throw OpenAccessUnsettledException(
                            OpenAccessShortfall(
                                OpenAccessSource.UNPAYWALL,
                                RequestFailure(RequestFailureKind.MALFORMED_RESPONSE)
                            )
                        )
                }
            } catch (e: RetryableStatusException) {
                throw OpenAccessUnsettledException(
                    OpenAccessShortfall(OpenAccessSource.UNPAYWALL, RequestFailure.forHttpStatus(e.statusCode))
                )
            } catch (e: IOException) {
                throw OpenAccessUnsettledException(
                    OpenAccessShortfall(OpenAccessSource.UNPAYWALL, RequestFailure.fromException(e))
                )
            } catch (e: SerializationException) {
                // An answer we cannot read has told us nothing about the article
                throw OpenAccessUnsettledException(
                    OpenAccessShortfall(OpenAccessSource.UNPAYWALL, RequestFailure.fromException(e))
                )
            }

            val pdfUrls = UnpaywallLandingPage.pdfUrls(body)
            if (pdfUrls.isNotEmpty()) {
                return pdfUrls.map { candidateOrRefused(it, PdfNamer.UNPAYWALL) }
            }

            // Outside the retry above: a landing page that cannot be read must not
            // ask Unpaywall again
            val page = UnpaywallLandingPage.chooseUrl(body).landingPage
            if (page == null) {
                Log.d(TAG, "Unpaywall names no PDF and no landing page for $doi")
                return emptyList()
            }
            when (val read = readLandingPage(page)) {
                is LandingPageRead.Declared -> listOf(candidateOrRefused(read.pdfUrl, PdfNamer.UNPAYWALL))
                LandingPageRead.DeclaresNone -> emptyList()
                is LandingPageRead.Unreachable -> listOf(
                    OpenAccessStep.Unsettled(OpenAccessShortfall(OpenAccessSource.LANDING_PAGE, read.failure))
                )
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: FullTextUnavailableException) {
            Log.d(TAG, "Unpaywall PDF lookup found nothing: ${e.message}")
            emptyList()
        } catch (e: OpenAccessUnsettledException) {
            Log.w(TAG, "The open-access copy of $doi went unassessed: ${e.message}")
            listOf(OpenAccessStep.Unsettled(e.shortfall))
        } catch (e: Exception) {
            // Not an answer about the article, so the copy went unassessed: the
            // reader is told so, as Swift does for an unexpected error
            Log.e(TAG, "Unpaywall lookup of $doi failed unexpectedly", e)
            listOf(
                OpenAccessStep.Unsettled(
                    OpenAccessShortfall(OpenAccessSource.UNPAYWALL, RequestFailure(RequestFailureKind.REQUEST_FAILED))
                )
            )
        }
    }

    /**
     * A PDF address as a step: a candidate, or refused at once, with its
     * address, when it cannot be requested (#478).
     *
     * An address that cannot be requested is never handed on as the PDF link:
     * the source answered, and the copy it named went unassessed. Swift refuses
     * the same addresses, and Python's `requests` will not send them.
     *
     * @param url The address the source named
     * @param namer Who named it
     * @return The step for it
     */
    private fun candidateOrRefused(url: String, namer: PdfNamer): OpenAccessStep =
        if (url.toHttpUrlOrNull() == null) {
            Log.w(TAG, "${namer.label} named a PDF address that cannot be requested: $url")
            OpenAccessStep.Unsettled(
                OpenAccessShortfall(namer.refusedAs, RequestFailure(RequestFailureKind.REQUEST_FAILED), url)
            )
        } else {
            OpenAccessStep.Candidate(url, namer)
        }

    /**
     * Read the landing page Unpaywall names for the PDF it declares (#464).
     *
     * Called only when no Unpaywall location offers a `url_for_pdf`. The page is
     * fetched with GET, asking for HTML, redirects followed; transport errors and
     * the throttles and server faults [NetworkRetry.isRetryableStatusCode] names are
     * retried with backoff. What the page settled is then read by [landingPageRead].
     *
     * A page that could not be reached, whose address is not an http(s) URL, or
     * whose status [UnpaywallLandingPage.webPageStatusUnsettled] calls unsettled
     * after the retries, is [LandingPageRead.Unreachable]: not the page's answer,
     * so not a page without a PDF. The landing page itself is returned only when
     * it was served as a PDF.
     *
     * @param pageUrl The landing page Unpaywall named.
     * @return What the read settled.
     * @throws CancellationException if the caller cancelled.
     */
    private suspend fun readLandingPage(pageUrl: String): LandingPageRead {
        // An address we cannot fetch is a page we did not read, not one that
        // declares no PDF: Python's `requests` refuses the same addresses and
        // records a failed request (#474)
        val url = pageUrl.toHttpUrlOrNull()
        if (url == null) {
            Log.w(TAG, "Unpaywall's landing page is not an http(s) URL ($pageUrl), so it was not read")
            return LandingPageRead.Unreachable(RequestFailure(RequestFailureKind.REQUEST_FAILED))
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
     * page, or one of no stated type, is read up to
     * [Constants.LANDING_PAGE_MAX_BYTES] for its `citation_pdf_url`, by its
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
        val source = body.source()
        source.request(Constants.LANDING_PAGE_MAX_BYTES.toLong())
        val bytes = source.buffer.readByteArray(
            minOf(source.buffer.size, Constants.LANDING_PAGE_MAX_BYTES.toLong())
        )
        val html = UnpaywallLandingPage.pageText(bytes, body.contentType()?.charset())
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
     * The body is written to `<id>.pdf.part` and renamed into place only once
     * it has arrived whole and begins with `%PDF` ([looksLikePdf]), so a page
     * served in the PDF's place, or a download that broke off, is never
     * returned as cached (#478). The partial file is removed on every other
     * outcome. A cached file that is not a PDF, written by an earlier build, is
     * quarantined and fetched again (fulltext_retrieval.md, "Cache Read
     * Validation").
     *
     * @param pdfUrl URL of the PDF to download.
     * @param documentId Document ID for file naming.
     * @return The cached file; why the source did not serve the PDF (the status,
     *   the transport failure, `MALFORMED_RESPONSE` for a body that is not a
     *   PDF, or `REQUEST_FAILED` for an address that cannot be requested); or
     *   [PdfDownload.NotSaved] when the cache could not be written.
     * @throws CancellationException if the caller cancelled.
     */
    suspend fun downloadPdf(pdfUrl: String, documentId: String): PdfDownload = withContext(Dispatchers.IO) {
        try {
            val cacheDir = File(context.cacheDir, PDF_CACHE_DIR).apply {
                if (!exists()) mkdirs()
            }

            val fileName = "${documentId}.pdf"
            val localFile = File(cacheDir, fileName)

            if (isCachedPdf(localFile)) {
                Log.d(TAG, "Using cached PDF: ${localFile.absolutePath}")
                return@withContext PdfDownload.Saved(localFile.absolutePath)
            }
            if (localFile.exists()) {
                Log.w(TAG, "Quarantining a cached file that is not a PDF: ${localFile.absolutePath}")
                quarantineCachedFile(localFile, File(cacheDir, "$fileName$PDF_CORRUPT_SUFFIX"))
            }

            val request = pdfUrl.toHttpUrlOrNull()?.let { url ->
                Request.Builder().url(url).header(USER_AGENT_HEADER, USER_AGENT).build()
            } ?: run {
                Log.w(TAG, "PDF address cannot be requested: $pdfUrl")
                return@withContext PdfDownload.Failed(RequestFailure(RequestFailureKind.REQUEST_FAILED))
            }

            Log.d(TAG, "Downloading PDF from: $pdfUrl")
            httpClient.newCall(request).execute().use { response ->
                if (!response.isSuccessful) {
                    Log.w(TAG, "PDF download failed: HTTP ${response.code}")
                    return@withContext PdfDownload.Failed(RequestFailure.forHttpStatus(response.code))
                }
                val body = response.body ?: return@withContext PdfDownload.Failed(
                    RequestFailure(RequestFailureKind.MALFORMED_RESPONSE)
                )

                val partial = File(cacheDir, "$fileName$PDF_PARTIAL_SUFFIX")
                try {
                    body.byteStream().use { input -> input.copyToCache(partial) }
                    if (!isCachedPdf(partial)) {
                        Log.w(TAG, "PDF download from $pdfUrl is not a PDF")
                        return@withContext PdfDownload.Failed(RequestFailure(RequestFailureKind.MALFORMED_RESPONSE))
                    }
                    if (!partial.renameTo(localFile)) {
                        Log.e(TAG, "Could not cache the PDF at ${localFile.absolutePath}")
                        return@withContext PdfDownload.NotSaved
                    }
                } finally {
                    // Gone once renamed; otherwise never to be read as the PDF
                    partial.delete()
                }
                Log.d(TAG, "PDF downloaded to: ${localFile.absolutePath}")
                PdfDownload.Saved(localFile.absolutePath)
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: CacheWriteException) {
            Log.e(TAG, "Could not write the PDF to the cache: ${e.cause?.javaClass?.simpleName}")
            PdfDownload.NotSaved
        } catch (e: Exception) {
            Log.w(TAG, "PDF download error: ${e.javaClass.simpleName}")
            PdfDownload.Failed(RequestFailure.fromException(e))
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

        return if (isCachedPdf(localFile)) localFile.absolutePath else null
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
            is FullTextResult.PmcOpenDataXml -> Constants.FULLTEXT_SOURCE_PMC_OPEN_DATA
            is FullTextResult.EuropePmcPdf -> Constants.FULLTEXT_SOURCE_EUROPE_PMC
            is FullTextResult.OpenAccessPdfs ->
                result.steps.filterIsInstance<OpenAccessStep.Candidate>().first().namedBy.fullTextSource
            is FullTextResult.OpenAccessPdf -> result.namedBy.fullTextSource
            is FullTextResult.DoiUrl -> Constants.FULLTEXT_SOURCE_DOI
            is FullTextResult.Unavailable -> null
            is FullTextResult.NotEstablished -> null
        }
    }
}

/**
 * Who named an open-access PDF, which decides its source and its refusal's name.
 *
 * @property fullTextSource The source a PDF it named is recorded under
 * @property label How that source is named to the reader
 * @property refusedAs The shortfall source a PDF it named is refused under (#478)
 */
enum class PdfNamer(val fullTextSource: String, val label: String, val refusedAs: OpenAccessSource) {
    /** Unpaywall: a location's `url_for_pdf`, or the PDF its landing page declares. */
    UNPAYWALL(Constants.FULLTEXT_SOURCE_UNPAYWALL, Constants.FULLTEXT_SOURCE_UNPAYWALL_LABEL, OpenAccessSource.PDF)
}

/** One step of the open-access phase, in chain order (#480, stage B). */
sealed interface OpenAccessStep {
    /**
     * A PDF to download.
     *
     * @property pdfUrl Its address, an absolute http(s) URL
     * @property namedBy Who named it
     */
    data class Candidate(val pdfUrl: String, val namedBy: PdfNamer) : OpenAccessStep

    /**
     * A lookup, or a PDF address, that went unsettled before any download: told
     * in its place if no candidate is obtained.
     *
     * @property shortfall What went unsettled, and why
     */
    data class Unsettled(val shortfall: OpenAccessShortfall) : OpenAccessStep
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
 * Unpaywall, the landing page it named, or the PDF it named (#478) could not settle whether a free copy
 * exists: the open-access copy went unassessed, which is not the same as there
 * being none (#464). The chain carries [shortfall] on its fallback to the reader
 * (#466).
 *
 * @property shortfall Which lookup left it unsettled, and why
 */
class OpenAccessUnsettledException(val shortfall: OpenAccessShortfall) : Exception(shortfall.notice)

/**
 * A throttle or server fault, thrown inside a retry block so the transport-error
 * retry policy ([NetworkRetry.isRetryableException]) retries it too.
 *
 * @property statusCode The status the source answered with
 */
class RetryableStatusException(val statusCode: Int) : IOException("HTTP $statusCode")

/**
 * A source whose shortfall a [FullTextService.FullTextResult.NotEstablished] names.
 *
 * @property serviceName The source as the reader's sentence names it, verbatim on
 *   every platform
 */
enum class NotEstablishedSource(val serviceName: String) {
    /** Europe PMC: its XML fetch or identifier search did not settle it. */
    EUROPE_PMC(Constants.EUROPE_PMC_SERVICE_NAME),

    /** PMC's open-data bucket (#480): it could not be read. */
    PMC_OPEN_DATA(Constants.PMC_OPEN_DATA_SERVICE_NAME)
}

/**
 * The sentence for a chain that found nothing while [service] did not settle
 * whether the full text exists (#434, #480).
 *
 * The verb follows #435's decision: an HTTP status other than a throttle or a 5xx
 * (#445) was an answer, so the source "did not serve it"; those and any other
 * failure mean it "could not be asked" ([RequestFailure.isAnswer]). Pinned by
 * `doc/cross_platform/fulltext_parity/pmc_open_data.json`
 * (`not_established_sentence`); worded as BioMedLit's
 * `FullTextError.notEstablishedSentence` (iOS and macOS).
 *
 * @param service The source the sentence names: a [NotEstablishedSource.serviceName],
 *   [Constants.EUROPE_PMC_SERVICE_NAME] or [Constants.PMC_OPEN_DATA_SERVICE_NAME]
 * @param failure What that source got instead of the article's text
 * @return The sentence
 */
fun notEstablishedMessage(service: String, failure: RequestFailure): String =
    if (failure.isAnswer) {
        "No source provided this article's full text. $service (${failure.describe()}) " +
            "did not serve it, so it may still exist. Try again later."
    } else {
        "No source provided this article's full text. $service could not be asked " +
            "(${failure.describe()}), so it may still exist. Try again later."
    }

/**
 * Europe PMC's not-established sentence ([notEstablishedMessage]); kept for
 * existing callers.
 *
 * @param failure What Europe PMC's side of the chain got instead of the article's text
 * @return The sentence
 */
fun absenceNotEstablishedMessage(failure: RequestFailure): String =
    notEstablishedMessage(Constants.EUROPE_PMC_SERVICE_NAME, failure)
