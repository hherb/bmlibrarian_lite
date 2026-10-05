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

package com.bmlibrarian.factchecker.ui.fulltext

import androidx.lifecycle.SavedStateHandle
import com.bmlibrarian.factchecker.data.local.dao.DocumentDao
import com.bmlibrarian.factchecker.data.local.entity.DocumentEntity
import com.bmlibrarian.factchecker.data.remote.fulltext.FullTextService
import com.bmlibrarian.factchecker.data.remote.fulltext.NotEstablishedSource
import com.bmlibrarian.factchecker.data.remote.fulltext.OpenAccessStep
import com.bmlibrarian.factchecker.data.remote.fulltext.PdfDownload
import com.bmlibrarian.factchecker.data.remote.fulltext.PdfNamer
import com.bmlibrarian.factchecker.data.repository.SettingsRepository
import com.bmlibrarian.factchecker.domain.model.AppSettings
import com.bmlibrarian.factchecker.domain.model.FullTextLinkKind
import com.bmlibrarian.factchecker.domain.model.OpenAccessShortfall
import com.bmlibrarian.factchecker.domain.model.OpenAccessSource
import com.bmlibrarian.factchecker.domain.model.RequestFailure
import com.bmlibrarian.factchecker.domain.model.RequestFailureKind
import com.bmlibrarian.factchecker.util.Constants
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * The full-text viewer tells the reader when the open-access copy went
 * unassessed, stores it, and forgets it once a fetch settled it (#466).
 */
@OptIn(ExperimentalCoroutinesApi::class)
class FullTextViewModelOpenAccessShortfallTest {

    private lateinit var fullTextService: FullTextService
    private lateinit var documentDao: DocumentDao
    private lateinit var settingsRepository: SettingsRepository

    private val throttled = OpenAccessShortfall(
        OpenAccessSource.UNPAYWALL, RequestFailure(RequestFailureKind.HTTP_STATUS, 429)
    )
    private val document = DocumentEntity(id = "d", sessionId = "s", title = "t", doi = "10.1/x")

    /** A download the server answered with 404. */
    private val notFound = PdfDownload.Failed(RequestFailure(RequestFailureKind.HTTP_STATUS, 404))

    @Before
    fun setUp() {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        fullTextService = mockk(relaxed = true) {
            every { getCachedPdfPath(any()) } returns null
            coEvery { downloadPdf(any(), any()) } returns notFound
            // A relaxed MockK answers a suspend call with null, not an empty list
            coEvery { openAlexSteps(any(), any()) } returns emptyList()
        }
        documentDao = mockk(relaxed = true)
        settingsRepository = mockk(relaxed = true)
        every { settingsRepository.settings } returns MutableStateFlow(AppSettings())
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    /** The chain's answer naming one Unpaywall PDF for 10.1/x. */
    private fun unpaywallPdfs(pdfUrl: String) = FullTextService.FullTextResult.OpenAccessPdfs(
        listOf(OpenAccessStep.Candidate(pdfUrl, PdfNamer.UNPAYWALL)), "10.1/x"
    )

    /** Opens the viewer on [stored] with the chain answering [answer]. */
    private fun open(stored: DocumentEntity, answer: FullTextService.FullTextResult): FullTextViewModel {
        coEvery { documentDao.getById("d") } returns stored
        coEvery { fullTextService.fetchFullText(any(), any(), any(), any()) } returns Result.success(answer)
        return FullTextViewModel(
            savedStateHandle = SavedStateHandle(mapOf(FullTextViewModel.DOCUMENT_ID_KEY to "d")),
            fullTextService = fullTextService,
            documentDao = documentDao,
            settingsRepository = settingsRepository
        )
    }

    @Test
    fun `a DOI link left by an unsettled lookup says so and stores it`() {
        val viewModel = open(document, FullTextService.FullTextResult.DoiUrl("https://doi.org/10.1/x", throttled))

        assertEquals(
            FullTextViewModel.FullTextState.WebUrl("https://doi.org/10.1/x", "t", FullTextLinkKind.PUBLISHER_PAGE, throttled.notice),
            viewModel.state.value
        )
        coVerify { documentDao.update(match { it.openAccessShortfall == throttled }) }
    }

    /** The control: a DOI link Unpaywall settled says nothing more, and forgets the old. */
    @Test
    fun `a settled DOI link carries no notice and clears an earlier shortfall`() {
        val unsettled = document.copy(fullTextOpenAccessShortfallJson = throttled.toJson())

        val viewModel = open(unsettled, FullTextService.FullTextResult.DoiUrl("https://doi.org/10.1/x"))

        assertEquals(
            FullTextViewModel.FullTextState.WebUrl("https://doi.org/10.1/x", "t", FullTextLinkKind.PUBLISHER_PAGE, null),
            viewModel.state.value
        )
        coVerify { documentDao.update(match { it.fullTextOpenAccessShortfallJson == null }) }
    }

    /**
     * Every answer that settles the lookup clears what an earlier fetch stored,
     * downloaded or not: the viewer writes through the fact-check and report
     * screens' writer, so the card never keeps saying a free copy may exist.
     */
    @Test
    fun `every settled answer clears an earlier shortfall`() {
        val pdfUrl = "https://repo.example.org/a.pdf"
        val answers = listOf(
            FullTextService.FullTextResult.EuropePmcXml(xml = "<a/>", markdown = "m", html = "<p>h</p>") to null,
            FullTextService.FullTextResult.PmcOpenDataXml(xml = "<a/>", markdown = "m", html = "<p>h</p>") to null,
            FullTextService.FullTextResult.EuropePmcPdf(pdfUrl) to "/cache/a.pdf",
            FullTextService.FullTextResult.EuropePmcPdf(pdfUrl) to null,
            unpaywallPdfs(pdfUrl) to "/cache/a.pdf",
            FullTextService.FullTextResult.Unavailable("none") to null,
        )
        for ((answer, downloaded) in answers) {
            documentDao = mockk(relaxed = true)
            coEvery { fullTextService.downloadPdf(any(), any()) } returns (downloaded?.let(PdfDownload::Saved) ?: notFound)
            val unsettled = document.copy(fullTextOpenAccessShortfallJson = throttled.toJson())

            open(unsettled, answer)

            coVerify(exactly = 1) {
                documentDao.update(match { it.fullTextOpenAccessShortfallJson == null && it.pdfPath == downloaded })
            }
        }
    }

    /** PMC's open-data bucket's JATS is shown as HTML, as Europe PMC's is, and named as its source (#480). */
    @Test
    fun `the bucket's text is shown as HTML under its own label`() {
        val state = open(
            document, FullTextService.FullTextResult.PmcOpenDataXml(xml = "<a/>", markdown = "m", html = "<p>h</p>")
        ).state.value

        assertTrue("$state", state is FullTextViewModel.FullTextState.HtmlContent)
        state as FullTextViewModel.FullTextState.HtmlContent
        assertEquals(Constants.FULLTEXT_SOURCE_PMC_OPEN_DATA_LABEL, state.source)
        assertEquals("t", state.title)
        assertTrue(state.html, state.html.contains("<p>h</p>"))
    }

    /** A downloaded PDF is shown; one that could not be is offered by its URL. */
    @Test
    fun `a PDF is shown when downloaded and linked when not`() {
        val pdfUrl = "https://repo.example.org/a.pdf"
        coEvery { fullTextService.downloadPdf(any(), any()) } returns PdfDownload.Saved("/cache/a.pdf")
        assertEquals(
            FullTextViewModel.FullTextState.PdfContent("/cache/a.pdf", "t", "Unpaywall"),
            open(document, unpaywallPdfs(pdfUrl)).state.value
        )

        coEvery { fullTextService.downloadPdf(any(), any()) } returns notFound
        assertEquals(
            FullTextViewModel.FullTextState.WebUrl(pdfUrl, "t", FullTextLinkKind.UNDOWNLOADED_PDF),
            open(document, FullTextService.FullTextResult.EuropePmcPdf(pdfUrl)).state.value
        )
    }

    /**
     * A PDF Unpaywall named that could not be downloaded is refused (#478): the
     * viewer offers the DOI link, says why the open-access copy went
     * unassessed, and stores that, rather than offering the dead PDF link.
     */
    @Test
    fun `an Unpaywall PDF that could not be downloaded is shown as the DOI link with why`() {
        val pdfUrl = "https://repo.example.org/a.pdf"
        val shortfall = OpenAccessShortfall(OpenAccessSource.PDF, notFound.failure, pdfUrl)

        val viewModel = open(document, unpaywallPdfs(pdfUrl))

        assertEquals(
            FullTextViewModel.FullTextState.WebUrl(
                "https://doi.org/10.1/x", "t", FullTextLinkKind.PUBLISHER_PAGE, shortfall.notice
            ),
            viewModel.state.value
        )
        coVerify { documentDao.update(match { it.openAccessShortfall == shortfall && it.pdfPath == null }) }
    }

    /**
     * Once every Unpaywall PDF failed, the viewer asks OpenAlex through the
     * service, with what was tried, and shows the copy it named (#480).
     */
    @Test
    fun `OpenAlex is asked through the service once Unpaywall's PDFs failed`() {
        val unpaywallPdf = "https://repo.example.org/a.pdf"
        val openAlexPdf = "https://oa.example.org/b.pdf"
        coEvery { fullTextService.downloadPdf(openAlexPdf, any()) } returns PdfDownload.Saved("/cache/b.pdf")
        coEvery { fullTextService.openAlexSteps("10.1/x", listOf(unpaywallPdf)) } returns
            listOf(OpenAccessStep.Candidate(openAlexPdf, PdfNamer.OPENALEX))

        val viewModel = open(document, unpaywallPdfs(unpaywallPdf))

        coVerify(exactly = 1) { fullTextService.openAlexSteps("10.1/x", listOf(unpaywallPdf)) }
        assertEquals(
            FullTextViewModel.FullTextState.PdfContent("/cache/b.pdf", "t", "OpenAlex"),
            viewModel.state.value
        )
        coVerify { documentDao.update(match { it.fullTextSource == "openalex" && it.pdfPath == "/cache/b.pdf" }) }
    }

    /**
     * A PDF served and not saved is offered by its link, with the caching note
     * beside it and no shortfall (#480), and the note is stored.
     */
    @Test
    fun `a PDF not saved is linked with the caching note`() {
        val pdfUrl = "https://repo.example.org/a.pdf"
        coEvery { fullTextService.downloadPdf(any(), any()) } returns PdfDownload.NotSaved
        val note = OpenAccessShortfall.notSavedNote(pdfUrl, linkKept = true)

        val viewModel = open(document, unpaywallPdfs(pdfUrl))

        assertEquals(
            FullTextViewModel.FullTextState.WebUrl(
                pdfUrl, "t", FullTextLinkKind.UNDOWNLOADED_PDF, openAccessNotice = null, pdfNotSavedNote = note
            ),
            viewModel.state.value
        )
        coVerify {
            documentDao.update(match { it.fullTextPdfNotSavedFrom == pdfUrl && it.fullTextOpenAccessShortfallJson == null })
        }
    }

    /** A chain that settled nothing records nothing, the stored shortfall included (#434). */
    @Test
    fun `an unestablished answer leaves the stored shortfall as it was`() {
        val unsettled = document.copy(fullTextOpenAccessShortfallJson = throttled.toJson())

        open(unsettled, FullTextService.FullTextResult.NotEstablished(
            RequestFailure(RequestFailureKind.TIMEOUT), NotEstablishedSource.EUROPE_PMC
        ))

        coVerify(exactly = 0) { documentDao.update(any()) }
    }

    /** Refresh forgets everything the last fetch stored, so it really fetches again. */
    @Test
    fun `refresh clears the stored shortfall and the cached text`() {
        val cached = document.copy(
            fullTextHTML = "<p>h</p>",
            fullTextMarkdown = "m",
            fullTextOpenAccessShortfallJson = throttled.toJson(),
            fullTextPdfNotSavedFrom = "https://repo.example.org/a.pdf"
        )
        val viewModel = open(cached, FullTextService.FullTextResult.DoiUrl("https://doi.org/10.1/x"))

        coEvery { documentDao.getById("d") } returns document

        viewModel.refresh()

        // Fetched again, rather than left on Loading
        assertEquals(
            FullTextViewModel.FullTextState.WebUrl("https://doi.org/10.1/x", "t", FullTextLinkKind.PUBLISHER_PAGE, null),
            viewModel.state.value
        )
        coVerify {
            documentDao.update(
                match {
                    it.fullTextOpenAccessShortfallJson == null && it.fullTextHTML == null && it.fullTextMarkdown == null &&
                        it.fullTextPdfNotSavedFrom == null
                }
            )
        }
    }
}
