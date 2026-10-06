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
package com.bmlibrarian.factchecker.data.remote.fulltext

import android.util.Log
import com.bmlibrarian.factchecker.data.remote.transparency.RequestPacer
import com.bmlibrarian.factchecker.domain.model.RequestFailure
import com.bmlibrarian.factchecker.domain.model.RequestFailureKind
import com.bmlibrarian.factchecker.util.Constants
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.Interceptor
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import okio.Buffer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.net.InetAddress
import java.util.concurrent.TimeUnit

class CoreServiceTest {
    private lateinit var server: MockWebServer
    private val routes = mutableMapOf<String, MockResponse>()
    private val path = Constants.CORE_SEARCH_PATH
    private val hitText = "x".repeat(Constants.CORE_MIN_FULLTEXT_CHARS)
    private val hitBody = """{"results":[{"doi":"10.1159/000513404","fullText":"$hitText"}]}"""
    private val doi = "10.1159/000513404"
    private val served = CoreFetch.Served(hitText)
    private val malformed = CoreFetch.Unreachable(RequestFailure(RequestFailureKind.MALFORMED_RESPONSE))
    private var key: String? = "test-core-key"

    @Before
    fun setUp() {
        server = MockWebServer()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse =
                routes[request.requestUrl?.encodedPath ?: ""] ?: MockResponse().setResponseCode(404)
        }
        server.start(InetAddress.getLoopbackAddress(), 0)
    }

    @After
    fun tearDown() {
        server.shutdown()
    }

    private fun service(maxRetries: Int = 0, pacer: RequestPacer = RequestPacer(0L)) =
        CoreService(
            PmcOpenDataService.bucketClient(OkHttpClient(), Constants.CORE_REQUEST_TIMEOUT_SECONDS),
            server.url("").toString().trimEnd('/'),
            { key?.trim()?.takeIf { it.isNotEmpty() } },
            pacer,
            maxRetries,
            0L
        )

    private fun contract() = Json.parseToJsonElement(
        generateSequence(File("").absoluteFile) { it.parentFile }
            .map { File(it, "doc/cross_platform/fulltext_parity/core_fulltext.json") }
            .first { it.isFile }
            .readText()
    ).jsonObject

    @Test
    fun `every status row of the fixture gets its outcome`() = runBlocking {
        val rows = contract().getValue("status").jsonArray
        assertTrue("${rows.size} status rows; an emptied table would pass vacuously", rows.size >= MIN_STATUS_ROWS)
        for (row in rows.map { it.jsonObject }) {
            val status = row.getValue("status").jsonPrimitive.int
            val outcome = row.getValue("outcome").jsonPrimitive.content
            routes[path] = MockResponse().setResponseCode(status).setBody(if (status == 200) hitBody else "")
            val expected = when (outcome) {
                "served" -> served
                "key_refused" -> CoreFetch.KeyRefused
                else -> CoreFetch.Unreachable(RequestFailure.forHttpStatus(status))
            }
            // A fresh service each row: two 429s would otherwise pause the next
            assertEquals("status $status", expected, service().fetchText(doi))
        }
    }

    @Test
    fun `an answer we cannot read is malformed`() = runBlocking {
        val rows = contract().getValue("bodies").jsonArray
        assertTrue(rows.size >= MIN_BODY_ROWS)
        for (row in rows.map { it.jsonObject }) {
            routes[path] = MockResponse().setBody(row.getValue("body").jsonPrimitive.content)
            assertEquals(row.getValue("name").jsonPrimitive.content, malformed, service().fetchText(doi))
        }
    }

    @Test
    fun `a body that is not UTF-8 is malformed`() = runBlocking {
        routes[path] = MockResponse().setBody(Buffer().write(byteArrayOf(0x7B, 0xFF.toByte(), 0x7D)))
        assertEquals(malformed, service().fetchText(doi))
    }

    @Test
    fun `the key travels in the header alone`() = runBlocking {
        Log.clear()
        routes[path] = MockResponse().setBody(hitBody)
        service().fetchText(doi)
        val request = server.takeRequest(REQUEST_WAIT_SECONDS, TimeUnit.SECONDS)!!
        assertEquals("Bearer test-core-key", request.getHeader("Authorization"))
        assertFalse(request.requestUrl.toString(), "test-core-key" in request.requestUrl.toString())
        assertFalse(Log.lines.toString(), Log.lines.any { "test-core-key" in it })
    }

    @Test
    fun `without a key nothing is asked`() = runBlocking {
        for (absent in listOf<String?>(null, "  ")) {
            key = absent
            assertNull(service().fetchText(doi))
        }
        assertEquals(0, server.requestCount)
    }

    @Test
    fun `another article's text is never served`() = runBlocking {
        routes[path] = MockResponse().setBody(
            """{"results":[{"doi":"10.1159/999999","fullText":"$hitText"}]}"""
        )
        assertEquals(CoreFetch.Absent, service().fetchText(doi))
        // The control that CORE was asked, once, and its answer read
        assertEquals(1, server.requestCount)
    }

    @Test
    fun `a blank DOI is never asked`() = runBlocking {
        assertEquals(CoreFetch.Absent, service().fetchText("  "))
        assertEquals(0, server.requestCount)
    }

    @Test
    fun `two 429s in a row pause CORE for the session`() = runBlocking {
        routes[path] = MockResponse().setResponseCode(429)
        val service = service()
        val throttled = CoreFetch.Unreachable(RequestFailure.forHttpStatus(429))
        assertEquals(throttled, service.fetchText(doi))
        assertFalse(service.isPaused)
        assertEquals(throttled, service.fetchText(doi))
        assertTrue(service.isPaused)
        assertEquals(throttled, service.fetchText(doi))
        assertEquals(2, server.requestCount)
    }

    @Test
    fun `another answer between 429s resets the count`() = runBlocking {
        val service = service()
        routes[path] = MockResponse().setResponseCode(429)
        service.fetchText(doi)
        routes[path] = MockResponse().setBody(hitBody)
        assertEquals(served, service.fetchText(doi))
        routes[path] = MockResponse().setResponseCode(429)
        service.fetchText(doi)
        assertFalse(service.isPaused)
    }

    @Test
    fun `a transport failure between 429s resets the count`() = runBlocking {
        val service = service()
        routes[path] = MockResponse().setResponseCode(429)
        service.fetchText(doi)
        val failing = OkHttpClient.Builder()
            .addInterceptor(Interceptor { throw java.io.IOException("down") })
            .build()
        val flaky = CoreService(failing, server.url("").toString().trimEnd('/'), { key }, RequestPacer(0L), 0, 0L)
        flaky.fetchText(doi)
        assertFalse(flaky.isPaused)
    }

    /** The first 401 is told as a refused key, and CORE is not asked again (#498). */
    @Test
    fun `a 401 refuses the key for the session`() = runBlocking {
        routes[path] = MockResponse().setResponseCode(Constants.CORE_KEY_REFUSED_STATUS)
        val service = service()
        assertEquals(CoreFetch.KeyRefused, service.fetchText(doi))
        assertTrue(service.refuses(Core.keyDigest("test-core-key")))
        routes[path] = MockResponse().setBody(hitBody)
        assertEquals(CoreFetch.KeyRefused, service.fetchText(doi))
        assertEquals("a refused key sends nothing", 1, server.requestCount)
    }

    /** The control: a 403 is an ordinary answer, and CORE is asked again. */
    @Test
    fun `a 403 is an ordinary answer and refuses nothing`() = runBlocking {
        routes[path] = MockResponse().setResponseCode(403)
        val service = service()
        assertEquals(CoreFetch.Unreachable(RequestFailure.forHttpStatus(403)), service.fetchText(doi))
        assertFalse(service.refuses(Core.keyDigest("test-core-key")))
        routes[path] = MockResponse().setBody(hitBody)
        assertEquals(served, service.fetchText(doi))
        assertEquals(2, server.requestCount)
    }

    /** The refusal is the refused key's: a key corrected in the settings is asked again (#498). */
    @Test
    fun `a corrected key is asked again`() = runBlocking {
        val service = service()
        routes[path] = MockResponse().setResponseCode(Constants.CORE_KEY_REFUSED_STATUS)
        assertEquals(CoreFetch.KeyRefused, service.fetchText(doi))
        key = "test-core-key-corrected"
        routes[path] = MockResponse().setBody(hitBody)
        assertEquals(served, service.fetchText(doi))
        assertEquals(2, server.requestCount)
        server.takeRequest(REQUEST_WAIT_SECONDS, TimeUnit.SECONDS)
        val corrected = server.takeRequest(REQUEST_WAIT_SECONDS, TimeUnit.SECONDS)!!
        assertEquals("Bearer test-core-key-corrected", corrected.getHeader("Authorization"))
    }

    /** The control: the refused key stays refused beside another, and sends nothing. */
    @Test
    fun `the refused key stays refused`() = runBlocking {
        val service = service()
        routes[path] = MockResponse().setResponseCode(Constants.CORE_KEY_REFUSED_STATUS)
        service.fetchText(doi)
        key = "test-core-key-corrected"
        routes[path] = MockResponse().setBody(hitBody)
        service.fetchText(doi)
        key = "test-core-key"
        assertEquals(CoreFetch.KeyRefused, service.fetchText(doi))
        assertEquals(2, server.requestCount)
    }

    /** A 401 for another key refuses that key instead; the earlier one is asked again. */
    @Test
    fun `a 401 for another key refuses that key instead`() = runBlocking {
        val service = service()
        routes[path] = MockResponse().setResponseCode(Constants.CORE_KEY_REFUSED_STATUS)
        service.fetchText(doi)
        key = "test-core-key-corrected"
        service.fetchText(doi)
        assertTrue(service.refuses(Core.keyDigest("test-core-key-corrected")))
        assertFalse(service.refuses(Core.keyDigest("test-core-key")))
    }

    /** The key is held as the SHA-256 hex of the trimmed key, as Python's `core_key_digest`. */
    @Test
    fun `the key is held as a digest of the trimmed key`() {
        val digest = Core.keyDigest("test-core-key")
        assertEquals("648a20094c7319271078b3f552cac0ce0f0f84c812ee4be3b825f6a3e489be68", digest)
        assertEquals(digest, Core.keyDigest("  test-core-key\n"))
        assertFalse("test-core-key" in digest)
    }

    /** A 401 is an ending other than 429, so 429, 401, 429 does not pause. */
    @Test
    fun `a 401 resets the 429 count`() = runBlocking {
        val service = service()
        routes[path] = MockResponse().setResponseCode(429)
        service.fetchText(doi)
        routes[path] = MockResponse().setResponseCode(Constants.CORE_KEY_REFUSED_STATUS)
        service.fetchText(doi)
        // A corrected key's 429 is the first in a row, not the second
        key = "test-core-key-corrected"
        routes[path] = MockResponse().setResponseCode(429)
        service.fetchText(doi)
        assertFalse(service.isPaused)
        assertEquals(3, server.requestCount)
    }

    @Test
    fun `no server is unreachable`() = runBlocking {
        server.shutdown()
        val fetch = service().fetchText(doi)
        assertTrue(fetch.toString(), fetch is CoreFetch.Unreachable)
        assertEquals(RequestFailureKind.CONNECTION, (fetch as CoreFetch.Unreachable).failure.kind)
    }

    @Test
    fun `cancellation still propagates`() {
        val cancelling = OkHttpClient.Builder()
            .addInterceptor(Interceptor { throw CancellationException("cancelled") })
            .build()
        val service = CoreService(cancelling, server.url("").toString().trimEnd('/'), { key }, RequestPacer(0L), 0, 0L)
        assertThrows(CancellationException::class.java) {
            runBlocking { service.fetchText(doi) }
        }
    }

    @Test
    fun `every attempt takes a pacer slot`() = runBlocking {
        routes[path] = MockResponse().setResponseCode(503)
        val retries = 3
        val service = service(maxRetries = retries, pacer = RequestPacer(PACER_INTERVAL_MS))
        val started = System.nanoTime()
        val fetch = service.fetchText(doi)
        val elapsedMs = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started)
        assertEquals(CoreFetch.Unreachable(RequestFailure.forHttpStatus(503)), fetch)
        assertEquals(retries + 1, server.requestCount)
        assertTrue("$elapsedMs ms", elapsedMs >= retries * PACER_INTERVAL_MS)
    }

    private companion object {
        const val PACER_INTERVAL_MS = 150L
        const val REQUEST_WAIT_SECONDS = 5L
        const val MIN_STATUS_ROWS = 9
        const val MIN_BODY_ROWS = 4
    }
}
