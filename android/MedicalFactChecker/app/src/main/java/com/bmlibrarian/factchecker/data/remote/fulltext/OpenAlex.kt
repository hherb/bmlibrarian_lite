/*
 * BMLibrarian Lite - Biomedical Literature Research Tool
 * Copyright (C) 2024-2026 Dr Horst Herb
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

import android.util.Log
import com.bmlibrarian.factchecker.data.remote.transparency.RequestPacer
import com.bmlibrarian.factchecker.data.repository.SettingsRepository
import com.bmlibrarian.factchecker.domain.model.RequestFailure
import com.bmlibrarian.factchecker.domain.model.RequestFailureKind
import com.bmlibrarian.factchecker.domain.model.UnpaywallContact
import com.bmlibrarian.factchecker.util.Constants
import com.bmlibrarian.factchecker.util.NetworkRetry
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.IOException
import java.util.Locale
import javax.inject.Inject
import javax.inject.Singleton

/**
 * OpenAlex's locations as open-access PDF sources (#480, stage B).
 *
 * Pinned with Python's `openalex.py` by
 * `doc/cross_platform/fulltext_parity/openalex_locations.json`. Every
 * `locations[].pdf_url` is a candidate, whatever the location's `is_oa`.
 */
object OpenAlex {
    /** RFC 3986's unreserved characters: all Python's `quote(s, safe="")` leaves bare. */
    private const val UNRESERVED = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    private const val BYTE_MASK = 0xFF
    private const val ASCII_LIMIT = 0x80

    /** [value] escaped as UTF-8 bytes, the unreserved characters left bare; never `+` for a space. */
    private fun escaped(value: String): String = buildString {
        for (byte in value.toByteArray(Charsets.UTF_8)) {
            val unsigned = byte.toInt() and BYTE_MASK
            val char = unsigned.toChar()
            if (unsigned < ASCII_LIMIT && char in UNRESERVED) {
                append(char)
            } else {
                append(String.format(Locale.ROOT, "%%%02X", unsigned))
            }
        }
    }

    /**
     * The address OpenAlex is asked about one DOI at: the DOI one path segment,
     * only `locations` selected, the contact email a query value.
     *
     * @param doi The DOI; surrounding whitespace is not part of it
     * @param mailto The contact email, or null (or empty) to ask without one
     * @param baseUrl OpenAlex's address
     */
    fun workUrl(doi: String, mailto: String?, baseUrl: String = Constants.OPENALEX_BASE_URL): String {
        val query = mailto?.takeIf { it.isNotEmpty() }?.let { "&mailto=${escaped(it)}" }.orEmpty()
        return "$baseUrl/works/doi:${escaped(doi.trim())}?select=locations$query"
    }

    /**
     * Every PDF URL a work's JSON body names; see [pdfUrls] for a decoded work.
     *
     * @throws IllegalArgumentException for a body that is not JSON, or a work that is unreadable
     */
    fun pdfUrls(json: String): List<String> = pdfUrls(Json.parseToJsonElement(json))

    /**
     * Every PDF URL a decoded work's locations name: each `pdf_url` that is a
     * non-blank string, trimmed, kept once, in OpenAlex's order.
     *
     * @throws IllegalArgumentException for a work that is not an object, or
     *   `locations` neither a list nor null: unreadable, never absent
     */
    fun pdfUrls(work: JsonElement): List<String> {
        val obj = work as? JsonObject ?: throw IllegalArgumentException("an OpenAlex work is a JSON object")
        val locations = when (val raw = obj["locations"]) {
            null, JsonNull -> return emptyList()
            is JsonArray -> raw
            else -> throw IllegalArgumentException("an OpenAlex work's locations are a list")
        }
        return locations
            .mapNotNull { (it as? JsonObject)?.get("pdf_url") as? JsonPrimitive }
            .filter { it.isString }
            .map { it.content.trim() }
            .filter { it.isNotEmpty() }
            .distinct()
    }

    /** The URLs not already tried, in their order. */
    fun untried(urls: List<String>, tried: Collection<String>): List<String> = urls.filterNot { it in tried }
}

/** What asking OpenAlex for a work's PDF locations produced. */
sealed interface OpenAlexFetch {
    /**
     * OpenAlex answered with the work; it may name no PDF.
     *
     * @property pdfUrls The PDF addresses its locations name, in its order
     */
    data class Served(val pdfUrls: List<String>) : OpenAlexFetch

    /** OpenAlex knows no work by this DOI. */
    data object Absent : OpenAlexFetch

    /** OpenAlex's answer is missing, of its real kind. */
    data class Unreachable(val failure: RequestFailure) : OpenAlexFetch
}

/**
 * Asks OpenAlex which PDFs a work's locations name, paced to 10 requests a second.
 *
 * @param httpClient Derived from the shared client with [PmcOpenDataService.bucketClient]:
 *   its own timeouts, no OkHttp replay
 * @param baseUrl OpenAlex's address; tests point it at a local server
 * @property contactEmail The contact sent as `mailto`, read per request; null asks without
 * @property pacer Every attempt, retries included, takes a slot
 * @property maxRetries Further attempts for a transport failure or a status in
 *   [Constants.OPENALEX_RETRYABLE_STATUSES]; tests pass 0
 * @property initialBackoffMs The wait before the first retry, doubling after
 */
