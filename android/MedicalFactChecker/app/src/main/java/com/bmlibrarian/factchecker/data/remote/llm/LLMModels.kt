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

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

// ==================== OpenAI-Compatible API Models ====================

/**
 * Chat completion request for OpenAI-compatible APIs.
 *
 * Compatible with OpenAI, DeepSeek, Groq, Mistral, and Ollama.
 */
@Serializable
data class OpenAIChatRequest(
    /** Model ID to use for completion. */
    val model: String,
    /** List of messages in the conversation. */
    val messages: List<OpenAIChatMessage>,
    /** Maximum tokens to generate. */
    @SerialName("max_tokens")
    val maxTokens: Int,
    /** Sampling temperature (0.0-2.0). */
    val temperature: Double = 0.0
)

/**
 * Chat message for OpenAI-compatible APIs.
 */
@Serializable
data class OpenAIChatMessage(
    /** Role: "system", "user", or "assistant". */
    val role: String,
    /** Message content. */
    val content: String
)

/**
 * Chat completion response from OpenAI-compatible APIs.
 */
@Serializable
data class OpenAIChatResponse(
    /** Unique ID for this completion. */
    val id: String? = null,
    /** Object type (always "chat.completion"). */
    val `object`: String? = null,
    /** Timestamp of creation. */
    val created: Long? = null,
    /** Model used for completion. */
    val model: String? = null,
    /** List of completion choices. */
    val choices: List<OpenAIChatChoice> = emptyList(),
    /** Token usage statistics. */
    val usage: OpenAITokenUsage? = null
)

/**
 * A completion choice from OpenAI-compatible APIs.
 */
@Serializable
data class OpenAIChatChoice(
    /** Index of this choice. */
    val index: Int = 0,
    /** The generated message. */
    val message: OpenAIChatMessage? = null,
    /** Reason for completion (e.g., "stop", "length"). */
    @SerialName("finish_reason")
    val finishReason: String? = null
)

/**
 * Token usage statistics from OpenAI-compatible APIs.
 */
@Serializable
data class OpenAITokenUsage(
    /** Tokens in the prompt. */
    @SerialName("prompt_tokens")
    val promptTokens: Int = 0,
    /** Tokens in the completion. */
    @SerialName("completion_tokens")
    val completionTokens: Int = 0,
    /** Total tokens used. */
    @SerialName("total_tokens")
    val totalTokens: Int = 0
)

/**
 * Error response from OpenAI-compatible APIs.
 */
@Serializable
data class OpenAIErrorResponse(
    val error: OpenAIError? = null
)

/**
 * Error details from OpenAI-compatible APIs.
 */
@Serializable
data class OpenAIError(
    val message: String? = null,
    val type: String? = null,
    val param: String? = null,
    val code: String? = null
)

// ==================== Anthropic API Models ====================

/**
 * Messages request for Anthropic Claude API.
 *
 * Anthropic uses a different format than OpenAI.
 */
@Serializable
data class AnthropicMessagesRequest(
    /** Model ID to use. */
    val model: String,
    /** Maximum tokens to generate. */
    @SerialName("max_tokens")
    val maxTokens: Int,
    /** System prompt (separate from messages). */
    val system: String? = null,
    /** List of messages in the conversation. */
    val messages: List<AnthropicMessage>,
    /** Sampling temperature (0.0-1.0). */
    val temperature: Double = 0.0
)

/**
 * Message for Anthropic Claude API.
 */
@Serializable
data class AnthropicMessage(
    /** Role: "user" or "assistant". */
    val role: String,
    /** Message content. */
    val content: String
)

/**
 * Messages response from Anthropic Claude API.
 */
@Serializable
data class AnthropicMessagesResponse(
    /** Unique ID for this message. */
    val id: String? = null,
    /** Object type (always "message"). */
    val type: String? = null,
    /** Role of the response (always "assistant"). */
    val role: String? = null,
    /** Content blocks in the response. */
    val content: List<AnthropicContentBlock> = emptyList(),
    /** Model used for completion. */
    val model: String? = null,
    /** Reason for stopping. */
    @SerialName("stop_reason")
    val stopReason: String? = null,
    /** Stop sequence if applicable. */
    @SerialName("stop_sequence")
    val stopSequence: String? = null,
    /** Token usage statistics. */
    val usage: AnthropicUsage? = null
)

/**
 * Content block in Anthropic response.
 */
@Serializable
data class AnthropicContentBlock(
    /** Type of content block (e.g., "text"). */
    val type: String,
    /** Text content (for type="text"). */
    val text: String? = null
)

/**
 * Token usage statistics from Anthropic API.
 */
@Serializable
data class AnthropicUsage(
    /** Tokens in the input. */
    @SerialName("input_tokens")
    val inputTokens: Int = 0,
    /** Tokens in the output. */
    @SerialName("output_tokens")
    val outputTokens: Int = 0
)

/**
 * Error response from Anthropic API.
 */
