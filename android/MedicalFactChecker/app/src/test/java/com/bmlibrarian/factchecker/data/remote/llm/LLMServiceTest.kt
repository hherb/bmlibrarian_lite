package com.bmlibrarian.factchecker.data.remote.llm

import com.bmlibrarian.factchecker.domain.model.LLMError
import com.bmlibrarian.factchecker.domain.model.LLMProvider
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.test.runTest
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertEquals
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
    private lateinit var service: LLMService

    @Before
    fun setup() {
        openAIApi = mockk()
        anthropicApi = mockk()
        service = LLMService(openAIApi, anthropicApi)
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
            model = "claude-sonnet-4-20250514",
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

    // ==================== PubMed Query Conversion Tests ====================

    @Test
    fun `convertToPubMedQuery returns query on success`() = runTest {
        // Arrange
        val expectedQuery = "(aspirin) AND (cardiovascular disease) AND (systematic review[pt])"
        coEvery {
            openAIApi.chatCompletion(any(), any(), any())
        } returns Response.success(
            OpenAIChatResponse(
                id = "test-id",
                choices = listOf(
                    OpenAIChatChoice(
                        index = 0,
                        message = OpenAIChatMessage("assistant", expectedQuery),
                        finishReason = "stop"
                    )
                ),
                usage = null
            )
        )

        // Act
        val result = service.convertToPubMedQuery(
            provider = LLMProvider.OPENAI,
            apiKey = "test-key",
            model = "gpt-4o",
            claim = "Aspirin reduces cardiovascular disease risk"
        )

        // Assert
        assertTrue(result.isSuccess)
        assertEquals(expectedQuery, result.getOrNull())
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
            model = "claude-sonnet-4-20250514",
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
    fun `chat uses correct URL for Ollama provider`() = runTest {
        // Arrange
        coEvery {
            openAIApi.chatCompletion(
                url = eq("http://localhost:11434/v1/chat/completions"),
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
            provider = LLMProvider.OLLAMA,
            apiKey = "", // Ollama doesn't require API key
            model = "llama3.2",
            systemPrompt = "Test",
            userPrompt = "Test"
        )

        // Assert
        coVerify {
            openAIApi.chatCompletion(
                url = "http://localhost:11434/v1/chat/completions",
                authorization = "Bearer ",
                request = any()
            )
        }
    }
}
