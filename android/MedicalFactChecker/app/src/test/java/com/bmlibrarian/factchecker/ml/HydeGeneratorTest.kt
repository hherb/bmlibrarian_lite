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

package com.bmlibrarian.factchecker.ml

import com.bmlibrarian.factchecker.data.remote.llm.LLMResult
import com.bmlibrarian.factchecker.data.remote.llm.LLMService
import com.bmlibrarian.factchecker.data.remote.llm.UsageSink
import com.bmlibrarian.factchecker.domain.model.LLMProvider
import com.bmlibrarian.factchecker.util.Constants
import io.mockk.coEvery
import io.mockk.mockk
import io.mockk.slot
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HydeGeneratorTest {

    @Test
    fun `a HyDE abstract is asked with its own limit`() = runTest {
        // #813: it borrowed the scoring limit, and 39 of 40 abstracts outgrew the old 500
        val llmService = mockk<LLMService>()
        val maxTokens = slot<Int>()
        val abstract = "word ".repeat(Constants.HYDE_TARGET_WORD_COUNT_MIN).trim()
        coEvery {
            llmService.chat(any(), any(), any(), any(), any(), capture(maxTokens), any(), any(), any())
        } returns Result.success(LLMResult(abstract, 0, 0, "stop", "m"))

        val generated = HydeGenerator(llmService)
            .generateHypotheticalAbstract("Aspirin prevents stroke", LLMProvider.ANTHROPIC, "k", "m")

        assertEquals(abstract, generated)
        assertEquals(Constants.LLM_HYDE_MAX_TOKENS, maxTokens.captured)
    }

    @Test
    fun `the prompt asks for a search passage, not a study to invent`() = runTest {
        // #819: asked for "a real published study abstract" with statistics, Claude Haiku 5.5 refused 1 of 10
        val llmService = mockk<LLMService>()
        val system = slot<String>()
        val user = slot<String>()
        coEvery {
            llmService.chat(any(), any(), any(), capture(system), capture(user), any(), any(), any(), any())
        } returns Result.success(LLMResult("too short", 0, 0, "stop", "m"))

        HydeGenerator(llmService).generateHypotheticalAbstract("Aspirin prevents stroke", LLMProvider.ANTHROPIC, "k", "m")

        val prompt = (system.captured + user.captured).lowercase()
        assertFalse(prompt.contains("real published"))
        assertFalse(prompt.contains("with statistics"))
        assertTrue(prompt.contains("without numbers"))
    }

    @Test
    fun `the tokens of an abstract too short to use are still heard`() = runTest {
        val llmService = mockk<LLMService>()
        coEvery { llmService.chat(any(), any(), any(), any(), any(), any(), any(), any(), any()) } answers {
            arg<UsageSink>(8)(40, 7)
            Result.success(LLMResult("too short", 40, 7, "stop", "m"))
        }
        val heard = mutableListOf<Pair<Int, Int>>()

        val generated = HydeGenerator(llmService).generateHypotheticalAbstract(
            "Aspirin prevents stroke", LLMProvider.ANTHROPIC, "k", "m", onUsage = { i, o -> heard += i to o }
        )

        assertNull(generated)
        assertEquals(listOf(40 to 7), heard)
    }
}
