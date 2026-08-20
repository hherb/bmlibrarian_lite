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

import kotlinx.serialization.json.Json
import kotlinx.serialization.encodeToString
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Tests for chat request serialization.
 *
 * DeepSeek V4 enables chain-of-thought by default, which spends output tokens on
 * reasoning and makes temperature a no-op.
 * See https://api-docs.deepseek.com/guides/thinking_mode/
 */
class OpenAIChatRequestTest {

    /** Mirrors the app-wide Json configuration from AppModule. */
    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
        encodeDefaults = true
        prettyPrint = false
    }

    private fun request(thinking: ThinkingConfig?) = OpenAIChatRequest(
        model = "deepseek-v4-flash",
        messages = listOf(OpenAIChatMessage(role = "user", content = "hi")),
        maxTokens = 10,
        temperature = 0.1,
        thinking = thinking
    )

    @Test
    fun `omits the thinking field entirely when unset`() {
        // encodeDefaults is on app-wide, so a plain null would be written as
        // "thinking":null and providers that do not know the field may reject it.
        val encoded = json.encodeToString(request(thinking = null))
        assertFalse(encoded, encoded.contains("thinking"))
    }

    @Test
    fun `serializes the DeepSeek opt-out`() {
        val encoded = json.encodeToString(request(thinking = ThinkingConfig.DISABLED))
        assertTrue(encoded, encoded.contains("\"thinking\":{\"type\":\"disabled\"}"))
    }
}
