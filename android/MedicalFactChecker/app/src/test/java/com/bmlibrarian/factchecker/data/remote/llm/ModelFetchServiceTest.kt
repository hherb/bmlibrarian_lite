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
        val flash = ModelFetchService.getDeepSeekPricing("deepseek-v4-flash")
        assertEquals(0.44, flash.first, 0.0001)
        assertEquals(1.32, flash.second, 0.0001)

        val pro = ModelFetchService.getDeepSeekPricing("deepseek-v4-pro")
        assertEquals(1.32, pro.first, 0.0001)
        assertEquals(3.96, pro.second, 0.0001)
    }
}
