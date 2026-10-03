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
import com.bmlibrarian.factchecker.data.repository.SettingsRepository
import com.bmlibrarian.factchecker.domain.model.AppSettings
import com.bmlibrarian.factchecker.domain.model.OpenAccessShortfall
import com.bmlibrarian.factchecker.domain.model.OpenAccessSource
import com.bmlibrarian.factchecker.domain.model.RequestFailure
import com.bmlibrarian.factchecker.domain.model.RequestFailureKind
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

    @Before
    fun setUp() {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        fullTextService = mockk(relaxed = true) {
            every { getCachedPdfPath(any()) } returns null
            coEvery { downloadPdf(any(), any()) } returns null
        }
        documentDao = mockk(relaxed = true)
        settingsRepository = mockk(relaxed = true)
        every { settingsRepository.settings } returns MutableStateFlow(AppSettings())
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

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
            FullTextViewModel.FullTextState.WebUrl("https://doi.org/10.1/x", "t", throttled.notice),
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
            FullTextViewModel.FullTextState.WebUrl("https://doi.org/10.1/x", "t", null),
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
            FullTextService.FullTextResult.EuropePmcPdf(pdfUrl) to "/cache/a.pdf",
            FullTextService.FullTextResult.EuropePmcPdf(pdfUrl) to null,
            FullTextService.FullTextResult.UnpaywallPdf(pdfUrl) to "/cache/a.pdf",
            FullTextService.FullTextResult.UnpaywallPdf(pdfUrl) to null,
            FullTextService.FullTextResult.Unavailable("none") to null,
        )
        for ((answer, downloaded) in answers) {
            documentDao = mockk(relaxed = true)
            coEvery { fullTextService.downloadPdf(any(), any()) } returns downloaded
            val unsettled = document.copy(fullTextOpenAccessShortfallJson = throttled.toJson())

            open(unsettled, answer)

            coVerify(exactly = 1) {
                documentDao.update(match { it.fullTextOpenAccessShortfallJson == null && it.pdfPath == downloaded })
            }
        }
    }

    /** A downloaded PDF is shown; one that could not be is offered by its URL. */
    @Test
    fun `a PDF is shown when downloaded and linked when not`() {
        val pdfUrl = "https://repo.example.org/a.pdf"
        coEvery { fullTextService.downloadPdf(any(), any()) } returns "/cache/a.pdf"
        assertEquals(
            FullTextViewModel.FullTextState.PdfContent("/cache/a.pdf", "t", "Unpaywall"),
            open(document, FullTextService.FullTextResult.UnpaywallPdf(pdfUrl)).state.value
        )

        coEvery { fullTextService.downloadPdf(any(), any()) } returns null
        assertEquals(
            FullTextViewModel.FullTextState.WebUrl(pdfUrl, "t"),
            open(document, FullTextService.FullTextResult.EuropePmcPdf(pdfUrl)).state.value
        )
    }

    /** A chain that settled nothing records nothing, the stored shortfall included (#434). */
    @Test
    fun `an unestablished answer leaves the stored shortfall as it was`() {
        val unsettled = document.copy(fullTextOpenAccessShortfallJson = throttled.toJson())

        open(unsettled, FullTextService.FullTextResult.NotEstablished(RequestFailure(RequestFailureKind.TIMEOUT)))

        coVerify(exactly = 0) { documentDao.update(any()) }
    }

    /** Refresh forgets everything the last fetch stored, so it really fetches again. */
    @Test
    fun `refresh clears the stored shortfall and the cached text`() {
        val cached = document.copy(
            fullTextHTML = "<p>h</p>",
            fullTextMarkdown = "m",
            fullTextOpenAccessShortfallJson = throttled.toJson()
        )
        val viewModel = open(cached, FullTextService.FullTextResult.DoiUrl("https://doi.org/10.1/x"))

        coEvery { documentDao.getById("d") } returns document

        viewModel.refresh()

        // Fetched again, rather than left on Loading
        assertEquals(
            FullTextViewModel.FullTextState.WebUrl("https://doi.org/10.1/x", "t", null),
            viewModel.state.value
        )
        coVerify {
            documentDao.update(
                match {
                    it.fullTextOpenAccessShortfallJson == null && it.fullTextHTML == null && it.fullTextMarkdown == null
                }
            )
        }
    }
}
