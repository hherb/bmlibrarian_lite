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
import com.bmlibrarian.factchecker.domain.model.RequestFailureKind
import com.bmlibrarian.factchecker.domain.model.SourceRequestException
import com.bmlibrarian.factchecker.util.Constants
import com.bmlibrarian.factchecker.util.NetworkRetry
import com.bmlibrarian.factchecker.util.jats.JATSParseError
import com.bmlibrarian.factchecker.util.jats.JATSXMLParser
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlin.coroutines.cancellation.CancellationException
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.io.FileOutputStream
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Service for fetching full-text content from multiple sources.
 *
 * Implements a fallback chain:
 * 1. Europe PMC XML (JATS format) - preferred, machine-readable
 * 2. Unpaywall PDF - open access PDFs
 * 3. DOI Resolution - link to publisher website
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
    }

    /**
     * Result of a full-text retrieval attempt.
     */
    sealed class FullTextResult {
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
        ) : FullTextResult()

        /**
         * PDF available from Europe PMC render URL (when XML is unavailable).
         *
         * @param pdfUrl URL to the Europe PMC PDF.
         * @param localPath Local file path if downloaded, null otherwise.
         */
        data class EuropePmcPdf(
            val pdfUrl: String,
            val localPath: String? = null
        ) : FullTextResult()

        /**
         * Full text available as PDF from Unpaywall.
         *
         * @param pdfUrl URL to the PDF.
         * @param localPath Local file path if downloaded, null otherwise.
         */
        data class UnpaywallPdf(
            val pdfUrl: String,
            val localPath: String? = null
        ) : FullTextResult()

        /**
         * Fall back to DOI/publisher URL.
         *
         * @param url URL to the publisher page.
         */
        data class DoiUrl(val url: String) : FullTextResult()

        /**
         * Full text is unavailable from all sources.
         *
         * A claim about the article: every source that could be asked was asked
         * and answered. Callers record it on the document for good.
         *
         * @param reason Explanation of why retrieval failed.
         */
        data class Unavailable(val reason: String) : FullTextResult()

        /**
         * No source provided the full text, but Europe PMC did not settle whether
         * it exists (#434).
         *
         * Europe PMC could not be asked (a throttle, an outage, a timeout, a blank
         * answer, a failed identifier search), or it answered 404 for an article
         * it holds, which `fullTextXML` does for text that is not open access
         * (#432). Unlike [Unavailable], a claim about us: callers must not mark
         * the document unavailable for good on it, or a busy Europe PMC takes the
         * retry away.
         *
         * @param failure What Europe PMC's side of the chain got instead of an answer
         */
        data class NotEstablished(val failure: RequestFailure) : FullTextResult() {
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
     * @return Result containing the full text or error.
     */
    suspend fun fetchFullText(
        pmcId: String?,
        doi: String?,
        pmid: String?,
        email: String = Constants.UNPAYWALL_DEFAULT_EMAIL
    ): Result<FullTextResult> = withContext(Dispatchers.IO) {
        // What Europe PMC's side of the chain got instead of an answer about the
        // article, if anything. Set by a lost identifier search, a failed fetch and
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
                    // fullTextXML serves open-access text only, and this accession
                    // names an article Europe PMC holds (#432)
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
        }
    }

    /**
     * Try to fetch a PDF from Unpaywall.
     *
     * @param doi Digital Object Identifier.
     * @param email Email for API identification.
     * @param pmid PubMed ID for caching.
     * @return Result containing PDF URL/path or error.
     */
    private suspend fun tryUnpaywallPdf(
        doi: String,
        email: String,
        pmid: String?
    ): Result<FullTextResult> {
        return try {
            NetworkRetry.withExponentialBackoff(
                maxRetries = Constants.NETWORK_MAX_RETRIES,
                shouldRetry = { NetworkRetry.isRetryableException(it) }
            ) {
                val response = unpaywallApi.getWorkByDoi(doi, email)

                if (!response.isSuccessful) {
                    if (response.code() == 404) {
                        throw FullTextUnavailableException("DOI not found in Unpaywall: $doi")
                    }
                    throw FullTextException("Unpaywall API error: ${response.code()} ${response.message()}")
                }

                val body = response.body()
                    ?: throw FullTextException("Empty response from Unpaywall")

                // Check if open access
                if (body.is_oa != true) {
                    throw FullTextUnavailableException("Not open access: $doi")
                }

                // Get PDF URL from best OA location
                val pdfUrl = body.best_oa_location?.url_for_pdf
                    ?: body.best_oa_location?.url
                    ?: body.oa_locations?.firstNotNullOfOrNull { it.url_for_pdf ?: it.url }
                    ?: throw FullTextUnavailableException("No PDF URL available for $doi")

                Result.success(
                    FullTextResult.UnpaywallPdf(
                        pdfUrl = pdfUrl,
                        localPath = null  // Not downloaded yet
                    )
                )
            }
        } catch (e: FullTextUnavailableException) {
            Result.failure(e)
        } catch (e: Exception) {
            Log.e(TAG, "Unpaywall lookup failed: ${e.message}")
            Result.failure(e)
        }
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
                .header("User-Agent", "BMLibrarian/1.0 (Medical Fact Checker)")
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
 * The sentence for a chain that found nothing while Europe PMC did not settle
 * whether the full text exists (#434).
 *
 * The verb follows #435's decision: an HTTP answer was an answer, so Europe PMC
 * "did not serve it"; any other failure means it "could not be asked". Worded as
 * the iOS app words `FullTextError.absenceNotEstablished`.
 *
 * @param failure What Europe PMC's side of the chain got instead of an answer
 * @return The sentence
 */
fun absenceNotEstablishedMessage(failure: RequestFailure): String =
    if (failure.kind == RequestFailureKind.HTTP_STATUS) {
        "No source provided this article's full text. Europe PMC (${failure.describe()}) " +
            "did not serve it, so it may still exist. Try again later."
    } else {
        "No source provided this article's full text. Europe PMC could not be asked " +
            "(${failure.describe()}), so it may still exist. Try again later."
    }