@Serializable
data class AnthropicErrorResponse(
    val type: String? = null,
    val error: AnthropicError? = null
)

/**
 * Error details from Anthropic API.
 */
@Serializable
data class AnthropicError(
    val type: String? = null,
    val message: String? = null
)

// ==================== Model Listing API Models ====================

/**
 * Response from OpenAI-compatible models list endpoint.
 *
 * Used by OpenAI, Groq, Mistral, and DeepSeek APIs.
 * All return the same response format.
 */
@Serializable
data class OpenAIModelsResponse(
    /** Object type (always "list"). */
    val `object`: String? = null,
    /** List of available models. */
    val data: List<OpenAIModelInfo> = emptyList()
)

/**
 * Model information from OpenAI-compatible APIs.
 */
@Serializable
data class OpenAIModelInfo(
    /** Model identifier (e.g., "gpt-4o"). */
    val id: String,
    /** Object type (always "model"). */
    val `object`: String? = null,
    /** Unix timestamp when model was created. */
    val created: Long? = null,
    /** Organization that owns the model. */
    @SerialName("owned_by")
    val ownedBy: String? = null
)

/**
 * Response from Anthropic models list endpoint.
 */
@Serializable
data class AnthropicModelsResponse(
    /** List of available models. */
    val data: List<AnthropicModelInfo> = emptyList(),
    /** Whether there are more models. */
    @SerialName("has_more")
    val hasMore: Boolean = false,
    /** First model ID for pagination. */
    @SerialName("first_id")
    val firstId: String? = null,
    /** Last model ID for pagination. */
    @SerialName("last_id")
    val lastId: String? = null
)

/**
 * Model information from Anthropic API.
 */
@Serializable
data class AnthropicModelInfo(
    /** Model identifier (e.g., "claude-sonnet-4-5-20250929"). */
    val id: String,
    /** Object type (always "model"). */
    val type: String? = null,
    /** Human-readable display name. */
    @SerialName("display_name")
    val displayName: String? = null,
    /** Creation timestamp. */
    @SerialName("created_at")
    val createdAt: String? = null
)

/**
 * Response from Ollama /api/tags endpoint.
 */
@Serializable
data class OllamaModelsResponse(
    /** List of local models. */
    val models: List<OllamaModelInfo> = emptyList()
)

/**
 * Model information from Ollama API.
 */
@Serializable
data class OllamaModelInfo(
    /** Model name (e.g., "llama3.2:latest"). */
    val name: String,
    /** Last modified timestamp. */
    @SerialName("modified_at")
    val modifiedAt: String? = null,
    /** Model size in bytes. */
    val size: Long? = null,
    /** SHA256 digest of the model. */
    val digest: String? = null,
    /** Model details (family, parameters, quantization). */
    val details: OllamaModelDetails? = null
)

/**
 * Model details from Ollama API.
 */
@Serializable
data class OllamaModelDetails(
    /** File format (e.g., "gguf"). */
    val format: String? = null,
    /** Model family (e.g., "llama"). */
    val family: String? = null,
    /** List of model families. */
    val families: List<String>? = null,
    /** Parameter size (e.g., "8B"). */
    @SerialName("parameter_size")
    val parameterSize: String? = null,
    /** Quantization level (e.g., "Q4_K_M"). */
    @SerialName("quantization_level")
    val quantizationLevel: String? = null
)

// ==================== Unified Result ====================

/**
 * Unified result from any LLM API call.
 *
 * Normalizes responses from OpenAI and Anthropic APIs.
 */
data class LLMResult(
    /** The generated text content. */
    val content: String,
    /** Number of input/prompt tokens used. */
    val inputTokens: Int,
    /** Number of output/completion tokens used. */
    val outputTokens: Int,
    /** Reason for completion (e.g., "stop", "length"). */
    val finishReason: String?,
    /** Model that generated this response. */
    val model: String?
) {
    companion object {
        /**
         * Create LLMResult from OpenAI response.
         */
        fun fromOpenAI(response: OpenAIChatResponse): LLMResult? {
            val choice = response.choices.firstOrNull() ?: return null
            val content = choice.message?.content ?: return null

            return LLMResult(
                content = content,
                inputTokens = response.usage?.promptTokens ?: 0,
                outputTokens = response.usage?.completionTokens ?: 0,
                finishReason = choice.finishReason,
                model = response.model
            )
        }

        /**
         * Create LLMResult from Anthropic response.
         */
        fun fromAnthropic(response: AnthropicMessagesResponse): LLMResult? {
            val textContent = response.content
                .filter { it.type == "text" }
                .mapNotNull { it.text }
                .joinToString("")

            if (textContent.isEmpty()) return null

            return LLMResult(
                content = textContent,
                inputTokens = response.usage?.inputTokens ?: 0,
                outputTokens = response.usage?.outputTokens ?: 0,
                finishReason = response.stopReason,
                model = response.model
            )
        }
    }
}
