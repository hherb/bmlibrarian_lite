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

package com.bmlibrarian.factchecker.util

import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.SocketPolicy
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** A cancelled caller cancels its OkHttp call, rather than waiting for the server (#665). */
class CancellableCallTest {

    private lateinit var server: MockWebServer

    /** Waits far longer than any test, so only a cancel can end a call early. */
    private val client = OkHttpClient.Builder().readTimeout(SLOW_SECONDS, TimeUnit.SECONDS).build()

    @Before
    fun setUp() {
        server = MockWebServer()
        server.start()
    }

    @After
    fun tearDown() {
        server.shutdown()
    }

    private fun request() = Request.Builder().url(server.url("/slow")).build()

    /** Start a call, wait until the server holds it, cancel, and answer what the caller saw. */
    private fun cancelInFlight(read: (okhttp3.Response) -> Unit): Throwable? = runBlocking {
        var thrown: Throwable? = null
        val job = launch(Dispatchers.IO) {
            try {
                client.executeCancellably(request(), read)
            } catch (e: Throwable) {
                thrown = e
                throw e
            }
        }
        assertNotNull(server.takeRequest(SLOW_SECONDS, TimeUnit.SECONDS))
        withTimeout(CANCEL_WITHIN_MS) { job.cancelAndJoin() }
        thrown
    }

    @Test
    fun `a cancel ends a call the server has not answered`() {
        server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.NO_RESPONSE))

        assertTrue(cancelInFlight { } is CancellationException)
    }

    @Test
    fun `a cancel ends a body that is still arriving`() {
        server.enqueue(MockResponse().setBody("x".repeat(SLOW_BODY_BYTES)).throttleBody(1, 1, TimeUnit.SECONDS))

        assertTrue(cancelInFlight { it.body?.bytes() } is CancellationException)
    }

    /** Control: with no cancel, a transport failure is still one, never a cancellation. */
    @Test
    fun `an uncancelled transport failure stays a transport failure`() {
        server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.DISCONNECT_AT_START))

        val thrown = runCatching { runBlocking(Dispatchers.IO) { client.executeCancellably(request()) { it.code } } }
            .exceptionOrNull()

        assertTrue("$thrown", thrown is IOException)
    }

    @Test
    fun `an answered call returns what its block read`() {
        server.enqueue(MockResponse().setBody("answer"))

        assertEquals("answer", runBlocking(Dispatchers.IO) { client.executeCancellably(request()) { it.body?.string() } })
    }

    private companion object {
        const val SLOW_SECONDS = 60L
        const val CANCEL_WITHIN_MS = 5_000L
        const val SLOW_BODY_BYTES = 20 // a second each: well past CANCEL_WITHIN_MS
    }
}
