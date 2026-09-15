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

package com.bmlibrarian.factchecker.data.remote.pubmed

import android.util.Log
import com.bmlibrarian.factchecker.di.AppModule
import com.bmlibrarian.factchecker.domain.model.NcbiCredentials
import com.bmlibrarian.factchecker.domain.model.RequestFailure
import com.bmlibrarian.factchecker.domain.model.RequestFailureKind
import com.bmlibrarian.factchecker.domain.model.RetrievalShortfall
import com.bmlibrarian.factchecker.domain.model.SearchProvider
import com.bmlibrarian.factchecker.domain.model.SourceRequestException
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * E-utilities' failed answers, as they arrive over the wire (#255).
 *
 * Runs the production converter stack against a local server: whether an
 * answer decodes, and what its decoding error would quote, is a property of
 * the real `Json` configuration, which a mocked [PubMedApi] cannot show.
 */
class PubMedFailedAnswerWireTest {

    private lateinit var server: MockWebServer

    @Before
    fun setUp() {
        server = MockWebServer().apply { start() }
        Log.clear()
    }

    @After
    fun tearDown() {
        server.shutdown()
    }

    /** A service on the production client and converters, pointed at the local server. */
    private fun service(): PubMedService =
        PubMedService(createPubMedApi(OkHttpClient(), AppModule.provideJson(), server.url("/").toString())) {
            NcbiCredentials.of(apiKey = null, email = null)
        }

    /** Answer the next request with an HTTP 200 and this body. */
    private fun answer(body: String) {
        server.enqueue(MockResponse().setResponseCode(HTTP_OK).setBody(body))
    }

    @Test
    fun `the backend's ERROR answer is a service error`() = runBlocking {
        // The shape esearch answered for term=(( on 2026-09-14
        answer(
            """{"header":{"type":"esearch","version":"0.3"},""" +
                """"esearchresult":{"ERROR":"Search Backend failed: SERVER_TEXT"}}"""
        )

        val error = service().search(query = "((").exceptionOrNull()

        assertEquals(RequestFailure(RequestFailureKind.SERVICE_ERROR), (error as SourceRequestException).failure)
        assertEquals(1, server.requestCount)
        assertNothingLogged("SERVER_TEXT")
    }

    @Test
    fun `an ERROR holding a raw newline is still a service error`() = runBlocking {
        // Past the 9,999-record cap the ERROR text holds a raw newline, which
        // strict JSON refuses (checked live 2026-09-15)
        answer("""{"header":{"type":"esearch","version":"0.3"},"esearchresult":{"ERROR":"retstart SERVER_TEXT""" + "\n" + """"}}""")

        val error = service().search(query = "aspirin").exceptionOrNull()

        assertEquals(RequestFailure(RequestFailureKind.SERVICE_ERROR), (error as SourceRequestException).failure)
    }

    @Test
    fun `an answer that is no JSON cannot be read, and is not quoted`() = runBlocking {
        answer("<html><body>BODY_TEXT maintenance</body></html>")

        val error = service().search(query = "aspirin").exceptionOrNull()

        assertEquals(RequestFailure(RequestFailureKind.MALFORMED_RESPONSE), (error as SourceRequestException).failure)
        assertFalse(error.message.orEmpty().contains("BODY_TEXT"))
        assertNothingLogged("BODY_TEXT")
    }

    @Test
    fun `an efetch error document is a service error for the PMIDs it held`() = runBlocking {
        answer("""{"esearchresult":{"count":"2","idlist":["1","2"]}}""")
        answer("<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n<eFetchResult>\n<ERROR>SERVER_TEXT</ERROR>\n</eFetchResult>")

        val searched = service().search(query = "aspirin").getOrThrow()

        assertTrue(searched.articles.isEmpty())
        assertEquals(
            listOf(RetrievalShortfall(SearchProvider.PUBMED, RequestFailure(RequestFailureKind.SERVICE_ERROR), 2)),
            searched.shortfalls
        )
        assertNothingLogged("SERVER_TEXT")
    }

    /** Assert that no logged line contains this text. */
    private fun assertNothingLogged(text: String) {
        assertTrue("nothing was logged, so nothing was checked", Log.lines.isNotEmpty())
        for (line in Log.lines) {
            assertFalse("logged \"$text\": $line", line.contains(text))
        }
    }

    private companion object {
        /** HTTP 200. */
        const val HTTP_OK = 200
    }
}
