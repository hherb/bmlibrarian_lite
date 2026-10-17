// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2026 Dr Horst Herb
// SPDX-License-Identifier: AGPL-3.0-or-later

package com.bmlibrarian.factchecker.domain.workflow

import com.bmlibrarian.factchecker.domain.model.LLMProvider
import com.bmlibrarian.factchecker.data.remote.llm.LLMResult
import com.bmlibrarian.factchecker.data.remote.llm.LLMService
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.mockk
import io.mockk.spyk
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * An unreadable relevance score is a parse failure the scorer retries, never a
 * default score that the default threshold would call relevant.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class ParallelScoringServiceTest {

    private fun llmAnswering(content: String): LLMService {
        val llm = spyk(LLMService(mockk(relaxed = true), mockk(relaxed = true)))
        coEvery { llm.chat(any(), any(), any(), any(), any(), any(), any()) } returns
            Result.success(LLMResult(content, 10, 10, "stop", "fake"))
        return llm
    }

    private val input = ScoringInput(
        documentId = "doc-1",
        pmid = "1",
        title = "A title",
        abstract = "An abstract",
        authors = "A. Author",
        year = 2024,
        journal = "A Journal"
    )

    @Test
    fun `an unreadable score is retried and never relevant`() = runTest {
        val llm = llmAnswering("""{"score": "high"}""")
        val service = ParallelScoringService(llm)

        val results = service.scoreDocuments(
            documents = listOf(input),
            claim = "A claim",
            provider = LLMProvider.OPENAI,
            apiKey = "key",
            model = "model"
        )

        assertEquals(1, results.size)
        assertTrue(results[0].toString(), results[0] is ScoringResult.ParseFailure)
        coVerify(exactly = ParallelScoringService.MAX_PARSE_RETRIES) {
            llm.chat(any(), any(), any(), any(), any(), any(), any())
        }
    }

    @Test
    fun `a readable score is scored once`() = runTest {
        val llm = llmAnswering("""{"score": 4, "rationale": "On topic"}""")
        val service = ParallelScoringService(llm)

        val results = service.scoreDocuments(
            documents = listOf(input),
            claim = "A claim",
            provider = LLMProvider.OPENAI,
            apiKey = "key",
            model = "model"
        )

        val success = results.single() as ScoringResult.Success
        assertEquals(4, success.score)
        coVerify(exactly = 1) { llm.chat(any(), any(), any(), any(), any(), any(), any()) }
    }
}
