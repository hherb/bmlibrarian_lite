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

package com.bmlibrarian.factchecker

import com.bmlibrarian.factchecker.domain.model.AppSettings
import com.bmlibrarian.factchecker.domain.model.LLMProvider
import com.bmlibrarian.factchecker.domain.model.SearchProvider
import com.bmlibrarian.factchecker.util.Constants
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for SettingsRepository.
 *
 * Note: Full integration tests requiring Android context (SharedPreferences,
 * EncryptedSharedPreferences) are in androidTest. These tests verify the
 * logic that doesn't require Android dependencies.
 */
class SettingsRepositoryTest {

    // ==================== Default Values Tests ====================

    @Test
    fun `default LLM provider is OpenAI`() {
        // SettingsRepository defaults to OpenAI when no value is stored
        val expectedDefault = "openai"
        assertEquals(expectedDefault, LLMProvider.OPENAI.id)
    }

    @Test
    fun `default LLM model is GPT-4o`() {
        // SettingsRepository defaults to GPT-4o for OpenAI
        val expectedDefault = "gpt-4o"
        assertEquals(expectedDefault, LLMProvider.OPENAI.defaultModel)
    }

    @Test
    fun `default budget values match Constants`() {
        // Default max run budget: $0.50
        assertEquals(0.50f, Constants.DEFAULT_MAX_RUN_BUDGET_USD, 0.001f)

        // Default monthly budget: $10.00
        assertEquals(10.00f, Constants.DEFAULT_MONTHLY_BUDGET_USD, 0.001f)
    }

    @Test
    fun `default search provider is PubMed`() {
        assertEquals(SearchProvider.PUBMED, AppSettings.DEFAULT.searchProvider)
    }

    @Test
    fun `default batch size is 20`() {
        assertEquals(AppSettings.DEFAULT_BATCH_SIZE, AppSettings.DEFAULT.batchSize)
        assertEquals(20, AppSettings.DEFAULT_BATCH_SIZE)
    }

    @Test
    fun `default relevance threshold is 3`() {
        assertEquals(Constants.SCORING_MIN_RELEVANT_SCORE, AppSettings.DEFAULT.relevanceThreshold)
    }

    // ==================== AppSettings Validation Tests ====================

    @Test
    fun `AppSettings validates correctly for valid settings`() {
        val settings = AppSettings.DEFAULT
        assertTrue(settings.validate().isEmpty())
    }

    @Test
    fun `AppSettings detects invalid batch size`() {
        val settings = AppSettings(batchSize = 1) // Below minimum
        assertFalse(settings.validate().isEmpty())
    }

    @Test
    fun `AppSettings detects invalid relevance threshold`() {
        val settings = AppSettings(relevanceThreshold = 10) // Above maximum
        assertFalse(settings.validate().isEmpty())
    }

    @Test
    fun `AppSettings detects budget mismatch`() {
        val settings = AppSettings(
            maxRunBudgetUsd = 20.0,
            monthlyBudgetUsd = 10.0
        )
        assertTrue(settings.validate().any { it.contains("cannot exceed") })
    }

    // ==================== Provider Configuration Tests ====================

    @Test
    fun `all providers have valid default models`() {
        LLMProvider.ALL_PROVIDERS.forEach { provider ->
            if (provider.models.isNotEmpty()) {
                val defaultModel = provider.models.find { it.id == provider.defaultModel }
                assertTrue(
                    "Provider ${provider.id} should have valid default model",
                    defaultModel != null || provider.id == "custom"
                )
            }
        }
    }

    @Test
    fun `Ollama provider does not require API key`() {
        assertFalse(LLMProvider.OLLAMA.requiresApiKey)
    }

    @Test
    fun `cloud providers require API keys`() {
        assertTrue(LLMProvider.OPENAI.requiresApiKey)
        assertTrue(LLMProvider.ANTHROPIC.requiresApiKey)
        assertTrue(LLMProvider.DEEPSEEK.requiresApiKey)
        assertTrue(LLMProvider.GROQ.requiresApiKey)
        assertTrue(LLMProvider.MISTRAL.requiresApiKey)
    }

    // ==================== Search Provider Tests ====================

    @Test
    fun `SearchProvider fromString parses correctly`() {
        assertEquals(SearchProvider.PUBMED, SearchProvider.fromString("pubmed"))
        assertEquals(SearchProvider.EUROPE_PMC, SearchProvider.fromString("europe pmc"))
        assertEquals(SearchProvider.EUROPE_PMC, SearchProvider.fromString("europepmc"))
        assertEquals(SearchProvider.BOTH, SearchProvider.fromString("both"))
    }

    @Test
    fun `SearchProvider fromString returns PUBMED for invalid input`() {
        assertEquals(SearchProvider.PUBMED, SearchProvider.fromString("invalid"))
    }

    @Test
    fun `SearchProvider includesPubMed returns correct values`() {
        assertTrue(SearchProvider.PUBMED.includesPubMed())
        assertFalse(SearchProvider.EUROPE_PMC.includesPubMed())
        assertTrue(SearchProvider.BOTH.includesPubMed())
    }

    @Test
    fun `SearchProvider includesEuropePMC returns correct values`() {
        assertFalse(SearchProvider.PUBMED.includesEuropePMC())
        assertTrue(SearchProvider.EUROPE_PMC.includesEuropePMC())
        assertTrue(SearchProvider.BOTH.includesEuropePMC())
    }

    // ==================== Budget Constants Tests ====================

    @Test
    fun `budget constants are positive`() {
        assertTrue(Constants.DEFAULT_MAX_RUN_BUDGET_USD > 0)
        assertTrue(Constants.DEFAULT_MONTHLY_BUDGET_USD > 0)
    }

    @Test
    fun `default run budget is less than monthly budget`() {
        assertTrue(Constants.DEFAULT_MAX_RUN_BUDGET_USD < Constants.DEFAULT_MONTHLY_BUDGET_USD)
    }

    // ==================== AppSettings Copy Tests ====================

    @Test
    fun `AppSettings copy preserves unchanged values`() {
        val original = AppSettings.DEFAULT
        val modified = original.copy(batchSize = 50)

        assertEquals(50, modified.batchSize)
        assertEquals(original.llmProviderId, modified.llmProviderId)
        assertEquals(original.modelId, modified.modelId)
        assertEquals(original.searchProvider, modified.searchProvider)
        assertEquals(original.maxRunBudgetUsd, modified.maxRunBudgetUsd, 0.001)
    }
}
