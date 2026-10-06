/*
 * BMLibrarian Lite - Biomedical Literature Research Tool
 * Copyright (C) 2024-2025 Dr Horst Herb
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

package com.bmlibrarian.factchecker.ui.report

import com.bmlibrarian.factchecker.data.local.entity.DocumentEntity
import com.bmlibrarian.factchecker.data.remote.fulltext.FullTextService
import com.bmlibrarian.factchecker.data.remote.fulltext.OpenAccessStep
import com.bmlibrarian.factchecker.data.remote.fulltext.PdfDownload
import com.bmlibrarian.factchecker.data.remote.fulltext.PdfNamer
import com.bmlibrarian.factchecker.data.repository.DocumentRepository
import com.bmlibrarian.factchecker.data.repository.SettingsRepository
import com.bmlibrarian.factchecker.domain.model.AppSettings
import com.bmlibrarian.factchecker.domain.model.OpenAccessShortfall
import com.bmlibrarian.factchecker.domain.model.OpenAccessSource
import com.bmlibrarian.factchecker.domain.model.RequestFailure
import com.bmlibrarian.factchecker.domain.model.RequestFailureKind
import com.bmlibrarian.factchecker.ui.report.components.ReferenceInfo
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import io.mockk.slot
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test

/**
 * The report's document sheet records a full-text fetch through the shared
 * writer, open-access shortfall included (#466): stored when the chain ended on
 * a DOI link it could not settle, cleared when a later fetch settles it.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class ReportViewModelFullTextTest {

    private lateinit var fullTextService: FullTextService
    private lateinit var documentRepository: DocumentRepository

    private val throttled = OpenAccessShortfall(
        OpenAccessSource.UNPAYWALL, RequestFailure(RequestFailureKind.HTTP_STATUS, 429)
    )
    private val document = DocumentEntity(id = "d", sessionId = "s", title = "t", doi = "10.1/x")

    @Before
    fun setUp() {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        fullTextService = mockk(relaxed = true) {
            // A relaxed MockK answers a suspend call with null, not an empty list
            coEvery { openAlexSteps(any(), any()) } returns emptyList()
        }
        documentRepository = mockk(relaxed = true)
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    /** Opens the report on [stored], selects it, and fetches with the chain answering [answer]. */
    private fun fetch(stored: DocumentEntity, answer: FullTextService.FullTextResult): DocumentEntity {
        every { documentRepository.getScoredDocumentsBySession("s") } returns flowOf(listOf(stored))
        coEvery { fullTextService.fetchFullText(any(), any(), any(), any()) } returns Result.success(answer)
        val written = slot<DocumentEntity>()
        coEvery { documentRepository.updateDocument(capture(written)) } returns Unit
        val settingsRepository = mockk<SettingsRepository>(relaxed = true) {
            every { settings } returns MutableStateFlow(AppSettings())
        }
        val viewModel = ReportViewModel(
            sessionRepository = mockk(relaxed = true),
            reportRepository = mockk(relaxed = true),
            documentRepository = documentRepository,
            fullTextService = fullTextService,
            settingsRepository = settingsRepository,
            pdfExporter = mockk(relaxed = true)
        )
        viewModel.loadReport("s")
        viewModel.onReferenceClick(ReferenceInfo(documentId = "d", displayText = "[1]"))

        viewModel.fetchFullText()

        coVerify { documentRepository.updateDocument(any()) }
        assertEquals(written.captured, viewModel.uiState.value.selectedDocument)
        return written.captured
    }

    @Test
    fun `a DOI link the chain could not settle stores the shortfall`() {
        val written = fetch(document, FullTextService.FullTextResult.DoiUrl("https://doi.org/10.1/x", throttled))

        assertEquals(throttled, written.openAccessShortfall)
    }

    @Test
    fun `a settled answer clears an earlier shortfall`() {
        val unsettled = document.copy(fullTextOpenAccessShortfallJson = throttled.toJson())

        val written = fetch(unsettled, FullTextService.FullTextResult.DoiUrl("https://doi.org/10.1/x"))

        assertNull(written.fullTextOpenAccessShortfallJson)
    }

    /**
     * Once every Unpaywall PDF failed, the sheet asks OpenAlex through the
     * service, with what was tried, and records the copy it named (#480).
     */
    @Test
    fun `OpenAlex is asked through the service once Unpaywall's PDFs failed`() {
        val unpaywallPdf = "https://repo.example.org/a.pdf"
        val openAlexPdf = "https://oa.example.org/b.pdf"
        coEvery { fullTextService.downloadPdf(unpaywallPdf, any()) } returns
            PdfDownload.Failed(RequestFailure.forHttpStatus(404))
        coEvery { fullTextService.downloadPdf(openAlexPdf, any()) } returns PdfDownload.Saved("/cache/d.pdf")
        coEvery { fullTextService.openAlexSteps("10.1/x", listOf(unpaywallPdf)) } returns
            listOf(OpenAccessStep.Candidate(openAlexPdf, PdfNamer.OPENALEX))

        val written = fetch(
            document,
            FullTextService.FullTextResult.OpenAccessPdfs(
                listOf(OpenAccessStep.Candidate(unpaywallPdf, PdfNamer.UNPAYWALL)), "10.1/x"
            )
        )

        coVerify(exactly = 1) { fullTextService.openAlexSteps("10.1/x", listOf(unpaywallPdf)) }
        assertEquals("openalex", written.fullTextSource)
        assertEquals("/cache/d.pdf", written.pdfPath)
    }
}
