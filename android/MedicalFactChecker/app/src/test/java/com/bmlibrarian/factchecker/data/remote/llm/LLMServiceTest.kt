/*
 * BMLibrarian Lite - Biomedical Literature Research Tool
 * Copyright (C) 2024-2025 Dr Horst Herb
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

import com.bmlibrarian.factchecker.di.AppModule
import com.bmlibrarian.factchecker.domain.model.LLMError
import com.bmlibrarian.factchecker.domain.model.LLMProvider
import com.bmlibrarian.factchecker.domain.model.StructuredQuery
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.mockk
import io.mockk.slot
import kotlinx.coroutines.test.runTest
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import retrofit2.Response
import java.io.IOException

/**
 * Unit tests for LLMService.
 *
 * Tests cover:
 * - OpenAI-compatible API calls
 * - Anthropic API calls
 * - Retry logic for transient failures
 * - Error handling for various failure modes
 * - Response parsing for different LLM operations
 */
class LLMServiceTest {

    private lateinit var openAIApi: OpenAIApi
    private lateinit var anthropicApi: AnthropicApi
    private lateinit var ollamaApi: OllamaApi
    private lateinit var service: LLMService

    @Before
    fun setup() {
        openAIApi = mockk()
        anthropicApi = mockk()
        ollamaApi = mockk()
        service = LLMService(openAIApi, anthropicApi, ollamaApi)
    }

    // ==================== OpenAI Chat Tests ====================

    @Test
    fun `chat returns success on valid OpenAI response`() = runTest {
        // Arrange
        val provider = LLMProvider.OPENAI
        val expectedContent = "Test response from GPT"
        coEvery {
            openAIApi.chatCompletion(any(), any(), any())
        } returns Response.success(
            OpenAIChatResponse(
                id = "chatcmpl-123",
                choices = listOf(
                    OpenAIChatChoice(
                        index = 0,
                        message = OpenAIChatMessage("assistant", expectedContent),
                        finishReason = "stop"
                    )
                ),
                usage = OpenAITokenUsage(
                    promptTokens = 100,
                    completionTokens = 50,
                    totalTokens = 150
                )
            )
        )

        // Act
        val result = service.chat(
            provider = provider,
            apiKey = "test-key",
            model = "gpt-4o",
            systemPrompt = "You are a helper",
            userPrompt = "Hello"
        )

        // Assert
        assertTrue(result.isSuccess)
        val llmResult = result.getOrNull()
        assertNotNull(llmResult)
        assertEquals(expectedContent, llmResult?.content)
        assertEquals(100, llmResult?.inputTokens)
        assertEquals(50, llmResult?.outputTokens)
    }

    @Test
    fun `chat returns success on valid Anthropic response`() = runTest {
        // Arrange
        val provider = LLMProvider.ANTHROPIC
        val expectedContent = "Test response from Claude"
        coEvery {
            anthropicApi.createMessage(any(), any(), any(), any())
        } returns Response.success(
            AnthropicMessagesResponse(
                id = "msg-123",
                type = "message",
                role = "assistant",
                content = listOf(
                    AnthropicContentBlock(type = "text", text = expectedContent)
                ),
                usage = AnthropicUsage(inputTokens = 200, outputTokens = 100)
            )
        )

        // Act
        val result = service.chat(
            provider = provider,
            apiKey = "test-key",
            model = "claude-sonnet-4-5-20250929",
            systemPrompt = "You are a helper",
            userPrompt = "Hello"
        )

        // Assert
        assertTrue(result.isSuccess)
        val llmResult = result.getOrNull()
        assertNotNull(llmResult)
        assertEquals(expectedContent, llmResult?.content)
        assertEquals(200, llmResult?.inputTokens)
        assertEquals(100, llmResult?.outputTokens)
    }

    // ==================== Retry Logic Tests ====================

