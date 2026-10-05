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
import com.bmlibrarian.factchecker.domain.model.FullTextLinkKind
import com.bmlibrarian.factchecker.domain.model.OpenAccessShortfall
import com.bmlibrarian.factchecker.domain.model.OpenAccessSource
import com.bmlibrarian.factchecker.domain.model.RequestFailure
import com.bmlibrarian.factchecker.domain.model.RequestFailureKind
import com.bmlibrarian.factchecker.util.Constants
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test

/**
 * What a full-text fetch records on the document, for the fact-check and report
 * screens alike: above all, that every answer writes the open-access shortfall
 * or clears the one an earlier fetch left (#466).
 */
class FullTextRecordingTest {

    private val earlier = OpenAccessShortfall(OpenAccessSource.UNPAYWALL, RequestFailure(RequestFailureKind.TIMEOUT))

    /** A document an earlier fetch left on the DOI link with Unpaywall unsettled. */
    private val document = DocumentEntity(
        id = "d", sessionId = "s", title = "t", doi = "10.1/x",
        fullTextSource = Constants.FULLTEXT_SOURCE_DOI,
        fullTextOpenAccessShortfallJson = earlier.toJson()
    )

    /** The chain's answer naming one Unpaywall PDF for 10.1/x. */
    private fun unpaywallPdfs(pdfUrl: String) =
        FullTextResult.OpenAccessPdfs(listOf(OpenAccessStep.Candidate(pdfUrl, PdfNamer.UNPAYWALL)), "10.1/x")

    private suspend fun record(result: FullTextResult, downloaded: String? = "/tmp/a.pdf") =
        recorded(result, downloaded).document

    /** The document and the settled result, the download answering [downloaded] or failing with a 404. */
    private suspend fun recorded(result: FullTextResult, downloaded: String? = "/tmp/a.pdf") =
        document.recordingFullTextFetch(result) {
            downloaded?.let(PdfDownload::Saved) ?: PdfDownload.Failed(RequestFailure(RequestFailureKind.HTTP_STATUS, 404))
        }

    @Test
    fun `a DOI link stores the shortfall it carries`() = runTest {
        val landing = OpenAccessShortfall(
            OpenAccessSource.LANDING_PAGE, RequestFailure(RequestFailureKind.HTTP_STATUS, 503)
        )

        val recorded = record(FullTextResult.DoiUrl("https://doi.org/10.1/x", landing))

        assertEquals(landing, recorded.openAccessShortfall)
        assertEquals(Constants.FULLTEXT_SOURCE_DOI, recorded.fullTextSource)
    }

    /** Every answer that settled the lookup clears what the earlier fetch left. */
    @Test
    fun `every settled answer clears the earlier shortfall`() = runTest {
        val answers = listOf(
            FullTextResult.DoiUrl("https://doi.org/10.1/x"),
            FullTextResult.EuropePmcXml(xml = "<a/>", markdown = "m", html = "<p>h</p>"),
            FullTextResult.PmcOpenDataXml(xml = "<a/>", markdown = "m", html = "<p>h</p>"),
            FullTextResult.EuropePmcPdf(pdfUrl = "https://europepmc.org/a.pdf"),
            unpaywallPdfs("https://repo.example.org/a.pdf"),
            FullTextResult.Unavailable("No full text source available"),
        )
        for (answer in answers) {
            assertNull("$answer", record(answer).fullTextOpenAccessShortfallJson)
        }
    }

    /** PMC's open-data bucket's JATS is stored as Europe PMC's is, under its own source (#480). */
    @Test
    fun `the bucket's text is recorded under its own source`() = runTest {
        val recorded = record(FullTextResult.PmcOpenDataXml(xml = "<a/>", markdown = "m", html = "<p>h</p>"))

        assertEquals("m", recorded.fullTextMarkdown)
        assertEquals("<p>h</p>", recorded.fullTextHTML)
        assertEquals(Constants.FULLTEXT_SOURCE_PMC_OPEN_DATA, recorded.fullTextSource)
        assertEquals(Constants.FULLTEXT_SOURCE_PMC_OPEN_DATA_LABEL, recorded.fullTextSourceDisplay)
        assertEquals("PMC Open-Access Collection", Constants.FULLTEXT_SOURCE_PMC_OPEN_DATA_LABEL)
        assertNull(recorded.fullTextOpenAccessShortfallJson)
        assertEquals(false, recorded.isLinkOnly)
    }

