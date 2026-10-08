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

import android.content.Context
import com.bmlibrarian.factchecker.data.local.entity.DocumentEntity
import com.bmlibrarian.factchecker.data.remote.europepmc.EuropePMCArticle
import com.bmlibrarian.factchecker.data.remote.europepmc.EuropePMCSearchResult
import com.bmlibrarian.factchecker.data.remote.europepmc.EuropePMCService
import com.bmlibrarian.factchecker.data.remote.europepmc.FullTextUrlEntry
import com.bmlibrarian.factchecker.data.remote.europepmc.FullTextUrlList
import com.bmlibrarian.factchecker.data.remote.europepmc.FullTextXmlFetch
import com.bmlibrarian.factchecker.data.remote.fulltext.FullTextService.FullTextResult
import com.bmlibrarian.factchecker.data.remote.transparency.RequestPacer
import com.bmlibrarian.factchecker.domain.model.FullTextLinkKind
import com.bmlibrarian.factchecker.domain.model.OpenAccessShortfall
import com.bmlibrarian.factchecker.domain.model.OpenAccessSource
import com.bmlibrarian.factchecker.domain.model.OpenAccessUnsettledReason
import com.bmlibrarian.factchecker.domain.model.RequestFailure
import com.bmlibrarian.factchecker.domain.model.RequestFailureKind
import com.bmlibrarian.factchecker.util.Constants
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.runTest
import okhttp3.OkHttpClient
import okhttp3.ResponseBody.Companion.toResponseBody
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okio.Buffer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import retrofit2.Response
import java.net.InetAddress

/**
 * Elsevier's API in the full-text chain (#480, stage C2): after Europe PMC's
 * render tier and before any Unpaywall lookup, only for an Elsevier DOI and
 * only with a key; its PDF held only as a local file, never as a link. Mirrors
 * Python's `fulltext_discovery.py` and BioMedLit's `FullTextService`.
 */
class FullTextServiceElsevierTest {

    @get:Rule
    val cache = TemporaryFolder()

    private val doi = "10.1016/j.cell.2020.02.052"
    private val email = "researcher@example.org"
    private val a = "https://repo.example.org/a.pdf"
    private val localPdf = "/data/cache/fulltext_pdfs/elsevier-x.pdf"

    private val unpaywallApi: UnpaywallApi = mockk()
    private var elsevier: ElsevierService = absentElsevier()
    private var core: CoreService = absentCore()
    private var europePmc: EuropePMCService = searchFinding()
    private lateinit var server: MockWebServer

    @Before
    fun setUp() {
        server = MockWebServer()
        server.start(InetAddress.getLoopbackAddress(), 0)
    }

    @After
    fun tearDown() {
        server.shutdown()
    }

    /** Europe PMC's search answering with [articles], so the chain reaches the tiers after it. */
    private fun searchFinding(vararg articles: EuropePMCArticle): EuropePMCService = mockk {
        coEvery { search(any(), any(), any(), any(), any()) } returns Result.success(
            EuropePMCSearchResult(
                articles = articles.toList(),
                totalResults = articles.size,
                nextCursor = null,
                resultsReceived = articles.size,
                shortfalls = emptyList()
            )
        )
        coEvery { fetchFullTextXml(any()) } returns FullTextXmlFetch.Absent
    }

    /** The service, built with whatever the fields hold when called. */
    private fun service() = FullTextService(
        context = mockk<Context> { every { cacheDir } returns cache.root },
        europePmcService = europePmc,
        unpaywallApi = unpaywallApi,
        httpClient = mockk(relaxed = true),
        pmcOpenData = absentBucket(),
        openAlex = absentOpenAlex(),
        core = core,
        elsevier = elsevier
    )

    /** Elsevier answering every DOI with [fetch]. */
    private fun elsevierAnswering(fetch: ElsevierFetch?): ElsevierService = mockk {
        coEvery { fetchPdf(any()) } returns fetch
    }

    /** The real service against the local server, with [key]; nothing paced or retried. */
    private fun realElsevier(key: String?): ElsevierService = ElsevierService(
        ElsevierService.client(OkHttpClient()),
        server.url("").toString().trimEnd('/'),
        { cache.root.resolve(Constants.FULLTEXT_PDF_CACHE_DIR) },
        { key },
        { null },
        RequestPacer(0L),
        0,
        0L,
        Elsevier.newSession()
    )

    /** Unpaywall holds no record of the DOI: its 404, an expected miss. */
    private fun unpaywallKnowsNothing() {
        coEvery { unpaywallApi.getWorkByDoi(any(), any()) } returns
            Response.error(Constants.HTTP_NOT_FOUND, "".toResponseBody(null))
    }

