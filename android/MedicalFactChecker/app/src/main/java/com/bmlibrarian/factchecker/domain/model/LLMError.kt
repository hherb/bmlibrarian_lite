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

/**
 * Sealed class representing errors from LLM API operations.
 *
 * Provides type-safe error handling for all LLM-related failures,
 * enabling exhaustive when-matching for error handling.
 *
 * @property message Human-readable error message
 * @property cause Underlying exception, if any
 */
sealed class LLMError(
    open val message: String,
    open val cause: Throwable? = null
) : Exception(message, cause) {

    /**
     * Authentication failed - invalid or missing API key.
     *
     * @property message Error message
     * @property statusCode HTTP status code (typically 401 or 403)
     */
    data class AuthenticationError(
        override val message: String,
        val statusCode: Int
    ) : LLMError(message)

    /**
     * Rate limit exceeded - too many requests.
     *
     * @property message Error message
     * @property retryAfterSeconds Suggested retry delay, if provided by API
     */
    data class RateLimitError(
        override val message: String,
        val retryAfterSeconds: Int? = null
    ) : LLMError(message)

    /**
     * Invalid request - malformed request or invalid parameters.
     *
     * @property message Error message
     * @property statusCode HTTP status code (typically 400)
     * @property details Additional error details from API
     */
    data class InvalidRequestError(
        override val message: String,
        val statusCode: Int,
        val details: String? = null
    ) : LLMError(message)

    /**
     * Model not found or not available.
     *
     * @property message Error message
     * @property modelId The requested model ID
     */
    data class ModelNotFoundError(
        override val message: String,
        val modelId: String
    ) : LLMError(message)

    /**
     * Context length exceeded - input too long for model.
     *
     * @property message Error message
     * @property maxTokens Maximum tokens allowed
     * @property requestedTokens Tokens in the request
     */
    data class ContextLengthError(
        override val message: String,
        val maxTokens: Int? = null,
        val requestedTokens: Int? = null
    ) : LLMError(message)

    /**
     * Content filtered - response blocked by content filter.
     *
     * @property message Error message
     * @property reason Filtering reason, if provided
     */
    data class ContentFilterError(
        override val message: String,
        val reason: String? = null
    ) : LLMError(message)

    /**
     * Server error - internal error at the API provider.
     *
     * @property message Error message
     * @property statusCode HTTP status code (5xx)
     */
    data class ServerError(
        override val message: String,
        val statusCode: Int
    ) : LLMError(message)

    /**
     * Network error - connection failure or timeout.
     *
     * @property message Error message
     * @property cause Underlying network exception
     */
    data class NetworkError(
        override val message: String,
        override val cause: Throwable? = null
    ) : LLMError(message, cause)

    /**
     * Parse error - failed to parse API response.
     *
     * @property message Error message
     * @property rawResponse The raw response that failed to parse
     */
    data class ParseError(
        override val message: String,
        val rawResponse: String? = null
    ) : LLMError(message)

    /**
     * Empty response - API returned no content.
     *
     * @property message Error message
     */
    data class EmptyResponseError(
        override val message: String = "API returned empty response"
    ) : LLMError(message)

    /**
     * Unknown error - unexpected error condition.
     *
     * @property message Error message
     * @property statusCode HTTP status code, if applicable
     * @property cause Underlying exception, if any
     */
    data class UnknownError(
        override val message: String,
        val statusCode: Int? = null,
        override val cause: Throwable? = null
    ) : LLMError(message, cause)

    companion object {
        /**
         * Create an appropriate LLMError from an HTTP status code and message.
         *
         * @param statusCode HTTP status code
         * @param message Error message
         * @param body Response body, if available
         * @return Appropriate LLMError subclass
         */
        fun fromHttpError(statusCode: Int, message: String, body: String? = null): LLMError {
            return when (statusCode) {
                401, 403 -> AuthenticationError(
                    message = "Authentication failed: $message",
                    statusCode = statusCode
                )
                429 -> RateLimitError(
                    message = "Rate limit exceeded: $message"
                )
                400 -> InvalidRequestError(
                    message = "Invalid request: $message",
                    statusCode = statusCode,
                    details = body
                )
                404 -> ModelNotFoundError(
                    message = "Model not found: $message",
                    modelId = ""
                )
                in 500..599 -> ServerError(
                    message = "Server error: $message",
                    statusCode = statusCode
                )
                else -> UnknownError(
                    message = "HTTP error $statusCode: $message",
                    statusCode = statusCode
                )
            }
        }

        /**
         * Check if an error is retryable.
         *
         * @param error The error to check
         * @return true if the error may succeed on retry
         */
        fun isRetryable(error: LLMError): Boolean {
            return when (error) {
                is RateLimitError -> true
                is ServerError -> true
                is NetworkError -> true
                else -> false
            }
        }
    }
}
