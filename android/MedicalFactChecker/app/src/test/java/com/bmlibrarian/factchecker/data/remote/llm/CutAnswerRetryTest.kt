/*
 * BMLibrarian Lite - Biomedical Literature Research Tool
 * Copyright (C) 2024-2026 Dr Horst Herb
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

package com.bmlibrarian.factchecker.data.remote.llm

import android.util.Log
import com.bmlibrarian.factchecker.domain.model.LLMProvider
import io.mockk.coEvery
import io.mockk.every
import io.mockk.mockk
import io.mockk.mockkStatic
import io.mockk.unmockkStatic
import kotlinx.coroutines.test.runTest
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import retrofit2.Response

/** #822: an answer cut at its token limit is asked once more with twice the limit, as the desktop does (#825). */
class CutAnswerRetryTest {

    private lateinit var openAIApi: OpenAIApi
    private lateinit var anthropicApi: AnthropicApi
    private lateinit var service: LLMService
    private val asked = mutableListOf<Int>()

    @Before
    fun setup() {
        mockkStatic(Log::class)
        every { Log.w(any<String>(), any<String>()) } returns 0
        openAIApi = mockk()
        anthropicApi = mockk()
        service = LLMService(openAIApi, anthropicApi, mockk())
    }

    @After
    fun tearDown() = unmockkStatic(Log::class)

    private fun openAIReplies(vararg replies: Response<OpenAIChatResponse>) {
        val queue = ArrayDeque(replies.toList())
        coEvery { openAIApi.chatCompletion(any(), any(), any()) } answers {
            asked += thirdArg<OpenAIChatRequest>().maxTokens
            queue.removeFirst()
        }
    }

    private fun answer(content: String, finishReason: String, outputTokens: Int) = Response.success(
        OpenAIChatResponse(
            id = "x",
            choices = listOf(OpenAIChatChoice(0, OpenAIChatMessage("assistant", content), finishReason)),
            usage = OpenAITokenUsage(promptTokens = 100, completionTokens = outputTokens, totalTokens = 100 + outputTokens)
        )
    )

    private suspend fun ask(maxTokens: Int = 2048, retryingCut: Boolean = true) = service.chat(
        provider = LLMProvider.OPENAI, apiKey = "k", model = "m", systemPrompt = "s", userPrompt = "u",
        maxTokens = maxTokens, retryingCut = retryingCut
    )

    @Test
    fun `a cut answer is asked once more with twice the limit`() = runTest {
        openAIReplies(answer("{\"score\":", "length", 2048), answer("{\"score\": 4}", "stop", 2300))

        val result = ask().getOrThrow()

        assertEquals("{\"score\": 4}", result.content)
        assertEquals(listOf(2048, 4096), asked)
        assertEquals("both requests are paid for", 200, result.inputTokens)
        assertEquals(4348, result.outputTokens)
    }

    @Test
    fun `a retry cut again is returned as written, never asked a third time`() = runTest {
        openAIReplies(answer("first", "length", 2048), answer("second", "length", 4096))

        assertEquals("second", ask().getOrThrow().content)
        assertEquals(listOf(2048, 4096), asked)
    }

    @Test
    fun `a failed retry keeps the cut answer`() = runTest {
        openAIReplies(
            answer("cut", "length", 2048),
            Response.error(400, """{"error":{"message":"refused"}}""".toResponseBody())
        )

        val result = ask().getOrThrow()

        assertEquals("cut", result.content)
        assertEquals(2048, result.outputTokens)
        assertEquals(listOf(2048, 4096), asked)
    }

    @Test
    fun `an answer cut short of its limit is not asked again`() = runTest {
        // the context window ran out: a larger limit does not change that
        openAIReplies(answer("cut", "length", 900))

        assertEquals("cut", ask().getOrThrow().content)
        assertEquals(listOf(2048), asked)
    }

    @Test
    fun `a finished answer and the connection test are asked once`() = runTest {
        openAIReplies(answer("whole", "stop", 2048), answer("O", "length", 10))

        ask()
        ask(maxTokens = 10, retryingCut = false)

        assertEquals(listOf(2048, 10), asked)
    }

    @Test
    fun `Anthropic's max_tokens stop is a cut`() = runTest {
        val limits = mutableListOf<Int>()
        val queue = ArrayDeque(listOf("max_tokens" to 2048, "end_turn" to 3000))
        coEvery { anthropicApi.createMessage(any(), any(), any(), any()) } answers {
            limits += arg<AnthropicMessagesRequest>(3).maxTokens
            val (stop, tokens) = queue.removeFirst()
            Response.success(
                AnthropicMessagesResponse(
                    id = "msg",
                    content = listOf(AnthropicContentBlock(type = "text", text = stop)),
                    stopReason = stop,
                    usage = AnthropicUsage(inputTokens = 100, outputTokens = tokens)
                )
            )
        }

        val result = service.chat(
            provider = LLMProvider.ANTHROPIC, apiKey = "k", model = "claude", systemPrompt = "s", userPrompt = "u",
            maxTokens = 2048
        ).getOrThrow()

        assertEquals("end_turn", result.content)
        assertEquals(listOf(2048, 4096), limits)
    }

    @Test
    fun `the raised limit follows the desktop rule`() {
        assertEquals(4096, LLMService.raisedLimit("length", 2048, 2048))
        assertEquals(4096, LLMService.raisedLimit("max_tokens", 2048, 2048))
        assertEquals(16384, LLMService.raisedLimit("length", 8192, 8192))
        assertEquals("capped", 16384, LLMService.raisedLimit("length", 12000, 12000))
        assertNull("no larger limit", LLMService.raisedLimit("length", 16384, 16384))
        assertNull(LLMService.raisedLimit("stop", 2048, 2048))
        assertNull(LLMService.raisedLimit(null, 2048, 2048))
        assertNull("no count stated", LLMService.raisedLimit("length", 0, 2048))
        assertNull(LLMService.raisedLimit("length", 0, 0))
    }
}