    @Test
    fun `chat retries on transient network failure and succeeds`() = runTest {
        // Arrange
        var callCount = 0
        coEvery {
            openAIApi.chatCompletion(any(), any(), any())
        } answers {
            callCount++
            if (callCount < 3) {
                throw IOException("Network error")
            }
            Response.success(
                OpenAIChatResponse(
                    id = "test-id",
                    choices = listOf(
                        OpenAIChatChoice(
                            index = 0,
                            message = OpenAIChatMessage("assistant", "Success after retry"),
                            finishReason = "stop"
                        )
                    ),
                    usage = null
                )
            )
        }

        // Act
        val result = service.chat(
            provider = LLMProvider.OPENAI,
            apiKey = "test-key",
            model = "gpt-4o",
            systemPrompt = "Test",
            userPrompt = "Test"
        )

        // Assert
        assertTrue(result.isSuccess)
        assertEquals(3, callCount)
        assertEquals("Success after retry", result.getOrNull()?.content)
    }

    @Test
    fun `chat retries on rate limit error`() = runTest {
        // Arrange
        var callCount = 0
        coEvery {
            openAIApi.chatCompletion(any(), any(), any())
        } answers {
            callCount++
            if (callCount < 2) {
                Response.error<OpenAIChatResponse>(
                    429,
                    "Rate limited".toResponseBody(null)
                )
            } else {
                Response.success(
                    OpenAIChatResponse(
                        id = "test-id",
                        choices = listOf(
                            OpenAIChatChoice(
                                index = 0,
                                message = OpenAIChatMessage("assistant", "Success"),
                                finishReason = "stop"
                            )
                        ),
                        usage = null
                    )
                )
            }
        }

        // Act
        val result = service.chat(
            provider = LLMProvider.OPENAI,
            apiKey = "test-key",
            model = "gpt-4o",
            systemPrompt = "Test",
            userPrompt = "Test"
        )

        // Assert
        assertTrue(result.isSuccess)
        assertEquals(2, callCount)
    }

    // ==================== Error Handling Tests ====================

    @Test
    fun `chat fails immediately on auth error without retry`() = runTest {
        // Arrange
        coEvery {
            openAIApi.chatCompletion(any(), any(), any())
        } returns Response.error(401, "Unauthorized".toResponseBody(null))

        // Act
        val result = service.chat(
            provider = LLMProvider.OPENAI,
            apiKey = "invalid-key",
            model = "gpt-4o",
            systemPrompt = "Test",
            userPrompt = "Test"
        )

        // Assert
        assertTrue(result.isFailure)
        val error = result.exceptionOrNull()
        assertTrue(error is LLMError.AuthenticationError)
        coVerify(exactly = 1) { openAIApi.chatCompletion(any(), any(), any()) }
    }

    @Test
    fun `chat fails immediately on invalid request error without retry`() = runTest {
        // Arrange
        coEvery {
            openAIApi.chatCompletion(any(), any(), any())
        } returns Response.error(400, "Bad request".toResponseBody(null))

        // Act
        val result = service.chat(
            provider = LLMProvider.OPENAI,
            apiKey = "test-key",
            model = "invalid-model",
            systemPrompt = "Test",
            userPrompt = "Test"
        )

        // Assert
        assertTrue(result.isFailure)
        val error = result.exceptionOrNull()
        assertTrue(error is LLMError.InvalidRequestError)
        coVerify(exactly = 1) { openAIApi.chatCompletion(any(), any(), any()) }
    }

    @Test
    fun `chat returns EmptyResponseError when response has no choices`() = runTest {
        // Arrange
        coEvery {
            openAIApi.chatCompletion(any(), any(), any())
        } returns Response.success(
            OpenAIChatResponse(
                id = "test-id",
                choices = emptyList(),
                usage = null
            )
        )

        // Act
        val result = service.chat(
            provider = LLMProvider.OPENAI,
            apiKey = "test-key",
            model = "gpt-4o",
            systemPrompt = "Test",
            userPrompt = "Test"
        )

        // Assert
        assertTrue(result.isFailure)
        val error = result.exceptionOrNull()
        assertTrue(error is LLMError.EmptyResponseError)
    }

