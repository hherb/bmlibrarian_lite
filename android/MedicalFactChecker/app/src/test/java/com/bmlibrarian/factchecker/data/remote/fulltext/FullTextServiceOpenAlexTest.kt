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

import com.bmlibrarian.factchecker.data.remote.europepmc.EuropePMCSearchResult
import com.bmlibrarian.factchecker.data.remote.europepmc.EuropePMCService
import com.bmlibrarian.factchecker.data.remote.fulltext.FullTextService.FullTextResult
import com.bmlibrarian.factchecker.domain.model.OpenAccessShortfall
import com.bmlibrarian.factchecker.domain.model.OpenAccessSource
import com.bmlibrarian.factchecker.domain.model.RequestFailure
import com.bmlibrarian.factchecker.domain.model.RequestFailureKind
import com.bmlibrarian.factchecker.util.Constants
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.mockk
import kotlinx.coroutines.test.runTest
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertEquals
import org.junit.Test
import retrofit2.Response

/**
 * OpenAlex in the full-text chain (#480, stage B): asked only when it can raise
 * the odds. With Unpaywall's candidates in hand it waits for recording, which
 * asks it once every one of them failed; with none, the service asks it itself.
 * Mirrors Python's `fulltext_discovery.py` and BioMedLit's `FullTextService`.
 */
class FullTextServiceOpenAlexTest {

    private val doi = "10.1/openalex"
    private val a = "https://repo.example.org/a.pdf"
    private val b = "https://oa.example.org/b.pdf"

    private val unpaywallApi: UnpaywallApi = mockk()
    private val openAlex: OpenAlexService = mockk()

    /** Europe PMC knows no record, so the chain reaches the open-access tier. */
    private val europePmc: EuropePMCService = mockk {
        coEvery { search(any(), any(), any(), any(), any()) } returns Result.success(
            EuropePMCSearchResult(
                articles = emptyList(),
                totalResults = 0,
                nextCursor = null,
                resultsReceived = 0,
                shortfalls = emptyList()
            )
        )
    }

    private val service = FullTextService(
        context = mockk(relaxed = true),
        europePmcService = europePmc,
        unpaywallApi = unpaywallApi,
        httpClient = mockk(relaxed = true),
        pmcOpenData = absentBucket(),
        openAlex = openAlex
    )

    /** Unpaywall answers with one location per URL, each naming it as `url_for_pdf`. */
    private fun unpaywallNames(urls: List<String>) {
        coEvery { unpaywallApi.getWorkByDoi(doi, any()) } returns Response.success(
            UnpaywallResponse(doi = doi, is_oa = true, oa_locations = urls.map { UnpaywallOaLocation(url_for_pdf = it) })
        )
    }

    /** Unpaywall holds no record of the DOI: its 404, an expected miss. */
    private fun unpaywallKnowsNothing() {
        coEvery { unpaywallApi.getWorkByDoi(doi, any()) } returns
            Response.error(Constants.HTTP_NOT_FOUND, "".toResponseBody(null))
    }

    @Test
    fun `with Unpaywall's candidates in hand, OpenAlex is not asked yet`() = runTest {
        unpaywallNames(listOf(a))
        assertEquals(
            Result.success(FullTextResult.OpenAccessPdfs(listOf(OpenAccessStep.Candidate(a, PdfNamer.UNPAYWALL)), doi)),
            service.fetchFullText(null, doi, null, "researcher@example.org")
        )
        coVerify(exactly = 0) { openAlex.fetchPdfUrls(any()) }
    }

    @Test
    fun `with no Unpaywall candidate, OpenAlex's are returned, asked`() = runTest {
        unpaywallKnowsNothing()
        coEvery { openAlex.fetchPdfUrls(doi) } returns OpenAlexFetch.Served(listOf(b))
        assertEquals(
            Result.success(
                FullTextResult.OpenAccessPdfs(
                    listOf(OpenAccessStep.Candidate(b, PdfNamer.OPENALEX)), doi, openAlexAsked = true
                )
            ),
            service.fetchFullText(null, doi, null, "researcher@example.org")
        )
    }

    @Test
    fun `an unconfigured Unpaywall still asks OpenAlex, its skip first`() = runTest {
        coEvery { openAlex.fetchPdfUrls(doi) } returns OpenAlexFetch.Served(listOf(b))
        assertEquals(
            Result.success(
                FullTextResult.OpenAccessPdfs(
                    listOf(
                        OpenAccessStep.Unsettled(OpenAccessShortfall.UNPAYWALL_NOT_CONFIGURED),
                        OpenAccessStep.Candidate(b, PdfNamer.OPENALEX)
                    ),
                    doi,
                    openAlexAsked = true
                )
            ),
            service.fetchFullText(null, doi, null, null)
        )
    }

    /**
     * A blank DOI is no DOI, as in Swift: neither Unpaywall nor OpenAlex is
     * asked, so OpenAlex's never-made lookup is not read as the work's absence,
     * and no DOI link is offered. The chain ends as it does without a DOI.
     */
    @Test
    fun `a blank DOI is no DOI`() = runTest {
        for (blank in listOf("", "   ", "\t\n")) {
            assertEquals(
                blank,
                Result.success(FullTextResult.Unavailable("No full text source available")),
                service.fetchFullText(null, blank, null, "researcher@example.org")
            )
        }
        coVerify(exactly = 0) { unpaywallApi.getWorkByDoi(any(), any()) }
        coVerify(exactly = 0) { openAlex.fetchPdfUrls(any()) }
        coVerify(exactly = 0) { europePmc.search(any(), any(), any(), any(), any()) }
    }

