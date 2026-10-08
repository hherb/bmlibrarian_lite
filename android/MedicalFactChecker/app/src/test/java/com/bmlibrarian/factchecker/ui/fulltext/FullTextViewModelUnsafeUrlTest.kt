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
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * No URL that could run script reaches the viewer's JavaScript-enabled WebView
 * (#495), whatever the HTML's route: stored by a build before #495, whose links
 * were written for any scheme and are never re-fetched, or freshly rendered.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class FullTextViewModelUnsafeUrlTest {

    private lateinit var fullTextService: FullTextService
    private lateinit var documentDao: DocumentDao
    private lateinit var settingsRepository: SettingsRepository

    /** A page as builds before #495 stored it: a live javascript: link, an unsafe figure, a safe link. */
    private val storedHtml = "<p>See <a href=\"javascript:alert(document.cookie)\">the trial</a> and " +
        "<a href=\"https://doi.org/10.1/x\">its record</a>.</p>" +
        "<figure><img src=\"&#106;avascript:alert(1)\" alt=\"Figure 1\"></figure>"

    @Before
    fun setUp() {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        fullTextService = mockk(relaxed = true) {
            every { getCachedPdfPath(any()) } returns null
            coEvery { askCore(any()) } returns null
        }
        documentDao = mockk(relaxed = true)
        settingsRepository = mockk(relaxed = true)
        every { settingsRepository.settings } returns MutableStateFlow(AppSettings())
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    /** Opens the viewer on [stored], the chain answering [answer] if it is asked. */
    private fun open(stored: DocumentEntity, answer: FullTextService.FullTextResult? = null): FullTextViewModel {
        coEvery { documentDao.getById("d") } returns stored
        if (answer != null) {
            coEvery { fullTextService.fetchFullText(any(), any(), any(), any()) } returns Result.success(answer)
        }
        return FullTextViewModel(
            savedStateHandle = SavedStateHandle(mapOf(FullTextViewModel.DOCUMENT_ID_KEY to "d")),
            fullTextService = fullTextService,
            documentDao = documentDao,
            settingsRepository = settingsRepository
        )
    }

    /** The page the viewer would load, asserting it is the HTML viewer's. */
    private fun shownHtml(viewModel: FullTextViewModel): String {
        val state = viewModel.state.value
        assertTrue("$state", state is FullTextViewModel.FullTextState.HtmlContent)
        return (state as FullTextViewModel.FullTextState.HtmlContent).html
    }

    /** Asserts [html] holds no unsafe URL and keeps the article's text and safe link. */
    private fun assertNeutralised(html: String) {
        assertFalse(html, "javascript:alert" in html)
        assertFalse(html, "&#106;avascript" in html)
        assertTrue(html, "<a>the trial</a>" in html)
        assertTrue(html, "<a href=\"https://doi.org/10.1/x\">its record</a>" in html)
        assertTrue(html, "<img alt=\"Figure 1\">" in html)
    }

    @Test
    fun `stored HTML from before the escaping is neutralised on the way to the WebView`() {
        val stored = DocumentEntity(
            id = "d", sessionId = "s", title = "t", doi = "10.1/x",
            fullTextHTML = storedHtml,
            fullTextMarkdown = "See the trial.",
            fullTextSource = Constants.FULLTEXT_SOURCE_EUROPE_PMC
        )

        assertNeutralised(shownHtml(open(stored)))
    }

    @Test
    fun `a fresh render is neutralised too`() {
        val stored = DocumentEntity(id = "d", sessionId = "s", title = "t", doi = "10.1/x")

        val viewModel = open(stored, FullTextService.FullTextResult.EuropePmcXml("<article/>", "See the trial.", storedHtml))

        assertNeutralised(shownHtml(viewModel))
    }
}
