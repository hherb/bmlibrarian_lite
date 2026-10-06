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
import com.bmlibrarian.factchecker.util.Constants
import com.bmlibrarian.factchecker.util.NetworkRetry
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.IOException
import javax.inject.Inject
import javax.inject.Singleton

/**
 * CORE's extracted text, asked by DOI with the user's own key (#480, stage C).
 *
 * The pure rules, pinned with Python's `core_api.py` by
 * `doc/cross_platform/fulltext_parity/core_fulltext.json`. Only a result whose own
 * DOI is this article's counts: the request is a search, and another article's
 * text served as this one's would be worse than none.
 */
object Core {
    private val DOI_PREFIXES = listOf(
        "https://doi.org/", "http://doi.org/", "https://dx.doi.org/", "http://dx.doi.org/", "doi:"
    )

    /**
     * CORE's search for one DOI, as a phrase query: backslash and double quote
     * escaped, the whole `q` value percent-encoded as [OpenAlex.escaped] does.
     *
     * @param doi The DOI; surrounding whitespace is not part of it
     * @param baseUrl CORE's address; a trailing slash is dropped
     */
    fun searchUrl(doi: String, baseUrl: String = Constants.CORE_BASE_URL): String {
        val phrase = doi.trim().replace("\\", "\\\\").replace("\"", "\\\"")
        val query = OpenAlex.escaped("doi:\"$phrase\"")
        return "${baseUrl.trimEnd('/')}${Constants.CORE_SEARCH_PATH}?q=$query&limit=${Constants.CORE_SEARCH_LIMIT}"
    }

    /** A DOI as compared: trimmed, lower-cased, one resolver or `doi:` prefix removed, trimmed. */
    fun normalisedDoi(doi: String): String {
        var text = doi.trim().lowercase()
        DOI_PREFIXES.firstOrNull { text.startsWith(it) }?.let { text = text.removePrefix(it) }
        return text.trim()
    }

    /**
     * The full text CORE's JSON answer serves for [doi]; see the decoded overload.
     *
     * @throws IllegalArgumentException for a body that is not JSON, or an answer that is unreadable
     */
    fun fullText(json: String, doi: String, minChars: Int = Constants.CORE_MIN_FULLTEXT_CHARS): String? =
        fullText(Json.parseToJsonElement(json), doi, minChars) // SerializationException is an IllegalArgumentException

    /**
     * The first result that is an object, whose string `doi` normalises to this DOI's
     * and whose string `fullText`, trimmed, holds at least [minChars] Unicode code points.
     *
     * @param answer The decoded search answer
     * @param doi The DOI asked about
     * @param minChars The fewest code points that count as a full text
     * @return That trimmed text, or null
     * @throws IllegalArgumentException if the answer is not an object or its `results` not a list
     */
    fun fullText(answer: JsonElement, doi: String, minChars: Int): String? {
        val obj = answer as? JsonObject ?: throw IllegalArgumentException("a CORE answer is a JSON object")
        val results = obj["results"] as? JsonArray
            ?: throw IllegalArgumentException("a CORE answer's results are a list")
        val wanted = normalisedDoi(doi)
        if (wanted.isEmpty()) return null
        for (result in results) {
            val record = result as? JsonObject ?: continue
            val resultDoi = stringOf(record["doi"]) ?: continue
            if (normalisedDoi(resultDoi) != wanted) continue
            val text = stringOf(record["fullText"])?.trim() ?: continue
            if (text.codePointCount(0, text.length) >= minChars) return text
        }
        return null
    }

    private fun stringOf(element: JsonElement?): String? =
        (element as? JsonPrimitive)?.takeIf { it.isString }?.content
}

/** What asking CORE for one DOI's text produced. */
sealed interface CoreFetch {
    /**
     * CORE holds this article's text.
     *
     * @property text The trimmed text, at least the minimum length
     */
    data class Served(val text: String) : CoreFetch

    /** CORE answered, and holds no usable text for this DOI. */
    data object Absent : CoreFetch

    /** CORE's answer is missing, of its real kind (a 404 is one: never an absence). */
    data class Unreachable(val failure: RequestFailure) : CoreFetch
}

/**
 * Asks CORE's search for a DOI's extracted text, the user's key in the
 * `Authorization` header alone, paced to CORE's polite rate.
 *
 * A singleton, so its session pause is the process's: two consecutive fetches
 * ending in 429 stop CORE being asked until the app restarts. A paused fetch
 * sends nothing and answers 429; any other ending, a transport failure included,
 * resets the count.
 *
 * @param httpClient Derived from the shared client with [PmcOpenDataService.bucketClient]
 * @param baseUrl CORE's address; tests point it at a local server
 * @property apiKey The trimmed key, read per request; null when none is set
 * @property pacer Every attempt, retries included, takes a slot
 * @property maxRetries Further attempts for a transport failure or a status in
 *   [Constants.CORE_RETRYABLE_STATUSES]; tests pass 0
 * @property initialBackoffMs The wait before the first retry, doubling after
 * @property pauseAfter Consecutive 429 endings that pause CORE
 */
