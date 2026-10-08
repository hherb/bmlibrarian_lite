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
import com.bmlibrarian.factchecker.util.Constants
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
 * The settings screen's Elsevier API key and institutional token (#480, stage
 * C2): loaded from the repository, saved trimmed, cleared by saving an empty
 * field, a failed write told as such, and both emptied by a reset, as CORE's
 * key is.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class SettingsViewModelElsevierKeyTest {

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
            every { getElsevierApiKey() } returns ""
            every { getElsevierInstToken() } returns ""
            every { saveElsevierApiKey(any()) } returns true
            every { saveElsevierInstToken(any()) } returns true
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
    fun `saving the key and the token trims them, and an empty field clears each`() {
        val viewModel = viewModel()

        viewModel.updateElsevierApiKeyInput("  k  ")
        viewModel.saveElsevierApiKey()
        assertEquals("Elsevier API key saved", viewModel.statusMessage.value)
        viewModel.updateElsevierInstTokenInput("\tt\n")
        viewModel.saveElsevierInstToken()
        assertEquals("Elsevier institutional token saved", viewModel.statusMessage.value)

        viewModel.updateElsevierApiKeyInput("   ")
        viewModel.saveElsevierApiKey()
        assertEquals("Elsevier API key cleared", viewModel.statusMessage.value)
        viewModel.updateElsevierInstTokenInput("")
        viewModel.saveElsevierInstToken()
        assertEquals("Elsevier institutional token cleared", viewModel.statusMessage.value)

        verifyOrder {
            settingsRepository.saveElsevierApiKey("k")
            settingsRepository.saveElsevierInstToken("t")
            settingsRepository.saveElsevierApiKey("")
            settingsRepository.saveElsevierInstToken("")
        }
    }

    @Test
    fun `the saved key and token are shown in their fields`() {
        every { settingsRepository.getElsevierApiKey() } returns "stored-key"
        every { settingsRepository.getElsevierInstToken() } returns "stored-token"

        val viewModel = viewModel()

        assertEquals("stored-key", viewModel.elsevierApiKeyInput.value)
        assertEquals("stored-token", viewModel.elsevierInstTokenInput.value)
    }

    @Test
    fun `typing changes the fields and saves nothing`() {
        val viewModel = viewModel()

        viewModel.updateElsevierApiKeyInput("typed-key")
        viewModel.updateElsevierInstTokenInput("typed-token")

        assertEquals("typed-key", viewModel.elsevierApiKeyInput.value)
        assertEquals("typed-token", viewModel.elsevierInstTokenInput.value)
        verify(exactly = 0) { settingsRepository.saveElsevierApiKey(any()) }
        verify(exactly = 0) { settingsRepository.saveElsevierInstToken(any()) }
    }

    /** A reset clears both, with every other key, in the repository and on screen. */
    @Test
    fun `a reset to defaults empties both fields`() {
        every { settingsRepository.getElsevierApiKey() } returns "stored-key"
        every { settingsRepository.getElsevierInstToken() } returns "stored-token"
        val viewModel = viewModel()

        viewModel.resetToDefaults()

        verify(exactly = 1) { settingsRepository.resetToDefaults() }
        assertEquals("", viewModel.elsevierApiKeyInput.value)
        assertEquals("", viewModel.elsevierInstTokenInput.value)
    }

    /** A write that fails is told as such, never as saved (the repository logs why, never the key). */
    @Test
    fun `a failed save is told, never as saved`() {
        every { settingsRepository.saveElsevierApiKey(any()) } returns false
        every { settingsRepository.saveElsevierInstToken(any()) } returns false
        val viewModel = viewModel()

        viewModel.updateElsevierApiKeyInput("k")
        viewModel.saveElsevierApiKey()
        assertEquals("Elsevier API key could not be saved; the key in use is unchanged", viewModel.statusMessage.value)

        viewModel.updateElsevierInstTokenInput("t")
        viewModel.saveElsevierInstToken()
        assertEquals(
            "Elsevier institutional token could not be saved; the key in use is unchanged",
            viewModel.statusMessage.value
        )

        viewModel.updateElsevierApiKeyInput("")
        viewModel.saveElsevierApiKey()
        assertEquals(
            "Elsevier API key could not be cleared; the key in use is unchanged",
            viewModel.statusMessage.value
        )
    }

    /** The explanations, verbatim on every platform. */
    @Test
    fun `the explanations are the shared words`() {
        assertEquals(
            "Optional. A free Elsevier API key (dev.elsevier.com) lets the app download the PDFs of Elsevier " +
                "articles you are entitled to: open-access articles anywhere, subscribed ones from your " +
                "institution's network.",
            Constants.ELSEVIER_API_KEY_EXPLANATION
        )
        assertEquals(
            "Optional. An institutional token from Elsevier lets the key use your institution's subscriptions " +
                "away from its network.",
            Constants.ELSEVIER_INSTTOKEN_EXPLANATION
        )
    }
}
