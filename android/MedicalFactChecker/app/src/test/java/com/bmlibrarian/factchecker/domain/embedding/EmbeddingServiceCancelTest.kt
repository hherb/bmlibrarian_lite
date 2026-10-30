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

package com.bmlibrarian.factchecker.domain.embedding

import android.content.Context
import com.bmlibrarian.factchecker.util.Constants
import com.bmlibrarian.factchecker.util.awaitFileEndingWith
import com.bmlibrarian.factchecker.util.cancelInFlight
import io.mockk.every
import io.mockk.mockk
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okio.Buffer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** Cancelling a run while the model downloads does not give up on embeddings (#665). */
class EmbeddingServiceCancelTest {

    @get:Rule
    val files = TemporaryFolder()

    private lateinit var server: MockWebServer
    private lateinit var service: EmbeddingService

    @Before
    fun setUp() {
        server = MockWebServer()
        server.start()
        val context = mockk<Context> { every { filesDir } returns files.root }
        // The model's address is a constant: every request goes to the test server instead
        val client = OkHttpClient.Builder()
            .addInterceptor { chain -> chain.proceed(chain.request().newBuilder().url(server.url("/model")).build()) }
            .build()
        service = EmbeddingService(context, client)
    }

    @After
    fun tearDown() {
        server.shutdown()
    }

    /** Start initializing, and cancel once the model is part-way written. */
    private fun cancelMidDownload(): Throwable? {
        server.enqueue(
            MockResponse().setBody(Buffer().write(ByteArray(SLOW_MODEL_BYTES)))
                .throttleBody(MODEL_BYTES_PER_SECOND, 1, TimeUnit.SECONDS)
        )
        return cancelInFlight(server, {
            awaitFileEndingWith(files.root, Constants.EMBEDDING_MODEL_PARTIAL_SUFFIX)
        }) { service.ensureInitialized() }
    }

    @Test
    fun `a cancelled initialization leaves embeddings available and no file behind`() {
        assertTrue(cancelMidDownload() is CancellationException)

        assertTrue(service.isAvailable)
        assertFalse(service.isModelDownloaded)
        assertEquals(emptyList<String>(), files.root.walkTopDown().filter { it.isFile }.map { it.name }.toList())
    }

    @Test
    fun `a cancelled initialization is tried again`() {
        cancelMidDownload()
        server.enqueue(MockResponse().setResponseCode(HTTP_NOT_FOUND))

        assertFalse(runBlocking { service.ensureInitialized() })
        assertEquals(2, server.requestCount)
    }

    private companion object {
        /** Forty seconds of body: far longer than any test. */
        const val SLOW_MODEL_BYTES = 4_000
        const val MODEL_BYTES_PER_SECOND = 100L
        const val HTTP_NOT_FOUND = 404
    }
}
