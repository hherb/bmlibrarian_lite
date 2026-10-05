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

import com.bmlibrarian.factchecker.data.remote.transparency.RequestPacer
import com.bmlibrarian.factchecker.domain.model.RequestFailure
import com.bmlibrarian.factchecker.domain.model.RequestFailureKind
import com.bmlibrarian.factchecker.util.Constants
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import okio.Buffer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.net.InetAddress
import java.util.concurrent.TimeUnit

class OpenAlexServiceTest {
    private lateinit var server: MockWebServer
    private val routes = mutableMapOf<String, MockResponse>()
    private val path = "/works/doi:10.1%2Fx"
    private val body = """{"locations":[{"pdf_url":"https://repo.example.org/a.pdf"}]}"""
    private val served = OpenAlexFetch.Served(listOf("https://repo.example.org/a.pdf"))
    private val malformed = OpenAlexFetch.Unreachable(RequestFailure(RequestFailureKind.MALFORMED_RESPONSE))

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

    private fun service(maxRetries: Int = 0, mailto: String? = null, pacer: RequestPacer = RequestPacer(0L)) =
        OpenAlexService(
            PmcOpenDataService.bucketClient(OkHttpClient(), Constants.OPENALEX_REQUEST_TIMEOUT_SECONDS),
            server.url("").toString().trimEnd('/'),
            { mailto },
            pacer,
            maxRetries,
            0L
        )

    private fun contractFile(): File {
        var candidate: File? = File("").absoluteFile
        while (candidate != null) {
            val file = File(candidate, "doc/cross_platform/fulltext_parity/openalex_locations.json")
            if (file.isFile) return file
            candidate = candidate.parentFile
        }
        error("openalex_locations.json not found")
    }

    @Test
    fun `every status row of the fixture gets its outcome`() = runBlocking {
        val rows = Json.parseToJsonElement(contractFile().readText()).jsonObject.getValue("status").jsonArray
        for (row in rows.map { it.jsonObject }) {
            val status = row.getValue("status").jsonPrimitive.int
            val outcome = row.getValue("outcome").jsonPrimitive.content
            routes[path] = MockResponse().setResponseCode(status).setBody(if (status == 200) body else "")
            val fetch = service().fetchPdfUrls("10.1/x")
            val expected = when (outcome) {
                "served" -> served
                "absent" -> OpenAlexFetch.Absent
                else -> OpenAlexFetch.Unreachable(RequestFailure.forHttpStatus(status))
            }
            assertEquals("status $status", expected, fetch)
        }
    }

    @Test
    fun `a 404 with an HTML body is absent`() = runBlocking {
        routes[path] = MockResponse().setResponseCode(404).setBody("<html>not found</html>")
        assertEquals(OpenAlexFetch.Absent, service().fetchPdfUrls("10.1/x"))
    }

    @Test
    fun `a throttle is asked again`() = runBlocking {
        var hits = 0
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse =
                if (hits++ == 0) MockResponse().setResponseCode(503) else MockResponse().setBody(body)
        }
        assertEquals(served, service(maxRetries = 1).fetchPdfUrls("10.1/x"))
        assertEquals(2, server.requestCount)
    }

    @Test
    fun `a 404 is not asked again`() = runBlocking {
        assertEquals(OpenAlexFetch.Absent, service(maxRetries = 1).fetchPdfUrls("10.1/x"))
        assertEquals(1, server.requestCount)
    }

    @Test
    fun `an answer we cannot read is malformed`() = runBlocking {
        for (text in listOf("not json", "[]", """{"locations":{"pdf_url":"x"}}""")) {
            routes[path] = MockResponse().setBody(text)
            assertEquals(text, malformed, service().fetchPdfUrls("10.1/x"))
        }
        routes[path] = MockResponse().setBody(Buffer().writeByte(0xFF))
        assertEquals(malformed, service().fetchPdfUrls("10.1/x"))
    }

    @Test
    fun `a work with no PDF is served empty`() = runBlocking {
        routes[path] = MockResponse().setBody("""{"locations":[]}""")
        assertEquals(OpenAlexFetch.Served(emptyList()), service().fetchPdfUrls("10.1/x"))
    }

    @Test
    fun `no server is unreachable`() = runBlocking {
        server.shutdown()
        val fetch = service().fetchPdfUrls("10.1/x")
        assertTrue(fetch.toString(), fetch is OpenAlexFetch.Unreachable)
    }

    @Test
    fun `the request names the DOI as one segment and the contact`() = runBlocking {
        routes[path] = MockResponse().setBody(body)
        service(mailto = "researcher@example.org").fetchPdfUrls("10.1/x")
        val with = server.takeRequest(REQUEST_WAIT_SECONDS, TimeUnit.SECONDS)!!.requestUrl!!
        assertEquals(path, with.encodedPath)
        assertEquals("select=locations&mailto=researcher%40example.org", with.encodedQuery)
        service(mailto = null).fetchPdfUrls("10.1/x")
        val without = server.takeRequest(REQUEST_WAIT_SECONDS, TimeUnit.SECONDS)!!.requestUrl!!
        assertEquals("select=locations", without.encodedQuery)
    }

    @Test
    fun `a blank DOI is never asked`() = runBlocking {
        assertEquals(OpenAlexFetch.Absent, service().fetchPdfUrls("  "))
        assertEquals(0, server.requestCount)
    }

    @Test
    fun `every attempt takes a pacer slot`() = runBlocking {
        routes[path] = MockResponse().setResponseCode(429)
        val retries = 3
        val service = service(maxRetries = retries, pacer = RequestPacer(PACER_INTERVAL_MS))
        val started = System.nanoTime()
        val fetch = service.fetchPdfUrls("10.1/x")
        val elapsedMs = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started)
        assertEquals(OpenAlexFetch.Unreachable(RequestFailure.forHttpStatus(429)), fetch)
        assertEquals(retries + 1, server.requestCount)
        assertTrue("$elapsedMs ms", elapsedMs >= retries * PACER_INTERVAL_MS)
    }

    private companion object {
        const val PACER_INTERVAL_MS = 150L
        const val REQUEST_WAIT_SECONDS = 5L
    }
}
