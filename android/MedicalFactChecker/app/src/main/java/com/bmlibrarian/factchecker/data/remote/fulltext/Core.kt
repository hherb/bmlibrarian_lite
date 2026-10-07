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
import java.security.MessageDigest
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
     *   (an unpaired surrogate escape included)
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
     * @throws IllegalArgumentException if the answer is not an object, its `results` not a
     *   list, or it holds a string that is not valid Unicode: an answer we cannot read is
     *   not an absence
     */
    fun fullText(answer: JsonElement, doi: String, minChars: Int): String? {
        if (holdsUnpairedSurrogate(answer)) {
            throw IllegalArgumentException("a CORE answer's strings are valid Unicode")
        }
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

    /**
     * Whether a decoded answer holds a string that is not valid Unicode, Python's
     * `holds_unpaired_surrogate`.
     *
     * The parser decodes each `\uXXXX` escape to its own UTF-16 unit, so a
     * well-formed escaped pair stays a valid pair and only an unpaired escape leaves
     * a lone surrogate. Such text cannot be written as UTF-8, and Apple's JSON parser
     * refuses the whole answer for it, so every platform reads it as an answer that
     * cannot be read (the contract's `bodies`).
     *
     * @param answer The decoded answer
     * @return True when any string in it, object keys included, holds a lone surrogate
     */
    fun holdsUnpairedSurrogate(answer: JsonElement): Boolean {
        val pending = ArrayDeque<JsonElement>().apply { add(answer) }
        while (pending.isNotEmpty()) {
            when (val element = pending.removeLast()) {
                is JsonObject -> {
                    if (element.keys.any { hasLoneSurrogate(it) }) return true
                    pending.addAll(element.values)
                }
                is JsonArray -> pending.addAll(element)
                is JsonPrimitive -> if (element.isString && hasLoneSurrogate(element.content)) return true
            }
        }
        return false
    }

    /** Whether [text] holds a surrogate that is not half of a high-then-low pair. */
    private fun hasLoneSurrogate(text: String): Boolean {
        var index = 0
        while (index < text.length) {
            val unit = text[index]
            if (Character.isHighSurrogate(unit) && index + 1 < text.length &&
                Character.isLowSurrogate(text[index + 1])
            ) {
                index += 2
                continue
            }
            if (Character.isSurrogate(unit)) return true
            index += 1
        }
        return false
    }

    /** The algorithm of the digest a refused key is remembered by. */
    private const val KEY_DIGEST_ALGORITHM = "SHA-256"

    /**
     * The fingerprint a refused key is remembered by (#498), Python's `core_key_digest`.
     *
     * A refusal is scoped to the key CORE refused, so a key corrected in the settings
     * is asked again. The key itself is never held for that, and the digest is never
     * logged.
     *
     * @param apiKey A CORE key; trimmed here, so padding names the same key
     * @return The SHA-256 digest of the trimmed key's UTF-8 bytes, as lower-case hex
     */
    fun keyDigest(apiKey: String): String =
        MessageDigest.getInstance(KEY_DIGEST_ALGORITHM)
            .digest(apiKey.trim().toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
}

/** What asking CORE for one DOI's text produced. */
sealed interface CoreFetch {
    /**
     * CORE holds this article's text.
     *
     * @property text The trimmed text, at least the minimum length; never blank
     */
    data class Served(val text: String) : CoreFetch {
        init {
            require(text.isNotBlank()) { "a served CORE text is never blank" }
        }
    }

    /** CORE answered, and holds no usable text for this DOI. */
    data object Absent : CoreFetch

    /**
     * CORE could not be asked, or its answer could not be read (a 404 included: never
     * an absence), of its real kind: a status, a transport failure, a malformed answer,
     * the session's pause, or a key that could not be read.
     */
    data class Unreachable(val failure: RequestFailure) : CoreFetch

    /**
     * CORE refused the key, on this fetch or an earlier one this session (#498): CORE
     * was not asked about the article, and the reader is told the key, never the article.
     */
    data object KeyRefused : CoreFetch
}

/**
 * Asks CORE's search for a DOI's extracted text, the user's key in the
 * `Authorization` header alone, paced to CORE's polite rate.
 *
 * A singleton, so its session state is the process's: two consecutive fetches
 * ending in 429 stop CORE being asked until the app restarts. A paused fetch
 * sends nothing and answers 429; any other ending, a transport failure included,
 * resets the count. A fetch ending in 401 marks the key it was sent with refused
 * for the rest of the process (#498): that fetch and every later one with that key
 * is [CoreFetch.KeyRefused], and nothing more is sent with it. The refusal is the
 * key's, held as its [Core.keyDigest]: another key, such as one corrected in the
 * settings, is asked as usual, and a 401 for it refuses that key instead.
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

    /** The [Core.keyDigest] of the key CORE refused this session, if any (#498). */
    @Volatile
    private var refusedKeyDigest: String? = null

    /** Whether CORE is paused for the rest of the session. */
    val isPaused: Boolean get() = paused

    /**
     * Whether CORE refused this key this session (#498); any other key is asked as usual.
     *
     * @param keyDigest The key's [Core.keyDigest]
     */
    fun refuses(keyDigest: String): Boolean = refusedKeyDigest == keyDigest

    /**
     * CORE's text for [doi].
     *
     * Never throws but for cancellation: an unexpected error is logged (never
     * with the key) and answered as CORE unreachable.
     *
     * The answer is decoded and parsed off the caller's thread: it can hold several MB.
     *
     * @param doi The DOI; a blank one sends nothing and is [CoreFetch.Absent], which
     *   records nothing, exactly as not asking does (callers ask only with a DOI)
     * @return Null when no key is set (nothing is asked or recorded; a debug line
     *   says so, never with the key); served; absent;
     *   unreachable, of its real kind; or key refused, for a 401 and for every later
     *   fetch with that key (nothing sent)
     * @throws kotlinx.coroutines.CancellationException if the caller cancelled
     */
    suspend fun fetchText(doi: String): CoreFetch? {
        val key = try {
            apiKey()
        } catch (e: Exception) {
            if (e is CancellationException) throw e
            Log.e(TAG, "CORE's key could not be read: ${e.javaClass.simpleName}")
            return CoreFetch.Unreachable(RequestFailure(RequestFailureKind.REQUEST_FAILED))
        }
        if (key == null) {
            Log.d(TAG, "No CORE key is set; CORE is not asked")
            return null
        }
        if (doi.isBlank()) return CoreFetch.Absent
        // The key before the pause: it is the cause the reader can act on (#498).
        // Only the refused key is refused: a corrected one is asked again
        val keyDigest = Core.keyDigest(key)
        if (refuses(keyDigest)) return CoreFetch.KeyRefused
        if (paused) return CoreFetch.Unreachable(RequestFailure.forHttpStatus(Constants.HTTP_TOO_MANY_REQUESTS))
        return try {
            val url = Core.searchUrl(doi, baseUrl).toHttpUrlOrNull()
                ?: return CoreFetch.Unreachable(RequestFailure(RequestFailureKind.REQUEST_FAILED))
            val request = Request.Builder().url(url)
                .header("Accept", "application/json")
                .header("Authorization", "Bearer $key")
                .build()
            val (code, bytes) = get(request)
            record(code, keyDigest)
            if (code == Constants.CORE_KEY_REFUSED_STATUS) return CoreFetch.KeyRefused
            if (code != Constants.HTTP_OK) return CoreFetch.Unreachable(RequestFailure.forHttpStatus(code))
            // Off the caller's thread, which may be Main: the answer can hold several MB
            withContext(Dispatchers.Default) {
                val text = bytes.strictUtf8() ?: return@withContext malformed(null)
                try {
                    Core.fullText(text, doi)?.let { CoreFetch.Served(it) } ?: CoreFetch.Absent
                } catch (e: IllegalArgumentException) {
                    malformed(e) // SerializationException is one
                }
            }
        } catch (e: RetryableStatusException) {
            record(e.statusCode, keyDigest)
            CoreFetch.Unreachable(RequestFailure.forHttpStatus(e.statusCode))
        } catch (e: IOException) {
            record(null, keyDigest)
            CoreFetch.Unreachable(RequestFailure.fromException(e))
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            record(null, keyDigest)
            Log.e(TAG, "CORE lookup failed unexpectedly: ${e.javaClass.simpleName}")
            CoreFetch.Unreachable(RequestFailure(RequestFailureKind.REQUEST_FAILED))
        }
    }

    /**
     * Count one fetch's ending: the consecutive 429s pause CORE, anything else resets them;
     * a 401 also marks the key it was sent with refused, in place of any refused before (#498).
     *
     * @param status The ending's HTTP status, or null for no status (a transport failure)
     * @param keyDigest The [Core.keyDigest] of the key it was sent with
     */
    private fun record(status: Int?, keyDigest: String) {
        synchronized(throttleLock) {
            if (status == Constants.CORE_KEY_REFUSED_STATUS && refusedKeyDigest != keyDigest) {
                refusedKeyDigest = keyDigest
                Log.w(TAG, "CORE refused the configured key (HTTP $status); not asked with it again this session")
            }
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
