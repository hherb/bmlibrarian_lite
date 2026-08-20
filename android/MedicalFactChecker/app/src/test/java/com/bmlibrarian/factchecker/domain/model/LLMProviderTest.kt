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

package com.bmlibrarian.factchecker.domain.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for LLMProvider domain model.
 */
class LLMProviderTest {

    // ==================== Provider Lookup Tests ====================

    @Test
    fun `fromId returns Anthropic provider`() {
        val provider = LLMProvider.fromId("anthropic")

        assertNotNull(provider)
        assertEquals("Anthropic (Claude)", provider?.displayName)
        assertTrue(provider?.usesAnthropicFormat == true)
    }

    @Test
    fun `fromId returns OpenAI provider`() {
        val provider = LLMProvider.fromId("openai")

        assertNotNull(provider)
        assertEquals("OpenAI", provider?.displayName)
        assertFalse(provider?.usesAnthropicFormat == true)
    }

    @Test
    fun `fromId returns null for unknown provider`() {
        val provider = LLMProvider.fromId("unknown-provider")

        assertNull(provider)
    }

    // ==================== Manual Model Entry Tests ====================

    @Test
    fun `only self-hosted and custom endpoints allow manual model entry`() {
        // This flag gates whether a stored model may be replaced when the provider stops
        // listing it. Getting it wrong for a hosted provider strands the user on a dead
        // ID; getting it wrong for Ollama overwrites a name they deliberately typed.
        assertTrue(LLMProvider.OLLAMA.allowsManualModelEntry)
        assertTrue(LLMProvider.CUSTOM.allowsManualModelEntry)

        assertFalse(LLMProvider.ANTHROPIC.allowsManualModelEntry)
        assertFalse(LLMProvider.OPENAI.allowsManualModelEntry)
        assertFalse(LLMProvider.DEEPSEEK.allowsManualModelEntry)
        assertFalse(LLMProvider.GROQ.allowsManualModelEntry)
        assertFalse(LLMProvider.MISTRAL.allowsManualModelEntry)
    }

    @Test
    fun `manual entry is not the same question as requiring an API key`() {
        // These were briefly conflated on Android. A custom endpoint usually needs a key
        // yet still lets the user name their own model, so one cannot stand in for the
        // other - see the iOS LLMProvider.allowsManualModelEntry docs.
        assertTrue(LLMProvider.CUSTOM.requiresApiKey)
        assertTrue(LLMProvider.CUSTOM.allowsManualModelEntry)
    }

    @Test
    fun `fromId is case sensitive`() {
        val provider = LLMProvider.fromId("ANTHROPIC")

        assertNull(provider)
    }

    // ==================== Model Lookup Tests ====================

    @Test
    fun `getModel returns model by ID`() {
        val model = LLMProvider.OPENAI.getModel("gpt-4o")

        assertNotNull(model)
        assertEquals("GPT-4o", model?.displayName)
    }

    @Test
    fun `getModel returns null for unknown model`() {
        val model = LLMProvider.OPENAI.getModel("unknown-model")

        assertNull(model)
    }

    // ==================== Provider Properties Tests ====================

    @Test
    fun `Anthropic has correct chat completions URL`() {
        val url = LLMProvider.ANTHROPIC.chatCompletionsUrl

        assertEquals("https://api.anthropic.com/v1/messages", url)
    }

    @Test
    fun `OpenAI has correct chat completions URL`() {
        val url = LLMProvider.OPENAI.chatCompletionsUrl

        assertEquals("https://api.openai.com/v1/chat/completions", url)
    }

    @Test
    fun `Ollama does not require API key`() {
        assertFalse(LLMProvider.OLLAMA.requiresApiKey)
    }

    @Test
    fun `Anthropic requires API key`() {
        assertTrue(LLMProvider.ANTHROPIC.requiresApiKey)
    }

    @Test
    fun `OpenAI supports model fetching`() {
        assertTrue(LLMProvider.OPENAI.supportsModelFetching)
    }

    @Test
    fun `Anthropic supports model fetching`() {
        // Phase 5 (Dynamic Model Fetching) added fetchAnthropicModels(); Anthropic
        // now supports listing available models like the other cloud providers.
        assertTrue(LLMProvider.ANTHROPIC.supportsModelFetching)
    }

    // ==================== ALL_PROVIDERS Tests ====================

    @Test
    fun `ALL_PROVIDERS contains all expected providers`() {
        val providers = LLMProvider.ALL_PROVIDERS

        assertEquals(7, providers.size)
        assertTrue(providers.any { it.id == "anthropic" })
        assertTrue(providers.any { it.id == "openai" })
        assertTrue(providers.any { it.id == "deepseek" })
        assertTrue(providers.any { it.id == "groq" })
        assertTrue(providers.any { it.id == "mistral" })
        assertTrue(providers.any { it.id == "ollama" })
        assertTrue(providers.any { it.id == "custom" })
    }

    // ==================== ModelInfo Tests ====================

    @Test
    fun `ModelInfo calculates cost correctly`() {
        val model = ModelInfo("test", "Test Model", 2.0, 10.0)

        val cost = model.calculateCost(inputTokens = 1000, outputTokens = 500)

        // (1000/1M * 2.0) + (500/1M * 10.0) = 0.002 + 0.005 = 0.007
        assertEquals(0.007, cost, 0.0001)
    }

    @Test
    fun `ModelInfo UNKNOWN has zero pricing`() {
        val unknown = ModelInfo.UNKNOWN

        assertEquals("unknown", unknown.id)
        assertEquals(0.0, unknown.inputPricePer1M, 0.0001)
        assertEquals(0.0, unknown.outputPricePer1M, 0.0001)
    }

    // ==================== DeepSeek Provider Tests ====================

    @Test
    fun `DeepSeek has correct base URL`() {
        assertEquals("https://api.deepseek.com/v1", LLMProvider.DEEPSEEK.baseUrl)
    }

    @Test
    fun `DeepSeek offers the current V4 models`() {
        // deepseek-chat and deepseek-reasoner were retired in July 2026.
        assertNotNull(LLMProvider.DEEPSEEK.getModel("deepseek-v4-flash"))
        assertNotNull(LLMProvider.DEEPSEEK.getModel("deepseek-v4-pro"))
        assertEquals("deepseek-v4-flash", LLMProvider.DEEPSEEK.defaultModel)
    }

    // ==================== Groq Provider Tests ====================

    @Test
    fun `Groq has correct base URL with openai path`() {
        assertEquals("https://api.groq.com/openai/v1", LLMProvider.GROQ.baseUrl)
    }

    @Test
    fun `Groq supports model fetching`() {
        assertTrue(LLMProvider.GROQ.supportsModelFetching)
    }

    // ==================== Mistral Provider Tests ====================

    @Test
    fun `Mistral has correct base URL`() {
        assertEquals("https://api.mistral.ai/v1", LLMProvider.MISTRAL.baseUrl)
    }

    @Test
    fun `Mistral has expected models`() {
        assertNotNull(LLMProvider.MISTRAL.getModel("mistral-large-latest"))
        assertNotNull(LLMProvider.MISTRAL.getModel("mistral-small-latest"))
        assertNotNull(LLMProvider.MISTRAL.getModel("codestral-latest"))
    }

    // ==================== Custom Provider Tests ====================

    @Test
    fun `Custom provider has empty defaults`() {
        assertEquals("", LLMProvider.CUSTOM.baseUrl)
        assertEquals("", LLMProvider.CUSTOM.defaultModel)
        assertTrue(LLMProvider.CUSTOM.models.isEmpty())
    }
}
