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
    val usesAnthropicFormat: Boolean = false
) {
    companion object {
        /**
         * Anthropic Claude API provider.
         * Uses native Anthropic API format with x-api-key authentication.
         */
        val ANTHROPIC = LLMProvider(
            id = "anthropic",
            displayName = "Anthropic",
            baseUrl = "https://api.anthropic.com/v1",
            defaultModel = "claude-sonnet-4-20250514",
            models = listOf(
                ModelInfo("claude-sonnet-4-20250514", "Claude Sonnet 4", 3.00, 15.00),
                ModelInfo("claude-opus-4-20250514", "Claude Opus 4", 15.00, 75.00),
                ModelInfo("claude-haiku-3-5-20250514", "Claude 3.5 Haiku", 0.80, 4.00)
            ),
            usesAnthropicFormat = true
        )

        /**
         * OpenAI API provider.
         * Standard OpenAI-compatible API format.
         */
        val OPENAI = LLMProvider(
            id = "openai",
            displayName = "OpenAI",
            baseUrl = "https://api.openai.com/v1",
            defaultModel = "gpt-4o",
            models = listOf(
                ModelInfo("gpt-4o", "GPT-4o", 2.50, 10.00),
                ModelInfo("gpt-4o-mini", "GPT-4o Mini", 0.15, 0.60),
                ModelInfo("gpt-4-turbo", "GPT-4 Turbo", 10.00, 30.00)
            ),
            supportsModelFetching = true
        )

        /**
         * DeepSeek API provider.
         * OpenAI-compatible API with competitive pricing.
         */
        val DEEPSEEK = LLMProvider(
            id = "deepseek",
            displayName = "DeepSeek",
            baseUrl = "https://api.deepseek.com/v1",
            defaultModel = "deepseek-chat",
            models = listOf(
                ModelInfo("deepseek-chat", "DeepSeek Chat", 0.14, 0.28),
                ModelInfo("deepseek-reasoner", "DeepSeek Reasoner", 0.55, 2.19)
            )
        )

        /**
         * Groq API provider.
         * Fast inference with OpenAI-compatible API.
         */
        val GROQ = LLMProvider(
            id = "groq",
            displayName = "Groq",
            baseUrl = "https://api.groq.com/openai/v1",
            defaultModel = "llama-3.3-70b-versatile",
            models = listOf(
                ModelInfo("llama-3.3-70b-versatile", "Llama 3.3 70B", 0.59, 0.79),
                ModelInfo("llama-3.1-8b-instant", "Llama 3.1 8B", 0.05, 0.08),
                ModelInfo("mixtral-8x7b-32768", "Mixtral 8x7B", 0.24, 0.24)
            ),
            supportsModelFetching = true
        )

        /**
         * Mistral API provider.
         * OpenAI-compatible API from Mistral AI.
         */
        val MISTRAL = LLMProvider(
            id = "mistral",
            displayName = "Mistral",
            baseUrl = "https://api.mistral.ai/v1",
            defaultModel = "mistral-large-latest",
            models = listOf(
                ModelInfo("mistral-large-latest", "Mistral Large", 2.00, 6.00),
                ModelInfo("mistral-small-latest", "Mistral Small", 0.20, 0.60),
                ModelInfo("codestral-latest", "Codestral", 0.20, 0.60)
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
                ModelInfo("mistral", "Mistral 7B", 0.0, 0.0),
                ModelInfo("gemma2", "Gemma 2", 0.0, 0.0)
            ),
            supportsModelFetching = true,
            requiresApiKey = false
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
            models = emptyList()
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
