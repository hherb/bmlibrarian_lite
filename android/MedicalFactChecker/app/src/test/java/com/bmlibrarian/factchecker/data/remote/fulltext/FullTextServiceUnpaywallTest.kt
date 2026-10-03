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
import com.bmlibrarian.factchecker.di.AppModule
import com.bmlibrarian.factchecker.di.NetworkModule
import com.bmlibrarian.factchecker.domain.model.OpenAccessShortfall
import com.bmlibrarian.factchecker.domain.model.OpenAccessSource
import com.bmlibrarian.factchecker.domain.model.RequestFailure
import com.bmlibrarian.factchecker.domain.model.RequestFailureKind
import com.bmlibrarian.factchecker.util.Constants
import io.mockk.coEvery
import io.mockk.mockk
import java.nio.charset.Charset
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import okhttp3.mockwebserver.SocketPolicy
import okio.Buffer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * The Unpaywall tier against a local server (#464): Unpaywall's answer and the
 * landing page it names are both served by [server], and Unpaywall is asked
 * through Retrofit built by `NetworkModule.provideRetrofitBuilder` from
 * `AppModule.provideJson`, so the decoding is the app's own.
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

        val httpClient = OkHttpClient()
        val unpaywallApi = NetworkModule.provideRetrofitBuilder(httpClient, AppModule.provideJson())
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

    /** How many times the handle was asked for. */
    private fun handleRequests(): Int = requestedPaths().count { it == handlePath }

    private val doiLink = FullTextService.FullTextResult.DoiUrl("${Constants.DOI_URL_PREFIX}$doi")

    /** The DOI fallback, carrying why the open-access copy went unassessed (#466). */
    private fun doiLinkLeaving(source: OpenAccessSource, failure: RequestFailure) =
        FullTextService.FullTextResult.DoiUrl("${Constants.DOI_URL_PREFIX}$doi", OpenAccessShortfall(source, failure))

    @Test
    fun `an unreachable landing page is retried and logged as unread, not as declaring nothing`() = runTest {
        unpaywallAnswers(pdfUrl = null, landingPage = server.url(handlePath).toString())
        routes[handlePath] = MockResponse().setSocketPolicy(SocketPolicy.DISCONNECT_AFTER_REQUEST)

        assertEquals(
            doiLinkLeaving(OpenAccessSource.LANDING_PAGE, RequestFailure(RequestFailureKind.CONNECTION)),
            fetch()
        )
        assertTrue("${Log.lines}", handleRequests() > 1)
        assertTrue("${Log.lines}", Log.lines.any { "could not be read" in it })
        assertFalse("${Log.lines}", Log.lines.any { "declares no PDF" in it })
    }

    @Test
    fun `a landing page server fault is retried, then left unsettled`() = runTest {
        unpaywallAnswers(pdfUrl = null, landingPage = server.url(handlePath).toString())
        routes[handlePath] = MockResponse().setResponseCode(HTTP_SERVICE_UNAVAILABLE)

        assertEquals(
            doiLinkLeaving(OpenAccessSource.LANDING_PAGE, RequestFailure.forHttpStatus(HTTP_SERVICE_UNAVAILABLE)),
            fetch()
        )
        assertTrue("${Log.lines}", handleRequests() > 1)
        assertTrue("${Log.lines}", Log.lines.any { "could not be read (HTTP 503" in it })
    }

    @Test
    fun `a 501 is not retried but is still not the page's answer`() = runTest {
        unpaywallAnswers(pdfUrl = null, landingPage = server.url(handlePath).toString())
        routes[handlePath] = MockResponse().setResponseCode(HTTP_NOT_IMPLEMENTED)

        assertEquals(
            doiLinkLeaving(OpenAccessSource.LANDING_PAGE, RequestFailure.forHttpStatus(HTTP_NOT_IMPLEMENTED)),
            fetch()
        )
        assertEquals(1, handleRequests())
        assertTrue("${Log.lines}", Log.lines.any { "could not be read (HTTP 501" in it })
    }

    @Test
    fun `a throttled Unpaywall is retried and logged as unassessed`() = runTest {
        routes[unpaywallPath] = MockResponse().setResponseCode(Constants.HTTP_TOO_MANY_REQUESTS)

        assertEquals(
            doiLinkLeaving(OpenAccessSource.UNPAYWALL, RequestFailure.forHttpStatus(Constants.HTTP_TOO_MANY_REQUESTS)),
            fetch()
        )
        assertTrue("${Log.lines}", requestedPaths().count { it == unpaywallPath } > 1)
        assertTrue("${Log.lines}", Log.lines.any { "went unassessed" in it })
    }

    @Test
    fun `an unreadable Unpaywall answer leaves the copy unassessed`() = runTest {
        routes[unpaywallPath] = MockResponse()
            .setHeader("Content-Type", "application/json")
            .setBody("not json")

        assertEquals(
            doiLinkLeaving(OpenAccessSource.UNPAYWALL, RequestFailure(RequestFailureKind.MALFORMED_RESPONSE)),
            fetch()
        )
    }

    /**
     * Any error status but 404 leaves the copy unassessed, as Python records it: a
     * 408 is an answer ("did not serve it"), a 501 or a Cloudflare 520 is not, and
     * neither says Unpaywall holds no copy (#466).
     */
    @Test
    fun `any Unpaywall error status but 404 leaves the copy unassessed`() = runTest {
        for (status in listOf(408, 403, 501, 520)) {
            routes[unpaywallPath] = MockResponse().setResponseCode(status)

            assertEquals(
                "HTTP $status",
                doiLinkLeaving(OpenAccessSource.UNPAYWALL, RequestFailure(RequestFailureKind.HTTP_STATUS, status)),
                fetch()
            )
        }
    }

    /** The control: Unpaywall knowing no copy leaves nothing for the reader to wonder about. */
    @Test
    fun `an Unpaywall that does not know the DOI leaves nothing unsettled`() = runTest {
        routes[unpaywallPath] = MockResponse().setResponseCode(Constants.HTTP_NOT_FOUND)

        assertEquals(doiLink, fetch())
    }

    /**
     * Unpaywall refuses the app's placeholder address with 422 for every article,
     * which read as "Unpaywall did not serve it": not asked, it is reported as not
     * configured, with the advice that goes with that (Python's
     * `usable_unpaywall_email`).
     */
    @Test
    fun `an Unpaywall with no usable email is not asked, and is reported as not configured`() = runTest {
        unpaywallAnswers(pdfUrl = null, landingPage = server.url(handlePath).toString())

        for (email in listOf(null, "", "   ", Constants.UNPAYWALL_DEFAULT_EMAIL)) {
            val result = service.fetchFullText(pmcId = null, doi = doi, pmid = null, email = email).getOrThrow()

            assertEquals(
                "email $email",
                FullTextService.FullTextResult.DoiUrl(
                    "${Constants.DOI_URL_PREFIX}$doi",
                    OpenAccessShortfall.UNPAYWALL_NOT_CONFIGURED
                ),
                result
            )
        }
        assertEquals(0, server.requestCount)
    }

    /** An answer with no body has told us nothing about the article. */
    @Test
    fun `an empty Unpaywall answer leaves the copy unassessed`() = runTest {
        for (empty in listOf(MockResponse().setResponseCode(HTTP_NO_CONTENT), MockResponse().setBody(""))) {
            routes[unpaywallPath] = empty

            assertEquals(
                "$empty",
                doiLinkLeaving(OpenAccessSource.UNPAYWALL, RequestFailure(RequestFailureKind.MALFORMED_RESPONSE)),
                fetch()
            )
        }
    }

    /**
     * An error the tier does not expect is no answer about the article either:
     * Retrofit refuses a DOI that reads as path traversal before anything is sent.
     */
    @Test
    fun `an unexpected error leaves the copy unassessed rather than silent`() = runTest {
        val traversal = "10.1234/.."

        val result = service.fetchFullText(pmcId = null, doi = traversal, pmid = null, email = "test@example.org")
            .getOrThrow()

        assertEquals(
            FullTextService.FullTextResult.DoiUrl(
                "${Constants.DOI_URL_PREFIX}$traversal",
                OpenAccessShortfall(OpenAccessSource.UNPAYWALL, RequestFailure(RequestFailureKind.REQUEST_FAILED))
            ),
            result
        )
        assertTrue("${Log.lines}", Log.lines.any { "failed unexpectedly" in it })
    }

    @Test
    fun `a landing page served as a PDF is the PDF`() = runTest {
        unpaywallAnswers(pdfUrl = null, landingPage = server.url(handlePath).toString())
        handleRedirectsToPage()
        pageServes("%PDF-1.7", contentType = "application/pdf")

        assertEquals(
            "${Log.lines}",
            FullTextService.FullTextResult.UnpaywallPdf(pdfUrl = server.url(pagePath).toString()),
            fetch()
        )
    }

    @Test
    fun `a landing page is read by the charset it declares`() = runTest {
        unpaywallAnswers(pdfUrl = null, landingPage = server.url(handlePath).toString())
        handleRedirectsToPage()
        val shiftJis = Charset.forName("Shift_JIS")
        routes[pagePath] = MockResponse()
            .setHeader("Content-Type", "text/html; charset=Shift_JIS")
            .setBody(Buffer().writeString("""<meta name="citation_pdf_url" content="./論文.pdf">""", shiftJis))

        val result = fetch()

        assertTrue("$result", (result as FullTextService.FullTextResult.UnpaywallPdf).pdfUrl.endsWith("/論文.pdf"))
    }

    @Test
    fun `a landing page is read only up to its cap`() = runTest {
        unpaywallAnswers(pdfUrl = null, landingPage = server.url(handlePath).toString())
        handleRedirectsToPage()
        val padding = "<!--" + "x".repeat(Constants.LANDING_PAGE_MAX_BYTES) + "-->"
        val tag = """<meta name="citation_pdf_url" content="./Okazakietal_2025.pdf">"""
        pageServes(padding + tag)

        assertEquals(doiLink, fetch())

        pageServes(tag + padding)

        assertEquals(
            FullTextService.FullTextResult.UnpaywallPdf(pdfUrl = server.url(pdfPath).toString()),
            fetch()
        )
    }

    @Test
    fun `a cancelled landing-page read is not logged as a failed lookup`() = runTest {
        unpaywallAnswers(pdfUrl = null, landingPage = server.url(handlePath).toString())
        routes[handlePath] = MockResponse()
            .setHeadersDelay(1, TimeUnit.SECONDS)
            .setHeader("Content-Type", "text/html")
            .setBody("""<meta name="citation_pdf_url" content="$pdfPath">""")

        var completed = false
        val job = launch(Dispatchers.Default) {
            fetch()
            completed = true
        }
        server.takeRequest() // Unpaywall
        server.takeRequest() // the landing page, now in flight
        job.cancel()
        job.join()

        assertFalse(completed)
        assertFalse("${Log.lines}", Log.lines.any { "lookup failed" in it || "went unassessed" in it })
    }

    private companion object {
        /** HTTP 503: a server fault that is retried. */
        const val HTTP_SERVICE_UNAVAILABLE = 503

        /** HTTP 501: a server fault outside the retried statuses. */
        const val HTTP_NOT_IMPLEMENTED = 501

        /** HTTP 302: the redirect a handle server answers with. */
        const val HTTP_FOUND = 302

        /** HTTP 204: an answer with no body. */
        const val HTTP_NO_CONTENT = 204
    }
}