    @Test
    fun `chat returns EmptyResponseError when message content is null`() = runTest {
        // Arrange
        coEvery {
            openAIApi.chatCompletion(any(), any(), any())
        } returns Response.success(
            OpenAIChatResponse(
                id = "test-id",
                choices = listOf(
                    OpenAIChatChoice(
                        index = 0,
                        message = null,
                        finishReason = "stop"
                    )
                ),
                usage = null
            )
        )

        // Act
        val result = service.chat(
            provider = LLMProvider.OPENAI,
            apiKey = "test-key",
            model = "gpt-4o",
            systemPrompt = "Test",
            userPrompt = "Test"
        )

        // Assert
        assertTrue(result.isFailure)
        val error = result.exceptionOrNull()
        assertTrue(error is LLMError.EmptyResponseError)
    }

    // ==================== Document Scoring Tests ====================

    @Test
    fun `scoreDocument returns valid score and rationale`() = runTest {
        // Arrange
        val jsonResponse = """{"score": 4, "rationale": "Highly relevant to the claim"}"""
        coEvery {
            openAIApi.chatCompletion(any(), any(), any())
        } returns Response.success(
            OpenAIChatResponse(
                id = "test-id",
                choices = listOf(
                    OpenAIChatChoice(
                        index = 0,
                        message = OpenAIChatMessage("assistant", jsonResponse),
                        finishReason = "stop"
                    )
                ),
                usage = OpenAITokenUsage(promptTokens = 500, completionTokens = 50, totalTokens = 550)
            )
        )

        // Act
        val result = service.scoreDocument(
            provider = LLMProvider.OPENAI,
            apiKey = "test-key",
            model = "gpt-4o",
            claim = "Test claim",
            title = "Test Document Title",
            abstractText = "This is the abstract"
        )

        // Assert
        assertTrue(result.isSuccess)
        val (score, rationale) = result.getOrNull()!!
        assertEquals(4, score)
        assertEquals("Highly relevant to the claim", rationale)
    }

    @Test
    fun `scoreDocument handles markdown code block response`() = runTest {
        // Arrange
        val jsonResponse = """```json
{"score": 5, "rationale": "Directly addresses the claim"}
```"""
        coEvery {
            openAIApi.chatCompletion(any(), any(), any())
        } returns Response.success(
            OpenAIChatResponse(
                id = "test-id",
                choices = listOf(
                    OpenAIChatChoice(
                        index = 0,
                        message = OpenAIChatMessage("assistant", jsonResponse),
                        finishReason = "stop"
                    )
                ),
                usage = null
            )
        )

        // Act
        val result = service.scoreDocument(
            provider = LLMProvider.OPENAI,
            apiKey = "test-key",
            model = "gpt-4o",
            claim = "Test claim",
            title = "Test Document",
            abstractText = null
        )

        // Assert
        assertTrue(result.isSuccess)
        assertEquals(5, result.getOrNull()?.first)
    }

    @Test
    fun `scoreDocument handles null abstract`() = runTest {
        // Arrange
        val jsonResponse = """{"score": 2, "rationale": "No abstract available"}"""
        coEvery {
            openAIApi.chatCompletion(any(), any(), any())
        } returns Response.success(
            OpenAIChatResponse(
                id = "test-id",
                choices = listOf(
                    OpenAIChatChoice(
                        index = 0,
                        message = OpenAIChatMessage("assistant", jsonResponse),
                        finishReason = "stop"
                    )
                ),
                usage = null
            )
        )

        // Act
        val result = service.scoreDocument(
            provider = LLMProvider.OPENAI,
            apiKey = "test-key",
            model = "gpt-4o",
            claim = "Test claim",
            title = "Test Document",
            abstractText = null
        )

        // Assert
        assertTrue(result.isSuccess)
        assertEquals(2, result.getOrNull()?.first)
    }

    // ==================== Citation Extraction Tests ====================

