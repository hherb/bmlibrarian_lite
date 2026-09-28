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
 * The full-text viewer offers a retry when the chain did not establish the
 * absence, and records nothing (#434).
 */
@OptIn(ExperimentalCoroutinesApi::class)
class FullTextViewModelNotEstablishedTest {

    private lateinit var fullTextService: FullTextService
    private lateinit var documentDao: DocumentDao
    private lateinit var settingsRepository: SettingsRepository

    private val document = DocumentEntity(id = "d", sessionId = "s", title = "t", pmcId = "PMC1")

    @Before
    fun setUp() {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        fullTextService = mockk(relaxed = true) {
            every { getCachedPdfPath(any()) } returns null
        }
        documentDao = mockk(relaxed = true) {
            coEvery { getById("d") } returns document
        }
        settingsRepository = mockk(relaxed = true)
        every { settingsRepository.settings } returns MutableStateFlow(AppSettings())
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    /** Opens the viewer on [document] with the chain answering [answer]. */
    private fun open(answer: FullTextService.FullTextResult): FullTextViewModel {
        coEvery { fullTextService.fetchFullText(any(), any(), any(), any()) } returns Result.success(answer)
        return FullTextViewModel(
            savedStateHandle = SavedStateHandle(mapOf(FullTextViewModel.DOCUMENT_ID_KEY to "d")),
            fullTextService = fullTextService,
            documentDao = documentDao,
            settingsRepository = settingsRepository
        )
    }

    @Test
    fun `a chain that did not establish the absence offers a retry and records nothing`() {
        val viewModel = open(
            FullTextService.FullTextResult.NotEstablished(RequestFailure(RequestFailureKind.HTTP_STATUS, 429))
        )

        assertEquals(
            FullTextViewModel.FullTextState.Error(
                message = "No source provided this article's full text. Europe PMC could not be " +
                    "asked (HTTP 429 Too Many Requests), so it may still exist. Try again later.",
                canRetry = true
            ),
            viewModel.state.value
        )
        coVerify(exactly = 0) { documentDao.update(any()) }
    }

    /** The control: without it the test above passes against a viewer that never records. */
    @Test
    fun `a chain that found nothing records the article as unavailable`() {
        val viewModel = open(FullTextService.FullTextResult.Unavailable("No full text source available"))

        assertEquals(
            FullTextViewModel.FullTextState.Unavailable("No full text source available"),
            viewModel.state.value
        )
        coVerify { documentDao.update(match { it.fullTextUnavailable }) }
    }
}
