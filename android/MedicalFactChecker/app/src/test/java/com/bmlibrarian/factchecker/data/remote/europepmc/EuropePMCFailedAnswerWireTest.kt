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

package com.bmlibrarian.factchecker.data.remote.europepmc

import android.util.Log
import com.bmlibrarian.factchecker.di.AppModule
import com.bmlibrarian.factchecker.di.NetworkModule
import com.bmlibrarian.factchecker.data.remote.REFUSED_JSON_VALUES
import com.bmlibrarian.factchecker.data.remote.serverBoundClient
import com.bmlibrarian.factchecker.domain.model.RequestFailure
import com.bmlibrarian.factchecker.domain.model.RequestFailureKind
import com.bmlibrarian.factchecker.domain.model.RetrievalShortfall
import com.bmlibrarian.factchecker.domain.model.SearchProvider
import com.bmlibrarian.factchecker.domain.model.SourceRequestException
import kotlinx.coroutines.runBlocking
import okio.Buffer
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.QueueDispatcher
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Europe PMC's failed and damaged answers, as they arrive over the wire (#252).
 *
 * Runs the app's Europe PMC provider and `Json` against a local server: whether an
 * answer or one record of it decodes is a property of the real converter.
 */
class EuropePMCFailedAnswerWireTest {

    private lateinit var server: MockWebServer

    /** How many answers the test queued: each is asked for once, and nothing more is. */
    private var answersQueued = 0

    @Before
    fun setUp() {
        // An unexpected request is answered at once, rather than waiting out the client's timeout on each retry
        server = MockWebServer().apply {
            (dispatcher as QueueDispatcher).setFailFast(true)
            start()
        }
        Log.clear()
    }

    @After
    fun tearDown() {
        try {
            assertEquals("requests the server received", answersQueued, server.requestCount)
        } finally {
            server.shutdown()
        }
    }

    /** A service built by the app's own provider, its requests sent to the local server. */
    private fun service(): EuropePMCService =
        EuropePMCService(NetworkModule.provideEuropePMCApi(serverBoundClient(server), AppModule.provideJson()))

    /** Answer the next request with an HTTP 200 and this body. */
    private fun answer(body: String) {
        server.enqueue(MockResponse().setResponseCode(HTTP_OK).setBody(body))
        answersQueued++
    }

    @Test
    fun `an answer holding only a version is unreadable, not a search with no hits`() = runBlocking {
        // Europe PMC's answer for an unknown cursorMark (checked live 2026-09-14)
        answer("""{"version":"6.9"}""")

        val error = service().search(query = "aspirin", cursor = "AoJwunknown", resultsReceived = 0).exceptionOrNull()

        assertEquals(RequestFailure(RequestFailureKind.MALFORMED_RESPONSE), (error as SourceRequestException).failure)
    }

    @Test
    fun `an answer that is no JSON cannot be read, and is not quoted`() = runBlocking {
        answer("<html><body>BODY_TEXT</body></html>")

        val error = service().search(query = "aspirin", resultsReceived = 0).exceptionOrNull()

        assertEquals(RequestFailure(RequestFailureKind.MALFORMED_RESPONSE), (error as SourceRequestException).failure)
        assertFalse(error.message.orEmpty().contains("BODY_TEXT"))
        assertTrue("nothing was logged, so nothing was checked", Log.lines.isNotEmpty())
        for (line in Log.lines) {
            assertFalse("logged the body: $line", line.contains("BODY_TEXT"))
        }
    }

    /** Answer the next request with an HTTP 200 and these bytes. */
    private fun answerBytes(body: ByteArray) {
        server.enqueue(MockResponse().setResponseCode(HTTP_OK).setBody(Buffer().write(body)))
        answersQueued++
    }

    private val onePage = """{"hitCount":1,"resultList":{"result":[{"pmid":"1","title":"T\u00e9 \ud83d\ude00","source":"MED"}]}}"""

