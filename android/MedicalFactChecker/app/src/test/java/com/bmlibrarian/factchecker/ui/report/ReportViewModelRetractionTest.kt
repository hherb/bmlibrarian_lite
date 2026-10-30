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

package com.bmlibrarian.factchecker.ui.report

import com.bmlibrarian.factchecker.data.local.entity.DocumentEntity
import com.bmlibrarian.factchecker.data.local.entity.SessionEntity
import com.bmlibrarian.factchecker.data.repository.DocumentRepository
import com.bmlibrarian.factchecker.data.repository.SessionRepository
import com.bmlibrarian.factchecker.data.repository.SettingsRepository
import com.bmlibrarian.factchecker.domain.model.AppSettings
import com.bmlibrarian.factchecker.domain.model.SearchProvider
import com.bmlibrarian.factchecker.domain.model.WorkflowStep
import com.bmlibrarian.factchecker.ui.report.components.ReferenceInfo
import com.bmlibrarian.factchecker.util.retraction.PaperRetractionCheck
import com.bmlibrarian.factchecker.util.retraction.RetractionService
import com.bmlibrarian.factchecker.util.retraction.RetractionSnapshot
import com.bmlibrarian.factchecker.util.retraction.StoredRetractionEvidence
import io.mockk.coEvery
import io.mockk.every
import io.mockk.mockk
import java.io.IOException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * The report's document sheet shows the paper's retraction check: the run's,
 * or a newer stored row; nothing while it loads, and "could not be read"
 * rather than "never checked" when it cannot be read. The paper carries a PMID
 * only, so its key needs no native library.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class ReportViewModelRetractionTest {

    private lateinit var retractionService: RetractionService
    private lateinit var sessionRepository: SessionRepository

    /** Each paper's stored row, by key. */
    private val rows = mutableMapOf<String, String>()

    private var snapshotJson: String? = null

    private val document = DocumentEntity(id = "d1", sessionId = "s", pmid = "1", title = "Study d1")

    @Before
    fun setUp() {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        retractionService = mockk {
            coEvery { storedChecks(any()) } answers {
                firstArg<Collection<String>>().mapNotNull { key -> rows[key]?.let { key to it } }.toMap()
            }
        }
        sessionRepository = mockk(relaxed = true) {
            coEvery { getSession("s") } answers {
                SessionEntity(
                    id = "s", claimText = "Aspirin prevents strokes", pubmedQuery = "aspirin",
                    workflowStep = WorkflowStep.COMPLETED, searchProvider = SearchProvider.PUBMED,
                    retractionSnapshotJson = snapshotJson
                )
            }
        }
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    /** Opens the report and the document's sheet. */
    private fun open(): ReportViewModel {
        val documentRepository = mockk<DocumentRepository>(relaxed = true) {
            every { getScoredDocumentsBySession("s") } returns flowOf(listOf(document))
        }
        val settingsRepository = mockk<SettingsRepository>(relaxed = true) {
            every { settings } returns MutableStateFlow(AppSettings())
        }
        val viewModel = ReportViewModel(
            sessionRepository = sessionRepository,
            reportRepository = mockk(relaxed = true),
            documentRepository = documentRepository,
            fullTextService = mockk(relaxed = true),
            settingsRepository = settingsRepository,
            pdfExporter = mockk(relaxed = true),
            retractionService = retractionService
        )
        viewModel.loadReport("s")
        viewModel.onReferenceClick(ReferenceInfo(documentId = "d1", displayText = "[1]"))
        return viewModel
    }

    private fun ran(check: PaperRetractionCheck) {
        snapshotJson = RetractionSnapshot.merged(null, mapOf("d1" to check))
    }

    @Test
    fun `the sheet shows the run's check`() {
        ran(CLEAR)

        val state = open().uiState.value

        assertTrue(state.selectedRetractionCheck!!.isClear)
        assertFalse(state.isLoadingRetractionCheck)
        assertFalse(state.isRetractionCheckUnread)
    }

    @Test
    fun `a newer stored retraction replaces the run's clear check`() {
        ran(CLEAR)
        rows["pmid:1"] = PaperRetractionCheck.encode(RETRACTED.copy(checkedAtMs = RUN_MS + 1))

        assertTrue(open().uiState.value.selectedRetractionCheck!!.isRetracted)
    }

    @Test
    fun `a newer unchecked row never replaces the run's decided check`() {
        ran(CLEAR)
        rows["pmid:1"] = PaperRetractionCheck.encode(OUTAGE.copy(checkedAtMs = RUN_MS + 1))

        assertTrue("an outage is not knowledge", open().uiState.value.selectedRetractionCheck!!.isClear)
    }

    @Test
    fun `a session from before the check reads the stored row alone`() {
        rows["pmid:1"] = PaperRetractionCheck.encode(RETRACTED)

        assertTrue(open().uiState.value.selectedRetractionCheck!!.isRetracted)
    }

    @Test
    fun `a paper never checked is null and not unread`() {
        val state = open().uiState.value

        assertNull(state.selectedRetractionCheck)
        assertFalse("it was read: it is never checked", state.isRetractionCheckUnread)
    }

    @Test
    fun `a stored row that cannot be read leaves the run's check, said as unread`() {
        ran(CLEAR)
        coEvery { retractionService.storedChecks(any()) } throws IOException("disk")

        val state = open().uiState.value

        assertTrue(state.selectedRetractionCheck!!.isClear)
        assertTrue(state.isRetractionCheckUnread)
    }

    /** Not knowing is not absence: without the run's check, an unreadable row is never "never checked". */
    @Test
    fun `nothing readable is unread, not never checked`() {
        coEvery { retractionService.storedChecks(any()) } throws IOException("disk")

        val state = open().uiState.value

        assertNull(state.selectedRetractionCheck)
        assertTrue(state.isRetractionCheckUnread)
    }

    @Test
    fun `a stored row that does not decode is unread`() {
        rows["pmid:1"] = "{not json"

        val state = open().uiState.value

        assertNull(state.selectedRetractionCheck)
        assertTrue(state.isRetractionCheckUnread)
    }

    @Test
    fun `the sheet says nothing while the check loads, and dismissing clears it`() {
        ran(CLEAR)
        val gate = CompletableDeferred<Unit>()
        coEvery { retractionService.storedChecks(any()) } coAnswers { gate.await(); emptyMap() }

        val viewModel = open()
        assertTrue(viewModel.uiState.value.isLoadingRetractionCheck)
        assertNull(viewModel.uiState.value.selectedRetractionCheck)
        gate.complete(Unit)
        assertFalse(viewModel.uiState.value.isLoadingRetractionCheck)
        assertTrue(viewModel.uiState.value.selectedRetractionCheck!!.isClear)

        viewModel.dismissDocumentSheet()

        assertNull(viewModel.uiState.value.selectedRetractionCheck)
        assertFalse(viewModel.uiState.value.isLoadingRetractionCheck)
    }

    private companion object {
        const val RUN_MS = 1_792_315_800_000L // 2026-10-18 09:30 UTC
        val NOTICE = StoredRetractionEvidence("retraction_watch_export", "retraction", "2026-03-09", "10.9/n")
        val CLEAR = PaperRetractionCheck("clear", checkedAtMs = RUN_MS, exportDataAsOf = "2026-10-01")
        val RETRACTED = PaperRetractionCheck("retracted", NOTICE, checkedAtMs = RUN_MS, exportDataAsOf = "2026-10-01")
        val OUTAGE = PaperRetractionCheck(
            "unchecked", unanswered = listOf("crossref"), checkedAtMs = RUN_MS, exportDataAsOf = "2026-10-01", crossrefFailure = "HTTP 503"
        )
    }
}
