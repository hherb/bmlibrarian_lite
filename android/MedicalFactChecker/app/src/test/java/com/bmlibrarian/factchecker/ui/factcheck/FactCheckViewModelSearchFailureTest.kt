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

package com.bmlibrarian.factchecker.ui.factcheck

import com.bmlibrarian.factchecker.data.repository.SettingsRepository
import com.bmlibrarian.factchecker.domain.model.RequestFailure
import com.bmlibrarian.factchecker.domain.model.RequestFailureKind
import com.bmlibrarian.factchecker.domain.model.RetrievalShortfall
import com.bmlibrarian.factchecker.domain.model.SearchProvider
import com.bmlibrarian.factchecker.domain.workflow.FactCheckWorkflow
import com.bmlibrarian.factchecker.domain.workflow.WorkflowProgress
import com.bmlibrarian.factchecker.domain.workflow.WorkflowState
import io.mockk.every
import io.mockk.mockk
import io.mockk.verify
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
 * The fact-check screen hears what the workflow's searches failed to retrieve (#252).
 *
 * The warning's wording is [FactCheckUiStateTest]'s; this checks that the
 * workflow's state reaches the screen at all, and that dismissing reaches back.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class FactCheckViewModelSearchFailureTest {

    private val shortfalls = MutableStateFlow<List<RetrievalShortfall>>(emptyList())
    private val failureMessage = MutableStateFlow<String?>(null)
    private val recordDamaged = MutableStateFlow(false)
    private lateinit var workflow: FactCheckWorkflow
    private lateinit var viewModel: FactCheckViewModel

    @Before
    fun setUp() {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        workflow = mockk(relaxed = true) {
            every { state } returns MutableStateFlow<WorkflowState>(WorkflowState.Idle)
            every { progress } returns MutableStateFlow(WorkflowProgress.idle())
            every { currentSessionId } returns MutableStateFlow(null)
            every { searchShortfalls } returns shortfalls
            every { searchFailureMessage } returns failureMessage
            every { searchRecordDamaged } returns recordDamaged
        }
        val settingsRepository = mockk<SettingsRepository>(relaxed = true) {
            every { configurationVersion } returns MutableStateFlow(0)
        }
        viewModel = FactCheckViewModel(
            workflow = workflow,
            settingsRepository = settingsRepository,
            documentRepository = mockk(relaxed = true),
            usageRepository = mockk(relaxed = true),
            sessionRepository = mockk(relaxed = true),
            fullTextService = mockk(relaxed = true)
        )
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    @Test
    fun `what the searches failed to retrieve reaches the screen as its warning`() {
        shortfalls.value = listOf(RetrievalShortfall(SearchProvider.PUBMED, RequestFailure(RequestFailureKind.HTTP_STATUS, 429)))

        assertEquals(
            "Incomplete search: PubMed could not be searched (HTTP 429 Too Many Requests).",
            viewModel.uiState.value.incompleteSearchWarning
        )
    }

    @Test
    fun `why a search failed reaches the screen`() {
        failureMessage.value = "The search could not be completed: PubMed could not be searched (the request timed out)."

        assertEquals(failureMessage.value, viewModel.uiState.value.searchFailureMessage)
    }

    @Test
    fun `a damaged record of shortfalls reaches the screen as its warning`() {
        recordDamaged.value = true

        assertTrue(
            "got ${viewModel.uiState.value.incompleteSearchWarning}",
            viewModel.uiState.value.incompleteSearchWarning.orEmpty().startsWith("This session's record")
        )
    }

    @Test
    fun `dismissing why a search failed asks the workflow to stop showing it`() {
        viewModel.dismissSearchFailure()

        verify { workflow.dismissSearchFailure() }
    }
}
