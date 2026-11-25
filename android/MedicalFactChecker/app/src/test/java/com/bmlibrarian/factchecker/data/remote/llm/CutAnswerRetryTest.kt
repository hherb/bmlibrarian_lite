/*
 * BMLibrarian Lite - Biomedical Literature Research Tool
 * Copyright (C) 2024-2026 Dr Horst Herb
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

package com.bmlibrarian.factchecker.data.remote.llm

import android.util.Log
import com.bmlibrarian.factchecker.domain.model.LLMError
import com.bmlibrarian.factchecker.domain.model.LLMProvider
import com.bmlibrarian.factchecker.util.OllamaContext
import io.mockk.coEvery
import io.mockk.every
import io.mockk.mockk
import io.mockk.mockkStatic
import io.mockk.unmockkStatic
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import retrofit2.Response

/** #822: an answer cut at its token limit is asked once more with twice the limit, as the desktop does (#825). */
class CutAnswerRetryTest {

    private lateinit var openAIApi: OpenAIApi
    private lateinit var anthropicApi: AnthropicApi
    private lateinit var ollamaApi: OllamaApi
    private lateinit var service: LLMService
    private val asked = mutableListOf<Int>()
    private val requests = mutableListOf<OpenAIChatRequest>()

    @Before
    fun setup() {
        mockkStatic(Log::class)
        every { Log.w(any<String>(), any<String>()) } returns 0
        openAIApi = mockk()
        anthropicApi = mockk()
        ollamaApi = mockk()
        service = LLMService(openAIApi, anthropicApi, ollamaApi)
    }

    @After
    fun tearDown() = unmockkStatic(Log::class)