    @Test
    fun `an answer bmlib refuses is unreadable, never a page`() = runBlocking {
        val refused = listOf(
            onePage.replace("\\ud83d\\ude00", "\\ud800").toByteArray(), // a lone surrogate escape
            onePage.replace("T", "T\u00ff").toByteArray(Charsets.ISO_8859_1), // not UTF-8
            byteArrayOf(0xEF.toByte(), 0xBB.toByte(), 0xBF.toByte()) + onePage.toByteArray(), // a BOM
            onePage.replace("\"hitCount\":1", "\"hitCount\":1,\"score\":NaN").toByteArray()
        )
        for (body in refused) {
            answerBytes(body)
            val error = service().search(query = "aspirin", resultsReceived = 0).exceptionOrNull()
            assertEquals(
                String(body, Charsets.ISO_8859_1),
                RequestFailure(RequestFailureKind.MALFORMED_RESPONSE),
                (error as SourceRequestException).failure
            )
        }
    }

    /** The grammar, depth and control-character refusals reach the wire too (#784). */
    @Test
    fun `a page holding a value serde_json refuses is unreadable`() = runBlocking {
        for (value in REFUSED_JSON_VALUES) {
            answer(onePage.replace("\"hitCount\":1", "\"hitCount\":1,\"score\":$value"))
            val error = service().search(query = "aspirin", resultsReceived = 0).exceptionOrNull()
            assertEquals(value.take(10), RequestFailure(RequestFailureKind.MALFORMED_RESPONSE), (error as SourceRequestException).failure)
        }
        answer(onePage.replace("\"hitCount\":1", "\"hitCount\":1,\"score\":1"))
        assertEquals(1, service().search(query = "aspirin", resultsReceived = 0).getOrThrow().articles.size)
    }

    @Test
    fun `a well-formed answer, escapes and a surrogate pair included, is read`() = runBlocking {
        answer(onePage)

        val searched = service().search(query = "aspirin", resultsReceived = 0).getOrThrow()

        assertEquals(listOf("T\u00e9 \ud83d\ude00"), searched.articles.map { it.title })
    }

    @Test
    fun `full-text XML is read as text, never as JSON`() = runBlocking {
        answer("<article><body>Text</body></article>")

        val fetch = service().fetchFullTextXml("PMC1")

        assertEquals(FullTextXmlFetch.Served("<article><body>Text</body></article>"), fetch)
    }

    @Test
    fun `a record that does not decode costs that record, not the page`() = runBlocking {
        answer(
            """{"version":"6.9","hitCount":3,"nextCursorMark":"AoK","resultList":{"result":[""" +
                """{"pmid":"1","title":"Kept","source":"MED"},""" +
                """{"pmid":"2","title":"Damaged","citedByCount":{"not":"a number"}},""" +
                """{"pmid":"3","title":"Also kept","source":"MED"}]}}"""
        )

        val searched = service().search(query = "aspirin", batchSize = 3, resultsReceived = 0).getOrThrow()

        assertEquals(listOf("1", "3"), searched.articles.map { it.pmid })
        assertEquals(
            listOf(RetrievalShortfall(SearchProvider.EUROPE_PMC, RequestFailure(RequestFailureKind.MALFORMED_RESPONSE), 1)),
            searched.shortfalls
        )
        // The log names why, by exception class, never by the record's text
        assertTrue(
            "no decode diagnostic in ${Log.lines}",
            Log.lines.any { it.contains("1 of 3 Europe PMC records did not decode") }
        )
        assertFalse(Log.lines.any { it.contains("not a number") })
    }

    @Test
    fun `a result list that is no list cannot be read`() = runBlocking {
        answer("""{"hitCount":3,"resultList":{"result":{"pmid":"1"}}}""")

        val error = service().search(query = "aspirin", resultsReceived = 0).exceptionOrNull()

        assertEquals(RequestFailure(RequestFailureKind.MALFORMED_RESPONSE), (error as SourceRequestException).failure)
    }

    private companion object {
        /** HTTP 200. */
        const val HTTP_OK = 200
    }
}
