// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2026 Dr Horst Herb
// SPDX-License-Identifier: AGPL-3.0-or-later

package com.bmlibrarian.factchecker.domain.workflow

import android.util.Log
import com.bmlibrarian.factchecker.domain.model.LLMError
import com.bmlibrarian.factchecker.domain.model.LLMProvider
import com.bmlibrarian.factchecker.data.remote.llm.LLMResult
import com.bmlibrarian.factchecker.data.remote.llm.LLMService
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.mockk
import io.mockk.spyk
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * An unreadable relevance score is a parse failure the scorer retries, never a
 * default score that the default threshold would call relevant.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class ParallelScoringServiceTest {

    private fun llmAnswering(content: String): LLMService {
        val llm = spyk(LLMService(mockk(relaxed = true), mockk(relaxed = true), mockk(relaxed = true)))
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
    fun `an unreadable reply is kept and logged`() = runTest {
        Log.clear()
        val reply = """{"score": "high", "explanation": "very"}"""
        val llm = llmAnswering(reply)
        val service = ParallelScoringService(llm)

        val failure = service.scoreDocuments(
            documents = listOf(input),
            claim = "A claim",
            provider = LLMProvider.OPENAI,
            apiKey = "key",
            model = "model"
        ).single() as ScoringResult.ParseFailure

        assertEquals(reply, failure.rawResponse)
        assertTrue(Log.lines.toString(), Log.lines.any { it.contains(reply) })
    }

    @Test
    fun `a ParseError is a parse error by its type, whatever its message`() {
        assertTrue(ParallelScoringService.isParseError(LLMError.ParseError("no score")))
        // Control: an error of another type is still judged by its message
        assertFalse(ParallelScoringService.isParseError(IllegalStateException("no score")))
    }

    @Test
    fun `the retries after an unreadable reply carry the correction note`() = runTest {
        val llm = spyk(LLMService(mockk(relaxed = true), mockk(relaxed = true), mockk(relaxed = true)))
        val prompts = mutableListOf<String>()
        val replies = ArrayDeque(listOf("""{"score": 4, "confidence": NaN}""", "no score", """{"score": 3}"""))
        coEvery { llm.chat(any(), any(), any(), any(), capture(prompts), any(), any()) } answers {
            Result.success(LLMResult(replies.removeFirst(), 10, 10, "stop", "fake"))
        }

        val success = ParallelScoringService(llm).scoreDocuments(
            documents = listOf(input),
            claim = "A claim",
            provider = LLMProvider.OPENAI,
            apiKey = "key",
            model = "model"
        ).single() as ScoringResult.Success

        assertEquals(3, success.score)
        val (first, second, third) = prompts
        assertFalse(first.contains(LLMService.JSON_CORRECTION_NOTE))
        // Appended to the user turn after a blank line, and kept on every later attempt
        assertEquals("$first\n\n${LLMService.JSON_CORRECTION_NOTE}", second)
        assertEquals(second, third)
    }

    @Test
    fun `the correction note is bmlib's, through the shared contract`() {
        val relative = "doc/cross_platform/llm_parity/json_correction.json"
        val file = generateSequence(File("").absoluteFile) { it.parentFile }
            .map { File(it, relative) }
            .firstOrNull { it.isFile }
            ?: error("could not locate $relative above ${File("").absolutePath}")
        val note = Json.parseToJsonElement(file.readText()).jsonObject["note"]!!.jsonPrimitive.content
        assertEquals(note, LLMService.JSON_CORRECTION_NOTE)
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
