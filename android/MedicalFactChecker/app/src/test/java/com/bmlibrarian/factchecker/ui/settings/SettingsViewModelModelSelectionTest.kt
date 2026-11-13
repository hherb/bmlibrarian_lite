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

package com.bmlibrarian.factchecker.ui.settings

import com.bmlibrarian.factchecker.data.remote.llm.ModelFetchService
import com.bmlibrarian.factchecker.data.repository.SettingsRepository
import com.bmlibrarian.factchecker.domain.model.AppSettings
import com.bmlibrarian.factchecker.domain.model.LLMProvider
import com.bmlibrarian.factchecker.domain.model.ModelInfo
import io.mockk.coEvery
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
 * A fetched model list replaces a retired selection (#758): for Anthropic with the
 * newest Sonnet, for other providers with their default if listed.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class SettingsViewModelModelSelectionTest {

    /** Anthropic's live list on 2026-11-13, sorted as the fetch sorts it (newest first). */
    private val liveAnthropicIds = listOf(
        "claude-fable-5-2", "claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5",
        "claude-fable-5-1", "claude-opus-5", "claude-sonnet-5", "claude-fable-5",
        "claude-opus-4-8", "claude-opus-4-7", "claude-sonnet-4-6", "claude-opus-4-6",
        "claude-opus-4-5-20251101", "claude-haiku-4-5-20251001", "claude-sonnet-4-5-20250929"
    ).sortedDescending()

    private fun models(ids: List<String>) = ids.map { ModelInfo(it, it, 0.0, 0.0) }

    private lateinit var settingsRepository: SettingsRepository
    private lateinit var modelFetchService: ModelFetchService

    @Before
    fun setUp() {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        modelFetchService = mockk(relaxed = true)
        coEvery { modelFetchService.fetchModels(any(), any(), any()) } returns models(liveAnthropicIds)
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    private fun viewModelWithAnthropicSelection(modelId: String): SettingsViewModel {
        settingsRepository = mockk(relaxed = true) {
            every { settings } returns MutableStateFlow(
                AppSettings(llmProviderId = LLMProvider.ANTHROPIC.id, modelId = modelId)
            )
            every { isLoaded } returns MutableStateFlow(true)
            every { getApiKey(any()) } returns "k"
        }
        return SettingsViewModel(
            settingsRepository = settingsRepository,
            llmService = mockk(relaxed = true),
            modelFetchService = modelFetchService,
            database = mockk(relaxed = true)
        )
    }

    @Test
    fun `a fetch moves a retired Claude selection to the newest Sonnet`() {
        viewModelWithAnthropicSelection("claude-sonnet-4-20250514").fetchModels()

        verify(exactly = 1) { settingsRepository.setLlmModel("claude-sonnet-5-5") }
    }

    @Test
    fun `a fetch keeps a Claude selection that is still listed`() {
        viewModelWithAnthropicSelection("claude-opus-4-7").fetchModels()

        verify(exactly = 0) { settingsRepository.setLlmModel(any()) }
    }

    @Test
    fun `a retired Anthropic selection moves to the newest Sonnet, not the hard-coded default`() {
        // The default, Sonnet 4.5, is still listed: older and dearer than Sonnet 5.5.
        assertTrue(LLMProvider.ANTHROPIC.defaultModel in liveAnthropicIds)
        assertEquals(
            "claude-sonnet-5-5",
            SettingsViewModel.retiredSelectionReplacement(LLMProvider.ANTHROPIC, models(liveAnthropicIds))
        )
        // Nor by alphabet: a family sorting after "sonnet" would lead the list.
        val later = listOf("claude-zeta-1") + liveAnthropicIds
        assertEquals(
            "claude-sonnet-5-5",
            SettingsViewModel.retiredSelectionReplacement(LLMProvider.ANTHROPIC, models(later))
        )
    }

    @Test
    fun `a list with no Sonnet falls back to the default, then the first model`() {
        val noSonnet = liveAnthropicIds.filterNot { it.contains("sonnet") }
        assertEquals(
            noSonnet.first(),
            SettingsViewModel.retiredSelectionReplacement(LLMProvider.ANTHROPIC, models(noSonnet))
        )
        // control: other providers keep their default rule
        assertEquals(
            "deepseek-v4-flash",
            SettingsViewModel.retiredSelectionReplacement(
                LLMProvider.DEEPSEEK, models(listOf("deepseek-v4-pro", "deepseek-v4-flash"))
            )
        )
    }
}
