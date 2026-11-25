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
import com.bmlibrarian.factchecker.domain.model.LLMProvider
import com.bmlibrarian.factchecker.util.Constants
import io.mockk.coEvery
import io.mockk.mockk
import io.mockk.slot
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
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
}
