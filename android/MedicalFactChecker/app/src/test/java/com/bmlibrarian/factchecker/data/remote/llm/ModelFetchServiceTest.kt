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

package com.bmlibrarian.factchecker.data.remote.llm

import com.bmlibrarian.factchecker.domain.model.LLMProvider
import com.bmlibrarian.factchecker.domain.model.ModelInfo
import com.bmlibrarian.factchecker.domain.model.ModelPricing
import com.bmlibrarian.factchecker.ui.settings.SettingsViewModel
import org.junit.Assert.assertNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Tests for DeepSeek model discovery.
 *
 * DeepSeek retired the deepseek-chat / deepseek-reasoner IDs in July 2026 and now
 * serves deepseek-v4-flash / deepseek-v4-pro.
 * See https://api-docs.deepseek.com/quick_start/pricing
 *
 * Mirrors the iOS DeepSeekModelTests suite.
 */
class ModelFetchServiceTest {

    // ==================== Model Filter Tests ====================

    @Test
    fun `accepts current DeepSeek model IDs`() {
        assertTrue(ModelFetchService.isUsableDeepSeekModel("deepseek-v4-flash"))
        assertTrue(ModelFetchService.isUsableDeepSeekModel("deepseek-v4-pro"))
    }

    @Test
    fun `accepts future DeepSeek generations`() {
        // The filter must not need a code change every time DeepSeek renames its line-up.
        assertTrue(ModelFetchService.isUsableDeepSeekModel("deepseek-v5-flash"))
    }

    @Test
    fun `rejects non-chat DeepSeek models`() {
        assertFalse(ModelFetchService.isUsableDeepSeekModel("deepseek-embedding"))
        assertFalse(ModelFetchService.isUsableDeepSeekModel("deepseek-reranker"))
        assertFalse(ModelFetchService.isUsableDeepSeekModel(""))
    }

    // ==================== Anthropic Recommended Model Tests ====================

    /** Anthropic's live list on 2026-11-13, sorted as the fetch sorts it (newest first). */
    private val liveAnthropicIds = listOf(
        "claude-fable-5-2", "claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5",
        "claude-fable-5-1", "claude-opus-5", "claude-sonnet-5", "claude-fable-5",
        "claude-opus-4-8", "claude-opus-4-7", "claude-sonnet-4-6", "claude-opus-4-6",
        "claude-opus-4-5-20251101", "claude-haiku-4-5-20251001", "claude-sonnet-4-5-20250929"
    ).sortedDescending()

    private fun models(ids: List<String>) = ids.map { ModelInfo(it, it, 0.0, 0.0) }

    @Test
    fun `recommends the newest Sonnet`() {
        assertEquals("claude-sonnet-5-5", ModelFetchService.recommendedAnthropicModelId(liveAnthropicIds))
        assertNull(ModelFetchService.recommendedAnthropicModelId(listOf("claude-opus-5-5")))
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

    // ==================== Display Name Tests ====================

    @Test
    fun `formats versioned DeepSeek names`() {
        assertEquals("DeepSeek V4 Flash", ModelFetchService.formatDeepSeekModelName("deepseek-v4-flash"))
        assertEquals("DeepSeek V4 Pro", ModelFetchService.formatDeepSeekModelName("deepseek-v4-pro"))
    }

    @Test
    fun `passes through IDs without the vendor prefix`() {
        assertEquals("some-other-model", ModelFetchService.formatDeepSeekModelName("some-other-model"))
    }

    // ==================== Pricing Tests ====================

    @Test
    fun `prices current DeepSeek models at peak cache-miss rates`() {
        val flash = ModelPricing.getDeepSeekPricing("deepseek-v4-flash")
        assertEquals(0.44, flash.first, 0.0001)
        assertEquals(1.32, flash.second, 0.0001)

        val pro = ModelPricing.getDeepSeekPricing("deepseek-v4-pro")
        assertEquals(1.32, pro.first, 0.0001)
        assertEquals(3.96, pro.second, 0.0001)
    }

    // ==================== Anthropic Pricing Tests ====================

    @Test
    fun `current Claude models are priced`() {
        // Each of these used to fall through to the $3/$15 default.
        assertEquals(10.00 to 50.00, ModelPricing.getAnthropicPricing("claude-fable-5-1"))
        assertEquals(4.00 to 20.00, ModelPricing.getAnthropicPricing("claude-opus-5-5"))
        assertEquals(5.00 to 25.00, ModelPricing.getAnthropicPricing("claude-opus-5"))
        assertEquals(2.00 to 10.00, ModelPricing.getAnthropicPricing("claude-sonnet-5"))
        assertEquals(1.00 to 5.00, ModelPricing.getAnthropicPricing("claude-haiku-4-5-20251001"))
    }

    @Test
    fun `newer Opus 4 is not captured by the retired Opus 4 rate`() {
        assertEquals(5.00 to 25.00, ModelPricing.getAnthropicPricing("claude-opus-4-8"))
        assertEquals(15.00 to 75.00, ModelPricing.getAnthropicPricing("claude-opus-4-1"))
    }

    @Test
    fun `unlisted Claude model is priced at its family's dearest rate`() {
        assertEquals(3.00 to 15.00, ModelPricing.getAnthropicPricing("claude-sonnet-6"))
        assertEquals(10.00 to 50.00, ModelPricing.getAnthropicPricing("claude-lyric-1"))
    }
}
