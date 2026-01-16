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

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.IOException
import java.net.ConnectException
import java.net.SocketTimeoutException
import java.net.UnknownHostException

/**
 * Unit tests for NetworkRetry utility.
 *
 * Tests the exponential backoff retry logic and retryable error detection.
 */
class NetworkRetryTest {

    // ==================== withExponentialBackoff Tests ====================

    /**
     * Test that successful operation returns immediately without retries.
     */
    @Test
    fun withExponentialBackoff_successOnFirstAttempt_returnsImmediately() = runTest {
        var attempts = 0

        val result = NetworkRetry.withExponentialBackoff(
            maxRetries = 3,
            initialDelayMs = 100,
            maxDelayMs = 1000
        ) {
            attempts++
            "success"
        }

        assertEquals("success", result)
        assertEquals(1, attempts)
    }

    /**
     * Test that operation succeeds after transient failures.
     */
    @Test
    fun withExponentialBackoff_failsThenSucceeds_retriesAndReturns() = runTest {
        var attempts = 0

        val result = NetworkRetry.withExponentialBackoff(
            maxRetries = 3,
            initialDelayMs = 10, // Short delay for test
            maxDelayMs = 100
        ) {
            attempts++
            if (attempts < 3) {
                throw IOException("Transient error")
            }
            "success after retries"
        }

        assertEquals("success after retries", result)
        assertEquals(3, attempts)
    }

    /**
     * Test that exception is thrown after max retries exhausted.
     */
    @Test
    fun withExponentialBackoff_alwaysFails_throwsAfterMaxRetries() = runTest {
        var attempts = 0

        try {
            NetworkRetry.withExponentialBackoff(
                maxRetries = 2,
                initialDelayMs = 10,
                maxDelayMs = 100
            ) {
                attempts++
                throw IOException("Persistent error")
            }
            fail("Expected IOException to be thrown")
        } catch (e: IOException) {
            assertEquals("Persistent error", e.message)
        }

        // Initial attempt + 2 retries = 3 total
        assertEquals(3, attempts)
    }

    /**
     * Test that non-retryable exceptions are thrown immediately.
     */
    @Test
    fun withExponentialBackoff_nonRetryableException_throwsImmediately() = runTest {
        var attempts = 0

        try {
            NetworkRetry.withExponentialBackoff(
                maxRetries = 3,
                initialDelayMs = 10,
                maxDelayMs = 100,
                shouldRetry = { false } // Never retry
            ) {
                attempts++
                throw IllegalArgumentException("Bad argument")
            }
            fail("Expected IllegalArgumentException to be thrown")
        } catch (e: IllegalArgumentException) {
            assertEquals("Bad argument", e.message)
        }

        assertEquals(1, attempts)
    }

    /**
     * Test that onRetry callback is invoked before each retry.
     */
    @Test
    fun withExponentialBackoff_callsOnRetryCallback() = runTest {
        val retryAttempts = mutableListOf<Int>()
        val retryDelays = mutableListOf<Long>()
        var attempts = 0

        try {
            NetworkRetry.withExponentialBackoff(
                maxRetries = 2,
                initialDelayMs = 100,
                maxDelayMs = 1000,
                onRetry = { attempt, delay, _ ->
                    retryAttempts.add(attempt)
                    retryDelays.add(delay)
                }
            ) {
                attempts++
                throw IOException("Transient error")
            }
        } catch (e: IOException) {
            // Expected
        }

        assertEquals(listOf(1, 2), retryAttempts)
        // First retry: 100ms, second retry: 200ms (exponential)
        assertEquals(100L, retryDelays[0])
        assertEquals(200L, retryDelays[1])
    }

    // ==================== isRetryableStatusCode Tests ====================

    /**
     * Test that timeout status codes are retryable.
     */
    @Test
    fun isRetryableStatusCode_timeoutCodes_returnsTrue() {
        assertTrue(NetworkRetry.isRetryableStatusCode(408)) // Request Timeout
        assertTrue(NetworkRetry.isRetryableStatusCode(504)) // Gateway Timeout
    }

    /**
     * Test that rate limit status code is retryable.
     */
    @Test
    fun isRetryableStatusCode_rateLimitCode_returnsTrue() {
        assertTrue(NetworkRetry.isRetryableStatusCode(429)) // Too Many Requests
    }

    /**
     * Test that server error codes are retryable.
     */
    @Test
    fun isRetryableStatusCode_serverErrorCodes_returnsTrue() {
        assertTrue(NetworkRetry.isRetryableStatusCode(500)) // Internal Server Error
        assertTrue(NetworkRetry.isRetryableStatusCode(502)) // Bad Gateway
        assertTrue(NetworkRetry.isRetryableStatusCode(503)) // Service Unavailable
    }

    /**
     * Test that client error codes are not retryable.
     */
    @Test
    fun isRetryableStatusCode_clientErrorCodes_returnsFalse() {
        assertFalse(NetworkRetry.isRetryableStatusCode(400)) // Bad Request
        assertFalse(NetworkRetry.isRetryableStatusCode(401)) // Unauthorized
        assertFalse(NetworkRetry.isRetryableStatusCode(403)) // Forbidden
        assertFalse(NetworkRetry.isRetryableStatusCode(404)) // Not Found
    }

    /**
     * Test that success codes are not retryable.
     */
    @Test
    fun isRetryableStatusCode_successCodes_returnsFalse() {
        assertFalse(NetworkRetry.isRetryableStatusCode(200))
        assertFalse(NetworkRetry.isRetryableStatusCode(201))
        assertFalse(NetworkRetry.isRetryableStatusCode(204))
    }

    // ==================== isRetryableException Tests ====================

    /**
     * Test that SocketTimeoutException is retryable.
     */
    @Test
    fun isRetryableException_socketTimeout_returnsTrue() {
        assertTrue(NetworkRetry.isRetryableException(SocketTimeoutException("Timeout")))
    }

    /**
     * Test that UnknownHostException is retryable.
     */
    @Test
    fun isRetryableException_unknownHost_returnsTrue() {
        assertTrue(NetworkRetry.isRetryableException(UnknownHostException("Unknown host")))
    }

    /**
     * Test that ConnectException is retryable.
     */
    @Test
    fun isRetryableException_connectException_returnsTrue() {
        assertTrue(NetworkRetry.isRetryableException(ConnectException("Connection refused")))
    }

    /**
     * Test that IOException is retryable.
     */
    @Test
    fun isRetryableException_ioException_returnsTrue() {
        assertTrue(NetworkRetry.isRetryableException(IOException("IO error")))
    }

    /**
     * Test that non-network exceptions are not retryable.
     */
    @Test
    fun isRetryableException_nonNetworkException_returnsFalse() {
        assertFalse(NetworkRetry.isRetryableException(IllegalArgumentException("Bad arg")))
        assertFalse(NetworkRetry.isRetryableException(IllegalStateException("Bad state")))
        assertFalse(NetworkRetry.isRetryableException(NullPointerException("Null")))
    }
}
