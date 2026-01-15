package com.bmlibrarian.factchecker.domain.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for LLMError sealed class.
 */
class LLMErrorTest {

    // ==================== fromHttpError Tests ====================

    @Test
    fun `fromHttpError creates AuthenticationError for 401`() {
        val error = LLMError.fromHttpError(401, "Unauthorized")

        assertTrue(error is LLMError.AuthenticationError)
        assertEquals(401, (error as LLMError.AuthenticationError).statusCode)
    }

    @Test
    fun `fromHttpError creates AuthenticationError for 403`() {
        val error = LLMError.fromHttpError(403, "Forbidden")

        assertTrue(error is LLMError.AuthenticationError)
        assertEquals(403, (error as LLMError.AuthenticationError).statusCode)
    }

    @Test
    fun `fromHttpError creates RateLimitError for 429`() {
        val error = LLMError.fromHttpError(429, "Too Many Requests")

        assertTrue(error is LLMError.RateLimitError)
    }

    @Test
    fun `fromHttpError creates InvalidRequestError for 400`() {
        val error = LLMError.fromHttpError(400, "Bad Request", "Invalid model parameter")

        assertTrue(error is LLMError.InvalidRequestError)
        assertEquals(400, (error as LLMError.InvalidRequestError).statusCode)
        assertEquals("Invalid model parameter", error.details)
    }

    @Test
    fun `fromHttpError creates ModelNotFoundError for 404`() {
        val error = LLMError.fromHttpError(404, "Not Found")

        assertTrue(error is LLMError.ModelNotFoundError)
    }

    @Test
    fun `fromHttpError creates ServerError for 500`() {
        val error = LLMError.fromHttpError(500, "Internal Server Error")

        assertTrue(error is LLMError.ServerError)
        assertEquals(500, (error as LLMError.ServerError).statusCode)
    }

    @Test
    fun `fromHttpError creates ServerError for 502`() {
        val error = LLMError.fromHttpError(502, "Bad Gateway")

        assertTrue(error is LLMError.ServerError)
        assertEquals(502, (error as LLMError.ServerError).statusCode)
    }

    @Test
    fun `fromHttpError creates ServerError for 503`() {
        val error = LLMError.fromHttpError(503, "Service Unavailable")

        assertTrue(error is LLMError.ServerError)
    }

    @Test
    fun `fromHttpError creates UnknownError for other status codes`() {
        val error = LLMError.fromHttpError(418, "I'm a teapot")

        assertTrue(error is LLMError.UnknownError)
        assertEquals(418, (error as LLMError.UnknownError).statusCode)
    }

    // ==================== isRetryable Tests ====================

    @Test
    fun `isRetryable returns true for RateLimitError`() {
        val error = LLMError.RateLimitError("Rate limited")

        assertTrue(LLMError.isRetryable(error))
    }

    @Test
    fun `isRetryable returns true for ServerError`() {
        val error = LLMError.ServerError("Server error", 500)

        assertTrue(LLMError.isRetryable(error))
    }

    @Test
    fun `isRetryable returns true for NetworkError`() {
        val error = LLMError.NetworkError("Connection failed")

        assertTrue(LLMError.isRetryable(error))
    }

    @Test
    fun `isRetryable returns false for AuthenticationError`() {
        val error = LLMError.AuthenticationError("Invalid key", 401)

        assertFalse(LLMError.isRetryable(error))
    }

    @Test
    fun `isRetryable returns false for InvalidRequestError`() {
        val error = LLMError.InvalidRequestError("Bad request", 400)

        assertFalse(LLMError.isRetryable(error))
    }

    @Test
    fun `isRetryable returns false for EmptyResponseError`() {
        val error = LLMError.EmptyResponseError()

        assertFalse(LLMError.isRetryable(error))
    }

    @Test
    fun `isRetryable returns false for ParseError`() {
        val error = LLMError.ParseError("Failed to parse")

        assertFalse(LLMError.isRetryable(error))
    }

    @Test
    fun `isRetryable returns false for ContentFilterError`() {
        val error = LLMError.ContentFilterError("Content blocked")

        assertFalse(LLMError.isRetryable(error))
    }

    @Test
    fun `isRetryable returns false for ContextLengthError`() {
        val error = LLMError.ContextLengthError("Context too long")

        assertFalse(LLMError.isRetryable(error))
    }

    // ==================== Error Properties Tests ====================

    @Test
    fun `ContextLengthError stores token counts`() {
        val error = LLMError.ContextLengthError(
            message = "Too long",
            maxTokens = 8192,
            requestedTokens = 10000
        )

        assertEquals(8192, error.maxTokens)
        assertEquals(10000, error.requestedTokens)
    }

    @Test
    fun `RateLimitError stores retry delay`() {
        val error = LLMError.RateLimitError(
            message = "Rate limited",
            retryAfterSeconds = 30
        )

        assertEquals(30, error.retryAfterSeconds)
    }

    @Test
    fun `NetworkError stores cause`() {
        val cause = RuntimeException("Connection reset")
        val error = LLMError.NetworkError(
            message = "Network failed",
            cause = cause
        )

        assertEquals(cause, error.cause)
    }

    @Test
    fun `ParseError stores raw response`() {
        val error = LLMError.ParseError(
            message = "Parse failed",
            rawResponse = "{invalid json"
        )

        assertEquals("{invalid json", error.rawResponse)
    }
}
