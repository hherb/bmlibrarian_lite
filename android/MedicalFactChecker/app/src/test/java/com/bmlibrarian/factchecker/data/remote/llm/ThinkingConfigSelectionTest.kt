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
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Tests which providers are sent a chain-of-thought setting.
 *
 * Mirrors the iOS ThinkingModeTests. Serialization of the field is covered separately
 * by OpenAIChatRequestTest; this pins the provider-to-setting decision, which is the
 * half that decides whether a provider receives a field it does not understand.
 *
 * @see <a href="https://api-docs.deepseek.com/guides/thinking_mode/">DeepSeek Thinking Mode</a>
 */
class ThinkingConfigSelectionTest {

    @Test
    fun `DeepSeek opts out of thinking mode`() {
        // V4 defaults thinking to enabled, which spends output tokens on reasoning and
        // makes temperature a no-op - scoring depends on temperature being honoured.
        val config = LLMService.thinkingConfigFor(LLMProvider.DEEPSEEK)

        assertEquals(ThinkingConfig.DISABLED, config)
        assertEquals("disabled", config?.type)
    }

    @Test
    fun `every other provider is sent no thinking field`() {
        // Sending "thinking" to a provider that does not know it risks the whole call
        // being rejected, so the field must be absent rather than explicitly enabled.
        val others = LLMProvider.ALL_PROVIDERS.filter { it.id != LLMProvider.DEEPSEEK.id }

        // Guard against the list silently shrinking to nothing and the loop passing.
        assert(others.size >= 5) { "expected several non-DeepSeek providers, got ${others.size}" }

        for (provider in others) {
            assertNull(
                "expected no thinking config for ${provider.id}",
                LLMService.thinkingConfigFor(provider)
            )
        }
    }
}
