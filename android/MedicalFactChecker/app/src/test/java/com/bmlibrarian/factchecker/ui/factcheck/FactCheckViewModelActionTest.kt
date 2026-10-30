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

package com.bmlibrarian.factchecker.ui.factcheck

import android.net.Uri
import com.bmlibrarian.factchecker.data.local.entity.DocumentEntity
import com.bmlibrarian.factchecker.data.remote.fulltext.FullTextUpload
import com.bmlibrarian.factchecker.data.remote.fulltext.FullTextUploadContent
import com.bmlibrarian.factchecker.data.remote.fulltext.FullTextUploadException
import com.bmlibrarian.factchecker.data.repository.DocumentRepository
import com.bmlibrarian.factchecker.data.repository.SettingsRepository
import com.bmlibrarian.factchecker.domain.model.AppSettings
import com.bmlibrarian.factchecker.domain.model.RetrievalShortfall
import com.bmlibrarian.factchecker.domain.workflow.FactCheckWorkflow
import com.bmlibrarian.factchecker.domain.workflow.WorkflowProgress
import com.bmlibrarian.factchecker.domain.workflow.WorkflowState
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import io.mockk.verify
import java.io.IOException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test

/**
 * What the reader is told about an action they took on the fact-check screen
 * (an upload, a retry), and that a second tap does not start a second run.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class FactCheckViewModelActionTest {

    private val workflowState = MutableStateFlow<WorkflowState>(WorkflowState.Completed(reportId = "r"))
    private lateinit var workflow: FactCheckWorkflow
    private lateinit var fullTextUpload: FullTextUpload
    private lateinit var documentRepository: DocumentRepository
    private lateinit var viewModel: FactCheckViewModel

    private val document = DocumentEntity(id = "d", sessionId = "s", title = "t")
    private val uri = mockk<Uri>()

    @Before
    fun setUp() {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        workflow = mockk(relaxed = true) {
            every { state } returns workflowState
            every { progress } returns MutableStateFlow(WorkflowProgress.idle())
            every { currentSessionId } returns MutableStateFlow(null)
            every { searchShortfalls } returns MutableStateFlow<List<RetrievalShortfall>>(emptyList())
            every { searchFailureMessage } returns MutableStateFlow<String?>(null)
            every { searchRecordDamaged } returns MutableStateFlow(false)
            every { smartSearchNotice } returns MutableStateFlow(null)
            every { fullTextNotice } returns MutableStateFlow(null)
            every { retractionNotice } returns MutableStateFlow(null)
            every { retractionSavedWorkLine } returns MutableStateFlow(null)
            every { retractionSavedWorkWarning } returns MutableStateFlow(null)
            every { retractionCurrentChecks } returns MutableStateFlow(emptyMap())
            every { isCheckingRetractionsAgain } returns MutableStateFlow(false)
        }
        val settingsRepository = mockk<SettingsRepository>(relaxed = true) {
            every { configurationVersion } returns MutableStateFlow(0)
            every { settings } returns MutableStateFlow(AppSettings())
        }
        fullTextUpload = mockk(relaxed = true)
        documentRepository = mockk(relaxed = true) {
            coEvery { getDocument("d") } returns document
        }
        viewModel = FactCheckViewModel(
            workflow = workflow,
            settingsRepository = settingsRepository,
            documentRepository = documentRepository,
            usageRepository = mockk(relaxed = true),
            sessionRepository = mockk(relaxed = true),
            fullTextService = mockk(relaxed = true),
            fullTextUpload = fullTextUpload
        )
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    @Test
    fun `a refused upload is told, and stays told while the run goes on`() {
        coEvery { fullTextUpload.read(uri, "d", any(), any()) } throws
            FullTextUploadException(FullTextUpload.UNSUPPORTED_MESSAGE)

        viewModel.uploadFullText(document, uri)
        workflowState.value = WorkflowState.ExtractingCitations(1, 3)

        assertEquals(FullTextUpload.UNSUPPORTED_MESSAGE, viewModel.uiState.value.actionMessage)
        assertNull(viewModel.uiState.value.uploadingFullTextDocumentId)
        coVerify(exactly = 0) { documentRepository.updateDocument(any()) }

        viewModel.dismissActionMessage()
        assertNull(viewModel.uiState.value.actionMessage)
    }

    @Test
    fun `a PDF stored without text is told, so the reader knows the abstract is still read`() {
        coEvery { fullTextUpload.read(uri, "d", any(), any()) } returns FullTextUploadContent.Pdf("/files/u.pdf", text = null)

        viewModel.uploadFullText(document, uri)

        coVerify(exactly = 1) { documentRepository.updateDocument(match { it.pdfPath == "/files/u.pdf" }) }
        assertEquals(FullTextUpload.PDF_WITHOUT_TEXT_MESSAGE, viewModel.uiState.value.actionMessage)
    }

    /** The control: a PDF with text tells nothing. */
    @Test
    fun `a PDF stored with text tells nothing`() {
        coEvery { fullTextUpload.read(uri, "d", any(), any()) } returns FullTextUploadContent.Pdf("/files/u.pdf", text = "Prose.")

        viewModel.uploadFullText(document, uri)

        assertNull(viewModel.uiState.value.actionMessage)
    }

    @Test
    fun `a second tap on retry while the first runs starts nothing`() {
        val running = CompletableDeferred<Unit>()
        coEvery { workflow.retryFullTextRetrieval(any()) } coAnswers { running.await() }

        viewModel.retryFullText()
        viewModel.retryFullText()
        running.complete(Unit)

        coVerify(exactly = 1) { workflow.retryFullTextRetrieval(any()) }
    }

    @Test
    fun `a second tap on the fetch-more decision while the first runs starts nothing`() {
        workflowState.value = WorkflowState.AwaitingUserDecision(relevantCount = 1, targetCount = 5, availableCount = 0)
        val running = CompletableDeferred<Unit>()
        coEvery { workflow.continueWithMoreDocuments() } coAnswers { running.await() }

        viewModel.fetchMoreDocuments()
        viewModel.fetchMoreDocuments()
        viewModel.skipMoreDocuments()
        running.complete(Unit)

        coVerify(exactly = 1) { workflow.continueWithMoreDocuments() }
        coVerify(exactly = 0) { workflow.proceedWithCurrentDocuments() }
    }

    /** Cancel ends the run by cancelling it, which is no failure to tell (#659). */
    @Test
    fun `a cancelled run is not told as a failure`() {
        coEvery { workflow.startFactCheck(any(), any()) } throws CancellationException("cancelled")
        coEvery { workflow.continueWithMoreDocuments() } throws CancellationException("cancelled")
        coEvery { workflow.proceedWithCurrentDocuments() } throws CancellationException("cancelled")
        viewModel.updateClaimText("Aspirin prevents strokes")

        viewModel.startFactCheck()
        viewModel.fetchMoreDocuments()
        viewModel.skipMoreDocuments()

        coVerify(exactly = 1) { workflow.startFactCheck(any(), any()) }
        coVerify(exactly = 1) { workflow.continueWithMoreDocuments() }
        coVerify(exactly = 1) { workflow.proceedWithCurrentDocuments() }
        assertNull(viewModel.uiState.value.errorMessage)
        assertFalse(viewModel.uiState.value.isRunning)
    }

    @Test
    fun `a retry that changed nothing in the workflow's state leaves the screen idle`() {
        viewModel.retryFullText()

        coVerify(exactly = 1) { workflow.retryFullTextRetrieval(any()) }
        assertFalse(viewModel.uiState.value.isRunning)
    }

    @Test
    fun `a retry that throws is told`() {
        coEvery { workflow.retryFullTextRetrieval(any()) } throws IllegalStateException("No active session")

        viewModel.retryFullText()

        assertEquals("No active session", viewModel.uiState.value.actionMessage)
        assertFalse(viewModel.uiState.value.isRunning)
    }

    /** Check again's Cancel stops only it: a tap landing after it ends never cancels the session. */
    @Test
    fun `Check again's Cancel never reaches the workflow's`() {
        viewModel.cancelCheckAgain()

        verify(exactly = 1) { workflow.cancelCheckAgain() }
        coVerify(exactly = 0) { workflow.cancel(any()) }
    }

    @Test
    fun `a Check again that cannot read the store is told`() {
        coEvery { workflow.checkRetractionsAgain() } throws IOException("disk")

        viewModel.checkRetractionsAgain()

        assertEquals("disk", viewModel.uiState.value.errorMessage)
    }
}
