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

package com.bmlibrarian.factchecker.data.remote.transparency

import com.bmlibrarian.factchecker.domain.transparency.TransparencyConstants
import com.bmlibrarian.factchecker.util.NetworkRetry
import java.io.IOException
import java.util.Locale
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request

// Shared transport for the CrossRef and ClinicalTrials.gov clients, mirroring
// what the Swift clients (BioMedLit) do with URLSession and RetryHelper.

/** HTTP settings the transparency clients share, taken from Swift's `BioMedLitConstants`. */
object TransparencyHttpConstants {
    /** Status of a successful response. */
    const val HTTP_STATUS_OK: Int = 200

    /** Status of a record the service does not have. */
    const val HTTP_STATUS_NOT_FOUND: Int = 404

    /** Statuses worth retrying: rate limiting and transient server failures. */
    val RETRYABLE_STATUS_CODES: Set<Int> = setOf(429, 500, 502, 503, 504)

    /** Attempts in total, first included (Swift `RetryConfiguration.networkDefault.maxAttempts`). */
    const val MAX_ATTEMPTS: Int = 3

    /** Delay before the first retry, in milliseconds (Swift: 1.0 s). */
    const val INITIAL_RETRY_DELAY_MS: Long = 1_000L

    /** Longest delay between retries, in milliseconds (Swift: 30.0 s). */
    const val MAX_RETRY_DELAY_MS: Long = 30_000L

    /** Request timeout, in seconds (Swift `BioMedLitConstants.defaultRequestTimeout`). */
    const val REQUEST_TIMEOUT_SECONDS: Long = 45L

    /** Characters Foundation's `CharacterSet.urlPathAllowed` leaves unescaped, besides letters and digits. */
    internal const val URL_PATH_ALLOWED_PUNCTUATION: String = "-._~!\$&'()*+,;=:@/"
}

/**
 * How a transparency client retries a failed request.
 *
 * @property maxAttempts Attempts in total, first included.
 * @property initialDelayMs Delay before the first retry; doubles on each later one.
 * @property maxDelayMs Longest delay between retries.
 */
data class TransparencyRetryPolicy(
    val maxAttempts: Int = TransparencyHttpConstants.MAX_ATTEMPTS,
    val initialDelayMs: Long = TransparencyHttpConstants.INITIAL_RETRY_DELAY_MS,
    val maxDelayMs: Long = TransparencyHttpConstants.MAX_RETRY_DELAY_MS,
)

/** What one HTTP exchange produced: the status and, for a 200, the body text. */
internal data class TransparencyHttpResponse(val statusCode: Int, val body: String?)

/**
 * Keeps successive requests to one service at least [minimumIntervalMs] apart.
 *
 * The Swift clients are actors holding the time of their last request; this is
 * the same pacing, serialised by a mutex.
 *
 * @param minimumIntervalMs Minimum gap between two requests.
 */
internal class RequestPacer(
    private val minimumIntervalMs: Long = TransparencyConstants.MINIMUM_REQUEST_INTERVAL_MS,
) {
    private val mutex = Mutex()
    private var lastRequestNanos: Long? = null

    /** Suspend until the minimum interval since the previous request has passed, then record this one. */
    suspend fun awaitTurn() {
        mutex.withLock {
            val last = lastRequestNanos
            if (last != null) {
                val elapsedMs = (System.nanoTime() - last) / NANOS_PER_MILLI
                if (elapsedMs < minimumIntervalMs) delay(minimumIntervalMs - elapsedMs)
            }
            lastRequestNanos = System.nanoTime()
        }
    }

    private companion object {
        const val NANOS_PER_MILLI: Long = 1_000_000L
    }
}

/**
 * Execute a GET and return its status and, for a 200, its body.
 *
 * Runs on [Dispatchers.IO]. The body of any other status is never read.
 *
 * @param client The HTTP client.
 * @param request The request.
 * @return The status and body.
 * @throws IOException if the exchange failed in transport.
 */
internal suspend fun executeTransparencyRequest(client: OkHttpClient, request: Request): TransparencyHttpResponse =
    withContext(Dispatchers.IO) {
        client.newCall(request).execute().use { response ->
            val body = if (response.code == TransparencyHttpConstants.HTTP_STATUS_OK) response.body?.string() else null
            TransparencyHttpResponse(response.code, body)
        }
    }

/**
 * Run [block], retrying while [isRetryable] says its failure is transient, with
 * exponential backoff as Swift's `RetryHelper.retry(config: .networkDefault)` does.
 *
 * @param policy Attempts and delays.
 * @param isRetryable Whether a failure is worth another attempt.
 * @param block The request.
 * @return What [block] returned.
 * @throws Exception the last failure once it is not retryable or attempts run out.
 */
internal suspend fun <T> withTransparencyRetries(
    policy: TransparencyRetryPolicy,
    isRetryable: (Exception) -> Boolean,
    block: suspend () -> T,
): T =
    NetworkRetry.withExponentialBackoff(
        maxRetries = policy.maxAttempts - 1,
        initialDelayMs = policy.initialDelayMs,
        maxDelayMs = policy.maxDelayMs,
        shouldRetry = isRetryable,
    ) { block() }

/**
 * Percent-encode a URL path segment the way Foundation's
 * `addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)` does: letters,
 * digits and [TransparencyHttpConstants.URL_PATH_ALLOWED_PUNCTUATION] (which
 * includes "/") pass through; every other character is escaped as UTF-8.
 *
 * @param text The raw path text.
 * @return The encoded text.
 */
internal fun percentEncodePath(text: String): String {
    val builder = StringBuilder()
    for (byte in text.toByteArray(Charsets.UTF_8)) {
        val code = byte.toInt() and BYTE_MASK
        val character = code.toChar()
        val passes = code < ASCII_LIMIT &&
            (character.isLetterOrDigit() || character in TransparencyHttpConstants.URL_PATH_ALLOWED_PUNCTUATION)
        if (passes) builder.append(character) else builder.append(String.format(Locale.ROOT, "%%%02X", code))
    }
    return builder.toString()
}

/** Mask turning a signed byte into its unsigned value. */
private const val BYTE_MASK: Int = 0xFF

/** First code point outside ASCII. */
private const val ASCII_LIMIT: Int = 0x80

/**
 * A failure as it may be logged: the message of the transparency clients' own
 * exceptions (which quote no response body), the class name of anything else.
 *
 * @param error The failure.
 * @return The loggable description.
 */
fun describeFailure(error: Exception): String =
    when (error) {
        is CrossRefException, is ClinicalTrialsException -> error.message ?: error.javaClass.simpleName
        else -> error.javaClass.simpleName
    }
