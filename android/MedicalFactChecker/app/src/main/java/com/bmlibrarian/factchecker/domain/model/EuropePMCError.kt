package com.bmlibrarian.factchecker.domain.model

/**
 * Sealed class representing errors from Europe PMC API operations.
 *
 * Provides type-safe error handling for all Europe PMC-related failures,
 * enabling exhaustive when-matching for error handling.
 *
 * @property message Human-readable error message
 * @property cause Underlying exception, if any
 */
sealed class EuropePMCError(
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
    ) : EuropePMCError(message)

    /**
     * Failed to parse JSON response.
     *
     * @property message Error message
     * @property cause Underlying parsing exception
     */
    data class ParseError(
        override val message: String,
        override val cause: Throwable? = null
    ) : EuropePMCError(message, cause)

    /**
     * Invalid cursor for pagination.
     *
     * @property message Error message
     * @property cursor The invalid cursor value
     */
    data class InvalidCursorError(
        override val message: String,
        val cursor: String
    ) : EuropePMCError(message)

    /**
     * Network error - connection failure or timeout.
     *
     * @property message Error message
     * @property cause Underlying network exception
     */
    data class NetworkError(
        override val message: String,
        override val cause: Throwable? = null
    ) : EuropePMCError(message, cause)

    /**
     * Empty search results - no articles found.
     *
     * @property message Error message
     * @property query The search query that returned no results
     */
    data class NoResultsError(
        override val message: String,
        val query: String
    ) : EuropePMCError(message)

    /**
     * Server error from Europe PMC.
     *
     * @property message Error message
     * @property statusCode HTTP status code
     */
    data class ServerError(
        override val message: String,
        val statusCode: Int
    ) : EuropePMCError(message)

    /**
     * Full text not available for article.
     *
     * @property message Error message
     * @property pmcId The PMC ID for which full text is unavailable
     */
    data class FullTextUnavailableError(
        override val message: String,
        val pmcId: String
    ) : EuropePMCError(message)

    /**
     * Unknown error - unexpected error condition.
     *
     * @property message Error message
     * @property cause Underlying exception, if any
     */
    data class UnknownError(
        override val message: String,
        override val cause: Throwable? = null
    ) : EuropePMCError(message, cause)

    companion object {
        /**
         * Create an appropriate EuropePMCError from an HTTP status code.
         *
         * @param statusCode HTTP status code
         * @param message Error message
         * @return Appropriate EuropePMCError subclass
         */
        fun fromHttpError(statusCode: Int, message: String): EuropePMCError {
            return when (statusCode) {
                400 -> SearchError(
                    message = "Invalid search query: $message",
                    query = ""
                )
                404 -> FullTextUnavailableError(
                    message = "Article not found: $message",
                    pmcId = ""
                )
                in 500..599 -> ServerError(
                    message = "Europe PMC server error: $message",
                    statusCode = statusCode
                )
                else -> UnknownError(
                    message = "Europe PMC error $statusCode: $message"
                )
            }
        }

        /**
         * Check if an error is retryable.
         *
         * @param error The error to check
         * @return true if the error may succeed on retry
         */
        fun isRetryable(error: EuropePMCError): Boolean {
            return when (error) {
                is ServerError -> true
                is NetworkError -> true
                else -> false
            }
        }
    }
}