    private fun openAIReplies(vararg replies: Response<OpenAIChatResponse>) {
        val queue = ArrayDeque(replies.toList())
        coEvery { openAIApi.chatCompletion(any(), any(), any()) } answers {
            requests += thirdArg<OpenAIChatRequest>()
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
    fun `a retry that fails transiently is tried once, not backed off`() = runTest {
        // a twice-as-long answer can pass the read timeout: re-sending it only adds cost
        val unavailable = { Response.error<OpenAIChatResponse>(503, "{}".toResponseBody()) }
        openAIReplies(answer("cut", "length", 2048), unavailable(), unavailable(), unavailable())

        assertEquals("cut", ask().getOrThrow().content)
        assertEquals(listOf(2048, 4096), asked)
    }

    @Test
    fun `the retry asks what the answer was asked, with only the limit raised`() = runTest {
        openAIReplies(answer("cut", "length", 2048), answer("whole", "stop", 3000))

        service.chat(
            provider = LLMProvider.OPENAI, apiKey = "k", model = "m", systemPrompt = "rubric", userPrompt = "paper",
            maxTokens = 2048, temperature = 0.3
        )

        assertEquals(requests[0].copy(maxTokens = 4096), requests[1])
    }

    @Test
    fun `a cancelled retry is a cancellation, not the cut answer`() = runTest {
        var calls = 0
        coEvery { openAIApi.chatCompletion(any(), any(), any()) } coAnswers {
            if (calls++ == 0) answer("cut", "length", 2048) else awaitCancellation()
        }
        var got: Result<LLMResult>? = null

        val job = launch { got = ask() }
        runCurrent()
        job.cancel()
        job.join()

        assertNull("a stopped run returns no answer", got)
    }

    @Test
    fun `Ollama's done_reason length is a cut, asked again with a context that holds it`() = runTest {
        val sent = mutableListOf<OllamaChatRequest>()
        val queue = ArrayDeque(listOf("length" to 2048, "stop" to 3000))
        coEvery { ollamaApi.chat(any(), any()) } answers {
            sent += secondArg<OllamaChatRequest>()
            val (reason, tokens) = queue.removeFirst()
            Response.success(
                OllamaChatResponse(
                    message = OpenAIChatMessage("assistant", reason),
                    promptEvalCount = 100,
                    evalCount = tokens,
                    doneReason = reason
                )
            )
        }

        val result = service.chat(
            provider = LLMProvider.OLLAMA, apiKey = "", model = "qwen3", systemPrompt = "s", userPrompt = "u",
            maxTokens = 2048
        ).getOrThrow()

        assertEquals("stop", result.content)
        assertEquals(listOf(2048, 4096), sent.map { it.options.numPredict })
        assertEquals(OllamaContext.numCtx(listOf("s", "u"), 4096), sent[1].options.numCtx)
        assertEquals(5048, result.outputTokens)
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
        assertEquals("both requests are paid for", 200, result.inputTokens)
        assertEquals(5048, result.outputTokens)
    }

    @Test
    fun `the raised limit follows the desktop rule`() {
        assertEquals(4096, LLMService.raisedLimit("length", 2048, 2048))
        assertEquals(4096, LLMService.raisedLimit("max_tokens", 2048, 2048))
        assertEquals("a count past the limit is a cut", 4096, LLMService.raisedLimit("length", 2049, 2048))
        assertEquals(16384, LLMService.raisedLimit("length", 8192, 8192))
        assertEquals("capped", 16384, LLMService.raisedLimit("length", 12000, 12000))
        assertNull("no larger limit", LLMService.raisedLimit("length", 16384, 16384))
        assertNull(LLMService.raisedLimit("stop", 2048, 2048))
        assertNull(LLMService.raisedLimit(null, 2048, 2048))
        assertNull("no count stated", LLMService.raisedLimit("length", 0, 2048))
        assertNull(LLMService.raisedLimit("length", 0, 0))
    }

    // ==================== #830: a cut answer with no text ====================

    private fun textless(finishReason: String, outputTokens: Int) = Response.success(
        OpenAIChatResponse(
            id = "x",
            choices = listOf(OpenAIChatChoice(0, OpenAIChatMessage("assistant", null), finishReason)),
            usage = OpenAITokenUsage(promptTokens = 100, completionTokens = outputTokens, totalTokens = 100 + outputTokens)
        )
    )

    private fun assertCutBeforeWriting(result: Result<LLMResult>) {
        val error = result.exceptionOrNull()
        assertTrue("$error", error is LLMError.EmptyResponseError)
        assertTrue(error!!.message!!, error.message!!.contains("before it wrote anything"))
    }

    @Test
    fun `a reply's null content decodes`() {
        val body = """{"id":"x","choices":[{"index":0,"message":{"role":"assistant","content":null},""" +
            """"finish_reason":"length"}],"usage":{"prompt_tokens":1,"completion_tokens":2048,"total_tokens":2049}}"""

        val reply = Json { ignoreUnknownKeys = true }.decodeFromString(OpenAIChatResponse.serializer(), body)

        assertEquals("", LLMResult.fromOpenAI(reply).content)
    }

    @Test
    fun `a textless cut answer is asked once more with twice the limit`() = runTest {
        openAIReplies(textless("length", 2048), answer("{\"score\": 4}", "stop", 2300))

        val result = ask().getOrThrow()

        assertEquals("{\"score\": 4}", result.content)
        assertEquals(listOf(2048, 4096), asked)
        assertEquals(4348, result.outputTokens)
    }

    @Test
    fun `a textless answer cut again fails, naming its limit`() = runTest {
        openAIReplies(textless("length", 2048), textless("length", 4096))

        assertCutBeforeWriting(ask())
        assertEquals(listOf(2048, 4096), asked)
    }

    @Test
    fun `a textless cut answer whose retry fails fails`() = runTest {
        openAIReplies(textless("length", 2048), Response.error(400, """{"error":{"message":"refused"}}""".toResponseBody()))

        assertCutBeforeWriting(ask())
    }

    @Test
    fun `a textless cut answer not asked again fails`() = runTest {
        openAIReplies(textless("length", 900), textless("length", 10))

        assertCutBeforeWriting(ask())
        assertCutBeforeWriting(ask(maxTokens = 10, retryingCut = false))
        assertEquals(listOf(2048, 10), asked)
    }

    @Test
    fun `a textless answer that was not cut stays an empty response, asked once`() = runTest {
        openAIReplies(textless("stop", 300))

        val error = ask().exceptionOrNull()

        assertEquals(LLMError.EmptyResponseError(), error)
        assertEquals(listOf(2048), asked)
    }

    @Test
    fun `Anthropic's thinking-only max_tokens reply is asked again`() = runTest {
        val limits = mutableListOf<Int>()
        val queue = ArrayDeque(
            listOf(
                Triple(listOf(AnthropicContentBlock(type = "thinking")), "max_tokens", 2048),
                Triple(listOf(AnthropicContentBlock(type = "text", text = "whole")), "end_turn", 3000)
            )
        )
        coEvery { anthropicApi.createMessage(any(), any(), any(), any()) } answers {
            limits += arg<AnthropicMessagesRequest>(3).maxTokens
            val (blocks, stop, tokens) = queue.removeFirst()
            Response.success(
                AnthropicMessagesResponse(
                    id = "msg", content = blocks, stopReason = stop,
                    usage = AnthropicUsage(inputTokens = 100, outputTokens = tokens)
                )
            )
        }

        val result = service.chat(
            provider = LLMProvider.ANTHROPIC, apiKey = "k", model = "claude", systemPrompt = "s", userPrompt = "u",
            maxTokens = 2048
        ).getOrThrow()

        assertEquals("whole", result.content)
        assertEquals(listOf(2048, 4096), limits)
    }

    @Test
    fun `a textless reply is an answer only when it was cut`() {
        assertTrue(LLMResult.fromOllama(OllamaChatResponse(message = null, evalCount = 2048, doneReason = "length")).holdsAnswer)
        assertFalse(LLMResult.fromOllama(OllamaChatResponse(message = null, doneReason = "stop")).holdsAnswer)
        assertFalse(LLMResult.fromAnthropic(AnthropicMessagesResponse(content = emptyList(), stopReason = "end_turn")).holdsAnswer)
        assertFalse(LLMResult.fromAnthropic(AnthropicMessagesResponse(content = emptyList(), stopReason = "refusal")).holdsAnswer)
        assertFalse(LLMResult.fromOpenAI(OpenAIChatResponse(id = "x", choices = emptyList())).holdsAnswer)
        assertTrue("an empty text is still an answer", LLMResult.fromOpenAI(answer("", "stop", 1).body()!!).holdsAnswer)
    }

    @Test
    fun `an empty reply that was not cut is paid for, so onUsage hears it`() = runTest {
        openAIReplies(textless("stop", 300))
        val heard = mutableListOf<Pair<Int, Int>>()

        val failed = service.chat(LLMProvider.OPENAI, "k", "m", "s", "u", maxTokens = 2048, onUsage = { i, o -> heard += i to o })

        assertEquals(LLMError.EmptyResponseError(), failed.exceptionOrNull())
        assertEquals(listOf(100 to 300), heard)
    }

    @Test
    fun `Anthropic's refusal is paid for, so onUsage hears it`() = runTest {
        coEvery { anthropicApi.createMessage(any(), any(), any(), any()) } returns Response.success(
            AnthropicMessagesResponse(
                id = "msg", content = emptyList(), stopReason = "refusal",
                usage = AnthropicUsage(inputTokens = 120, outputTokens = 3)
            )
        )
        val heard = mutableListOf<Pair<Int, Int>>()

        val failed = service.chat(
            provider = LLMProvider.ANTHROPIC, apiKey = "k", model = "claude", systemPrompt = "s", userPrompt = "u",
            maxTokens = 2048, onUsage = { i, o -> heard += i to o }
        )

        assertEquals(LLMError.RefusedError("The model claude declined to answer"), failed.exceptionOrNull())
        assertEquals(listOf(120 to 3), heard)
    }

    // ==================== #819: a refusal is a refusal ====================

    @Test
    fun `a refusal fails as one, whatever text came with it, and is asked once`() = runTest {
        openAIReplies(answer("I can't write that study", "content_filter", 12), answer("partial", "refusal", 5))

        assertTrue(ask().exceptionOrNull() is LLMError.RefusedError)
        assertTrue(ask().exceptionOrNull() is LLMError.RefusedError)
        assertEquals("never retried", listOf(2048, 2048), asked)
    }

    @Test
    fun `a cut answer whose retry is refused fails as a refusal`() = runTest {
        // the desktop raises the retry's refusal too, never keeping the cut answer
        openAIReplies(answer("cut", "length", 2048), answer("", "refusal", 4))

        assertTrue(ask().exceptionOrNull() is LLMError.RefusedError)
        assertEquals(listOf(2048, 4096), asked)
    }

    // ==================== #818: each request's real tokens ====================

    @Test
    fun `onUsage hears each request's own tokens, a retry's and a failed answer's too`() = runTest {
        openAIReplies(answer("cut", "length", 2048), answer("whole", "stop", 2300), textless("length", 2048), textless("length", 4096))
        val heard = mutableListOf<Pair<Int, Int>>()

        service.chat(LLMProvider.OPENAI, "k", "m", "s", "u", maxTokens = 2048, onUsage = { i, o -> heard += i to o })
        val failed = service.chat(LLMProvider.OPENAI, "k", "m", "s", "u", maxTokens = 2048, onUsage = { i, o -> heard += i to o })

        assertCutBeforeWriting(failed)
        assertEquals(listOf(100 to 2048, 100 to 2300, 100 to 2048, 100 to 4096), heard)
    }

    @Test
    fun `every task method passes its onUsage to chat`() = runTest {
        // one reply each, its own output count; what the content parses to does not matter
        openAIReplies(*(1..5).map { answer("{}", "stop", it) }.toTypedArray())
        val heard = mutableListOf<Pair<Int, Int>>()
        val sink: UsageSink = { i, o -> heard += i to o }
        val p = LLMProvider.OPENAI

        service.convertToStructuredQuery(p, "k", "m", "claim", onUsage = sink)
        service.generateAlternativeQueries(p, "k", "m", "claim", null, 0, 0, onUsage = sink)
        service.scoreDocument(p, "k", "m", "claim", "title", "abstract", onUsage = sink)
        service.extractCitations(p, "k", "m", "claim", "title", "abstract", onUsage = sink)
        service.generateReport(p, "k", "m", "claim", listOf(LLMService.DocumentCitation("t", "passage")), onUsage = sink)

        assertEquals((1..5).map { 100 to it }, heard)
    }
}