@Singleton
class CoreService internal constructor(
    private val httpClient: OkHttpClient,
    private val baseUrl: String,
    private val apiKey: () -> String?,
    private val pacer: RequestPacer,
    private val maxRetries: Int,
    private val initialBackoffMs: Long,
    private val pauseAfter: Int = Constants.CORE_PAUSE_AFTER_CONSECUTIVE_429
) {
    /** The key is the user's, read from the settings at each request. */
    @Inject
    constructor(httpClient: OkHttpClient, settingsRepository: SettingsRepository) : this(
        PmcOpenDataService.bucketClient(httpClient, Constants.CORE_REQUEST_TIMEOUT_SECONDS),
        Constants.CORE_BASE_URL,
        { settingsRepository.getCoreApiKey().trim().takeIf { it.isNotEmpty() } },
        RequestPacer(Constants.CORE_MIN_INTERVAL_MS),
        Constants.CORE_MAX_RETRIES,
        Constants.CORE_INITIAL_BACKOFF_MS
    )

    private val throttleLock = Any()
    private var consecutive429 = 0

    @Volatile
    private var paused = false

    /** Whether CORE is paused for the rest of the session. */
    val isPaused: Boolean get() = paused

    /**
     * CORE's text for [doi].
     *
     * Never throws but for cancellation: an unexpected error is logged (never
     * with the key) and answered as CORE unreachable.
     *
     * @param doi The DOI; a blank one is never asked
     * @return Null when no key is set (nothing is asked or recorded); served; absent;
     *   or unreachable, of its real kind
     * @throws kotlinx.coroutines.CancellationException if the caller cancelled
     */
    suspend fun fetchText(doi: String): CoreFetch? {
        val key = try {
            apiKey()
        } catch (e: Exception) {
            if (e is CancellationException) throw e
            Log.e(TAG, "CORE's key could not be read: ${e.javaClass.simpleName}")
            return CoreFetch.Unreachable(RequestFailure(RequestFailureKind.REQUEST_FAILED))
        } ?: return null
        if (doi.isBlank()) return CoreFetch.Absent
        if (paused) return CoreFetch.Unreachable(RequestFailure.forHttpStatus(Constants.HTTP_TOO_MANY_REQUESTS))
        return try {
            val url = Core.searchUrl(doi, baseUrl).toHttpUrlOrNull()
                ?: return CoreFetch.Unreachable(RequestFailure(RequestFailureKind.REQUEST_FAILED))
            val request = Request.Builder().url(url)
                .header("Accept", "application/json")
                .header("Authorization", "Bearer $key")
                .build()
            val (code, bytes) = get(request)
            record(code)
            if (code != Constants.HTTP_OK) return CoreFetch.Unreachable(RequestFailure.forHttpStatus(code))
            val text = bytes.strictUtf8() ?: return malformed(null)
            try {
                Core.fullText(text, doi)?.let { CoreFetch.Served(it) } ?: CoreFetch.Absent
            } catch (e: IllegalArgumentException) {
                malformed(e) // SerializationException is one
            }
        } catch (e: RetryableStatusException) {
            record(e.statusCode)
            CoreFetch.Unreachable(RequestFailure.forHttpStatus(e.statusCode))
        } catch (e: IOException) {
            record(null)
            CoreFetch.Unreachable(RequestFailure.fromException(e))
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            record(null)
            Log.e(TAG, "CORE lookup failed unexpectedly: ${e.javaClass.simpleName}")
            CoreFetch.Unreachable(RequestFailure(RequestFailureKind.REQUEST_FAILED))
        }
    }

    /**
     * Count one fetch's ending: the consecutive 429s pause CORE, anything else resets them.
     *
     * @param status The ending's HTTP status, or null for no status (a transport failure)
     */
    private fun record(status: Int?) {
        synchronized(throttleLock) {
            if (status != Constants.HTTP_TOO_MANY_REQUESTS) {
                consecutive429 = 0
                return
            }
            consecutive429 += 1
            if (consecutive429 >= pauseAfter && !paused) {
                paused = true
                Log.w(TAG, "CORE answered HTTP 429 $consecutive429 times in a row; not asked again this session")
            }
        }
    }

    /** CORE's answer could not be read: logged with its class only (never the body), told as malformed. */
    private fun malformed(cause: Exception?): CoreFetch.Unreachable {
        Log.w(TAG, "CORE's answer could not be read: ${cause?.javaClass?.simpleName ?: "not UTF-8"}")
        return CoreFetch.Unreachable(RequestFailure(RequestFailureKind.MALFORMED_RESPONSE))
    }

    private suspend fun get(request: Request): Pair<Int, ByteArray> = NetworkRetry.withExponentialBackoff(
        maxRetries = maxRetries,
        initialDelayMs = initialBackoffMs,
        shouldRetry = { NetworkRetry.isRetryableException(it) }
    ) {
        pacer.awaitTurn() // every attempt takes its own slot
        withContext(Dispatchers.IO) {
            httpClient.newCall(request).execute().use { response ->
                if (response.code in Constants.CORE_RETRYABLE_STATUSES) {
                    throw RetryableStatusException(response.code)
                }
                response.code to (response.body?.bytes() ?: ByteArray(0))
            }
        }
    }

    private companion object {
        const val TAG = "CoreService"
    }
}
