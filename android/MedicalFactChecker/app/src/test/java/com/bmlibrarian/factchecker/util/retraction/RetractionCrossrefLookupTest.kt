// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2026 Dr Horst Herb
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.
package com.bmlibrarian.factchecker.util.retraction

import com.bmlibrarian.factchecker.data.remote.transparency.TransparencyRetryPolicy
import com.bmlibrarian.factchecker.domain.model.RequestFailure
import com.bmlibrarian.factchecker.domain.model.RequestFailureKind
import kotlinx.coroutines.test.runTest
import okhttp3.mockwebserver.MockWebServer
import org.bmlib.ffi.CrossrefResult
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** Crossref's answers per DOI: a failed batch is unanswered, never clear (`RetractionCrossrefLookupTests.swift`). */
class RetractionCrossrefLookupTest {
    private lateinit var stub: StubServer

    private val notice = """
        {"DOI": "10.1000/a0", "updated-by": [
          {"DOI": "10.1000/notice", "type": "retraction", "source": "retraction-watch",
           "updated": {"date-parts": [[2020, 1, 1]]}}]}
    """.trimIndent()

    @Before
    fun setUp() {
        BmlibFfi.assumeAvailable()
        stub = StubServer()
    }

    @After
    fun tearDown() {
        if (::stub.isInitialized) stub.close()
    }

    private fun lookup(client: okhttp3.OkHttpClient = stub.client()) = RetractionCrossrefLookup(
        email = "t@example.org",
        httpClient = client,
        retryPolicy = TransparencyRetryPolicy(initialDelayMs = 0, maxDelayMs = 0),
        minimumRequestIntervalMs = 0
    )

    @Test
    fun `a served batch parses`() = runTest {
        stub.stubbed = StubServer.answer(200, StubServer.crossrefBody(notice))
        val out = lookup().results(listOf("10.1000/a0", "10.1000/a1"))
        val served = out["10.1000/a0"]?.result as? CrossrefResult.Served
        assertTrue("a0 should be served: ${out["10.1000/a0"]}", served != null && served.evidence.isNotEmpty())
        assertNull(out["10.1000/a0"]?.failure)
        assertEquals(CrossrefResult.NotKnown, out["10.1000/a1"]?.result)
        assertNull(out["10.1000/a1"]?.failure)
    }

    @Test
    fun `no DOIs ask nothing`() = runTest {
        assertTrue(lookup().results(emptyList()).isEmpty())
        assertTrue(stub.requestedUrls.isEmpty())
    }

    @Test
    fun `one failed batch leaves only its DOIs unreachable`() = runTest {
        val first = (0 until 50).map { "10.1000/a$it" }
        val second = (0 until 10).map { "10.1000/b$it" }
        stub.routes = mapOf(
            "doi:10.1000/a0," to StubServer.answer(429),
            "doi:10.1000/b0," to StubServer.answer(200, StubServer.crossrefBody("""{"DOI": "10.1000/b0"}""")),
        )
        val out = lookup().results(first + second)
        for (doi in first) {
            assertTrue(doi, out[doi]?.result is CrossrefResult.Unreachable)
            assertEquals(doi, RequestFailure(RequestFailureKind.HTTP_STATUS, 429), out[doi]?.failure)
        }
        assertTrue(out["10.1000/b0"]?.result is CrossrefResult.Served)
        assertEquals(CrossrefResult.NotKnown, out["10.1000/b1"]?.result)
        assertEquals("three attempts, then the second batch", 3 + 1, stub.requestedUrls.size)
    }

    @Test
    fun `a 429 then an answer is served`() = runTest {
        stub.sequence += StubServer.answer(429)
        stub.stubbed = StubServer.answer(200, StubServer.crossrefBody(notice))
        assertTrue(lookup().results(listOf("10.1000/a0"))["10.1000/a0"]?.result is CrossrefResult.Served)
        assertEquals(2, stub.requestedUrls.size)
    }

    @Test
    fun `malformed JSON is unreachable`() = runTest {
        stub.stubbed = StubServer.answer(200, "not json")
        val out = lookup().results(listOf("10.1000/a0"))
        assertTrue(out["10.1000/a0"]?.result is CrossrefResult.Unreachable)
        assertEquals(RequestFailure(RequestFailureKind.MALFORMED_RESPONSE), out["10.1000/a0"]?.failure)
    }

    /** A status bmlib does not retry is still unanswered, never clear (#649). */
    @Test
    fun `a 404 is unreachable`() = runTest {
        stub.stubbed = StubServer.answer(404)
        val out = lookup().results(listOf("10.1000/a0"))
        assertTrue(out["10.1000/a0"]?.result is CrossrefResult.Unreachable)
        assertEquals(RequestFailure(RequestFailureKind.HTTP_STATUS, 404), out["10.1000/a0"]?.failure)
    }

    @Test
    fun `a network error is unreachable, in the app's words`() = runTest {
        val dead = MockWebServer().apply { start() }
        val url = dead.url("/")
        dead.shutdown()
        val client = okhttp3.OkHttpClient.Builder().addInterceptor { chain ->
            chain.proceed(chain.request().newBuilder().url(chain.request().url.newBuilder().host(url.host).port(url.port).scheme("http").build()).build())
        }.build()
        val out = lookup(client).results(listOf("10.1000/a0"))
        val connection = RequestFailure(RequestFailureKind.CONNECTION)
        assertEquals(connection, out["10.1000/a0"]?.failure)
        assertEquals(CrossrefResult.Unreachable(connection.describe()), out["10.1000/a0"]?.result)
    }

    @Test
    fun `the User-Agent carries the mailto`() = runTest {
        stub.stubbed = StubServer.answer(200, StubServer.crossrefBody(""))
        lookup().results(listOf("10.1000/a0"))
        val agent = stub.requests.first().getHeader("User-Agent") ?: ""
        assertTrue(agent, agent.contains("mailto:t@example.org"))
    }
}
