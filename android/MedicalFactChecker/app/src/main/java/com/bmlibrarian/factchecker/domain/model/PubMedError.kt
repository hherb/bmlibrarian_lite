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

package com.bmlibrarian.factchecker.domain.model

import com.bmlibrarian.factchecker.util.Constants

/**
 * Sealed class representing errors from PubMed/NCBI E-utilities operations.
 *
 * Provides type-safe error handling for all PubMed-related failures,
 * enabling exhaustive when-matching for error handling.
 *
 * @property message Human-readable error message
 * @property cause Underlying exception, if any
 */
sealed class PubMedError(
    override val message: String,
    override val cause: Throwable? = null
) : Exception(message, cause) {

    /**
     * Search query failed or returned invalid results.
     *
     * @property message Error message
     * @property query The search query that failed
     */
    data class SearchError(
        override val message: String,
        val query: String
    ) : PubMedError(message)

    /**
     * Failed to fetch article details.
     *
     * @property message Error message
     * @property pmids PMIDs that failed to fetch
     */
    data class FetchError(
        override val message: String,
        val pmids: List<String>
    ) : PubMedError(message)

    /**
     * Failed to parse XML response.
     *
     * @property message Error message
     * @property cause Underlying parsing exception
     */
    data class ParseError(
        override val message: String,
        override val cause: Throwable? = null
    ) : PubMedError(message, cause)

    /**
     * Rate limit exceeded - too many requests.
     *
     * NCBI E-utilities rate limits:
     * - Without API key: 3 requests/second
     * - With API key: 10 requests/second
     *
     * @property message Error message
     */
    data class RateLimitError(
        override val message: String = "NCBI rate limit exceeded. Please wait before retrying."
    ) : PubMedError(message)

    /**
     * NCBI refused a request that carried an API key, most likely because the key
     * is invalid.
     *
     * NCBI answers a bad key with HTTP 400, and its body repeats the key, so the
     * body is never read; the status and the fact that a key was sent are enough.
     *
     * @property message Error message
     */
    data class InvalidApiKeyError(
        override val message: String = "NCBI refused the request (HTTP 400), most likely because " +
            "the saved NCBI API key is invalid. Check or clear it in Settings."
    ) : PubMedError(message)

    /**
     * Network error - connection failure or timeout.
     *
     * @property message Error message
     * @property cause Underlying network exception
     */
    data class NetworkError(
        override val message: String,
        override val cause: Throwable? = null
    ) : PubMedError(message, cause)

    /**
     * Empty search results - no articles found.
     *
     * @property message Error message
     * @property query The search query that returned no results
     */
    data class NoResultsError(
        override val message: String,
        val query: String
    ) : PubMedError(message)

    /**
     * Server error from NCBI.
     *
     * @property message Error message
     * @property statusCode HTTP status code
     */
    data class ServerError(
        override val message: String,
        val statusCode: Int
    ) : PubMedError(message)

    /**
     * NCBI answered with a redirect, which is never followed (#243).
     *
     * E-utilities parameters, the API key included, travel in the request body.
     * A 307 or 308 would re-send that body to whatever host it names; a 301,
     * 302 or 303 would re-send the request as a GET without its parameters.
     * Not retryable: a redirect does not go away on a second attempt.
     *
     * @property message Error message
     * @property statusCode The 3xx status NCBI answered with
     */
    data class RedirectRefusedError(
        override val message: String,
        val statusCode: Int
    ) : PubMedError(message)

    /**
     * Invalid offset - pagination offset out of range.
     *
     * PubMed limits offset to 9999.
     *
     * @property message Error message
     * @property offset The invalid offset value
     */
    data class InvalidOffsetError(
        override val message: String,
        val offset: Int
    ) : PubMedError(message)

    /**
     * Unknown error - unexpected error condition.
     *
     * @property message Error message
     * @property cause Underlying exception, if any
     */
    data class UnknownError(
        override val message: String,
        override val cause: Throwable? = null
    ) : PubMedError(message, cause)

    companion object {
        /**
         * Create an appropriate PubMedError from an unsuccessful HTTP response.
         *
         * Takes the status line's reason phrase and never the response body:
         * NCBI's 400 for a bad key repeats the key in its body, so a body in an
         * error message would carry the key into logs and onto the screen.
         *
         * @param statusCode HTTP status code
         * @param reasonPhrase The status line's reason phrase; blank under HTTP/2
         * @param apiKeySent Whether the request carried an NCBI API key, which
         *   makes a 400 a rejected key rather than a rejected search
         * @return Appropriate PubMedError subclass
         */
        fun fromHttpError(statusCode: Int, reasonPhrase: String, apiKeySent: Boolean = false): PubMedError {
            val status = if (reasonPhrase.isBlank()) "HTTP $statusCode" else "HTTP $statusCode $reasonPhrase"
            return when (statusCode) {
                Constants.HTTP_BAD_REQUEST -> if (apiKeySent) {
                    InvalidApiKeyError()
                } else {
                    SearchError(
                        message = "NCBI rejected the search ($status)",
                        query = ""
                    )
                }
                in Constants.HTTP_REDIRECT_STATUS_CODES -> RedirectRefusedError(
                    message = "PubMed answered with a redirect (HTTP $statusCode), which was not followed",
                    statusCode = statusCode
                )
                Constants.HTTP_TOO_MANY_REQUESTS -> RateLimitError()
                in Constants.HTTP_SERVER_ERROR_STATUS_CODES -> ServerError(
                    message = "NCBI server error ($status)",
                    statusCode = statusCode
                )
                else -> UnknownError(
                    message = "PubMed error ($status)"
                )
            }
        }

        /**
         * Check if an error is retryable.
         *
         * Lists every error type, so a new one must be classified here to compile.
         *
         * @param error The error to check
         * @return true if the error may succeed on retry
         */
        fun isRetryable(error: PubMedError): Boolean {
            return when (error) {
                is RateLimitError, is ServerError, is NetworkError -> true
                is SearchError, is FetchError, is ParseError, is InvalidApiKeyError,
                is NoResultsError, is RedirectRefusedError, is InvalidOffsetError,
                is UnknownError -> false
            }
        }
    }
}
