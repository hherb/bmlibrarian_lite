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

import com.bmlibrarian.factchecker.data.remote.debugHttpLoggingInterceptor
import com.bmlibrarian.factchecker.domain.model.NcbiCredentials
import com.bmlibrarian.factchecker.domain.model.PubMedError
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.net.URLDecoder
import java.util.concurrent.CopyOnWriteArrayList

/**
 * The NCBI API key reaches NCBI and nothing else (#243, the Android half of #196).
 *
 * A query string is part of the URL, and a URL is what gets printed: debug
 * builds log `--> GET <url>` to logcat for every request. So the key travels in
 * a form-encoded POST body, and because a 307 or 308 re-sends a body, a redirect
 * is refused rather than followed.
 *
 * Runs the real Retrofit interface and OkHttp client against local servers,
 * since the subject is what reaches the wire; a mocked [PubMedApi] cannot say.
 */
class PubMedCredentialConfinementTest {

    /** One request as a local server received it. */
    private data class Recorded(
        val method: String,
        val uri: String,
        val contentType: String?,
        val body: String
    ) {
        /** The request path without any query. */
        val path: String get() = uri.substringBefore('?')
    }

    /** How a local server answers one request. */
    private sealed class Reply {
        /** A 200 with this body. */
        data class Ok(val body: String) : Reply()
        /** A redirect with this status to this location. */
        data class Redirect(val statusCode: Int, val location: String) : Reply()
    }

    /** A loopback HTTP server that records every request and answers by [reply]. */
    private class RecordingServer {
        val recorded = CopyOnWriteArrayList<Recorded>()

        @Volatile
        var reply: (Recorded) -> Reply = { Reply.Ok("") }

        private val server = MockWebServer().apply {
            dispatcher = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse {
                    val received = Recorded(
                        method = request.method.orEmpty(),
                        uri = request.path.orEmpty(),
                        contentType = request.getHeader("Content-Type"),
                        body = request.body.readUtf8()
                    )
                    recorded.add(received)
                    return when (val answer = reply(received)) {
                        is Reply.Ok -> MockResponse().setResponseCode(HTTP_OK).setBody(answer.body)
                        is Reply.Redirect -> MockResponse()
                            .setResponseCode(answer.statusCode)
                            .addHeader("Location", answer.location)
                    }
                }
            }
            start()
        }

        /** Base URL ending in a slash, as Retrofit requires. */
        val baseUrl: String get() = server.url("/").toString()