    /** Unpaywall naming [url] as a location's `url_for_pdf`. */
    private fun unpaywallNames(url: String) {
        coEvery { unpaywallApi.getWorkByDoi(any(), any()) } returns Response.success(
            UnpaywallResponse(doi = doi, is_oa = true, oa_locations = listOf(UnpaywallOaLocation(url_for_pdf = url)))
        )
    }

    private suspend fun fetch(): FullTextResult = service().fetchFullText(null, doi, "1", email).getOrThrow()

    // ==================== The chain ====================

    @Test
    fun `a PDF Elsevier serves is the result, and Unpaywall is never asked`() = runTest {
        unpaywallKnowsNothing()
        elsevier = elsevierAnswering(ElsevierFetch.Served(localPdf))
        core = mockk(relaxed = true)

        assertEquals(FullTextResult.ElsevierPdf(localPdf), fetch())
        coVerify(exactly = 1) { elsevier.fetchPdf(doi) }
        coVerify(exactly = 0) { unpaywallApi.getWorkByDoi(any(), any()) }
        coVerify(exactly = 0) { core.fetchText(any()) }
    }

    /** Review focus 1: a first page is never served, and Unpaywall is asked next. */
    @Test
    fun `a first page or a 404 adds nothing, and Unpaywall is asked`() = runBlocking {
        val path = "${Constants.ELSEVIER_ARTICLE_PATH}$doi"
        val answers = listOf(
            MockResponse().setHeader(
                Constants.ELSEVIER_STATUS_HEADER,
                "WARNING - Response limited to first page because requestor not entitled to resource"
            ).setBody(Buffer().write(CONTRACT_PDF_BODY)),
            MockResponse().setResponseCode(Constants.HTTP_NOT_FOUND)
        )
        unpaywallKnowsNothing()
        for (answer in answers) {
            server.enqueue(answer)
            elsevier = realElsevier("k")

            val result = fetch()

            assertEquals(FullTextResult.DoiUrl(doiLink(doi), openAccessShortfall = null), result)
            assertEquals(path, server.takeRequest().requestUrl!!.encodedPath)
        }
        coVerify(exactly = answers.size) { unpaywallApi.getWorkByDoi(doi, any()) }
        // Nothing was cached for the first page
        assertTrue(cache.root.walkTopDown().none { it.isFile })
    }

    /** Unreachable, before Unpaywall's own lookup and the PDFs it names: first in the notice. */
    @Test
    fun `an unreachable Elsevier is told first`() = runTest {
        val unavailable = RequestFailure.forHttpStatus(503)
        elsevier = elsevierAnswering(ElsevierFetch.Unreachable(unavailable))
        val elsevierShortfall = OpenAccessShortfall(OpenAccessSource.ELSEVIER, unavailable)

        unpaywallKnowsNothing()
        assertEquals(FullTextResult.DoiUrl(doiLink(doi), elsevierShortfall), fetch())

        // With a PDF named: Elsevier's step first, then the candidate
        unpaywallNames(a)
        val pdfs = fetch() as FullTextResult.OpenAccessPdfs
        assertEquals(OpenAccessStep.Unsettled(elsevierShortfall), pdfs.steps.first())
        val recorded = DocumentEntity(id = "d", sessionId = "s", title = "t", doi = doi).recordingFullTextFetch(
            pdfs,
            { PdfDownload.Failed(RequestFailure.forHttpStatus(403)) },
            { _, _ -> emptyList() },
            { null }
        )
        val shortfall = (recorded.result as FullTextResult.DoiUrl).openAccessShortfall!!
        assertEquals(OpenAccessSource.ELSEVIER, shortfall.entries.first().source)
        assertEquals(
            "Failed to obtain a PDF from the following tried sources: Elsevier's API (HTTP 503 Service " +
                "Unavailable); repo.example.org, named by Unpaywall (HTTP 403 Forbidden). A freely available " +
                "copy may exist. Whether this document is open access was not established.",
            shortfall.notice
        )
    }

    /** An unconfigured Unpaywall's skip comes after Elsevier's failure, and is still nudged. */
    @Test
    fun `Elsevier is told before an unconfigured Unpaywall`() = runTest {
        val failure = RequestFailure(RequestFailureKind.TIMEOUT)
        elsevier = elsevierAnswering(ElsevierFetch.Unreachable(failure))

        val result = service().fetchFullText(null, doi, "1", null).getOrThrow() as FullTextResult.DoiUrl

        assertEquals(
            OpenAccessShortfall(OpenAccessSource.ELSEVIER, failure) + OpenAccessShortfall.UNPAYWALL_NOT_CONFIGURED,
            result.openAccessShortfall
        )
    }

