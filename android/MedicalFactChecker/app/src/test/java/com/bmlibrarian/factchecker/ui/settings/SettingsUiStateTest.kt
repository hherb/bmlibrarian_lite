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

package com.bmlibrarian.factchecker.ui.settings

import com.bmlibrarian.factchecker.domain.model.AppSettings
import com.bmlibrarian.factchecker.domain.model.LLMProvider
import com.bmlibrarian.factchecker.domain.model.ModelInfo
import com.bmlibrarian.factchecker.domain.model.SearchProvider
import com.bmlibrarian.factchecker.util.Constants
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for Settings UI state and logic.
 *
 * Tests verify that settings state is correctly computed and that
 * the UI constants produce valid slider configurations.
 */
class SettingsUiStateTest {

    // ==================== Provider List Tests ====================

    @Test
    fun `all providers list contains expected providers`() {
        val providers = LLMProvider.ALL_PROVIDERS

        assertTrue("Should contain Anthropic", providers.any { it.id == "anthropic" })
        assertTrue("Should contain OpenAI", providers.any { it.id == "openai" })
        assertTrue("Should contain DeepSeek", providers.any { it.id == "deepseek" })
        assertTrue("Should contain Groq", providers.any { it.id == "groq" })
        assertTrue("Should contain Mistral", providers.any { it.id == "mistral" })
        assertTrue("Should contain Ollama", providers.any { it.id == "ollama" })
        assertTrue("Should contain Custom", providers.any { it.id == "custom" })
    }

    @Test
    fun `each provider has display name`() {
        LLMProvider.ALL_PROVIDERS.forEach { provider ->
            assertTrue(
                "Provider ${provider.id} should have non-empty display name",
                provider.displayName.isNotEmpty()
            )
        }
    }

    @Test
    fun `non-custom providers have base URL`() {
        LLMProvider.ALL_PROVIDERS
            .filter { it.id != "custom" }
            .forEach { provider ->
                assertTrue(
                    "Provider ${provider.id} should have non-empty base URL",
                    provider.baseUrl.isNotEmpty()
                )
            }
    }

    // ==================== Model Selection Tests ====================

    @Test
    fun `each non-custom provider has at least one model`() {
        LLMProvider.ALL_PROVIDERS
            .filter { it.id != "custom" }
            .forEach { provider ->
                assertTrue(
                    "Provider ${provider.id} should have at least one model",
                    provider.models.isNotEmpty()
                )
            }
    }

    @Test
    fun `model info has required fields`() {
        LLMProvider.ALL_PROVIDERS.flatMap { it.models }.forEach { model ->
            assertTrue("Model should have non-empty id", model.id.isNotEmpty())
            assertTrue("Model should have non-empty display name", model.displayName.isNotEmpty())
            assertTrue(
                "Model input price should be non-negative",
                model.inputPricePer1M >= 0
            )
            assertTrue(
                "Model output price should be non-negative",
                model.outputPricePer1M >= 0
            )
        }
    }

    @Test
    fun `free models are correctly identified`() {
        val freeModel = ModelInfo("test", "Test", 0.0, 0.0)
        val paidModel = ModelInfo("test", "Test", 1.0, 2.0)

        assertTrue("Model with zero pricing should be free", freeModel.isFree)
        assertFalse("Model with non-zero pricing should not be free", paidModel.isFree)
    }

    // ==================== Search Provider Tests ====================

    @Test
    fun `all search providers have display names`() {
        SearchProvider.entries.forEach { provider ->
            assertTrue(
                "SearchProvider ${provider.name} should have non-empty display name",
                provider.displayName.isNotEmpty()
            )
        }
    }

    @Test
    fun `search provider count matches expected`() {
        // Should have exactly 3 options: PubMed, Europe PMC, Both
        assertEquals(3, SearchProvider.entries.size)
    }

    // ==================== Budget Slider Configuration Tests ====================

    @Test
    fun `run budget slider range covers default value`() {
        val defaultBudget = Constants.DEFAULT_MAX_RUN_BUDGET_USD
        assertTrue(
            "Default run budget should be within slider range",
            defaultBudget >= Constants.SETTINGS_MIN_RUN_BUDGET_USD &&
                defaultBudget <= Constants.SETTINGS_MAX_RUN_BUDGET_USD
        )
    }

    @Test
    fun `monthly budget slider range covers default value`() {
        val defaultBudget = Constants.DEFAULT_MONTHLY_BUDGET_USD
        assertTrue(
            "Default monthly budget should be within slider range",
            defaultBudget >= Constants.SETTINGS_MIN_MONTHLY_BUDGET_USD &&
                defaultBudget <= Constants.SETTINGS_MAX_MONTHLY_BUDGET_USD
        )
    }

    @Test
    fun `run budget slider allows minimum sensible value`() {
        // Should allow at least $0.10 for experimentation
        assertTrue(
            "Min run budget should allow cheap runs",
            Constants.SETTINGS_MIN_RUN_BUDGET_USD <= 0.5f
        )
    }

    @Test
    fun `monthly budget slider allows reasonable maximum`() {
        // Should allow reasonable spending limit
        assertTrue(
            "Max monthly budget should be at least $20",
            Constants.SETTINGS_MAX_MONTHLY_BUDGET_USD >= 20f
        )
    }

