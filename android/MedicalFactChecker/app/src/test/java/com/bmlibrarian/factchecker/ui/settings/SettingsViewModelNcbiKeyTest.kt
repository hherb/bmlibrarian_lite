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

import com.bmlibrarian.factchecker.data.repository.SettingsRepository
import com.bmlibrarian.factchecker.domain.model.AppSettings
import io.mockk.every
import io.mockk.mockk
import io.mockk.verify
import io.mockk.verifyOrder
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
 * The settings screen's NCBI API key (#496): loaded from the repository, saved
 * trimmed, and cleared by saving an empty field, as the CORE key is.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class SettingsViewModelNcbiKeyTest {

    private lateinit var settingsRepository: SettingsRepository

    @Before
    fun setUp() {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        settingsRepository = mockk(relaxed = true) {
            every { settings } returns MutableStateFlow(AppSettings())
            every { isLoaded } returns MutableStateFlow(true)
            every { getApiKey(any()) } returns ""
            every { getNcbiApiKey() } returns ""
            every { getCoreApiKey() } returns ""
        }
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    private fun viewModel() = SettingsViewModel(
        settingsRepository = settingsRepository,
        llmService = mockk(relaxed = true),
        modelFetchService = mockk(relaxed = true),
        database = mockk(relaxed = true)
    )

    @Test
    fun `saving the NCBI key trims it, and an empty field clears it`() {
        val viewModel = viewModel()

        viewModel.updateNcbiApiKeyInput("  k  ")
        viewModel.saveNcbiApiKey()
        assertEquals("NCBI API key saved", viewModel.statusMessage.value)

        viewModel.updateNcbiApiKeyInput("")
        viewModel.saveNcbiApiKey()
        assertEquals("NCBI API key cleared", viewModel.statusMessage.value)

        verifyOrder {
            settingsRepository.saveNcbiApiKey("k")
            settingsRepository.saveNcbiApiKey("")
        }
    }

    /** A field of whitespace alone is no key: it clears, not saves. */
    @Test
    fun `a blank field clears the key`() {
        val viewModel = viewModel()

        viewModel.updateNcbiApiKeyInput("   ")
        viewModel.saveNcbiApiKey()

        verify(exactly = 1) { settingsRepository.saveNcbiApiKey("") }
    }

    @Test
    fun `the saved key is shown in the field`() {
        every { settingsRepository.getNcbiApiKey() } returns "stored"

        assertEquals("stored", viewModel().ncbiApiKeyInput.value)
    }
}
