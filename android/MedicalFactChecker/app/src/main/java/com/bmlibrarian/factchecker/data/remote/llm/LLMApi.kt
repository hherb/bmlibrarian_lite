package com.bmlibrarian.factchecker.data.remote.llm

import retrofit2.Response
import retrofit2.http.Body
import retrofit2.http.Header
import retrofit2.http.POST
import retrofit2.http.Url

/**
 * Retrofit interface for OpenAI-compatible LLM APIs.
 *
 * Uses dynamic URL to support multiple providers (OpenAI, DeepSeek, Groq, Mistral, Ollama).
 * Authentication is done via Bearer token in Authorization header.
 */
interface OpenAIApi {

    /**
     * Send a chat completion request.
     *
     * @param url Full URL for chat/completions endpoint
     * @param authorization Bearer token authorization header
     * @param request Chat completion request body
     * @return Chat completion response
     */
    @POST
    suspend fun chatCompletion(
        @Url url: String,
        @Header("Authorization") authorization: String,
        @Body request: OpenAIChatRequest
    ): Response<OpenAIChatResponse>
}

/**
 * Retrofit interface for Anthropic Claude API.
 *
 * Anthropic uses a different authentication scheme (x-api-key header)
 * and request/response format than OpenAI-compatible APIs.
 */
interface AnthropicApi {

    /**
     * Send a messages request to Claude.
     *
     * @param url Full URL for messages endpoint
     * @param apiKey API key via x-api-key header
     * @param anthropicVersion API version header (required by Anthropic)
     * @param request Messages request body
     * @return Messages response
     */
    @POST
    suspend fun createMessage(
        @Url url: String,
        @Header("x-api-key") apiKey: String,
        @Header("anthropic-version") anthropicVersion: String,
        @Body request: AnthropicMessagesRequest
    ): Response<AnthropicMessagesResponse>

    companion object {
        /** Current Anthropic API version. */
        const val API_VERSION = "2023-06-01"
    }
}
