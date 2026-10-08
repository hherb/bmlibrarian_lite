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

import com.bmlibrarian.factchecker.data.local.entity.DocumentEntity
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
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import retrofit2.Response

/**
 * CORE's extracted text in the full-text chain (#480, stage C): asked once, only
 * with a key and a DOI, last before the DOI link, and only when no open-access
 * copy was served. With no candidate the service asks it itself; with
 * candidates in hand it waits for recording. Mirrors Python's
 * `fulltext_discovery.py` and BioMedLit's `FullTextService`.
 */
class FullTextServiceCoreTest {

    private val doi = "10.1159/000513404"
    private val text = "x".repeat(Constants.CORE_MIN_FULLTEXT_CHARS)
    private val email = "researcher@example.org"
    private val a = "https://repo.example.org/a.pdf"

    private val unpaywallApi: UnpaywallApi = mockk()
    private var core: CoreService = absentCore()

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

    /** The service, built with whatever [core] holds when called. */
    private fun service() = FullTextService(
        context = mockk(relaxed = true),
        europePmcService = europePmc,
        unpaywallApi = unpaywallApi,
        httpClient = mockk(relaxed = true),
        pmcOpenData = absentBucket(),
        openAlex = absentOpenAlex(),
        core = core,
        elsevier = absentElsevier()
    )

    /** CORE answering every DOI with [fetch]. */
    private fun coreAnswering(fetch: CoreFetch?): CoreService = mockk {
        coEvery { fetchText(any()) } returns fetch
    }

    /** Unpaywall holds no record of the DOI: its 404, an expected miss, and no location. */
    private fun unpaywallKnowsNothing() {
        coEvery { unpaywallApi.getWorkByDoi(doi, any()) } returns
            Response.error(Constants.HTTP_NOT_FOUND, "".toResponseBody(null))
    }

    /** Unpaywall answers with one location per URL, each naming it as `url_for_pdf`. */
    private fun unpaywallNames(urls: List<String>) {
        coEvery { unpaywallApi.getWorkByDoi(doi, any()) } returns Response.success(
            UnpaywallResponse(doi = doi, is_oa = true, oa_locations = urls.map { UnpaywallOaLocation(url_for_pdf = it) })
        )
    }

    @Test
    fun `with no open-access candidate, CORE's text is the result`() = runTest {
        unpaywallKnowsNothing()
        core = coreAnswering(CoreFetch.Served(text))
        val result = service().fetchFullText(null, doi, "1", email).getOrThrow()
        assertEquals(FullTextResult.CoreText(text), result)
        coVerify(exactly = 1) { core.fetchText(doi) }
    }

    @Test
    fun `an unreachable CORE is told on the DOI link, last`() = runTest {
        unpaywallKnowsNothing()
        core = coreAnswering(CoreFetch.Unreachable(RequestFailure.forHttpStatus(503)))
        val result = service().fetchFullText(null, doi, "1", email).getOrThrow() as FullTextResult.DoiUrl
        assertEquals(OpenAccessSource.CORE, result.openAccessShortfall!!.entries.last().source)
        assertEquals(RequestFailure.forHttpStatus(503), result.openAccessShortfall!!.entries.last().failure)
    }

    /** A refused key is a skip of CORE, told as the key, on the DOI link (#498). */
    @Test
    fun `a refused CORE key is told on the DOI link as the key`() = runTest {
        unpaywallKnowsNothing()
        core = coreAnswering(CoreFetch.KeyRefused)
        val result = service().fetchFullText(null, doi, "1", email).getOrThrow() as FullTextResult.DoiUrl
        assertEquals(OpenAccessShortfall.CORE_KEY_REFUSED, result.openAccessShortfall)
        assertEquals(
            "CORE (the key in the settings was refused) could not be asked, so a freely available copy " +
                "may exist. Whether this document is open access was not established.",
            result.openAccessShortfall!!.notice
        )
    }

    /** Chain order: Unpaywall's skip first, CORE's failure after it. */
    @Test
    fun `an unconfigured Unpaywall and an unreachable CORE are told in chain order`() = runTest {
        val failure = RequestFailure(RequestFailureKind.TIMEOUT)
        core = coreAnswering(CoreFetch.Unreachable(failure))
        assertEquals(
            Result.success(
                FullTextResult.DoiUrl(
                    doiLink(doi),
                    OpenAccessShortfall.UNPAYWALL_NOT_CONFIGURED + OpenAccessShortfall(OpenAccessSource.CORE, failure)
                )
            ),
            service().fetchFullText(null, doi, "1", null)
        )
    }