    // ==================== Batch Size Slider Configuration Tests ====================

    @Test
    fun `batch size slider range covers default value`() {
        val defaultBatchSize = AppSettings.DEFAULT_BATCH_SIZE.toFloat()
        assertTrue(
            "Default batch size should be within slider range",
            defaultBatchSize >= Constants.SETTINGS_MIN_BATCH_SIZE &&
                defaultBatchSize <= Constants.SETTINGS_MAX_BATCH_SIZE
        )
    }

    @Test
    fun `batch size slider covers AppSettings constraints`() {
        assertTrue(
            "Slider min should accommodate AppSettings min",
            Constants.SETTINGS_MIN_BATCH_SIZE <= AppSettings.MIN_BATCH_SIZE
        )
        assertTrue(
            "Slider max should accommodate AppSettings max",
            Constants.SETTINGS_MAX_BATCH_SIZE >= AppSettings.MAX_BATCH_SIZE
        )
    }

    // ==================== Target Documents Slider Configuration Tests ====================

    @Test
    fun `target documents slider range covers default value`() {
        val defaultTarget = AppSettings.DEFAULT_TARGET_RELEVANT_DOCS.toFloat()
        assertTrue(
            "Default target docs should be within slider range",
            defaultTarget >= Constants.SETTINGS_MIN_TARGET_DOCS &&
                defaultTarget <= Constants.SETTINGS_MAX_TARGET_DOCS
        )
    }

    @Test
    fun `target documents slider covers AppSettings constraints`() {
        assertTrue(
            "Slider min should accommodate AppSettings min",
            Constants.SETTINGS_MIN_TARGET_DOCS <= AppSettings.MIN_TARGET_RELEVANT_DOCS
        )
        assertTrue(
            "Slider max should accommodate AppSettings max",
            Constants.SETTINGS_MAX_TARGET_DOCS >= AppSettings.MAX_TARGET_RELEVANT_DOCS
        )
    }

    // ==================== Relevance Threshold Tests ====================

    @Test
    fun `relevance threshold uses scoring constants`() {
        // The slider should use the scoring min/max from Constants
        assertTrue(
            "Min score should be at least 1",
            Constants.SCORING_MIN_SCORE >= 1
        )
        assertTrue(
            "Max score should be 5",
            Constants.SCORING_MAX_SCORE == 5
        )
    }

    @Test
    fun `relevance threshold steps calculation is correct`() {
        // For a 1-5 range, there should be 3 intermediate steps
        val expectedSteps = Constants.SCORING_MAX_SCORE - Constants.SCORING_MIN_SCORE - 1
        assertEquals(3, expectedSteps)
    }

    // ==================== AppSettings Integration Tests ====================

    @Test
    fun `AppSettings default produces valid configuration`() {
        val settings = AppSettings.DEFAULT

        assertNotNull("Should have LLM provider", settings.llmProvider)
        assertNotNull("Should have model info", settings.modelInfo)
        assertTrue("Should be configured", settings.isConfigured)
        assertTrue("Validation should pass", settings.validate().isEmpty())
    }

    @Test
    fun `AppSettings requiresApiKey reflects provider setting`() {
        val openaiSettings = AppSettings.DEFAULT
        val ollamaSettings = AppSettings(
            llmProviderId = LLMProvider.OLLAMA.id,
            modelId = LLMProvider.OLLAMA.defaultModel
        )

        assertTrue("OpenAI should require API key", openaiSettings.requiresApiKey)
        assertFalse("Ollama should not require API key", ollamaSettings.requiresApiKey)
    }

    @Test
    fun `AppSettings effectiveBaseUrl handles custom provider`() {
        val customUrl = "https://custom.api.com/v1"
        val customSettings = AppSettings(
            llmProviderId = LLMProvider.CUSTOM.id,
            customBaseUrl = customUrl
        )

        assertEquals(customUrl, customSettings.effectiveBaseUrl)
    }

    @Test
    fun `AppSettings effectiveBaseUrl uses provider default for non-custom`() {
        val settings = AppSettings(
            llmProviderId = LLMProvider.OPENAI.id,
            modelId = LLMProvider.OPENAI.defaultModel
        )

        assertEquals(LLMProvider.OPENAI.baseUrl, settings.effectiveBaseUrl)
    }

    // ==================== Cost Calculation Tests ====================

    @Test
    fun `ModelInfo calculateCost returns sensible values`() {
        val model = ModelInfo("test", "Test", 3.00, 15.00)

        // 1000 input tokens + 500 output tokens
        val cost = model.calculateCost(1000, 500)

        // Expected: (1000/1M * 3.00) + (500/1M * 15.00)
        // = 0.003 + 0.0075 = 0.0105
        assertEquals(0.0105, cost, 0.0001)
    }

    @Test
    fun `free model calculateCost returns zero`() {
        val freeModel = ModelInfo("test", "Test", 0.0, 0.0)
        val cost = freeModel.calculateCost(10000, 5000)

        assertEquals(0.0, cost, 0.0001)
    }
}