    @Test
    fun `extractCitations returns parsed citations`() = runTest {
        // Arrange
        val jsonResponse = """{"citations": [
            {"passage": "The study found significant results", "relevance": "Supports the claim"},
            {"passage": "Additional evidence was presented", "relevance": "Provides context"}
        ]}"""
        coEvery {
            openAIApi.chatCompletion(any(), any(), any())
        } returns Response.success(
            OpenAIChatResponse(
                id = "test-id",
                choices = listOf(
                    OpenAIChatChoice(
                        index = 0,
                        message = OpenAIChatMessage("assistant", jsonResponse),
                        finishReason = "stop"
                    )
                ),
                usage = null
            )
        )

        // Act
        val result = service.extractCitations(
            provider = LLMProvider.OPENAI,
            apiKey = "test-key",
            model = "gpt-4o",
            claim = "Test claim",
            title = "Test Document",
            content = "Full document content here"
        )

        // Assert
        assertTrue(result.isSuccess)
        val citations = result.getOrNull()!!
        assertEquals(2, citations.size)
        assertEquals("The study found significant results", citations[0].passage)
        assertEquals("Supports the claim", citations[0].relevance)
    }

    // ==================== Report Generation Tests ====================

    @Test
    fun `generateReport returns parsed report`() = runTest {
        // Arrange
        val jsonResponse = """{
            "verdict": "LIKELY_SUPPORTED",
            "summary": "Evidence suggests the claim is likely true",
            "report": "## Summary\\n\\nThe evidence supports the claim [1]."
        }"""
        coEvery {
            openAIApi.chatCompletion(any(), any(), any())
        } returns Response.success(
            OpenAIChatResponse(
                id = "test-id",
                choices = listOf(
                    OpenAIChatChoice(
                        index = 0,
                        message = OpenAIChatMessage("assistant", jsonResponse),
                        finishReason = "stop"
                    )
                ),
                usage = null
            )
        )

        // Act
        val result = service.generateReport(
            provider = LLMProvider.OPENAI,
            apiKey = "test-key",
            model = "gpt-4o",
            claim = "Test claim",
            citations = listOf(
                LLMService.DocumentCitation("Test Paper", "Key passage here", "12345")
            )
        )

        // Assert
        assertTrue(result.isSuccess)
        val report = result.getOrNull()!!
        assertEquals("LIKELY_SUPPORTED", report.verdict)
        assertEquals("Evidence suggests the claim is likely true", report.summary)
        assertTrue(report.report.contains("Summary"))
    }

    // ==================== HyDE Generation Tests ====================

    @Test
    fun `generateHypotheticalDocument returns hypothetical abstract`() = runTest {
        // Arrange
        val hypotheticalAbstract = """
            Background: This study investigates the effects of aspirin on cardiovascular outcomes.
            Methods: A randomized controlled trial was conducted with 1000 participants.
            Results: Aspirin reduced cardiovascular events by 25% (p<0.001).
            Conclusion: Regular aspirin use may reduce cardiovascular risk.
        """.trimIndent()
        coEvery {
            openAIApi.chatCompletion(any(), any(), any())
        } returns Response.success(
            OpenAIChatResponse(
                id = "test-id",
                choices = listOf(
                    OpenAIChatChoice(
                        index = 0,
                        message = OpenAIChatMessage("assistant", hypotheticalAbstract),
                        finishReason = "stop"
                    )
                ),
                usage = null
            )
        )

        // Act
        val result = service.generateHypotheticalDocument(
            provider = LLMProvider.OPENAI,
            apiKey = "test-key",
            model = "gpt-4o",
            claim = "Aspirin reduces cardiovascular risk"
        )

        // Assert
        assertTrue(result.isSuccess)
        assertTrue(result.getOrNull()!!.contains("cardiovascular"))
    }

    // ==================== Provider-Specific Tests ====================