    /** The control: a DOI with whitespace around it is that DOI, trimmed, in every branch. */
    @Test
    fun `a padded DOI is asked and linked trimmed`() = runTest {
        unpaywallKnowsNothing()
        coEvery { openAlex.fetchPdfUrls(doi) } returns OpenAlexFetch.Absent
        assertEquals(
            Result.success(FullTextResult.DoiUrl(doiLink(doi), null)),
            service.fetchFullText(null, "  $doi\n", null, "researcher@example.org")
        )
        coVerify(exactly = 1) { unpaywallApi.getWorkByDoi(doi, any()) }
        coVerify(exactly = 1) { openAlex.fetchPdfUrls(doi) }
        coVerify(exactly = 1) { europePmc.search(match { it == "DOI:\"$doi\"" }, any(), any(), any(), any()) }
    }

    @Test
    fun `with no candidate anywhere, the DOI link carries every shortfall`() = runTest {
        unpaywallKnowsNothing()
        val failure = RequestFailure(RequestFailureKind.TIMEOUT)
        coEvery { openAlex.fetchPdfUrls(doi) } returns OpenAlexFetch.Unreachable(failure)
        assertEquals(
            Result.success(FullTextResult.DoiUrl(doiLink(doi), OpenAccessShortfall(OpenAccessSource.OPENALEX, failure))),
            service.fetchFullText(null, doi, null, "researcher@example.org")
        )
    }

    /** Chain order: Unpaywall's skip, then OpenAlex's lookup. */
    @Test
    fun `an unconfigured Unpaywall and an unreachable OpenAlex are told in chain order`() = runTest {
        val failure = RequestFailure(RequestFailureKind.TIMEOUT)
        coEvery { openAlex.fetchPdfUrls(doi) } returns OpenAlexFetch.Unreachable(failure)
        assertEquals(
            Result.success(
                FullTextResult.DoiUrl(
                    doiLink(doi),
                    OpenAccessShortfall.UNPAYWALL_NOT_CONFIGURED + OpenAccessShortfall(OpenAccessSource.OPENALEX, failure)
                )
            ),
            service.fetchFullText(null, doi, null, null)
        )
    }

    @Test
    fun `OpenAlex knowing no work adds nothing`() = runTest {
        unpaywallKnowsNothing()
        coEvery { openAlex.fetchPdfUrls(doi) } returns OpenAlexFetch.Absent
        assertEquals(
            Result.success(FullTextResult.DoiUrl(doiLink(doi), null)),
            service.fetchFullText(null, doi, null, "researcher@example.org")
        )
    }

    @Test
    fun `OpenAlex's steps drop what was tried, and refuse an address that cannot be requested`() = runTest {
        coEvery { openAlex.fetchPdfUrls(doi) } returns
            OpenAlexFetch.Served(listOf(a, "ftp://x.example.org/c.pdf", b))
        assertEquals(
            listOf(
                OpenAccessStep.Unsettled(
                    OpenAccessShortfall(
                        OpenAccessSource.OPENALEX_PDF,
                        RequestFailure(RequestFailureKind.REQUEST_FAILED),
                        "ftp://x.example.org/c.pdf"
                    )
                ),
                OpenAccessStep.Candidate(b, PdfNamer.OPENALEX)
            ),
            service.openAlexSteps(doi, listOf(a))
        )
    }

    /**
     * An address Unpaywall named that cannot be requested is refused once:
     * OpenAlex naming it too adds no second refusal, as Python's `known_urls`
     * and BioMedLit's `triedPDFs` hold it.
     */
    @Test
    fun `an address Unpaywall named and refused is not refused again as OpenAlex's`() = runTest {
        val unfetchable = "ftp://x.example.org/c.pdf"
        unpaywallNames(listOf(unfetchable))
        coEvery { openAlex.fetchPdfUrls(doi) } returns OpenAlexFetch.Served(listOf(unfetchable, b))
        assertEquals(
            Result.success(
                FullTextResult.OpenAccessPdfs(
                    listOf(
                        OpenAccessStep.Unsettled(
                            OpenAccessShortfall(
                                OpenAccessSource.PDF, RequestFailure(RequestFailureKind.REQUEST_FAILED), unfetchable
                            )
                        ),
                        OpenAccessStep.Candidate(b, PdfNamer.OPENALEX)
                    ),
                    doi,
                    openAlexAsked = true
                )
            ),
            service.fetchFullText(null, doi, null, "researcher@example.org")
        )
    }

    @Test
    fun `no DOI, no OpenAlex`() = runTest {
        service.fetchFullText(null, null, "123", null)
        coVerify(exactly = 0) { openAlex.fetchPdfUrls(any()) }
    }

    @Test
    fun `an OpenAlex PDF is recorded as OpenAlex's`() {
        assertEquals("openalex", service.getSourceConstant(FullTextResult.OpenAccessPdf(b, doi, PdfNamer.OPENALEX)))
        assertEquals("OpenAlex", PdfNamer.OPENALEX.label)
        assertEquals(OpenAccessSource.OPENALEX_PDF, PdfNamer.OPENALEX.refusedAs)
    }
}
