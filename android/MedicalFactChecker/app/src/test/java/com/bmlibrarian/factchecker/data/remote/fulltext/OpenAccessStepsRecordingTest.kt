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
        val recorded = document().recordingFullTextFetch(found(candidate(first), candidate(second))) { url ->
            asked += url
            if (url == first) PdfDownload.Failed(RequestFailure.forHttpStatus(403)) else PdfDownload.Saved("/cache/d.pdf")
        }
        assertEquals(listOf(first, second), asked)
        assertEquals(FullTextResult.OpenAccessPdf(second, doi, PdfNamer.UNPAYWALL), recorded.result)
        assertEquals("/cache/d.pdf", recorded.document.pdfPath)
        assertEquals(Constants.FULLTEXT_SOURCE_UNPAYWALL, recorded.document.fullTextSource)
        assertNull(recorded.document.fullTextOpenAccessShortfallJson)
    }

    @Test
    fun `every candidate refused is told, each by its address`() = runTest {
        val recorded = document().recordingFullTextFetch(found(candidate(first), candidate(second))) { url ->
            PdfDownload.Failed(RequestFailure.forHttpStatus(if (url == first) 403 else 503))
        }
        val expected = refused(first, 403) + refused(second, 503)
        assertEquals(FullTextResult.DoiUrl(doiLink(doi), expected), recorded.result)
        assertEquals(expected, recorded.document.openAccessShortfall)
        assertEquals(Constants.FULLTEXT_SOURCE_DOI, recorded.document.fullTextSource)
        assertNull(recorded.document.pdfPath)
    }

    @Test
    fun `an unsettled lookup before the candidates is told first`() = runTest {
        val lookup = OpenAccessShortfall(OpenAccessSource.LANDING_PAGE, RequestFailure(RequestFailureKind.TIMEOUT))
        val recorded = document().recordingFullTextFetch(found(OpenAccessStep.Unsettled(lookup), candidate(first))) {
            PdfDownload.Failed(RequestFailure.forHttpStatus(403))
        }
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
            found(candidate(first), OpenAccessStep.Unsettled(unfetchable), candidate(second))
        ) { url ->
            asked += url
            PdfDownload.Failed(RequestFailure.forHttpStatus(404))
        }
        assertEquals(listOf(first, second), asked)
        assertEquals(
            FullTextResult.DoiUrl(doiLink(doi), refused(first, 404) + unfetchable + refused(second, 404)),
            recorded.result
        )
    }

    @Test
    fun `a copy served but not saved ends the walk with a caching note and no shortfall`() = runTest {
        val asked = mutableListOf<String>()
        val recorded = document().recordingFullTextFetch(found(candidate(first), candidate(second))) { url ->
            asked += url; PdfDownload.NotSaved
        }
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
        val recorded = document().recordingFullTextFetch(found(candidate(first), candidate(second))) { url ->
            if (url == first) PdfDownload.Failed(RequestFailure.forHttpStatus(403)) else PdfDownload.NotSaved
        }
        assertEquals(FullTextResult.OpenAccessPdf(second, doi, PdfNamer.UNPAYWALL, notSaved = true), recorded.result)
        assertNull(recorded.document.fullTextOpenAccessShortfallJson)
        assertEquals(second, recorded.document.fullTextPdfNotSavedFrom)
    }

    @Test
    fun `a saved copy stops the walk and clears an earlier note`() = runTest {
        val asked = mutableListOf<String>()
        val recorded = document().copy(fullTextPdfNotSavedFrom = first)
            .recordingFullTextFetch(found(candidate(first), candidate(second))) { url ->
                asked += url; PdfDownload.Saved("/cache/d.pdf")
            }
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
                .recordingFullTextFetch(answer) { PdfDownload.Failed(RequestFailure.forHttpStatus(404)) }
            assertNull("$answer", recorded.document.fullTextPdfNotSavedFrom)
        }
    }

    @Test
    fun `a Europe PMC render served but not saved is noted too`() = runTest {
        val render = "https://europepmc.org/articles/PMC1/pdf"
        val recorded = document().recordingFullTextFetch(FullTextResult.EuropePmcPdf(render)) { PdfDownload.NotSaved }
        assertEquals(render, recorded.document.fullTextPdfNotSavedFrom)
        assertNull(recorded.document.pdfPath)
    }

    /** The note says the link is kept when the link is what the reader is given. */
    @Test
    fun `the caching note says the link is kept on a link-only record`() = runTest {
        val recorded = document().recordingFullTextFetch(found(candidate(first))) { PdfDownload.NotSaved }
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

    @Test(expected = IllegalArgumentException::class)
    fun `steps with no candidate are refused`() {
        found(OpenAccessStep.Unsettled(OpenAccessShortfall.UNPAYWALL_NOT_CONFIGURED))
    }
}