@Singleton
class OpenAlexService internal constructor(
    private val httpClient: OkHttpClient,
    private val baseUrl: String,
    private val contactEmail: () -> String?,
    private val pacer: RequestPacer,
    private val maxRetries: Int,
    private val initialBackoffMs: Long
) {
    /**
     * The contact is the NCBI email, the one the transparency analysis sends
     * CrossRef; the placeholder or a blank one asks without `mailto` (#480).
     */
    @Inject
    constructor(httpClient: OkHttpClient, settingsRepository: SettingsRepository) : this(
        PmcOpenDataService.bucketClient(httpClient, Constants.OPENALEX_REQUEST_TIMEOUT_SECONDS),
        Constants.OPENALEX_BASE_URL,
        { UnpaywallContact.usableEmail(settingsRepository.getNcbiEmail()) },
        RequestPacer(Constants.OPENALEX_MIN_INTERVAL_MS),
        Constants.OPENALEX_MAX_RETRIES,
        Constants.OPENALEX_INITIAL_BACKOFF_MS
    )

    /**
     * Ask OpenAlex for the PDFs a work's locations name.
     *
     * Never throws but for cancellation: an unexpected error (a
     * `SecurityException` from the platform, say) is logged and answered as
     * OpenAlex unreachable, so the caller keeps every refusal it already
     * collected and the reader is told OpenAlex could not be asked, as
     * Unpaywall's lookup does.
     *
     * @param doi The DOI; a blank one is never asked
     * @return Served URLs (possibly none); absent for a 404; or unreachable, of
     *   its real kind (a body that is not UTF-8 JSON of a work is malformed;
     *   an unexpected error is a failed request)
     * @throws kotlinx.coroutines.CancellationException if the caller cancelled
     */
    suspend fun fetchPdfUrls(doi: String): OpenAlexFetch {
        if (doi.isBlank()) return OpenAlexFetch.Absent
        return try {
            val url = OpenAlex.workUrl(doi, contactEmail(), baseUrl).toHttpUrlOrNull()
                ?: return OpenAlexFetch.Unreachable(RequestFailure(RequestFailureKind.REQUEST_FAILED))
            val (code, bytes) = get(url)
            when (code) {
                HTTP_OK -> {
                    val text = bytes.strictUtf8() ?: return malformed(doi, null)
                    try {
                        OpenAlexFetch.Served(OpenAlex.pdfUrls(text))
                    } catch (e: IllegalArgumentException) {
                        malformed(doi, e) // SerializationException is one
                    }
                }
                Constants.HTTP_NOT_FOUND -> OpenAlexFetch.Absent
                else -> OpenAlexFetch.Unreachable(RequestFailure.forHttpStatus(code))
            }
        } catch (e: RetryableStatusException) {
            OpenAlexFetch.Unreachable(RequestFailure.forHttpStatus(e.statusCode))
        } catch (e: IOException) {
            OpenAlexFetch.Unreachable(RequestFailure.fromException(e))
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            // Not an answer about the work: OpenAlex went unasked, and the
            // Unpaywall refusals the caller holds must survive it
            Log.e(TAG, "OpenAlex lookup of $doi failed unexpectedly", e)
            OpenAlexFetch.Unreachable(RequestFailure(RequestFailureKind.REQUEST_FAILED))
        }
    }

    private suspend fun get(url: HttpUrl): Pair<Int, ByteArray> {
        val request = Request.Builder().url(url).header("Accept", "application/json").build()
        return NetworkRetry.withExponentialBackoff(
            maxRetries = maxRetries,
            initialDelayMs = initialBackoffMs,
            shouldRetry = { NetworkRetry.isRetryableException(it) }
        ) {
            pacer.awaitTurn() // every attempt takes its own slot
            withContext(Dispatchers.IO) {
                httpClient.newCall(request).execute().use { response ->
                    if (response.code in Constants.OPENALEX_RETRYABLE_STATUSES) {
                        throw RetryableStatusException(response.code)
                    }
                    response.code to (response.body?.bytes() ?: ByteArray(0))
                }
            }
        }
    }

    /**
     * OpenAlex's answer could not be read as a work: logged with its cause,
     * and told as a malformed response.
     *
     * @param doi The DOI asked about
     * @param cause Why the body could not be read; null for a body that is not UTF-8
     * @return The fetch, unreachable as malformed
     */
    private fun malformed(doi: String, cause: Exception?): OpenAlexFetch.Unreachable {
        if (cause != null) {
            Log.w(TAG, "OpenAlex's answer about $doi could not be read as a work", cause)
        } else {
            Log.w(TAG, "OpenAlex's answer about $doi is not UTF-8")
        }
        return OpenAlexFetch.Unreachable(RequestFailure(RequestFailureKind.MALFORMED_RESPONSE))
    }

    private companion object {
        const val HTTP_OK = 200
        const val TAG = "OpenAlexService"
    }
}
