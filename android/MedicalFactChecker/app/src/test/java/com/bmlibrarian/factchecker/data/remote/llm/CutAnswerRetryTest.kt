/*
 * BMLibrarian Lite - Biomedical Literature Research Tool
 * Copyright (C) 2024-2026 Dr Horst Herb
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

package com.bmlibrarian.factchecker.data.remote.llm

import android.util.Log
import com.bmlibrarian.factchecker.di.AppModule
import com.bmlibrarian.factchecker.domain.model.LLMError
import com.bmlibrarian.factchecker.domain.model.LLMProvider
import com.bmlibrarian.factchecker.util.Constants
import com.bmlibrarian.factchecker.util.OllamaContext
import com.jakewharton.retrofit2.converter.kotlinx.serialization.asConverterFactory
import io.mockk.coEvery
import io.mockk.every
import io.mockk.mockk
import io.mockk.mockkStatic
import io.mockk.unmockkStatic
import io.mockk.verify
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.ResponseBody.Companion.toResponseBody
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import retrofit2.Response
import retrofit2.Retrofit
import java.net.SocketTimeoutException
import java.util.concurrent.TimeUnit

/**
 * #822, #831: an answer cut at its token limit is asked again up to three times,
 * each with twice the last limit, as the desktop does (#825, #831); one still cut
 * fails with [LLMError.TruncatedResponseError], quoting it.
 */
class CutAnswerRetryTest {

    private lateinit var openAIApi: OpenAIApi
    private lateinit var anthropicApi: AnthropicApi
    private lateinit var ollamaApi: OllamaApi
    private lateinit var service: LLMService
    private val asked = mutableListOf<Int>()
    private val tagged = mutableListOf<Int>()
    private val requests = mutableListOf<OpenAIChatRequest>()
    private val logged = mutableListOf<String>()

    @Before
    fun setup() {
        mockkStatic(Log::class)
        every { Log.w(any<String>(), any<String>()) } answers { logged += secondArg<String>(); 0 }
        openAIApi = mockk()
        anthropicApi = mockk()
        ollamaApi = mockk()
        service = LLMService(openAIApi, anthropicApi, ollamaApi)
    }

    @After
    fun tearDown() = unmockkStatic(Log::class)