        /** Shut the server down. */
        fun stop() = server.shutdown()
    }

    private val apiKey = "0123456789abcdef0123456789abcdef0123"
    private val email = "researcher@example.org"
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    private lateinit var ncbi: RecordingServer
    private lateinit var elsewhere: RecordingServer

    /** Start a local NCBI and a foreign host for redirects to point at. */
    @Before
    fun setUp() {
        ncbi = RecordingServer()
        elsewhere = RecordingServer()
    }

    /** Stop both local servers. */
    @After
    fun tearDown() {
        ncbi.stop()
        elsewhere.stop()
    }

    // ==================== Fixtures ====================

    /** A service on the production client stack, pointed at the local NCBI. */
    private fun service(baseClient: OkHttpClient = OkHttpClient()): PubMedService =
        PubMedService(createPubMedApi(baseClient, json, ncbi.baseUrl)) {
            NcbiCredentials.of(apiKey = apiKey, email = email)
        }

    /** Answer esearch with one PMID and efetch with that article. */
    private fun serveOneArticle() {
        ncbi.reply = { request ->
            if (request.path.endsWith("esearch.fcgi")) {
                Reply.Ok("""{"esearchresult":{"count":"1","idlist":["12345"]}}""")
            } else {
                Reply.Ok(
                    "<PubmedArticleSet><PubmedArticle><MedlineCitation><PMID>12345</PMID>" +
                        "<Article><ArticleTitle>A title</ArticleTitle></Article>" +
                        "</MedlineCitation></PubmedArticle></PubmedArticleSet>"
                )
            }
        }
    }

    /** Decode a form-encoded body into its fields, in order. */
    private fun formFields(body: String): List<Pair<String, String>> =
        body.split('&').filter { it.isNotEmpty() }.map { pair ->
            val name = pair.substringBefore('=')
            val value = pair.substringAfter('=', "")
            URLDecoder.decode(name, Charsets.UTF_8.name()) to URLDecoder.decode(value, Charsets.UTF_8.name())
        }

    /** The value of the first field with this name, or null. */
    private fun field(name: String, body: String): String? =
        formFields(body).firstOrNull { it.first == name }?.second

    // ==================== Where the key travels ====================

    @Test
    fun `the key travels in the body of both requests and in no URL`() = runBlocking {
        serveOneArticle()

        val result = service().search(query = "aspirin")

        assertTrue("search failed: ${result.exceptionOrNull()}", result.isSuccess)
        assertEquals(listOf("/esearch.fcgi", "/efetch.fcgi"), ncbi.recorded.map { it.path })
        for (request in ncbi.recorded) {
            assertFalse("${request.path} carried a query string", request.uri.contains('?'))
            assertFalse("${request.path} URL carried the key", request.uri.contains(apiKey))
            assertEquals(request.path, "POST", request.method)
            assertTrue(
                "${request.path} content type ${request.contentType}",
                request.contentType.orEmpty().startsWith("application/x-www-form-urlencoded")
            )
            assertEquals("${request.path} body lacked the key", apiKey, field("api_key", request.body))
            assertEquals(request.path, email, field("email", request.body))
        }
    }

    @Test
    fun `a query with form delimiters arrives verbatim`() = runBlocking {
        serveOneArticle()
        val query = "C++ & \"x=y\" #1 100% [tiab] ß→é&retmax=1"

        service().search(query = query)

        val search = ncbi.recorded.first { it.path.endsWith("esearch.fcgi") }
        assertEquals(query, field("term", search.body))
        assertEquals(1, formFields(search.body).count { it.first == "retmax" })
    }

    // ==================== What gets printed ====================

    @Test
    fun `the debug HTTP log carries no key`() = runBlocking {
        serveOneArticle()
        val lines = CopyOnWriteArrayList<String>()
        val loggingClient = OkHttpClient.Builder()
            .addInterceptor(debugHttpLoggingInterceptor { lines.add(it) })
            .build()

        service(loggingClient).search(query = "aspirin")

        assertTrue("nothing was logged, so nothing was checked", lines.isNotEmpty())
        for (line in lines) {
            assertFalse("logged the key: $line", line.contains(apiKey))
        }
    }

    // ==================== Redirects ====================

    @Test
    fun `the harness can observe a followed redirect`() {
        // Without this control, the refusal test below would pass just as well if
        // the local server's redirect never reached the client at all.
        ncbi.reply = { Reply.Redirect(307, elsewhere.baseUrl + "collect") }
        val request = Request.Builder()
            .url(ncbi.baseUrl + "esearch.fcgi")
            .post("api_key=$apiKey".toRequestBody("application/x-www-form-urlencoded".toMediaType()))
            .build()

        OkHttpClient().newCall(request).execute().close()

        assertEquals(1, elsewhere.recorded.size)
        assertEquals("api_key=$apiKey", elsewhere.recorded.single().body)
    }

    @Test
    fun `a redirect is refused and not followed, whatever its status`() = runBlocking {
        for (statusCode in listOf(301, 302, 303, 307, 308)) {
            ncbi.recorded.clear()
            elsewhere.recorded.clear()
            ncbi.reply = { Reply.Redirect(statusCode, elsewhere.baseUrl + "collect") }

            val result = service().search(query = "aspirin")

            val error = result.exceptionOrNull()
            assertTrue("HTTP $statusCode: got $error", error is PubMedError.RedirectRefusedError)
            assertEquals(statusCode, (error as PubMedError.RedirectRefusedError).statusCode)
            assertEquals("HTTP $statusCode was followed", 0, elsewhere.recorded.size)
            assertEquals("HTTP $statusCode was retried", 1, ncbi.recorded.size)
        }
    }

    @Test
    fun `the PubMed client follows no redirect while the shared client still does`() {
        val shared = OkHttpClient()

        val pubMed = pubMedHttpClient(shared)

        assertFalse(pubMed.followRedirects)
        assertFalse(pubMed.followSslRedirects)
        assertTrue("Unpaywall and PDF links need redirects", shared.followRedirects)
    }

    // ==================== Credentials ====================

    @Test
    fun `credentials never print the key`() {
        val credentials = NcbiCredentials.of(apiKey = apiKey, email = email)

        assertFalse(credentials.toString().contains(apiKey))
        assertNull(NcbiCredentials.of(apiKey = "  ", email = "").apiKey)
        assertNull(NcbiCredentials.of(apiKey = null, email = "").email)
    }

    private companion object {
        /** HTTP 200. */
        const val HTTP_OK = 200
    }
}