    /** Absent: the DOI link as it was without CORE, and the absence holds (Python's twin). */
    @Test
    fun `CORE knowing nothing adds nothing`() = runTest {
        unpaywallKnowsNothing()
        core = coreAnswering(CoreFetch.Absent)
        val result = service().fetchFullText(null, doi, "1", email).getOrThrow()
        // Else the absence proves nothing
        coVerify(exactly = 1) { core.fetchText(doi) }
        // Nothing left unsettled: the absence of a free copy is established
        assertEquals(FullTextResult.DoiUrl(doiLink(doi), openAccessShortfall = null), result)
    }

    @Test
    fun `without a key nothing is recorded`() = runTest {
        unpaywallKnowsNothing()
        core = coreAnswering(null)
        val result = service().fetchFullText(null, doi, "1", email).getOrThrow() as FullTextResult.DoiUrl
        assertTrue(result.openAccessShortfall?.entries.orEmpty().none { it.source == OpenAccessSource.CORE })
    }

    @Test
    fun `with candidates in hand, CORE is not asked by the service`() = runTest {
        unpaywallNames(listOf(a))
        core = coreAnswering(CoreFetch.Served(text))
        val result = service().fetchFullText(null, doi, "1", email).getOrThrow()
        assertTrue("$result", result is FullTextResult.OpenAccessPdfs)
        coVerify(exactly = 0) { core.fetchText(any()) }
    }

    @Test
    fun `no DOI, no CORE`() = runTest {
        core = coreAnswering(CoreFetch.Served(text))
        service().fetchFullText(null, null, "1")
        coVerify(exactly = 0) { core.fetchText(any()) }
    }

    /** A blank DOI is no DOI: CORE is not asked with it. */
    @Test
    fun `a blank DOI asks no CORE`() = runTest {
        core = coreAnswering(CoreFetch.Served(text))
        service().fetchFullText(null, "   ", "1", email)
        coVerify(exactly = 0) { core.fetchText(any()) }
    }

    @Test
    fun `askCore is CORE's own answer`() = runTest {
        core = coreAnswering(CoreFetch.Served(text))
        assertEquals(CoreFetch.Served(text), service().askCore(doi))
    }

    @Test
    fun `a CORE text is recorded as CORE's`() {
        assertEquals(Constants.FULLTEXT_SOURCE_CORE, service().getSourceConstant(FullTextResult.CoreText(text)))
    }

    @Test
    fun `a CORE text is recorded as CORE's, plain, with no shortfall`() = runTest {
        // FullTextRecordingTest's fixture: an earlier fetch left the DOI link with
        // Unpaywall unsettled, and an earlier caching note
        val entity = DocumentEntity(
            id = "d", sessionId = "s", title = "t", doi = "10.1/x",
            fullTextSource = Constants.FULLTEXT_SOURCE_DOI,
            fullTextOpenAccessShortfallJson =
                OpenAccessShortfall(OpenAccessSource.UNPAYWALL, RequestFailure(RequestFailureKind.TIMEOUT)).toJson(),
            fullTextHTML = "<p>stale</p>",
            fullTextPdfNotSavedFrom = a
        )
        val recorded = entity.recordingFullTextFetch(
            FullTextResult.CoreText(text),
            { error("no PDF") },
            { _, _ -> emptyList() },
            { null }
        )
        assertEquals(FullTextResult.CoreText(text), recorded.result)
        assertEquals(text, recorded.document.fullTextMarkdown)
        assertNull(recorded.document.fullTextHTML)
        assertEquals(Constants.FULLTEXT_SOURCE_CORE, recorded.document.fullTextSource)
        assertNull(recorded.document.fullTextOpenAccessShortfallJson)
        assertNull(recorded.document.fullTextPdfNotSavedFrom)
        assertEquals(Constants.FULLTEXT_SOURCE_CORE_LABEL, recorded.document.fullTextSourceDisplay)
    }
}