    @Test
    fun `chat uses correct URL for Anthropic provider`() = runTest {
        // Arrange
        coEvery {
            anthropicApi.createMessage(
                url = eq("https://api.anthropic.com/v1/messages"),
                apiKey = any(),
                anthropicVersion = any(),
                request = any()
            )
        } returns Response.success(
            AnthropicMessagesResponse(
                id = "msg-123",
                content = listOf(AnthropicContentBlock(type = "text", text = "Response")),
                usage = AnthropicUsage(inputTokens = 100, outputTokens = 50)
            )
        )

        // Act
        service.chat(
            provider = LLMProvider.ANTHROPIC,
            apiKey = "test-key",
            model = "claude-sonnet-4-5-20250929",
            systemPrompt = "Test",
            userPrompt = "Test"
        )

        // Assert
        coVerify {
            anthropicApi.createMessage(
                url = "https://api.anthropic.com/v1/messages",
                apiKey = "test-key",
                anthropicVersion = "2023-06-01",
                request = any()
            )
        }
    }

    /**
     * #758: Claude Opus 4.7 and later answer 400 to `temperature`, so a Claude
     * request carries none, even for a call that asks for one. Encoded with the
     * app's own Json (`encodeDefaults = true`), as Retrofit sends it.
     */
    @Test
    fun `Anthropic request carries no temperature`() = runTest {
        val sent = slot<AnthropicMessagesRequest>()
        coEvery {
            anthropicApi.createMessage(any(), any(), any(), capture(sent))
        } returns Response.success(
            AnthropicMessagesResponse(
                id = "msg-123",
                content = listOf(AnthropicContentBlock(type = "text", text = "Response")),
                usage = AnthropicUsage(inputTokens = 100, outputTokens = 50)
            )
        )

        service.chat(
            provider = LLMProvider.ANTHROPIC,
            apiKey = "test-key",
            model = "claude-opus-5-5",
            systemPrompt = "Test",
            userPrompt = "Test",
            temperature = 0.1
        )

        val body = AppModule.provideJson().encodeToString(AnthropicMessagesRequest.serializer(), sent.captured)
        assertFalse(body, body.contains("temperature"))
        assertTrue("control: the body is the request", body.contains("\"model\":\"claude-opus-5-5\""))
    }

    @Test
    fun `chat uses correct URL for OpenAI provider`() = runTest {
        // Arrange
        coEvery {
            openAIApi.chatCompletion(
                url = eq("https://api.openai.com/v1/chat/completions"),
                authorization = any(),
                request = any()
            )
        } returns Response.success(
            OpenAIChatResponse(
                id = "test-id",
                choices = listOf(
                    OpenAIChatChoice(
                        index = 0,
                        message = OpenAIChatMessage("assistant", "Response"),
                        finishReason = "stop"
                    )
                ),
                usage = null
            )
        )

        // Act
        service.chat(
            provider = LLMProvider.OPENAI,
            apiKey = "test-key",
            model = "gpt-4o",
            systemPrompt = "Test",
            userPrompt = "Test"
        )

        // Assert
        coVerify {
            openAIApi.chatCompletion(
                url = "https://api.openai.com/v1/chat/completions",
                authorization = "Bearer test-key",
                request = any()
            )
        }
    }

    @Test
    fun `Ollama is asked on its native chat endpoint with a context that holds the request`() = runTest {
        // #760: the OpenAI-compatible /v1 takes no num_ctx, so a long prompt was cut silently
        val request = slot<OllamaChatRequest>()
        coEvery { ollamaApi.chat(any(), capture(request)) } returns Response.success(
            OllamaChatResponse(
                model = "llama3.2",
                message = OpenAIChatMessage("assistant", "Response"),
                promptEvalCount = 6000,
                evalCount = 3,
                doneReason = "stop"
            )
        )

        val result = service.chat(
            provider = LLMProvider.OLLAMA,
            apiKey = "", // Ollama doesn't require API key
            model = "llama3.2",
            systemPrompt = "Cite.",
            userPrompt = "a".repeat(20_000),
            maxTokens = 4096
        ).getOrThrow()

        coVerify { ollamaApi.chat(url = "http://localhost:11434/api/chat", request = any()) }
        coVerify(exactly = 0) { openAIApi.chatCompletion(any(), any(), any()) }
        assertEquals(16384, request.captured.options.numCtx)
        assertEquals(4096, request.captured.options.numPredict)
        assertFalse(request.captured.stream)
        assertFalse(request.captured.truncate)
        assertFalse(request.captured.shift)
        assertEquals("Response", result.content)
        assertEquals(6000, result.inputTokens)
        assertEquals(3, result.outputTokens)
    }

