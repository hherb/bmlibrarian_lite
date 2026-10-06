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
import com.bmlibrarian.factchecker.data.remote.fulltext.FullTextService.FullTextResult
import com.bmlibrarian.factchecker.domain.model.OpenAccessShortfall
import com.bmlibrarian.factchecker.domain.model.OpenAccessSource
import com.bmlibrarian.factchecker.domain.model.RequestFailure
import com.bmlibrarian.factchecker.domain.model.RequestFailureKind
import com.bmlibrarian.factchecker.util.Constants
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Recording walks the open-access steps in chain order (#480, stage B): the
 * first copy served ends the walk, every PDF refused is listed by its address,
 * and a copy served but not saved keeps its link with a caching note of its own.
 */
class OpenAccessStepsRecordingTest {
    private val doi = "10.1/locations"
    private val first = "https://walled.example.org/a.pdf"
    private val second = "https://repo.example.org/b.pdf"
    private fun candidate(url: String) = OpenAccessStep.Candidate(url, PdfNamer.UNPAYWALL)
    private fun found(vararg steps: OpenAccessStep) = FullTextResult.OpenAccessPdfs(steps.toList(), doi)
    private fun refused(url: String, status: Int) =
        OpenAccessShortfall(OpenAccessSource.PDF, RequestFailure.forHttpStatus(status), url)

    /** OpenAlex naming nothing: the walk ends where Unpaywall's steps end. */
    private val noOpenAlex: suspend (String, List<String>) -> List<OpenAccessStep> = { _, _ -> emptyList() }
    private val openAlexPdf = "https://oa.example.org/c.pdf"

    /** A document an earlier fetch left on the DOI link with Unpaywall unsettled, as [FullTextRecordingTest]'s. */
    private fun document() = DocumentEntity(
        id = "d", sessionId = "s", title = "t", doi = doi,
        fullTextSource = Constants.FULLTEXT_SOURCE_DOI,
        fullTextOpenAccessShortfallJson =
            OpenAccessShortfall(OpenAccessSource.UNPAYWALL, RequestFailure(RequestFailureKind.TIMEOUT)).toJson()
    )

    @Test
    fun `a second candidate is downloaded when the first is refused`() = runTest {
        val asked = mutableListOf<String>()
        val recorded = document().recordingFullTextFetch(found(candidate(first), candidate(second)), downloadPdf = { url ->
            asked += url
            if (url == first) PdfDownload.Failed(RequestFailure.forHttpStatus(403)) else PdfDownload.Saved("/cache/d.pdf")
        }, askOpenAlex = noOpenAlex)
        assertEquals(listOf(first, second), asked)
        assertEquals(FullTextResult.OpenAccessPdf(second, doi, PdfNamer.UNPAYWALL), recorded.result)
        assertEquals("/cache/d.pdf", recorded.document.pdfPath)
        assertEquals(Constants.FULLTEXT_SOURCE_UNPAYWALL, recorded.document.fullTextSource)
        assertNull(recorded.document.fullTextOpenAccessShortfallJson)
    }

    @Test
    fun `every candidate refused is told, each by its address`() = runTest {
        val recorded = document().recordingFullTextFetch(found(candidate(first), candidate(second)), downloadPdf = { url ->
            PdfDownload.Failed(RequestFailure.forHttpStatus(if (url == first) 403 else 503))
        }, askOpenAlex = noOpenAlex)
        val expected = refused(first, 403) + refused(second, 503)
        assertEquals(FullTextResult.DoiUrl(doiLink(doi), expected), recorded.result)
        assertEquals(expected, recorded.document.openAccessShortfall)
        assertEquals(Constants.FULLTEXT_SOURCE_DOI, recorded.document.fullTextSource)
        assertNull(recorded.document.pdfPath)
    }

    @Test
    fun `an unsettled lookup before the candidates is told first`() = runTest {
        val lookup = OpenAccessShortfall(OpenAccessSource.LANDING_PAGE, RequestFailure(RequestFailureKind.TIMEOUT))
        val recorded = document().recordingFullTextFetch(found(OpenAccessStep.Unsettled(lookup), candidate(first)), downloadPdf = {
            PdfDownload.Failed(RequestFailure.forHttpStatus(403))
        }, askOpenAlex = noOpenAlex)
        assertEquals(FullTextResult.DoiUrl(doiLink(doi), lookup + refused(first, 403)), recorded.result)
    }

    /** An address refused before any request keeps its place in the list, and the walk goes on past it. */
    @Test
    fun `an unfetchable address between candidates is told in its place`() = runTest {
        val unfetchable = OpenAccessShortfall(
            OpenAccessSource.PDF, RequestFailure(RequestFailureKind.REQUEST_FAILED), "ftp://repo.example.org/c.pdf"
        )
        val asked = mutableListOf<String>()
        val recorded = document().recordingFullTextFetch(
            found(candidate(first), OpenAccessStep.Unsettled(unfetchable), candidate(second)),
            downloadPdf = { url ->
                asked += url
                PdfDownload.Failed(RequestFailure.forHttpStatus(404))
            },
            askOpenAlex = noOpenAlex
        )
        assertEquals(listOf(first, second), asked)
        assertEquals(
            FullTextResult.DoiUrl(doiLink(doi), refused(first, 404) + unfetchable + refused(second, 404)),
            recorded.result
        )
    }

    @Test
    fun `a copy served but not saved ends the walk with a caching note and no shortfall`() = runTest {
        val asked = mutableListOf<String>()
        val recorded = document().recordingFullTextFetch(found(candidate(first), candidate(second)), downloadPdf = { url ->
            asked += url; PdfDownload.NotSaved
        }, askOpenAlex = noOpenAlex)
        assertEquals("saving is our problem: no further candidate", listOf(first), asked)
        assertEquals(FullTextResult.OpenAccessPdf(first, doi, PdfNamer.UNPAYWALL, notSaved = true), recorded.result)
        assertNull(recorded.document.pdfPath)
        assertNull(recorded.document.fullTextOpenAccessShortfallJson)
        assertEquals(first, recorded.document.fullTextPdfNotSavedFrom)
        assertEquals(Constants.FULLTEXT_SOURCE_UNPAYWALL, recorded.document.fullTextSource)
    }

    /** A refused copy before the one not saved is not told: the copy served settled the question. */
    @Test
    fun `a copy not saved after a refused one records no shortfall`() = runTest {
        val recorded = document().recordingFullTextFetch(found(candidate(first), candidate(second)), downloadPdf = { url ->
            if (url == first) PdfDownload.Failed(RequestFailure.forHttpStatus(403)) else PdfDownload.NotSaved
        }, askOpenAlex = noOpenAlex)
        assertEquals(FullTextResult.OpenAccessPdf(second, doi, PdfNamer.UNPAYWALL, notSaved = true), recorded.result)
        assertNull(recorded.document.fullTextOpenAccessShortfallJson)
        assertEquals(second, recorded.document.fullTextPdfNotSavedFrom)
    }

    @Test
    fun `a saved copy stops the walk and clears an earlier note`() = runTest {
        val asked = mutableListOf<String>()
        val recorded = document().copy(fullTextPdfNotSavedFrom = first)
            .recordingFullTextFetch(found(candidate(first), candidate(second)), downloadPdf = { url ->
                asked += url; PdfDownload.Saved("/cache/d.pdf")
            }, askOpenAlex = noOpenAlex)
        assertEquals(listOf(first), asked)
        assertNull(recorded.document.fullTextPdfNotSavedFrom)
    }

    /** Every other answer clears the note an earlier fetch left, as it clears the shortfall. */
    @Test
    fun `every other answer clears an earlier note`() = runTest {
        val answers = listOf(
            FullTextResult.DoiUrl(doiLink(doi)),
            FullTextResult.EuropePmcXml(xml = "<a/>", markdown = "m", html = "<p>h</p>"),
            FullTextResult.PmcOpenDataXml(xml = "<a/>", markdown = "m", html = "<p>h</p>"),
            FullTextResult.EuropePmcPdf(pdfUrl = "https://europepmc.org/a.pdf"),
            FullTextResult.Unavailable("No full text source available"),
            found(candidate(first)),
        )
        for (answer in answers) {
            val recorded = document().copy(fullTextPdfNotSavedFrom = second)
                .recordingFullTextFetch(answer, downloadPdf = { PdfDownload.Failed(RequestFailure.forHttpStatus(404)) }, askOpenAlex = noOpenAlex)
            assertNull("$answer", recorded.document.fullTextPdfNotSavedFrom)
        }
    }

    @Test
    fun `a Europe PMC render served but not saved is noted too`() = runTest {
        val render = "https://europepmc.org/articles/PMC1/pdf"
        val recorded = document().recordingFullTextFetch(FullTextResult.EuropePmcPdf(render), downloadPdf = { PdfDownload.NotSaved }, askOpenAlex = noOpenAlex)
        assertEquals(render, recorded.document.fullTextPdfNotSavedFrom)
        assertNull(recorded.document.pdfPath)
    }

    /** The note says the link is kept when the link is what the reader is given. */
    @Test
    fun `the caching note says the link is kept on a link-only record`() = runTest {
        val recorded = document().recordingFullTextFetch(found(candidate(first)), downloadPdf = { PdfDownload.NotSaved }, askOpenAlex = noOpenAlex)
        assertEquals(
            "A PDF of this article was found at walled.example.org but could not be saved on this device, " +
                "so only its link is kept. Check the free storage space and try again.",
            recorded.document.pdfNotSavedNote
        )
    }

    /** With text in hand the link is not what the reader is given, so the note does not say it is. */
    @Test
    fun `the caching note does not claim a kept link when the record holds text`() {
        val withText = document().copy(
            fullTextMarkdown = "m", fullTextFetchedAt = java.util.Date(), fullTextPdfNotSavedFrom = first
        )
        assertEquals(
            "A PDF of this article was found at walled.example.org but could not be saved on this device, " +
                "so it could not be read. Check the free storage space and try again.",
            withText.pdfNotSavedNote
        )
        assertNull(document().pdfNotSavedNote)
    }

    // ==================== OpenAlex, asked only when it can help (#480) ====================

    @Test
    fun `OpenAlex is asked once every Unpaywall candidate failed, with what was tried`() = runTest {
        var askedWith: List<String>? = null
        val recorded = document().recordingFullTextFetch(
            found(candidate(first)),
            { url ->
                if (url == first) PdfDownload.Failed(RequestFailure.forHttpStatus(403)) else PdfDownload.Saved("/cache/d.pdf")
            },
            { _, tried -> askedWith = tried; listOf(OpenAccessStep.Candidate(openAlexPdf, PdfNamer.OPENALEX)) }
        )
        assertEquals(listOf(first), askedWith)
        assertEquals(FullTextResult.OpenAccessPdf(openAlexPdf, doi, PdfNamer.OPENALEX), recorded.result)
        assertEquals("openalex", recorded.document.fullTextSource)
        assertEquals("/cache/d.pdf", recorded.document.pdfPath)
        assertNull(recorded.document.fullTextOpenAccessShortfallJson)
    }

    /** Asked with the DOI the steps were found for, once, however many candidates failed. */
    @Test
    fun `OpenAlex is asked once, by the DOI, after all of Unpaywall's candidates`() = runTest {
        val calls = mutableListOf<Pair<String, List<String>>>()
        val downloads = mutableListOf<String>()
        document().recordingFullTextFetch(
            found(candidate(first), candidate(second)),
            { url -> downloads += url; PdfDownload.Failed(RequestFailure.forHttpStatus(404)) },
            { askedDoi, tried -> calls += askedDoi to tried; downloads += "openalex"; emptyList() }
        )
        assertEquals(listOf(doi to listOf(first, second)), calls)
        assertEquals(listOf(first, second, "openalex"), downloads)
    }

    /** An address refused before any request counts as tried: OpenAlex is not to name it again. */
    @Test
    fun `OpenAlex is told of addresses refused before any request too`() = runTest {
        val unfetchable = OpenAccessShortfall(
            OpenAccessSource.PDF, RequestFailure(RequestFailureKind.REQUEST_FAILED), "ftp://repo.example.org/c.pdf"
        )
        var askedWith: List<String>? = null
        document().recordingFullTextFetch(
            found(candidate(first), OpenAccessStep.Unsettled(unfetchable)),
            { PdfDownload.Failed(RequestFailure.forHttpStatus(404)) },
            { _, tried -> askedWith = tried; emptyList() }
        )
        assertEquals(listOf(first, "ftp://repo.example.org/c.pdf"), askedWith)
    }

    @Test
    fun `OpenAlex is not asked when an Unpaywall copy was served, saved or not`() = runTest {
        for (download in listOf(PdfDownload.Saved("/cache/d.pdf"), PdfDownload.NotSaved)) {
            var asked = false
            document().recordingFullTextFetch(found(candidate(first)), { download }, { _, _ -> asked = true; emptyList() })
            assertFalse("$download", asked)
        }
    }

    @Test
    fun `OpenAlex already asked by the service is not asked again`() = runTest {
        var asked = false
        document().recordingFullTextFetch(
            FullTextResult.OpenAccessPdfs(
                listOf(OpenAccessStep.Candidate(openAlexPdf, PdfNamer.OPENALEX)), doi, openAlexAsked = true
            ),
            { PdfDownload.Failed(RequestFailure.forHttpStatus(403)) },
            { _, _ -> asked = true; emptyList() }
        )
        assertFalse(asked)
    }

    @Test
    fun `every refusal is told in chain order, OpenAlex's lookup and copy after Unpaywall's`() = runTest {
        val timeout = OpenAccessShortfall(OpenAccessSource.OPENALEX, RequestFailure(RequestFailureKind.TIMEOUT))
        val recorded = document().recordingFullTextFetch(
            found(candidate(first)),
            { PdfDownload.Failed(RequestFailure.forHttpStatus(if (it == first) 403 else 404)) },
            { _, _ -> listOf(OpenAccessStep.Unsettled(timeout), OpenAccessStep.Candidate(openAlexPdf, PdfNamer.OPENALEX)) }
        )
        assertEquals(
            refused(first, 403) + timeout +
                OpenAccessShortfall(OpenAccessSource.OPENALEX_PDF, RequestFailure.forHttpStatus(404), openAlexPdf),
            (recorded.result as FullTextResult.DoiUrl).openAccessShortfall
        )
    }

    /** An OpenAlex copy served and not saved is kept by its link, as Unpaywall's is. */
    @Test
    fun `an OpenAlex copy not saved keeps its link with the caching note`() = runTest {
        val recorded = document().recordingFullTextFetch(
            found(candidate(first)),
            { url -> if (url == first) PdfDownload.Failed(RequestFailure.forHttpStatus(403)) else PdfDownload.NotSaved },
            { _, _ -> listOf(OpenAccessStep.Candidate(openAlexPdf, PdfNamer.OPENALEX)) }
        )
        assertEquals(FullTextResult.OpenAccessPdf(openAlexPdf, doi, PdfNamer.OPENALEX, notSaved = true), recorded.result)
        assertEquals(openAlexPdf, recorded.document.fullTextPdfNotSavedFrom)
        assertNull(recorded.document.fullTextOpenAccessShortfallJson)
    }

    @Test(expected = IllegalArgumentException::class)
    fun `steps with no candidate are refused`() {
        found(OpenAccessStep.Unsettled(OpenAccessShortfall.UNPAYWALL_NOT_CONFIGURED))
    }
}
