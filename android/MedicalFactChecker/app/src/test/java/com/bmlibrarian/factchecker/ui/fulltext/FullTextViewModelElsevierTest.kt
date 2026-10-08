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
import org.junit.Assert.assertFalse
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

/**
 * The full-text viewer and Elsevier's PDF (#480, stage C2): a stored PDF opens
 * from disk without the chain, so a key cleared since never overwrites the
 * record; a PDF the chain returns is shown as the local file it is, never as a
 * link, since Elsevier's URL needs the key.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class FullTextViewModelElsevierTest {

    @get:Rule
    val folder = TemporaryFolder()

    private lateinit var fullTextService: FullTextService
    private lateinit var documentDao: DocumentDao
    private lateinit var settingsRepository: SettingsRepository

    private val document = DocumentEntity(id = "d", sessionId = "s", title = "t", doi = "10.1016/j.x.1")

    @Before
    fun setUp() {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        fullTextService = mockk(relaxed = true) {
            // Elsevier's file is not under the document's ID
            every { getCachedPdfPath(any()) } returns null
            coEvery { openAlexSteps(any(), any()) } returns emptyList()
            coEvery { askCore(any()) } returns null
        }
        documentDao = mockk(relaxed = true)
        // No Elsevier key: the stored PDF must not need one
        settingsRepository = mockk(relaxed = true) {
            every { settings } returns MutableStateFlow(AppSettings())
            every { getElsevierApiKey() } returns ""
            every { getElsevierInstToken() } returns ""
        }
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    /** A PDF on disk, as Elsevier's service caches it. */
    private fun pdfOnDisk(): File = folder.newFile("elsevier-x.pdf").apply { writeBytes("%PDF-1.7\nbytes".toByteArray()) }

    /** Opens the viewer on [stored], the chain answering [answer] if asked. */
    private fun open(
        stored: DocumentEntity,
        answer: FullTextService.FullTextResult = FullTextService.FullTextResult.DoiUrl("https://doi.org/10.1016/j.x.1")
    ): FullTextViewModel {
        coEvery { documentDao.getById("d") } returns stored
        coEvery { fullTextService.fetchFullText(any(), any(), any(), any()) } returns Result.success(answer)
        return FullTextViewModel(
            savedStateHandle = SavedStateHandle(mapOf(FullTextViewModel.DOCUMENT_ID_KEY to "d")),
            fullTextService = fullTextService,
            documentDao = documentDao,
            settingsRepository = settingsRepository
        )
    }

    /** An Elsevier record as recording leaves it: the local file, its source, no text. */
    private fun elsevierRecord(path: String) = document.copy(
        pdfPath = path,
        fullTextSource = Constants.FULLTEXT_SOURCE_ELSEVIER,
        fullTextFetchedAt = java.util.Date()
    )

    @Test
    fun `a stored Elsevier PDF opens from disk, and the chain is not run`() {
        val pdf = pdfOnDisk()

        val viewModel = open(elsevierRecord(pdf.absolutePath))

        assertEquals(
            FullTextViewModel.FullTextState.PdfContent(pdf.absolutePath, "t", Constants.FULLTEXT_SOURCE_ELSEVIER_LABEL),
            viewModel.state.value
        )
        coVerify(exactly = 0) { fullTextService.fetchFullText(any(), any(), any(), any()) }
        coVerify(exactly = 0) { documentDao.update(any()) }
    }

    /** The control: the file gone, the chain runs, and its answer is what the reader gets. */
    @Test
    fun `a stored Elsevier PDF that is gone runs the chain`() {
        val viewModel = open(elsevierRecord(File(folder.root, "gone.pdf").absolutePath))

        coVerify(exactly = 1) { fullTextService.fetchFullText(any(), any(), any(), any()) }
        val state = viewModel.state.value
        assertFalse("$state", state is FullTextViewModel.FullTextState.PdfContent)
        assertFalse("$state", state is FullTextViewModel.FullTextState.Error)
    }

    /** A file that exists but is not a PDF (empty, or a page) is not opened as the article. */
    @Test
    fun `a stored Elsevier file that is not a PDF runs the chain`() {
        for (content in listOf(ByteArray(0), "<html>sign in</html>".toByteArray())) {
            val file = folder.newFile().apply { writeBytes(content) }

            val viewModel = open(elsevierRecord(file.absolutePath))

            val state = viewModel.state.value
            assertFalse("$state", state is FullTextViewModel.FullTextState.PdfContent)
        }
        coVerify(exactly = 2) { fullTextService.fetchFullText(any(), any(), any(), any()) }
    }

    /** The control: only a record whose source is Elsevier's owns the path it holds. */
    @Test
    fun `a PDF path left under another source is not served from disk`() {
        val pdf = pdfOnDisk()

        open(elsevierRecord(pdf.absolutePath).copy(fullTextSource = Constants.FULLTEXT_SOURCE_DOI))

        coVerify(exactly = 1) { fullTextService.fetchFullText(any(), any(), any(), any()) }
    }

    /** handleFullTextResult's ElsevierPdf branch: the local file, never a link. */
    @Test
    fun `a PDF the chain returns is shown as the local file and recorded`() {
        val pdf = pdfOnDisk()

        val viewModel = open(document, FullTextService.FullTextResult.ElsevierPdf(pdf.absolutePath))

        val state = viewModel.state.value
        assertEquals(
            FullTextViewModel.FullTextState.PdfContent(pdf.absolutePath, "t", Constants.FULLTEXT_SOURCE_ELSEVIER_LABEL),
            state
        )
        assertFalse("$state", state is FullTextViewModel.FullTextState.WebUrl)
        coVerify(exactly = 0) { fullTextService.downloadPdf(any(), any()) }
        coVerify {
            documentDao.update(
                match {
                    it.pdfPath == pdf.absolutePath && it.fullTextSource == Constants.FULLTEXT_SOURCE_ELSEVIER &&
                        it.fullTextPdfNotSavedFrom == null
                }
            )
        }
    }
}