    /** Including when the Europe PMC PDF it found could not be downloaded: Europe PMC is not the open-access tier. */
    @Test
    fun `a Europe PMC PDF that could not be downloaded still clears it`() = runTest {
        val recorded = record(FullTextResult.EuropePmcPdf(pdfUrl = "https://europepmc.org/a.pdf"), downloaded = null)

        assertNull(recorded.pdfPath)
        assertNull(recorded.fullTextOpenAccessShortfallJson)
    }

    /**
     * A PDF Unpaywall named that could not be downloaded is refused, not
     * recorded as found (#478): the document is the DOI link, carrying why and
     * the PDF's address (#480), and the result the screens are shown is that
     * link too.
     */
    @Test
    fun `an Unpaywall PDF that could not be downloaded is refused for the DOI link`() = runTest {
        val notFound = RequestFailure(RequestFailureKind.HTTP_STATUS, 404)
        val pdfUrl = "https://repo.example.org/a.pdf"

        val (doc, shown) = recorded(unpaywallPdfs(pdfUrl), downloaded = null)

        val shortfall = OpenAccessShortfall(OpenAccessSource.PDF, notFound, pdfUrl)
        assertEquals(FullTextResult.DoiUrl("${Constants.DOI_URL_PREFIX}10.1/x", shortfall), shown)
        assertNull(doc.pdfPath)
        assertEquals(Constants.FULLTEXT_SOURCE_DOI, doc.fullTextSource)
        assertEquals(shortfall, doc.openAccessShortfall)
    }

    /** The control: a downloaded Unpaywall PDF is recorded as found. */
    @Test
    fun `a downloaded Unpaywall PDF is recorded as found`() = runTest {
        val pdfUrl = "https://repo.example.org/a.pdf"

        val (doc, shown) = recorded(unpaywallPdfs(pdfUrl), downloaded = "/cache/a.pdf")

        assertEquals(FullTextResult.OpenAccessPdf(pdfUrl, "10.1/x", PdfNamer.UNPAYWALL), shown)
        assertEquals("/cache/a.pdf", doc.pdfPath)
        assertEquals(Constants.FULLTEXT_SOURCE_UNPAYWALL, doc.fullTextSource)
        assertNull(doc.fullTextOpenAccessShortfallJson)
        assertNull(doc.fullTextPdfNotSavedFrom)
    }

    /**
     * A PDF the source served that could not be saved is our fault, not the
     * copy's: it stays the Unpaywall PDF's link, with no shortfall, as
     * BioMedLit keeps its link (#478), and a caching note of its own (#480).
     */
    @Test
    fun `an Unpaywall PDF that could not be saved keeps its link`() = runTest {
        val pdfUrl = "https://repo.example.org/a.pdf"

        val (doc, shown) = document.recordingFullTextFetch(unpaywallPdfs(pdfUrl)) { PdfDownload.NotSaved }

        assertEquals(FullTextResult.OpenAccessPdf(pdfUrl, "10.1/x", PdfNamer.UNPAYWALL, notSaved = true), shown)
        assertNull(doc.pdfPath)
        assertEquals(Constants.FULLTEXT_SOURCE_UNPAYWALL, doc.fullTextSource)
        assertNull(doc.fullTextOpenAccessShortfallJson)
        assertEquals(pdfUrl, doc.fullTextPdfNotSavedFrom)
        assertEquals(FullTextLinkKind.UNDOWNLOADED_PDF, doc.linkOnlyKind)
    }

    /** A chain that settled nothing records nothing, the shortfall included (#434). */
    @Test
    fun `a chain that did not establish the absence leaves the document as it was`() = runTest {
        val recorded = record(FullTextResult.NotEstablished(
            RequestFailure(RequestFailureKind.CONNECTION), NotEstablishedSource.EUROPE_PMC
        ))

        assertSame(document, recorded)
    }
}