    /** The refusals are skips of a configured channel: told as such, no nudge, the absence kept open. */
    @Test
    fun `a refused key or network is told as a skip, with no nudge`() = runTest {
        unpaywallKnowsNothing()
        val expected = mapOf(
            ElsevierFetch.KeyRefused to OpenAccessShortfall.ELSEVIER_KEY_REFUSED,
            ElsevierFetch.NetworkRefused to OpenAccessShortfall.ELSEVIER_NETWORK_REFUSED
        )
        for ((fetched, shortfall) in expected) {
            elsevier = elsevierAnswering(fetched)

            val result = fetch() as FullTextResult.DoiUrl

            assertEquals("$fetched", shortfall, result.openAccessShortfall)
            assertFalse(result.openAccessShortfall!!.notice, "Configuring" in result.openAccessShortfall!!.notice)
        }
        assertEquals(
            "Elsevier's API (not available from this network) could not be asked, so a freely available copy " +
                "may exist. Whether this document is open access was not established.",
            OpenAccessShortfall.ELSEVIER_NETWORK_REFUSED.notice
        )
        assertEquals(
            "Elsevier's API (the key in the settings was refused) could not be asked, so a freely available copy " +
                "may exist. Whether this document is open access was not established.",
            OpenAccessShortfall.ELSEVIER_KEY_REFUSED.notice
        )
    }

    /** Review focus 3: without a key, or for another publisher's DOI, nothing changes. */
    @Test
    fun `without a key, or for another DOI, nothing is asked or recorded`() = runBlocking {
        unpaywallKnowsNothing()
        elsevier = realElsevier(key = null)
        assertEquals(FullTextResult.DoiUrl(doiLink(doi), openAccessShortfall = null), fetch())

        elsevier = realElsevier(key = "k")
        val other = "10.1371/journal.pone.0000217"
        assertEquals(
            FullTextResult.DoiUrl(doiLink(other), openAccessShortfall = null),
            service().fetchFullText(null, other, "1", email).getOrThrow()
        )
        assertEquals("no request was made", 0, server.requestCount)
        // The control: with a key, an Elsevier DOI is asked
        server.enqueue(MockResponse().setResponseCode(Constants.HTTP_NOT_FOUND))
        fetch()
        assertEquals(1, server.requestCount)
    }

    /**
     * #493's limit, pinned so fixing #493 updates it: Android's render tier hands
     * back its URL undownloaded, so a render URL ends the chain before Elsevier.
     */
    @Test
    fun `a render URL present, Elsevier is not asked`() = runTest {
        europePmc = searchFinding(
            EuropePMCArticle(
                id = "1", source = "MED", pmid = "1", title = "t",
                fullTextUrlList = FullTextUrlList(
                    listOf(FullTextUrlEntry(availability = "Free", documentStyle = "pdf", url = "https://europepmc.org/a.pdf"))
                )
            )
        )
        elsevier = elsevierAnswering(ElsevierFetch.Served(localPdf))

        assertEquals(FullTextResult.EuropePmcPdf("https://europepmc.org/a.pdf"), fetch())
        coVerify(exactly = 0) { elsevier.fetchPdf(any()) }
    }

    /** Only when nothing earlier obtained the article. */
    @Test
    fun `Europe PMC's text served, Elsevier is not asked`() = runTest {
        europePmc = searchFinding(EuropePMCArticle(id = "1", source = "MED", pmid = "1", pmcid = "PMC7", title = "t"))
        coEvery { europePmc.fetchFullTextXml("PMC7") } returns FullTextXmlFetch.Served(
            "<article><front><article-meta><title-group><article-title>T</article-title></title-group>" +
                "</article-meta></front><body><p>Text.</p></body></article>"
        )
        elsevier = elsevierAnswering(ElsevierFetch.Served(localPdf))

        assertTrue(fetch() is FullTextResult.EuropePmcXml)
        coVerify(exactly = 0) { elsevier.fetchPdf(any()) }
    }

    /** Not saved: the walk goes on, and a copy Unpaywall serves settles it. */
    @Test
    fun `a PDF not saved goes on to Unpaywall, whose copy settles it`() = runTest {
        elsevier = elsevierAnswering(ElsevierFetch.NotSaved)
        unpaywallNames(a)

        val pdfs = fetch() as FullTextResult.OpenAccessPdfs
        val recorded = DocumentEntity(id = "d", sessionId = "s", title = "t", doi = doi).recordingFullTextFetch(
            pdfs,
            { PdfDownload.Saved("/cache/d.pdf") },
            { _, _ -> emptyList() },
            { null }
        )

        assertEquals(FullTextResult.OpenAccessPdf(a, doi, PdfNamer.UNPAYWALL), recorded.result)
        assertNull(recorded.document.fullTextOpenAccessShortfallJson)
        assertNull(recorded.document.fullTextPdfNotSavedFrom)
    }

