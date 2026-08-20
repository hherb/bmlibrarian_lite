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

package com.bmlibrarian.factchecker.domain.model

/**
 * LLM provider configuration.
 *
 * Represents a supported LLM API provider with its base URL, default model,
 * available models, and capabilities. Mirrors iOS LLMProvider for cross-platform
 * consistency.
 *
 * @property id Unique identifier for this provider (e.g., "anthropic", "openai")
 * @property displayName Human-readable name for UI display
 * @property baseUrl Base URL for the API endpoint
 * @property defaultModel Default model ID to use when none specified
 * @property models List of available models with pricing information
 * @property supportsModelFetching Whether the API supports listing available models
 * @property requiresApiKey Whether an API key is required (false for local providers)
 * @property allowsManualModelEntry Whether the user may type a model name this provider
 *   does not list. Local and self-hosted endpoints are the user's own, so a name they
 *   enter is a deliberate choice and must not be second-guessed; hosted providers own
 *   their catalogue instead, so a selection missing from it is a retired model rather
 *   than a preference. Mirrors iOS `LLMProvider.allowsManualModelEntry`.
 * @property usesAnthropicFormat Whether this provider uses Anthropic's native API format
 */
data class LLMProvider(
    val id: String,
    val displayName: String,
    val baseUrl: String,
    val defaultModel: String,
    val models: List<ModelInfo>,
    val supportsModelFetching: Boolean = false,
    val requiresApiKey: Boolean = true,
    val allowsManualModelEntry: Boolean = false,
    val usesAnthropicFormat: Boolean = false
) {
    companion object {
        /**
         * Anthropic Claude API provider.
         * Uses native Anthropic API format with x-api-key authentication.
         * Updated: January 2026 - Claude 4.5 series
         */
        val ANTHROPIC = LLMProvider(
            id = "anthropic",
            displayName = "Anthropic (Claude)",
            baseUrl = "https://api.anthropic.com/v1",
            defaultModel = "claude-sonnet-4-5-20250929",
            models = listOf(
                // Claude 4.5 Series (Latest - January 2026)
                ModelInfo("claude-sonnet-4-5-20250929", "Claude Sonnet 4.5", 3.00, 15.00),
                ModelInfo("claude-haiku-4-5-20251001", "Claude Haiku 4.5", 1.00, 5.00),
                ModelInfo("claude-opus-4-5-20251101", "Claude Opus 4.5", 5.00, 25.00),
                // Legacy models still available
                ModelInfo("claude-sonnet-4-20250514", "Claude Sonnet 4", 3.00, 15.00),
                ModelInfo("claude-3-7-sonnet-20250219", "Claude 3.7 Sonnet", 3.00, 15.00)
            ),
            supportsModelFetching = true,
            usesAnthropicFormat = true
        )

        /**
         * OpenAI API provider.
         * Standard OpenAI-compatible API format.
         * Updated: January 2026 - GPT-5 series
         */
        val OPENAI = LLMProvider(
            id = "openai",
            displayName = "OpenAI",
            baseUrl = "https://api.openai.com/v1",
            defaultModel = "gpt-5.2",
            models = listOf(
                // GPT-5 Series (Latest - January 2026)
                ModelInfo("gpt-5.2", "GPT-5.2", 2.00, 8.00),
                ModelInfo("o4-mini", "o4-mini", 1.10, 4.40),
                ModelInfo("o3", "o3", 2.00, 8.00),
                ModelInfo("gpt-4o", "GPT-4o", 2.50, 10.00),
                ModelInfo("gpt-4o-mini", "GPT-4o Mini", 0.15, 0.60)
            ),
            supportsModelFetching = true
        )

        /**
         * DeepSeek API provider.
         * OpenAI-compatible API with competitive pricing.
         * Updated: August 2026 - DeepSeek V4. The V3 IDs deepseek-chat and
         * deepseek-reasoner were retired in July 2026.
         * Prices are peak-hour, cache-miss rates; off-peak is half.
         */
        val DEEPSEEK = LLMProvider(
            id = "deepseek",
            displayName = "DeepSeek",
            baseUrl = "https://api.deepseek.com/v1",
            defaultModel = "deepseek-v4-flash",
            models = listOf(
                ModelInfo("deepseek-v4-flash", "DeepSeek V4 Flash", 0.44, 1.32),
                ModelInfo("deepseek-v4-pro", "DeepSeek V4 Pro", 1.32, 3.96)
            ),
            supportsModelFetching = true
        )

        /**
         * Groq API provider.
         * Fast inference with OpenAI-compatible API.
         * Updated: January 2026 - Llama 4 series
         */
        val GROQ = LLMProvider(
            id = "groq",
            displayName = "Groq",
            baseUrl = "https://api.groq.com/openai/v1",
            defaultModel = "llama-4-maverick-17b-128e-instruct",
            models = listOf(
                // Llama 4 Series (Latest - January 2026)
                ModelInfo("llama-4-maverick-17b-128e-instruct", "Llama 4 Maverick", 0.50, 0.77),
                ModelInfo("llama-4-scout-17b-16e-instruct", "Llama 4 Scout", 0.11, 0.34),
                ModelInfo("llama-3.3-70b-versatile", "Llama 3.3 70B", 0.59, 0.79),
                ModelInfo("llama-3.1-8b-instant", "Llama 3.1 8B", 0.05, 0.08)
            ),
            supportsModelFetching = true
        )

        /**
         * Mistral API provider.
         * OpenAI-compatible API from Mistral AI.
         * Updated: January 2026
         */
        val MISTRAL = LLMProvider(
            id = "mistral",
            displayName = "Mistral AI",
            baseUrl = "https://api.mistral.ai/v1",
            defaultModel = "mistral-large-latest",
            models = listOf(
                ModelInfo("mistral-large-latest", "Mistral Large", 2.00, 6.00),
                ModelInfo("mistral-medium-latest", "Mistral Medium", 2.70, 8.10),
                ModelInfo("mistral-small-latest", "Mistral Small", 0.20, 0.60),
                ModelInfo("codestral-latest", "Codestral", 0.30, 0.90),
                ModelInfo("open-mistral-nemo", "Mistral Nemo", 0.15, 0.15)
            ),
            supportsModelFetching = true
        )

        /**
         * Ollama local provider.
         * For running local LLM models. No API key required.
         */
        val OLLAMA = LLMProvider(
            id = "ollama",
            displayName = "Ollama (Local)",
            baseUrl = "http://localhost:11434/v1",
            defaultModel = "llama3.2",
            models = listOf(
                ModelInfo("llama3.2", "Llama 3.2", 0.0, 0.0),
                ModelInfo("llama3.1", "Llama 3.1", 0.0, 0.0),
                ModelInfo("mistral", "Mistral 7B", 0.0, 0.0),
                ModelInfo("mixtral", "Mixtral 8x7B", 0.0, 0.0),
                ModelInfo("phi3", "Phi-3", 0.0, 0.0)
            ),
            supportsModelFetching = true,
            requiresApiKey = false,
            allowsManualModelEntry = true
        )

        /**
         * Custom provider for user-defined endpoints.
         * Allows connecting to any OpenAI-compatible API.
         */
        val CUSTOM = LLMProvider(
            id = "custom",
            displayName = "Custom",
            baseUrl = "",
            defaultModel = "",
            models = emptyList(),
            allowsManualModelEntry = true
        )

        /** List of all built-in providers. */
        val ALL_PROVIDERS = listOf(ANTHROPIC, OPENAI, DEEPSEEK, GROQ, MISTRAL, OLLAMA, CUSTOM)

        /**
         * Find a provider by its ID.
         *
         * @param id The provider ID to look up
         * @return The matching provider, or null if not found
         */
        fun fromId(id: String): LLMProvider? = ALL_PROVIDERS.find { it.id == id }
    }

    /**
     * Get a model by its ID.
     *
     * @param modelId The model ID to look up
     * @return The matching model info, or null if not found
     */
    fun getModel(modelId: String): ModelInfo? = models.find { it.id == modelId }

    /**
     * Get the chat completions endpoint URL.
     *
     * @return Full URL for chat completions API
     */
    val chatCompletionsUrl: String
        get() = if (usesAnthropicFormat) {
            "$baseUrl/messages"
        } else {
            "$baseUrl/chat/completions"
        }
}

