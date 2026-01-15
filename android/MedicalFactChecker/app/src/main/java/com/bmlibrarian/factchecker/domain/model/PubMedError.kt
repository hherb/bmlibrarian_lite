package com.bmlibrarian.factchecker.domain.model

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
    open val message: String,
    open val cause: Throwable? = null
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
     * Invalid API key.
     *
     * @property message Error message
     */
    data class InvalidApiKeyError(
        override val message: String = "Invalid NCBI API key"
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
         * Create an appropriate PubMedError from an HTTP status code.
         *
         * @param statusCode HTTP status code
         * @param message Error message
         * @return Appropriate PubMedError subclass
         */
        fun fromHttpError(statusCode: Int, message: String): PubMedError {
            return when (statusCode) {
                400 -> SearchError(
                    message = "Invalid search query: $message",
                    query = ""
                )
                429 -> RateLimitError()
                in 500..599 -> ServerError(
                    message = "NCBI server error: $message",
                    statusCode = statusCode
                )
                else -> UnknownError(
                    message = "PubMed error $statusCode: $message"
                )
            }
        }

        /**
         * Check if an error is retryable.
         *
         * @param error The error to check
         * @return true if the error may succeed on retry
         */
        fun isRetryable(error: PubMedError): Boolean {
            return when (error) {
                is RateLimitError -> true
                is ServerError -> true
                is NetworkError -> true
                else -> false
            }
        }
    }
}
