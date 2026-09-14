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

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for how an unsuccessful E-utilities status becomes a [PubMedError].
 */
class PubMedErrorTest {

    // ==================== fromHttpError Tests ====================

    @Test
    fun `a 400 on a request that carried a key is a rejected key`() {
        val error = PubMedError.fromHttpError(400, "", apiKeySent = true)

        assertTrue("got $error", error is PubMedError.InvalidApiKeyError)
        assertTrue(error.message.contains("Settings"))
    }

    @Test
    fun `a 400 on a request without a key is a rejected search`() {
        val error = PubMedError.fromHttpError(400, "Bad Request", apiKeySent = false)

        assertTrue("got $error", error is PubMedError.SearchError)
        assertEquals("NCBI rejected the search (HTTP 400 Bad Request)", error.message)
    }

    @Test
    fun `a blank reason phrase leaves no dangling separator`() {
        // HTTP/2 has no reason phrase, which is how NCBI answers
        val error = PubMedError.fromHttpError(503, "")

        assertEquals("NCBI server error (HTTP 503)", error.message)
    }

    @Test
    fun `every redirect status is a refused redirect`() {
        for (statusCode in listOf(300, 301, 302, 303, 307, 308, 399)) {
            val error = PubMedError.fromHttpError(statusCode, "", apiKeySent = true)

            assertTrue("HTTP $statusCode: got $error", error is PubMedError.RedirectRefusedError)
            assertEquals(statusCode, (error as PubMedError.RedirectRefusedError).statusCode)
        }
    }

    @Test
    fun `429 is rate limiting and 5xx a server error`() {
        assertTrue(PubMedError.fromHttpError(429, "") is PubMedError.RateLimitError)
        val serverError = PubMedError.fromHttpError(502, "Bad Gateway")
        assertTrue(serverError is PubMedError.ServerError)
        assertEquals(502, (serverError as PubMedError.ServerError).statusCode)
    }

    @Test
    fun `any other status is an unknown error naming the status`() {
        val error = PubMedError.fromHttpError(403, "Forbidden")

        assertTrue("got $error", error is PubMedError.UnknownError)
        assertEquals("PubMed error (HTTP 403 Forbidden)", error.message)
    }

    // ==================== isRetryable Tests ====================

    @Test
    fun `only transient failures are retryable`() {
        assertTrue(PubMedError.isRetryable(PubMedError.RateLimitError()))
        assertTrue(PubMedError.isRetryable(PubMedError.ServerError("down", 503)))
        assertTrue(PubMedError.isRetryable(PubMedError.NetworkError("offline")))

        assertFalse(PubMedError.isRetryable(PubMedError.InvalidApiKeyError()))
        assertFalse(PubMedError.isRetryable(PubMedError.RedirectRefusedError("moved", 307)))
        assertFalse(PubMedError.isRetryable(PubMedError.SearchError("bad", "q")))
        assertFalse(PubMedError.isRetryable(PubMedError.UnknownError("odd")))
    }
}