    private fun openAIReplies(vararg replies: Response<OpenAIChatResponse>) {
        val queue = ArrayDeque(replies.toList())
        coEvery { openAIApi.chatCompletion(any(), any(), any(), any()) } answers {
            val request = thirdArg<OpenAIChatRequest>()
            requests += request
            asked += request.maxTokens ?: request.maxCompletionTokens!!
            tagged += arg<LLMOutputLimit>(3).maxTokens
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

    private fun refused(status: Int, message: String) =
        Response.error<OpenAIChatResponse>(status, """{"error":{"message":"$message"}}""".toResponseBody())

    private suspend fun ask(
        maxTokens: Int = 2048,
        retryingCut: Boolean = true,
        provider: LLMProvider = LLMProvider.OPENAI,
        onUsage: UsageSink = NO_USAGE
    ) = service.chat(
        provider = provider, apiKey = "k", model = "m", systemPrompt = "s", userPrompt = "u",
        maxTokens = maxTokens, retryingCut = retryingCut, onUsage = onUsage
    )

    private fun cutError(result: Result<LLMResult>): LLMError.TruncatedResponseError {
        val error = result.exceptionOrNull()
        assertTrue("got $result", error is LLMError.TruncatedResponseError)
        return error as LLMError.TruncatedResponseError
    }

    @Test
    fun `a cut answer is asked again with twice the limit`() = runTest {
        openAIReplies(answer("{\"score\":", "length", 2048), answer("{\"score\": 4}", "stop", 2300))

        val result = ask().getOrThrow()

        assertEquals("{\"score\": 4}", result.content)
        assertEquals(listOf(2048, 4096), asked)
        assertEquals("both requests are paid for", 200, result.inputTokens)
        assertEquals(4348, result.outputTokens)
    }

    @Test
    fun `each retry doubles the last limit, three times`() = runTest {
        openAIReplies(
            answer("a", "length", 2048), answer("b", "length", 4096), answer("c", "length", 8192),
            answer("whole", "stop", 9000)
        )

        val result = ask().getOrThrow()

        assertEquals("whole", result.content)
        assertEquals(listOf(2048, 4096, 8192, 16384), asked)
        assertEquals("each request's read timeout follows its own limit", asked, tagged)
        assertEquals("every request is paid for", 400, result.inputTokens)
        assertEquals(2048 + 4096 + 8192 + 9000, result.outputTokens)
    }

    @Test
    fun `an answer still cut after three retries fails, quoting the last answer`() = runTest {
        openAIReplies(
            answer("a", "length", 2048), answer("b", "length", 4096), answer("c", "length", 8192),
            answer("{\"score\": 4, \"rationale\": \"the tri", "length", 16384)
        )

        val error = cutError(ask())

        assertEquals("four requests, never a fifth", listOf(2048, 4096, 8192, 16384), asked)
        assertEquals(
            "The answer from m reached its token limit (16384 tokens) and is incomplete. The answer as cut:\n\n" +
                "{\"score\": 4, \"rationale\": \"the tri",
            error.message
        )
        assertEquals(16384, error.maxTokens)
        assertEquals(16384, error.outputTokens)
        assertEquals("{\"score\": 4, \"rationale\": \"the tri", error.content)
    }

    @Test
    fun `every cut answer is logged with its text, once`() = runTest {
        openAIReplies(answer("first", "length", 2048), answer("second", "length", 4096), answer("whole", "stop", 10))

        ask()

        assertEquals(
            listOf(
                "The answer from m reached its token limit (2048; 2048 tokens generated, attempt 0); " +
                    "asking again with 4096. The answer as cut:\nfirst",
                "The answer from m reached its token limit (4096; 4096 tokens generated, attempt 1); " +
                    "asking again with 8192. The answer as cut:\nsecond"
            ),
            logged
        )
    }

    @Test
    fun `a retry that fails is tried once and fails with the cut answer, naming the failure`() = runTest {
        // a twice-as-long answer can pass the read timeout: re-sending it only adds cost
        val unavailable = { Response.error<OpenAIChatResponse>(503, "{\"error\":\"sk-secret\"}".toResponseBody()) }
        openAIReplies(answer("cut", "length", 2048), unavailable(), unavailable(), unavailable())

        val error = cutError(ask())

        assertEquals(listOf(2048, 4096), asked)
        assertEquals(
            "The answer from m reached its token limit (2048 tokens) and is incomplete; asking again with " +
                "4096 tokens failed (HTTP 503). The answer as cut:\n\ncut",
            error.message
        )
        assertFalse("never the provider's body", error.message.contains("sk-secret"))
        assertFalse(LLMError.isRetryable(error))
    }

    @Test
    fun `a retry that times out is not sent again, and the cut error names the timeout`() = runTest {
        var calls = 0
        coEvery { openAIApi.chatCompletion(any(), any(), any(), any()) } answers {
            if (calls++ == 0) answer("cut", "length", 2048) else throw SocketTimeoutException("timeout")
        }

        val error = cutError(ask())

        assertEquals("one request per retry", 2, calls)
        assertTrue(error.message, error.message.contains("; asking again with 4096 tokens failed (SocketTimeoutException)."))
    }

    @Test
    fun `a retry refused for a limit past the model's maximum is asked again within it`() = runTest {
        openAIReplies(
            answer("cut", "length", 2048),
            refused(400, "max_tokens: 4096 > 3000, which is the maximum allowed number of output tokens for claude"),
            answer("whole", "stop", 2500)
        )

        assertEquals("whole", ask(provider = LLMProvider.DEEPSEEK).getOrThrow().content)
        assertEquals(listOf(2048, 4096, 3000), asked)
    }

    @Test
    fun `an answer cut at the model's stated maximum fails, not asked past it`() = runTest {
        openAIReplies(
            answer("first", "length", 2048),
            refused(400, "This model supports at most 3000 completion tokens, whereas you provided 4096."),
            answer("second", "length", 3000)
        )

        val error = cutError(ask())

        assertEquals("the refused request is not an attempt", listOf(2048, 4096, 3000), asked)
        assertEquals(3000, error.maxTokens)
        assertEquals("second", error.content)
        assertEquals("the text is logged once per answer", 2, logged.count { it.contains("The answer as cut:") })
    }

    @Test
    fun `a stated maximum not below the raised limit fails the retry, not asked again`() = runTest {
        for (maximum in listOf(9000, 4096)) {
            asked.clear()
            openAIReplies(
                answer("cut", "length", 2048),
                refused(400, "max_tokens: 4096 > $maximum, which is the maximum allowed number of output tokens for m")
            )

            val error = cutError(ask(provider = LLMProvider.DEEPSEEK))

            assertEquals("asking within $maximum changes nothing", listOf(2048, 4096), asked)
            assertTrue(error.message, error.message.contains("failed (HTTP 400)"))
        }
    }

    @Test
    fun `a 400 stating no maximum fails the retry`() = runTest {
        openAIReplies(answer("cut", "length", 2048), refused(400, "refused"))

        val error = cutError(ask())

        assertEquals(listOf(2048, 4096), asked)
        assertTrue(error.message, error.message.contains("failed (HTTP 400)"))
    }

    @Test
    fun `the retry asks what the answer was asked, with only the limit raised`() = runTest {
        openAIReplies(answer("cut", "length", 2048), answer("whole", "stop", 3000))

        service.chat(
            provider = LLMProvider.DEEPSEEK, apiKey = "k", model = "m", systemPrompt = "rubric", userPrompt = "paper",
            maxTokens = 2048, temperature = 0.3
        )

        assertEquals(requests[0].copy(maxTokens = 4096), requests[1])
    }

    @Test
    fun `OpenAI is sent max_completion_tokens, DeepSeek max_tokens`() = runTest {
        openAIReplies(answer("a", "stop", 1), answer("b", "stop", 1))
        val json = AppModule.provideJson()

        ask(provider = LLMProvider.OPENAI)
        ask(provider = LLMProvider.DEEPSEEK)

        val openAI = json.encodeToString(OpenAIChatRequest.serializer(), requests[0])
        val deepSeek = json.encodeToString(OpenAIChatRequest.serializer(), requests[1])
        assertTrue(openAI, openAI.contains("\"max_completion_tokens\":2048"))
        assertFalse(openAI, openAI.contains("\"max_tokens\""))
        assertTrue(deepSeek, deepSeek.contains("\"max_tokens\":2048"))
        assertFalse(deepSeek, deepSeek.contains("max_completion_tokens"))
    }

    @Test
    fun `a cancelled retry is a cancellation, not the cut answer`() = runTest {
        var calls = 0
        coEvery { openAIApi.chatCompletion(any(), any(), any(), any()) } coAnswers {
            if (calls++ == 0) answer("cut", "length", 2048) else awaitCancellation()
        }
        var got: Result<LLMResult>? = null

        val job = launch { got = ask() }
        runCurrent()
        job.cancel()
        job.join()

        assertNull("a stopped run returns no answer", got)
    }

    private fun ollamaReplies(sent: MutableList<OllamaChatRequest>, promptTokens: Int, vararg replies: Pair<String, Int>) {
        val queue = ArrayDeque(replies.toList())
        coEvery { ollamaApi.chat(any(), any(), any()) } answers {
            sent += secondArg<OllamaChatRequest>()
            tagged += thirdArg<LLMOutputLimit>().maxTokens
            val (reason, tokens) = queue.removeFirst()
            Response.success(
                OllamaChatResponse(
                    message = OpenAIChatMessage("assistant", reason),
                    promptEvalCount = promptTokens,
                    evalCount = tokens,
                    doneReason = reason
                )
            )
        }
    }

    @Test
    fun `Ollama's done_reason length is a cut, asked again with a context that holds it`() = runTest {
        val sent = mutableListOf<OllamaChatRequest>()
        ollamaReplies(sent, 100, "length" to 2048, "stop" to 3000)

        val result = ask(provider = LLMProvider.OLLAMA).getOrThrow()

        assertEquals("stop", result.content)
        assertEquals(listOf(2048, 4096), sent.map { it.options.numPredict })
        assertEquals("each request's read timeout follows its own limit", listOf(2048, 4096), tagged)
        assertEquals(OllamaContext.numCtx(listOf("s", "u"), 4096), sent[1].options.numCtx)
        assertEquals(5048, result.outputTokens)
    }

    @Test
    fun `Ollama's retry is capped by the room its largest context leaves`() = runTest {
        val sent = mutableListOf<OllamaChatRequest>()
        val prompt = Constants.OLLAMA_MAX_NUM_CTX - Constants.OLLAMA_TEMPLATE_TOKENS - 3000
        ollamaReplies(sent, prompt, "length" to 2048, "length" to 3000)

        val error = cutError(ask(provider = LLMProvider.OLLAMA))

        assertEquals("room spent: not asked a third time", listOf(2048, 3000), sent.map { it.options.numPredict })
        assertEquals(3000, error.maxTokens)
    }

    @Test
    fun `an answer cut short of its limit is not asked again, and fails`() = runTest {
        // the context window ran out: a larger limit does not change that
        openAIReplies(answer("cut", "length", 900))

        assertEquals("cut", cutError(ask()).content)
        assertEquals(listOf(2048), asked)
    }

    @Test
    fun `a finished answer and the connection test are asked once`() = runTest {
        openAIReplies(answer("whole", "stop", 2048), answer("O", "length", 10))

        ask()
        val test = ask(maxTokens = 10, retryingCut = false)

        assertEquals(listOf(2048, 10), asked)
        assertEquals("the connection test's cut answer is still an answer", "O", test.getOrThrow().content)
    }

    @Test
    fun `Anthropic's max_tokens stop is a cut`() = runTest {
        val limits = mutableListOf<Int>()
        val queue = ArrayDeque(listOf("max_tokens" to 2048, "end_turn" to 3000))
        coEvery { anthropicApi.createMessage(any(), any(), any(), any(), any()) } answers {
            limits += arg<AnthropicMessagesRequest>(3).maxTokens
            tagged += arg<LLMOutputLimit>(4).maxTokens
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

        val result = ask(provider = LLMProvider.ANTHROPIC).getOrThrow()

        assertEquals("end_turn", result.content)
        assertEquals(listOf(2048, 4096), limits)
        assertEquals("each request's read timeout follows its own limit", limits, tagged)
        assertEquals("both requests are paid for", 200, result.inputTokens)
        assertEquals(5048, result.outputTokens)
    }

    @Test
    fun `the raised limit follows the desktop rule`() {
        assertEquals(4096, LLMService.raisedLimit(2048, 2048, null))
        assertEquals("a count past the limit is a cut", 4096, LLMService.raisedLimit(2049, 2048, null))
        assertEquals("no fixed cap", 32768, LLMService.raisedLimit(16384, 16384, null, attempt = 2))
        assertEquals("capped by the room", 3000, LLMService.raisedLimit(2048, 2048, 3000))
        assertNull("room spent", LLMService.raisedLimit(3000, 3000, 3000))
        assertNull("three retries spent", LLMService.raisedLimit(16384, 16384, null, attempt = 3))
        assertNull("stopped short", LLMService.raisedLimit(900, 2048, null))
        assertNull("no count stated", LLMService.raisedLimit(0, 2048, null))
        assertNull(LLMService.raisedLimit(0, 0, null))
    }

    @Test
    fun `the model's stated maximum is read from each probed refusal`() {
        assertEquals(
            64000,
            LLMService.statedOutputMaximum(
                "max_tokens: 10000000 > 64000, which is the maximum allowed number of output tokens for claude-sonnet-4-5-20250929"
            )
        )
        assertEquals(
            128000,
            LLMService.statedOutputMaximum(
                "max_tokens is too large: 10000000. This model supports at most 128000 completion tokens, " +
                    "whereas you provided 10000000."
            )
        )
        assertEquals(
            393216,
            LLMService.statedOutputMaximum(
                "Invalid max_tokens value, the valid range of max_tokens is [1, 393216] (request_id: abc)"
            )
        )
        assertNull(
            LLMService.statedOutputMaximum(
                "Unsupported parameter: 'max_tokens' is not supported with this model. Use 'max_completion_tokens' instead."
            )
        )
    }

    // ==================== #831: timeouts scale with the limit ====================

    @Test
    fun `the timeout scale is one per 8192 tokens, rounded up`() {
        assertEquals(1, LLMService.timeoutScale(0))
        assertEquals(1, LLMService.timeoutScale(2048))
        assertEquals(1, LLMService.timeoutScale(8192))
        assertEquals(2, LLMService.timeoutScale(8193))
        assertEquals(2, LLMService.timeoutScale(16384))
        assertEquals(8, LLMService.timeoutScale(65536))
    }

    @Test
    fun `an untagged request keeps the client's read timeout`() {
        val chain = mockk<Interceptor.Chain>(relaxed = true)
        every { chain.request() } returns Request.Builder().url("http://localhost/").build()

        llmReadTimeoutInterceptor(120).intercept(chain)

        verify(exactly = 0) { chain.withReadTimeout(any(), any()) }
        verify { chain.proceed(any()) }
    }

    @Test
    fun `a chat request's read timeout grows with its limit, and its tag is never sent`() = runBlocking {
        val server = MockWebServer()
        server.enqueue(MockResponse().setBody("""{"id":"x","choices":[]}"""))
        server.start()
        try {
            var readTimeoutMillis = 0
            val client = OkHttpClient.Builder()
                .readTimeout(120, TimeUnit.SECONDS)
                .addInterceptor(llmReadTimeoutInterceptor(120))
                .addInterceptor { chain -> readTimeoutMillis = chain.readTimeoutMillis(); chain.proceed(chain.request()) }
                .build()
            val api = Retrofit.Builder()
                .baseUrl(server.url("/"))
                .client(client)
                .addConverterFactory(AppModule.provideJson().asConverterFactory("application/json".toMediaType()))
                .build()
                .create(OpenAIApi::class.java)

            api.chatCompletion(
                server.url("/v1/chat/completions").toString(), "Bearer k",
                OpenAIChatRequest(model = "m", messages = emptyList(), maxTokens = 16384), LLMOutputLimit(16384)
            )

            assertEquals(240_000, readTimeoutMillis)
            val sent = server.takeRequest()
            assertFalse(sent.headers.toString(), sent.headers.any { (_, value) -> value.contains("16384") })
        } finally {
            server.shutdown()
        }
    }

    // ==================== #830: a cut answer with no text ====================

    private fun textless(finishReason: String, outputTokens: Int) = Response.success(
        OpenAIChatResponse(
            id = "x",
            choices = listOf(OpenAIChatChoice(0, OpenAIChatMessage("assistant", null), finishReason)),
            usage = OpenAITokenUsage(promptTokens = 100, completionTokens = outputTokens, totalTokens = 100 + outputTokens)
        )
    )

    @Test
    fun `a reply's null content decodes`() {
        val body = """{"id":"x","choices":[{"index":0,"message":{"role":"assistant","content":null},""" +
            """"finish_reason":"length"}],"usage":{"prompt_tokens":1,"completion_tokens":2048,"total_tokens":2049}}"""

        val reply = Json { ignoreUnknownKeys = true }.decodeFromString(OpenAIChatResponse.serializer(), body)

        assertEquals("", LLMResult.fromOpenAI(reply).content)
    }

    @Test
    fun `a textless cut answer is asked again with twice the limit`() = runTest {
        openAIReplies(textless("length", 2048), answer("{\"score\": 4}", "stop", 2300))

        val result = ask().getOrThrow()

        assertEquals("{\"score\": 4}", result.content)
        assertEquals(listOf(2048, 4096), asked)
        assertEquals(4348, result.outputTokens)
    }

    @Test
    fun `the connection test's textless cut answer fails, as on iOS`() = runTest {
        openAIReplies(textless("length", 10))

        assertEquals(10, cutError(ask(maxTokens = 10, retryingCut = false)).maxTokens)
        assertEquals("not asked again", listOf(10), asked)
    }

    @Test
    fun `a textless cut answer not asked again fails with the cut error, an empty quote`() = runTest {
        openAIReplies(textless("length", 900))

        val error = cutError(ask())

        assertEquals(
            "The answer from m reached its token limit (2048 tokens) and is incomplete. The answer as cut:\n\n",
            error.message
        )
        assertEquals("", error.content)
        assertEquals(listOf(2048), asked)
    }

    @Test
    fun `the cut error names the tokens generated when the limit is unknown`() {
        val error = LLMService.cutError("m", 0, LLMResult("x", 1, 700, "length", "m"))

        assertEquals(
            "The answer from m reached its token limit (700 tokens generated) and is incomplete. The answer as cut:\n\nx",
            error.message
        )
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
        coEvery { anthropicApi.createMessage(any(), any(), any(), any(), any()) } answers {
            limits += arg<AnthropicMessagesRequest>(3).maxTokens
            val (blocks, stop, tokens) = queue.removeFirst()
            Response.success(
                AnthropicMessagesResponse(
                    id = "msg", content = blocks, stopReason = stop,
                    usage = AnthropicUsage(inputTokens = 100, outputTokens = tokens)
                )
            )
        }

        val result = ask(provider = LLMProvider.ANTHROPIC).getOrThrow()

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

        val failed = ask(onUsage = { i, o -> heard += i to o })

        assertEquals(LLMError.EmptyResponseError(), failed.exceptionOrNull())
        assertEquals(listOf(100 to 300), heard)
    }

    @Test
    fun `Anthropic's refusal is paid for, so onUsage hears it`() = runTest {
        coEvery { anthropicApi.createMessage(any(), any(), any(), any(), any()) } returns Response.success(
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
    fun `onUsage hears each request's own tokens, every retry's and a failed answer's too`() = runTest {
        openAIReplies(
            answer("cut", "length", 2048), answer("whole", "stop", 2300),
            textless("length", 2048), textless("length", 4096), textless("length", 8192), textless("length", 16384)
        )
        val heard = mutableListOf<Pair<Int, Int>>()
        val sink: UsageSink = { i, o -> heard += i to o }

        ask(onUsage = sink)
        val failed = ask(onUsage = sink)

        cutError(failed)
        assertEquals(
            listOf(100 to 2048, 100 to 2300, 100 to 2048, 100 to 4096, 100 to 8192, 100 to 16384),
            heard
        )
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

    @Test
    fun `an unreadable query answer is a parse failure, and one still cut stays a cut`() = runTest {
        // the workflow searches the claim itself for exactly these two (#840)
        openAIReplies(answer("not json", "stop", 10))
        val unreadable = service.convertToStructuredQuery(LLMProvider.OPENAI, "k", "m", "claim")
        assertTrue("got $unreadable", unreadable.exceptionOrNull() is LLMError.ParseError)

        openAIReplies(*(0..3).map { answer("{\"concepts\": [", "length", Constants.LLM_QUERY_MAX_TOKENS shl it) }.toTypedArray())
        val cut = service.convertToStructuredQuery(LLMProvider.OPENAI, "k", "m", "claim")
        assertTrue("got $cut", cut.exceptionOrNull() is LLMError.TruncatedResponseError)
    }

    @Test
    fun `a cut alternative-query answer is a failure, not an unusable answer`() = runTest {
        openAIReplies(*(0..3).map { answer("[{\"concepts\": [", "length", 4096 shl it) }.toTypedArray())

        val result = service.generateAlternativeQueries(LLMProvider.OPENAI, "k", "m", "claim", null, 0, 0)

        assertTrue("got $result", result.exceptionOrNull() is LLMError.TruncatedResponseError)
    }
}
