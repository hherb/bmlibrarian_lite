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
import com.bmlibrarian.factchecker.data.remote.europepmc.EuropePMCService
import com.bmlibrarian.factchecker.util.Constants
import com.bmlibrarian.factchecker.util.NetworkRetry
import com.bmlibrarian.factchecker.util.jats.JATSParseError
import com.bmlibrarian.factchecker.util.jats.JATSXMLParser
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
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
         * @param reason Explanation of why retrieval failed.
         */
        data class Unavailable(val reason: String) : FullTextResult()
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
        // Try Europe PMC XML first if PMC ID is available
        if (!pmcId.isNullOrEmpty()) {
            Log.d(TAG, "Attempting Europe PMC XML for $pmcId")
            val xmlResult = tryEuropePmcXml(pmcId)
            if (xmlResult.isSuccess) {
                return@withContext xmlResult
            }
            Log.d(TAG, "Europe PMC XML failed: ${xmlResult.exceptionOrNull()?.message}")
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

        // No full text available
        Result.success(
            FullTextResult.Unavailable(
                "No full text source available (no PMC ID or DOI)"
            )
        )
    }

    /**
     * Try to fetch full text from Europe PMC.
     *
     * @param pmcId PubMed Central ID.
     * @return Result containing parsed XML content or error.
     */
    private suspend fun tryEuropePmcXml(pmcId: String): Result<FullTextResult> {
        return try {
            val xmlResult = europePmcService.getFullTextXml(pmcId)

            xmlResult.fold(
                onSuccess = { xml ->
                    // Parse the XML to markdown and HTML
                    try {
                        val parser = JATSXMLParser(
                            xmlData = xml.toByteArray(Charsets.UTF_8),
                            knownPmcId = pmcId
                        )
                        val markdown = parser.parseToMarkdown()

                        // Create a new parser instance for HTML (parsers are single-use)
                        val htmlParser = JATSXMLParser(
                            xmlData = xml.toByteArray(Charsets.UTF_8),
                            knownPmcId = pmcId
                        )
                        val html = htmlParser.parseToHTML()

                        Result.success(
                            FullTextResult.EuropePmcXml(
                                xml = xml,
                                markdown = markdown,
                                html = html
                            )
                        )
                    } catch (e: JATSParseError) {
                        Log.e(TAG, "JATS parsing failed: ${e.message}")
                        Result.failure(e)
                    }
                },
                onFailure = { error ->
                    Result.failure(error)
                }
            )
        } catch (e: Exception) {
            Log.e(TAG, "Europe PMC XML retrieval failed: ${e.message}")
            Result.failure(e)
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
            is FullTextResult.UnpaywallPdf -> Constants.FULLTEXT_SOURCE_UNPAYWALL
            is FullTextResult.DoiUrl -> Constants.FULLTEXT_SOURCE_DOI
            is FullTextResult.Unavailable -> null
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
