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
import com.bmlibrarian.factchecker.data.remote.europepmc.EuropePMCSearchResult
import com.bmlibrarian.factchecker.data.remote.europepmc.EuropePMCService
import com.bmlibrarian.factchecker.util.Constants
import com.jakewharton.retrofit2.converter.kotlinx.serialization.asConverterFactory
import io.mockk.coEvery
import io.mockk.mockk
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import retrofit2.Retrofit

/**
 * The Unpaywall tier against a local server (#464): Unpaywall's answer and the
 * landing page it names are both served by [server], and Unpaywall is asked
 * through Retrofit built as `NetworkModule` builds it, so the decoding is the
 * app's too.
 *
 * The parsing rules themselves are pinned by [UnpaywallLandingPageContractTest].
 */
class FullTextServiceUnpaywallTest {

    private lateinit var server: MockWebServer
    private lateinit var service: FullTextService

    /** What each path on [server] answers; a path not listed answers 404. */
    private val routes = mutableMapOf<String, MockResponse>()

    private val doi = "10.1126/science.adk9967"
    private val unpaywallPath = "/v2/$doi"
    private val handlePath = "/handle/2115/95934"
    private val pagePath = "/repo/huscap/all/95934/"
    private val pdfPath = "/repo/huscap/all/95934/Okazakietal_2025.pdf"

    @Before
    fun setup() {
        Log.clear()
        server = MockWebServer()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse =
                routes[request.requestUrl?.encodedPath] ?: MockResponse().setResponseCode(Constants.HTTP_NOT_FOUND)
        }
        server.start()

        // AppModule.provideJson and NetworkModule.provideRetrofitBuilder
        val json = Json {
            ignoreUnknownKeys = true
            isLenient = true
            encodeDefaults = true
            prettyPrint = false
        }
        val httpClient = OkHttpClient()
        val unpaywallApi = Retrofit.Builder()
            .client(httpClient)
            .addConverterFactory(json.asConverterFactory("application/json".toMediaType()))
            .baseUrl(server.url("/v2/"))
            .build()
            .create(UnpaywallApi::class.java)

        // Europe PMC knows no record, so the chain reaches Unpaywall
        val europePmc = mockk<EuropePMCService>()
        coEvery { europePmc.search(any(), any(), any(), any(), any()) } returns Result.success(
            EuropePMCSearchResult(
                articles = emptyList(),
                totalResults = 0,
                nextCursor = null,
                resultsReceived = 0,
                shortfalls = emptyList()
            )
        )