    /** Not saved and nothing later serving: request_failed, never the not-saved note's link. */
    @Test
    fun `a PDF not saved, with nothing after, keeps request_failed and no link`() = runTest {
        elsevier = elsevierAnswering(ElsevierFetch.NotSaved)
        unpaywallKnowsNothing()

        val result = fetch() as FullTextResult.DoiUrl
        val recorded = DocumentEntity(id = "d", sessionId = "s", title = "t", doi = doi)
            .recordingFullTextFetch(result, { error("no PDF") }, { _, _ -> emptyList() }, { null })

        val requestFailed = OpenAccessShortfall(OpenAccessSource.ELSEVIER, RequestFailure(RequestFailureKind.REQUEST_FAILED))
        assertEquals(requestFailed, result.openAccessShortfall)
        assertEquals(
            "Elsevier's API (the request failed) could not be asked, so a freely available copy may exist. " +
                "Whether this document is open access was not established.",
            result.openAccessShortfall!!.notice
        )
        assertEquals(requestFailed.toJson(), recorded.document.fullTextOpenAccessShortfallJson)
        assertNull(recorded.document.fullTextPdfNotSavedFrom)
        assertFalse(recorded.document.toString(), "api.elsevier.com" in recorded.document.toString())
    }

    // ==================== Recording and display ====================

    /** Review focus 2: the PDF is a local file, with no Elsevier URL in any column. */
    @Test
    fun `an Elsevier PDF is recorded as a local file under its source`() = runTest {
        // An earlier fetch left the DOI link, a shortfall, text and a caching note
        val entity = DocumentEntity(
            id = "d", sessionId = "s", title = "t", doi = doi,
            fullTextSource = Constants.FULLTEXT_SOURCE_DOI,
            fullTextOpenAccessShortfallJson =
                OpenAccessShortfall(OpenAccessSource.UNPAYWALL, RequestFailure(RequestFailureKind.TIMEOUT)).toJson(),
            fullTextHTML = "<p>stale</p>",
            fullTextMarkdown = "stale",
            fullTextPdfNotSavedFrom = a
        )
        val served = FullTextResult.ElsevierPdf(localPdf)

        val recorded = entity.recordingFullTextFetch(
            served,
            { error("an Elsevier PDF is never downloaded again") },
            { _, _ -> error("nothing further is asked") },
            { error("nothing further is asked") }
        )

        assertEquals(served, recorded.result)
        assertEquals(localPdf, recorded.document.pdfPath)
        assertEquals(Constants.FULLTEXT_SOURCE_ELSEVIER, recorded.document.fullTextSource)
        assertNull(recorded.document.fullTextOpenAccessShortfallJson)
        assertNull(recorded.document.fullTextPdfNotSavedFrom)
        assertNull(recorded.document.fullTextHTML)
        assertNull(recorded.document.fullTextMarkdown)
        assertTrue(recorded.document.fullTextFetchedAt != null)
        assertFalse(recorded.document.isLinkOnly)
        assertNull(recorded.document.linkOnlyPdfUrl)
        assertFalse(recorded.document.toString(), "api.elsevier.com" in recorded.document.toString())
        assertEquals(Constants.FULLTEXT_SOURCE_ELSEVIER_LABEL, recorded.document.fullTextSourceDisplay)
    }

    @Test
    fun `an Elsevier PDF has content, and is stored as Elsevier's`() {
        assertTrue(FullTextResult.ElsevierPdf(localPdf).hasContent)
        assertEquals(Constants.FULLTEXT_SOURCE_ELSEVIER, service().getSourceConstant(FullTextResult.ElsevierPdf(localPdf)))
    }

    /** A stored Elsevier source is a PDF tier's, never the publisher's page. */
    @Test
    fun `a stored Elsevier source is a PDF, not a publisher page`() {
        val kind = FullTextLinkKind.forStoredSource(Constants.FULLTEXT_SOURCE_ELSEVIER)
        assertNotEquals(FullTextLinkKind.PUBLISHER_PAGE, kind)
        assertEquals(FullTextLinkKind.UNDOWNLOADED_PDF, kind)
    }

    @Test
    fun `the refusals are Elsevier's own skips`() {
        assertEquals(OpenAccessUnsettledReason.KeyRefused, OpenAccessShortfall.ELSEVIER_KEY_REFUSED.reason)
        assertEquals(OpenAccessSource.ELSEVIER, OpenAccessShortfall.ELSEVIER_KEY_REFUSED.source)
        assertEquals(OpenAccessUnsettledReason.NetworkRefused, OpenAccessShortfall.ELSEVIER_NETWORK_REFUSED.reason)
        assertEquals(OpenAccessSource.ELSEVIER, OpenAccessShortfall.ELSEVIER_NETWORK_REFUSED.source)
    }
}