    @Test
    fun `an Ollama prompt over its context is refused with Ollama's own reason, not retried`() = runTest {
        val reason = "request (3022 tokens) exceeds the available context size (1024 tokens), try increasing it"
        coEvery { ollamaApi.chat(any(), any()) } returns
            Response.error(400, """{"error":"$reason"}""".toResponseBody(null))

        val error = service.chat(
            provider = LLMProvider.OLLAMA,
            apiKey = "",
            model = "llama3.2",
            systemPrompt = "Test",
            userPrompt = "Test"
        ).exceptionOrNull()

        assertTrue(error is LLMError.InvalidRequestError)
        val message = error?.message.orEmpty()
        assertTrue(message, message.contains(reason))
        coVerify(exactly = 1) { ollamaApi.chat(any(), any()) }
    }

    // ==================== Alternative Query Tests ====================

    @Test
    fun `an alternative-query answer that holds no query is an unusable answer, not a failed request`() = runTest {
        coEvery { openAIApi.chatCompletion(any(), any(), any()) } returns Response.success(
            OpenAIChatResponse(
                choices = listOf(OpenAIChatChoice(message = OpenAIChatMessage("assistant", "I cannot suggest any.")))
            )
        )

        val result = generateAlternativeQueries()

        assertEquals(emptyList<StructuredQuery>(), result.getOrThrow())
    }

    @Test
    fun `an alternative-query answer with no content is an unusable answer`() = runTest {
        coEvery { openAIApi.chatCompletion(any(), any(), any()) } returns Response.success(OpenAIChatResponse())

        val result = generateAlternativeQueries()

        assertEquals(emptyList<StructuredQuery>(), result.getOrThrow())
    }

    @Test
    fun `an alternative-query request that failed stays a failure`() = runTest {
        coEvery { openAIApi.chatCompletion(any(), any(), any()) } returns Response.error(401, "".toResponseBody(null))

        val result = generateAlternativeQueries()

        assertTrue("got $result", result.exceptionOrNull() is LLMError.AuthenticationError)
    }

    @Test
    fun `the first smart search round's prompt names no earlier queries`() {
        val text = alternativeQueriesPrompt(tried = emptyList())

        assertFalse(text.contains("already run"))
        assertTrue("the first round's prompt is unchanged", text.contains("Relevant documents: 1\n\nGenerate 2-3"))
    }

    @Test
    fun `a later smart search round's prompt lists the queries already run`() {
        val text = alternativeQueriesPrompt(tried = listOf("aspirin AND ischaemic stroke", "salicylate AND cerebrovascular"))

        assertTrue(text.contains("already run"))
        assertTrue(text.contains("- aspirin AND ischaemic stroke\n- salicylate AND cerebrovascular\n\nGenerate 2-3"))
    }

    /** The alternative-query prompt for a claim, with the queries already run. */
    private fun alternativeQueriesPrompt(tried: List<String>): String = LLMService.alternativeQueriesPrompt(
        claim = "Aspirin prevents stroke", initialQuery = "aspirin AND stroke",
        totalResults = 4, relevantCount = 1, triedQueries = tried
    )

    /** Ask the service for alternative queries, over the OpenAI-compatible API. */
    private suspend fun generateAlternativeQueries(): Result<List<StructuredQuery>> =
        service.generateAlternativeQueries(
            provider = LLMProvider.OPENAI,
            apiKey = "test-key",
            model = "gpt-4o",
            claim = "Aspirin prevents strokes",
            initialQuery = "aspirin",
            totalResults = 5,
            relevantCount = 0
        )
}