        service = FullTextService(
            context = mockk(relaxed = true),
            europePmcService = europePmc,
            unpaywallApi = unpaywallApi,
            httpClient = httpClient
        )
    }

    @After
    fun tearDown() {
        server.shutdown()
    }

    /**
     * Unpaywall answers as it does for PMID 40608933: one location, no
     * `url_for_pdf`, `url` the repository's landing page. Trimmed of the fields
     * the tier does not read, but keeping some it ignores.
     */
    private fun unpaywallAnswers(pdfUrl: String?, landingPage: String) {
        val pdf = pdfUrl?.let { "\"$it\"" } ?: "null"
        val location = """
            {"url": ${if (pdfUrl != null) pdf else "\"$landingPage\""}, "url_for_pdf": $pdf,
             "url_for_landing_page": "$landingPage", "license": null, "version": "acceptedVersion",
             "host_type": "repository", "is_best": true, "evidence": "oa repository (via OAI-PMH title match)",
             "pmh_id": "oai:eprints.lib.hokudai.ac.jp:00095934", "updated": "2025-09-01T00:00:00"}
        """.trimIndent()
        routes[unpaywallPath] = MockResponse()
            .setHeader("Content-Type", "application/json")
            .setBody(
                """
                {"doi": "$doi", "is_oa": true, "oa_status": "green", "best_oa_location": $location,
                 "oa_locations": [$location], "oa_locations_embargoed": [], "first_oa_location": $location,
                 "title": "Membrane topology inversion of GGCX", "year": 2025, "publisher": "AAAS",
                 "z_authors": [{"family": "Okazaki", "given": "S."}], "journal_is_oa": false}
                """.trimIndent()
            )
    }

    /** The handle redirects to the repository page, as hdl.handle.net does. */
    private fun handleRedirectsToPage() {
        routes[handlePath] = MockResponse()
            .setResponseCode(HTTP_FOUND)
            .setHeader("Location", server.url(pagePath).toString())
    }

    /** The repository page, served as HTML. */
    private fun pageServes(html: String, contentType: String = "text/html; charset=UTF-8") {
        routes[pagePath] = MockResponse().setHeader("Content-Type", contentType).setBody(html)
    }

    private suspend fun fetch(): FullTextService.FullTextResult =
        service.fetchFullText(pmcId = null, doi = doi, pmid = null, email = "test@example.org").getOrThrow()

    /** The paths [server] was asked for, in order. */
    private fun requestedPaths(): List<String?> =
        List(server.requestCount) { server.takeRequest().requestUrl?.encodedPath }

    @Test
    fun `a landing page that declares its PDF yields that PDF`() = runTest {
        unpaywallAnswers(pdfUrl = null, landingPage = server.url(handlePath).toString())
        handleRedirectsToPage()
        // Relative, so it resolves only against the page served after the redirect
        pageServes(
            """<head><meta name="citation_title" content="Membrane topology inversion of GGCX" />
               <meta name="citation_pdf_url" content="./Okazakietal_2025.pdf" /></head>"""
        )

        val result = fetch()

        assertEquals(
            "${Log.lines}",
            FullTextService.FullTextResult.UnpaywallPdf(pdfUrl = server.url(pdfPath).toString()),
            result
        )
        server.takeRequest() // Unpaywall
        val pageRequest = server.takeRequest()
        assertEquals(handlePath, pageRequest.requestUrl?.encodedPath)
        assertEquals(Constants.LANDING_PAGE_ACCEPT, pageRequest.getHeader(Constants.HTTP_ACCEPT_HEADER))
    }

    @Test
    fun `a landing page without the tag is not offered as the PDF`() = runTest {
        unpaywallAnswers(pdfUrl = null, landingPage = server.url(handlePath).toString())
        handleRedirectsToPage()
        pageServes("<html><head><title>Item</title></head><body><a href=\"x.pdf\">PDF</a></body></html>")

        assertEquals(FullTextService.FullTextResult.DoiUrl("${Constants.DOI_URL_PREFIX}$doi"), fetch())
    }

    @Test
    fun `a landing page that is not HTML is not read`() = runTest {
        unpaywallAnswers(pdfUrl = null, landingPage = server.url(handlePath).toString())
        handleRedirectsToPage()
        pageServes(
            """<meta name="citation_pdf_url" content="./Okazakietal_2025.pdf">""",
            contentType = "application/octet-stream"
        )

        assertEquals(FullTextService.FullTextResult.DoiUrl("${Constants.DOI_URL_PREFIX}$doi"), fetch())
    }

    @Test
    fun `a landing page that answers an error status is not read`() = runTest {
        unpaywallAnswers(pdfUrl = null, landingPage = server.url(handlePath).toString())
        // No route for the handle: it answers 404, with a body that declares a PDF
        routes[handlePath] = MockResponse()
            .setResponseCode(Constants.HTTP_NOT_FOUND)
            .setHeader("Content-Type", "text/html")
            .setBody("""<meta name="citation_pdf_url" content="$pdfPath">""")

        assertEquals(FullTextService.FullTextResult.DoiUrl("${Constants.DOI_URL_PREFIX}$doi"), fetch())
    }

    /** The control: a `url_for_pdf` is taken as it is, and no landing page is visited. */
    @Test
    fun `a url_for_pdf is used without visiting the landing page`() = runTest {
        val pdfUrl = server.url(pdfPath).toString()
        unpaywallAnswers(pdfUrl = pdfUrl, landingPage = server.url(handlePath).toString())

        assertEquals("${Log.lines}", FullTextService.FullTextResult.UnpaywallPdf(pdfUrl = pdfUrl), fetch())
        assertEquals(listOf<String?>(unpaywallPath), requestedPaths())
    }

    private companion object {
        /** HTTP 302: the redirect a handle server answers with. */
        const val HTTP_FOUND = 302
    }
}
