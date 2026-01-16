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

package com.bmlibrarian.factchecker.util

import kotlinx.coroutines.delay
import kotlin.math.min
import kotlin.math.pow

/**
 * Network retry utilities with exponential backoff.
 *
 * Implements retry logic for network operations following the golden rule:
 * "All network / LLM / API calls that could fail or time out need proper
 * retry functionality with exponential backoff"
 */
object NetworkRetry {

    /**
     * HTTP status codes that indicate transient errors worth retrying.
     * Using Set for O(1) lookup performance.
     */
    private val RETRYABLE_STATUS_CODES = setOf(
        408, // Request Timeout
        429, // Too Many Requests (rate limited)
        500, // Internal Server Error
        502, // Bad Gateway
        503, // Service Unavailable
        504  // Gateway Timeout
    )

    /**
     * Executes a suspending block with exponential backoff retry.
     *
     * Retries the operation up to [maxRetries] times with exponentially
     * increasing delays: 2s, 4s, 8s, 16s (capped at [maxDelayMs]).
     *
     * @param T The return type of the operation
     * @param maxRetries Maximum number of retry attempts (default: 4)
     * @param initialDelayMs Initial delay before first retry in milliseconds (default: 2000)
     * @param maxDelayMs Maximum delay between retries in milliseconds (default: 16000)
     * @param shouldRetry Predicate to determine if the exception should trigger a retry
     * @param onRetry Optional callback invoked before each retry with attempt number and delay
     * @param block The suspending operation to execute
     * @return The result of the successful operation
     * @throws Exception The last exception if all retries fail
     */
    suspend fun <T> withExponentialBackoff(
        maxRetries: Int = Constants.NETWORK_MAX_RETRIES,
        initialDelayMs: Long = Constants.NETWORK_INITIAL_BACKOFF_MS,
        maxDelayMs: Long = Constants.NETWORK_MAX_BACKOFF_MS,
        shouldRetry: (Exception) -> Boolean = { true },
        onRetry: ((attempt: Int, delayMs: Long, error: Exception) -> Unit)? = null,
        block: suspend () -> T
    ): T {
        var lastException: Exception? = null

        repeat(maxRetries + 1) { attempt ->
            try {
                return block()
            } catch (e: Exception) {
                lastException = e

                // Check if we should retry this exception
                if (!shouldRetry(e)) {
                    throw e
                }

                // If this was the last attempt, throw
                if (attempt >= maxRetries) {
                    throw e
                }

                // Calculate exponential backoff delay
                val delayMs = min(
                    initialDelayMs * 2.0.pow(attempt.toDouble()).toLong(),
                    maxDelayMs
                )

                // Notify callback before retry
                onRetry?.invoke(attempt + 1, delayMs, e)

                // Wait before retrying
                delay(delayMs)
            }
        }

        // Should never reach here, but satisfy compiler
        throw lastException ?: IllegalStateException("Retry loop completed without result")
    }

    /**
     * Determines if an HTTP status code indicates a retryable error.
     *
     * Retryable status codes:
     * - 408: Request Timeout
     * - 429: Too Many Requests (rate limited)
     * - 500: Internal Server Error
     * - 502: Bad Gateway
     * - 503: Service Unavailable
     * - 504: Gateway Timeout
     *
     * @param statusCode The HTTP status code
     * @return True if the status code indicates a retryable error
     */
    fun isRetryableStatusCode(statusCode: Int): Boolean {
        return statusCode in RETRYABLE_STATUS_CODES
    }

    /**
     * Determines if an exception represents a retryable network error.
     *
     * @param exception The exception to check
     * @return True if the exception indicates a retryable error
     */
    fun isRetryableException(exception: Exception): Boolean {
        return when (exception) {
            is java.net.SocketTimeoutException -> true
            is java.net.UnknownHostException -> true
            is java.net.ConnectException -> true
            is java.io.IOException -> true
            else -> false
        }
    }
}