/**
 * Model information with pricing.
 *
 * Contains model identification and pricing data for cost calculation.
 * Prices are specified per 1 million tokens in USD.
 *
 * @property id Model identifier used in API requests
 * @property displayName Human-readable model name for UI display
 * @property inputPricePer1M Cost per 1 million input tokens in USD
 * @property outputPricePer1M Cost per 1 million output tokens in USD
 */
data class ModelInfo(
    val id: String,
    val displayName: String,
    val inputPricePer1M: Double,
    val outputPricePer1M: Double
) {
    /**
     * Calculate cost for given token counts.
     *
     * @param inputTokens Number of input (prompt) tokens
     * @param outputTokens Number of output (completion) tokens
     * @return Total cost in USD
     */
    fun calculateCost(inputTokens: Int, outputTokens: Int): Double {
        val inputCost = (inputTokens / TOKENS_PER_MILLION) * inputPricePer1M
        val outputCost = (outputTokens / TOKENS_PER_MILLION) * outputPricePer1M
        return inputCost + outputCost
    }

    /**
     * Check if this model is free (local/zero cost).
     *
     * @return true if both input and output prices are zero
     */
    val isFree: Boolean
        get() = inputPricePer1M == 0.0 && outputPricePer1M == 0.0

    companion object {
        /** Number of tokens per million for cost calculation. */
        private const val TOKENS_PER_MILLION = 1_000_000.0

        /** Default model info for unknown models. */
        val UNKNOWN = ModelInfo(
            id = "unknown",
            displayName = "Unknown Model",
            inputPricePer1M = 0.0,
            outputPricePer1M = 0.0
        )
    }
}
