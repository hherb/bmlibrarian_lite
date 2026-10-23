// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2026 Dr Horst Herb
// SPDX-License-Identifier: AGPL-3.0-or-later

package com.bmlibrarian.factchecker.domain.workflow

import com.bmlibrarian.factchecker.data.remote.llm.LLMService
import com.bmlibrarian.factchecker.data.remote.llm.LLMService.CitationExtraction
import com.bmlibrarian.factchecker.domain.model.LLMProvider
import io.mockk.coEvery
import io.mockk.mockk
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** A paper's text is read in windows, one call each, never cut; the passages merged (Python's `extract_citations`). */
class ParallelCitationServiceTest {

    /** A text of about 50,000 characters, so several windows. */
    private val longText = (1..2_000).joinToString(" ") { "Sentence $it of the body." } + " The last sentence."

    private val asked = mutableListOf<Triple<String?, Int, Int>>()

    private fun llm(answer: (content: String?, part: Int) -> Result<List<CitationExtraction>>): LLMService {
        val llm = mockk<LLMService>()
        coEvery { llm.extractCitations(any(), any(), any(), any(), any(), any(), any(), any()) } answers {
            val content = arg<String?>(5)
            val part = arg<Int>(6)
            asked += Triple(content, part, arg(7))
            answer(content, part)
        }
        return llm
    }

    private suspend fun extract(llm: LLMService, input: CitationInput): CitationResult =
        ParallelCitationService(llm).extractCitations(listOf(input), "A claim", LLMProvider.OPENAI, "key", "model").single()

    private fun input(fullText: String?, abstract: String? = "The abstract.") =
        CitationInput(documentId = "d1", pmid = "1", title = "A title", abstract = abstract, fullText = fullText)

    @Test
    fun `a long text is read in several calls, labelled, and every part reaches the model`() = runTest {
        val result = extract(llm { _, _ -> Result.success(emptyList()) }, input(longText))

        assertTrue(result.isSuccess)
        val windows = input(longText).windows
        assertTrue(windows.size > 1)
        assertEquals(windows, asked.map { it.first })
        assertEquals((1..windows.size).map { it to windows.size }, asked.map { it.second to it.third })
        assertTrue(asked.any { it.first!!.endsWith("The last sentence.") })
        assertTrue("the abstract is not beside the full text", asked.none { it.first!!.contains("The abstract.") })
    }

    @Test
    fun `the usage of every window is summed`() = runTest {
        val one = extract(llm { _, _ -> Result.success(emptyList()) }, input("A short body."))
        assertEquals(1, asked.size)
        asked.clear()
        val many = extract(llm { _, _ -> Result.success(emptyList()) }, input(longText))

        assertTrue(asked.size > 1)
        assertEquals(one.outputTokens * asked.size, many.outputTokens)
        assertTrue(many.inputTokens >= input(longText).windows.sumOf { it.length } / 4)
    }

    @Test
    fun `passages of all windows are merged, each once`() = runTest {
        val result = extract(
            llm { _, part ->
                Result.success(
                    if (part == 1) listOf(CitationExtraction("Stroke fell by 20%.", "a"), CitationExtraction("Bleeding rose.", "b"))
                    else listOf(CitationExtraction("stroke  fell by 20%.", "c"), CitationExtraction("Mortality fell.", "d"))
                )
            },
            input(longText)
        )

        assertEquals(
            listOf("Stroke fell by 20%.", "Bleeding rose.", "Mortality fell."),
            result.extractionsOrEmpty.map { it.passage }
        )
    }

    @Test
    fun `a failing window fails the paper`() = runTest {
        val result = extract(
            llm { _, part -> if (part == 2) Result.failure(RuntimeException("down")) else Result.success(listOf(CitationExtraction("A.", "a"))) },
            input(longText)
        )

        assertTrue(result.isError)
        assertEquals("no window is asked after the failure", 2, asked.size)
        assertTrue(result.inputTokens > 0)
    }

    @Test
    fun `without a full text the abstract is read once, unlabelled, and an empty one is still asked`() = runTest {
        extract(llm { _, _ -> Result.success(emptyList()) }, input(fullText = null))
        extract(llm { _, _ -> Result.success(emptyList()) }, input(fullText = null, abstract = null))

        assertEquals(listOf(Triple("The abstract.", 1, 1), Triple(null, 1, 1)), asked)
    }
}
