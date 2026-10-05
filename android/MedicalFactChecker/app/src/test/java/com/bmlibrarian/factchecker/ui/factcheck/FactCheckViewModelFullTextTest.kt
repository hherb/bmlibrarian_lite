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

import com.bmlibrarian.factchecker.data.local.entity.DocumentEntity
import com.bmlibrarian.factchecker.data.remote.fulltext.FullTextService
import com.bmlibrarian.factchecker.data.remote.fulltext.NotEstablishedSource
import com.bmlibrarian.factchecker.data.repository.DocumentRepository
import com.bmlibrarian.factchecker.data.repository.SettingsRepository
import com.bmlibrarian.factchecker.domain.model.AppSettings
import com.bmlibrarian.factchecker.domain.model.OpenAccessShortfall
import com.bmlibrarian.factchecker.domain.model.OpenAccessSource
import com.bmlibrarian.factchecker.domain.model.RequestFailure
import com.bmlibrarian.factchecker.domain.model.RequestFailureKind
import com.bmlibrarian.factchecker.domain.model.RetrievalShortfall
import com.bmlibrarian.factchecker.domain.workflow.FactCheckWorkflow
import com.bmlibrarian.factchecker.domain.workflow.WorkflowProgress
import com.bmlibrarian.factchecker.domain.workflow.WorkflowState
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import io.mockk.slot
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * The fact-check screen records only what the full-text chain established (#434).
 *
 * `NotEstablished` is a claim about us: recording it as `fullTextUnavailable`
 * would take the fetch away for good from an article whose only fault was a
 * busy Europe PMC.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class FactCheckViewModelFullTextTest {

    private lateinit var fullTextService: FullTextService
    private lateinit var documentRepository: DocumentRepository
    private lateinit var viewModel: FactCheckViewModel

    private val document = DocumentEntity(id = "d", sessionId = "s", title = "t", pmcId = "PMC1")

    @Before
    fun setUp() {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        val workflow = mockk<FactCheckWorkflow>(relaxed = true) {
            every { state } returns MutableStateFlow<WorkflowState>(WorkflowState.Idle)
            every { progress } returns MutableStateFlow(WorkflowProgress.idle())
            every { currentSessionId } returns MutableStateFlow(null)
            // Collected at start-up: a relaxed flow's collect returns instead of
            // suspending, and the exception leaks into whichever test runs next
            every { searchShortfalls } returns MutableStateFlow<List<RetrievalShortfall>>(emptyList())
            every { searchFailureMessage } returns MutableStateFlow<String?>(null)
            every { searchRecordDamaged } returns MutableStateFlow(false)
        }
        val settingsRepository = mockk<SettingsRepository>(relaxed = true) {
            every { configurationVersion } returns MutableStateFlow(0)
        }
        every { settingsRepository.settings } returns MutableStateFlow(AppSettings())
        fullTextService = mockk(relaxed = true)
        documentRepository = mockk(relaxed = true)
        viewModel = FactCheckViewModel(
            workflow = workflow,
            settingsRepository = settingsRepository,
            documentRepository = documentRepository,
            usageRepository = mockk(relaxed = true),
            sessionRepository = mockk(relaxed = true),
            fullTextService = fullTextService
        )
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    /** What the chain answers, and what the view model then stored and reported. */
    private fun fetch(
        answer: FullTextService.FullTextResult,
        from: DocumentEntity = document
    ): Pair<DocumentEntity, Boolean?> {
        coEvery { fullTextService.fetchFullText(any(), any(), any(), any()) } returns Result.success(answer)
        val stored = slot<DocumentEntity>()
        coEvery { documentRepository.updateDocument(capture(stored)) } returns Unit
        var reported: Boolean? = null

        viewModel.fetchFullText(from) { reported = it }

        coVerify { documentRepository.updateDocument(any()) }
        return stored.captured to reported
    }

    @Test
    fun `a chain that did not establish the absence records nothing`() {
        val (stored, reported) = fetch(
            FullTextService.FullTextResult.NotEstablished(
                RequestFailure(RequestFailureKind.HTTP_STATUS, 429), NotEstablishedSource.EUROPE_PMC
            )
        )

        assertFalse("the fetch must stay on offer", stored.fullTextUnavailable)
        assertEquals(document, stored)
        assertEquals(false, reported)
    }

    /** The control: without it the test above passes against a view model that never records. */
    @Test
    fun `a chain that found nothing records the article as unavailable`() {
        val (stored, reported) = fetch(FullTextService.FullTextResult.Unavailable("No full text source available"))

        assertTrue(stored.fullTextUnavailable)
        assertEquals(false, reported)
    }

    @Test
    fun `a link to the article is a success`() {
        val (_, reported) = fetch(FullTextService.FullTextResult.DoiUrl("https://doi.org/10.1/x"))

        assertEquals(true, reported)
    }

    /** A link the chain settled on because Unpaywall could not answer keeps why (#466). */
    @Test
    fun `a link left by an unsettled open-access lookup records the shortfall`() {
        val shortfall = OpenAccessShortfall(OpenAccessSource.UNPAYWALL, RequestFailure(RequestFailureKind.TIMEOUT))

        val (stored, _) = fetch(FullTextService.FullTextResult.DoiUrl("https://doi.org/10.1/x", shortfall))

        assertEquals(shortfall, stored.openAccessShortfall)
    }

    /** A later fetch that settled the question clears it, whatever it found. */
    @Test
    fun `a later settled fetch clears the shortfall`() {
        val unsettled = document.copy(
            fullTextOpenAccessShortfallJson = OpenAccessShortfall(
                OpenAccessSource.LANDING_PAGE, RequestFailure(RequestFailureKind.CONNECTION)
            ).toJson()
        )

        val (link, _) = fetch(FullTextService.FullTextResult.DoiUrl("https://doi.org/10.1/x"), from = unsettled)
        val (none, _) = fetch(FullTextService.FullTextResult.Unavailable("No full text source available"), from = unsettled)

        assertEquals(null, link.openAccessShortfall)
        assertEquals(null, none.openAccessShortfall)
    }

    /** A thrown fetch is not an article without full text either. */
    @Test
    fun `a failed fetch records nothing`() {
        coEvery { fullTextService.fetchFullText(any(), any(), any(), any()) } throws IllegalStateException("boom")
        var reported: Boolean? = null

        viewModel.fetchFullText(document) { reported = it }

        coVerify(exactly = 0) { documentRepository.updateDocument(any()) }
        assertEquals(false, reported)
    }
}
