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

import android.util.Log
import com.bmlibrarian.factchecker.domain.model.LLMProvider
import com.bmlibrarian.factchecker.domain.model.ModelInfo
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Service for fetching available models from LLM provider APIs.
 *
 * Supports dynamic model discovery for providers that offer model listing endpoints.
 * Falls back to hardcoded lists when API calls fail or are not supported.
 *
 * API Endpoints used:
 * - Anthropic: GET https://api.anthropic.com/v1/models (x-api-key + anthropic-version headers)
 * - OpenAI: GET https://api.openai.com/v1/models (Bearer token)
 * - Groq: GET https://api.groq.com/openai/v1/models (Bearer token)
 * - Mistral: GET https://api.mistral.ai/v1/models (Bearer token)
 * - DeepSeek: GET https://api.deepseek.com/models (Bearer token)
 * - Ollama: GET http://localhost:11434/api/tags (no auth)
 *
 * @see <a href="https://docs.anthropic.com/en/api/models">Anthropic Models API</a>
 * @see <a href="https://platform.openai.com/docs/api-reference/models/list">OpenAI Models API</a>
 * @see <a href="https://console.groq.com/docs/api-reference">Groq API Reference</a>
 * @see <a href="https://docs.mistral.ai/api/endpoint/models">Mistral Models API</a>
 * @see <a href="https://api-docs.deepseek.com/api/list-models">DeepSeek Models API</a>
 * @see <a href="https://docs.ollama.com/api/tags">Ollama Tags API</a>
 */
@Singleton
class ModelFetchService @Inject constructor(
    private val openAIApi: OpenAIApi,
    private val anthropicApi: AnthropicApi,
    private val ollamaApi: OllamaApi
) {
    companion object {
        private const val TAG = "ModelFetchService"

        /** Cache duration in milliseconds (1 hour). */
        private const val CACHE_DURATION_MS = 3600_000L
    }

    /** Cached models per provider with timestamp. */
    private val cache = mutableMapOf<String, CachedModels>()

    /**
     * Fetch available models for a provider.
     *
     * Attempts to fetch models dynamically from the provider's API.
     * Returns cached results if available and not expired.
     * Falls back to hardcoded models if the API call fails.
     *
     * @param provider The LLM provider
     * @param apiKey Optional API key for authentication
     * @param customBaseUrl Optional custom base URL
     * @return List of available models
     */
    suspend fun fetchModels(
        provider: LLMProvider,
        apiKey: String? = null,
        customBaseUrl: String? = null
    ): List<ModelInfo> {
        // Check cache first
        val cached = cache[provider.id]
        if (cached != null && !cached.isExpired()) {
            Log.d(TAG, "Returning cached models for ${provider.id}")
            return cached.models
        }

        // Try to fetch from API
        return try {
            val models = fetchModelsFromAPI(provider, apiKey, customBaseUrl)
            if (models.isNotEmpty()) {
                // Cache successful result
                cache[provider.id] = CachedModels(models, System.currentTimeMillis())
                Log.d(TAG, "Fetched ${models.size} models for ${provider.id}")
                models
            } else {
                Log.w(TAG, "No models returned for ${provider.id}, using fallback")
                provider.models
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to fetch models for ${provider.id}: ${e.message}")
            // Return fallback models
            provider.models
        }
    }

    /**
     * Clear the model cache for a specific provider or all providers.
     *
     * @param providerId Optional provider ID to clear. If null, clears all caches.
     */
    fun clearCache(providerId: String? = null) {
        if (providerId != null) {
            cache.remove(providerId)
        } else {
            cache.clear()
        }
    }

    /**
     * Fetch models from the provider's API.
     */
    private suspend fun fetchModelsFromAPI(
        provider: LLMProvider,
        apiKey: String?,
        customBaseUrl: String?
    ): List<ModelInfo> {
        return when (provider.id) {
            "anthropic" -> fetchAnthropicModels(apiKey, customBaseUrl)
            "openai" -> fetchOpenAIModels(apiKey, customBaseUrl)
            "groq" -> fetchGroqModels(apiKey, customBaseUrl)
            "mistral" -> fetchMistralModels(apiKey, customBaseUrl)
            "deepseek" -> fetchDeepSeekModels(apiKey, customBaseUrl)
            "ollama" -> fetchOllamaModels(customBaseUrl)
            else -> emptyList() // Custom providers don't support model fetching
        }
    }

    // ==================== Provider-Specific Fetchers ====================

    /**
     * Fetch models from Anthropic API.
     */
    private suspend fun fetchAnthropicModels(
        apiKey: String?,
        customBaseUrl: String?
    ): List<ModelInfo> {
        if (apiKey.isNullOrBlank()) {
            throw IllegalArgumentException("API key required to fetch Anthropic models")
        }

        val baseUrl = customBaseUrl ?: "https://api.anthropic.com"
        val url = "$baseUrl/v1/models"

        val response = anthropicApi.listModels(
            url = url,
            apiKey = apiKey,
            anthropicVersion = AnthropicApi.API_VERSION
        )

        if (!response.isSuccessful) {
            throw RuntimeException("API error: ${response.code()} ${response.message()}")
        }

        val body = response.body() ?: return emptyList()

        return body.data
            .filter { isUsableAnthropicModel(it.id) }
            .map { model ->
                val pricing = getAnthropicPricing(model.id)
                ModelInfo(
                    id = model.id,
                    displayName = formatAnthropicModelName(model.id),
                    inputPricePer1M = pricing.first,
                    outputPricePer1M = pricing.second
                )
            }
            .sortedByDescending { it.id }  // Newest first
    }

    /**
     * Check if an Anthropic model is usable for chat completion.
     */
    private fun isUsableAnthropicModel(modelId: String): Boolean {
        // Filter out deprecated and non-chat models
        return modelId.startsWith("claude-") &&
               !modelId.contains("instant") &&
               !modelId.contains("2024")  // Prefer 2025+ models
    }

    /**
     * Format Anthropic model ID to display name.
     */
    private fun formatAnthropicModelName(modelId: String): String {
        // claude-sonnet-4-5-20250929 -> Claude Sonnet 4.5
        val parts = modelId.removePrefix("claude-").split("-")
        if (parts.size < 2) return modelId

        val modelName = parts[0].replaceFirstChar { it.uppercase() }
        var version = parts[1]

        // Handle version like "4-5" -> "4.5"
        if (parts.size >= 3) {
            val minor = parts[2].toIntOrNull()
            if (minor != null && minor < 10) {
                version = "${parts[1]}.$minor"
            }
        }

        return "Claude $modelName $version"
    }

    /**
     * Get pricing for Anthropic models (per 1M tokens, January 2026).
     */
    private fun getAnthropicPricing(modelId: String): Pair<Double, Double> {
        return when {
            modelId.contains("opus-4-5") -> 5.00 to 25.00
            modelId.contains("sonnet-4-5") -> 3.00 to 15.00
            modelId.contains("haiku-4-5") -> 1.00 to 5.00
            modelId.contains("opus-4-1") || modelId.contains("opus-4-0") -> 15.00 to 75.00
            modelId.contains("sonnet-4") || modelId.contains("sonnet-3-7") -> 3.00 to 15.00
            modelId.contains("haiku") -> 0.25 to 1.25
            else -> 3.00 to 15.00  // Default
        }
    }

    /**
     * Fetch models from OpenAI API.
     */
    private suspend fun fetchOpenAIModels(
        apiKey: String?,
        customBaseUrl: String?
    ): List<ModelInfo> {
        if (apiKey.isNullOrBlank()) {
            throw IllegalArgumentException("API key required to fetch OpenAI models")
        }

        val baseUrl = customBaseUrl ?: "https://api.openai.com"
        val url = "$baseUrl/v1/models"

        val response = openAIApi.listModels(
            url = url,
            authorization = "Bearer $apiKey"
        )

        if (!response.isSuccessful) {
            throw RuntimeException("API error: ${response.code()} ${response.message()}")
        }

        val body = response.body() ?: return emptyList()

        return body.data
            .filter { isUsableOpenAIModel(it.id) }
            .map { model ->
                val pricing = getOpenAIPricing(model.id)
                ModelInfo(
                    id = model.id,
                    displayName = formatOpenAIModelName(model.id),
                    inputPricePer1M = pricing.first,
                    outputPricePer1M = pricing.second
                )
            }
            .sortedBy { getOpenAISortOrder(it.id) }
    }

    /**
     * Check if an OpenAI model is usable for chat completion.
     */
    private fun isUsableOpenAIModel(modelId: String): Boolean {
        val chatPrefixes = listOf("gpt-5", "gpt-4", "o3", "o4")
        val excludePatterns = listOf("realtime", "audio", "tts", "whisper", "dall-e", "embedding")

        return chatPrefixes.any { modelId.startsWith(it) } &&
               excludePatterns.none { modelId.contains(it) }
    }

    /**
     * Format OpenAI model ID to display name.
     */
    private fun formatOpenAIModelName(modelId: String): String {
        val mapping = mapOf(
            "gpt-5.2" to "GPT-5.2",
            "gpt-5.2-pro" to "GPT-5.2 Pro",
            "gpt-5.1" to "GPT-5.1",
            "gpt-5" to "GPT-5",
            "gpt-4o" to "GPT-4o",
            "gpt-4o-mini" to "GPT-4o Mini",
            "gpt-4.1" to "GPT-4.1",
            "gpt-4.1-mini" to "GPT-4.1 Mini",
            "o4-mini" to "o4-mini",
            "o3" to "o3",
            "o3-pro" to "o3 Pro"
        )

        for ((prefix, name) in mapping) {
            if (modelId.startsWith(prefix)) {
                return name
            }
        }
        return modelId.uppercase()
    }

    /**
     * Get pricing for OpenAI models (per 1M tokens, January 2026).
     */
    private fun getOpenAIPricing(modelId: String): Pair<Double, Double> {
        return when {
            modelId.contains("5.2-pro") -> 24.00 to 96.00
            modelId.contains("5.2") || modelId.contains("5.1") -> 2.00 to 8.00
            modelId.startsWith("o4-mini") -> 1.10 to 4.40
            modelId.startsWith("o3-pro") -> 24.00 to 96.00
            modelId.startsWith("o3") -> 2.00 to 8.00
            modelId.contains("4o-mini") -> 0.15 to 0.60
            modelId.contains("4o") -> 2.50 to 10.00
            modelId.contains("4.1-mini") -> 0.40 to 1.60
            modelId.contains("4.1") -> 2.00 to 8.00
            else -> 2.00 to 8.00  // Default
        }
    }

    /**
     * Get sort order for OpenAI models.
     */
    private fun getOpenAISortOrder(modelId: String): Int {
        return when {
            modelId.contains("5.2") -> 0
            modelId.contains("o4-mini") -> 1
            modelId.contains("o3") -> 2
            modelId.contains("4o") -> 3
            else -> 10
        }
    }

    /**
     * Fetch models from Groq API.
     */
    private suspend fun fetchGroqModels(
        apiKey: String?,
        customBaseUrl: String?
    ): List<ModelInfo> {
        if (apiKey.isNullOrBlank()) {
            throw IllegalArgumentException("API key required to fetch Groq models")
        }

        val baseUrl = customBaseUrl ?: "https://api.groq.com/openai"
        val url = "$baseUrl/v1/models"

        val response = openAIApi.listModels(
            url = url,
            authorization = "Bearer $apiKey"
        )

        if (!response.isSuccessful) {
            throw RuntimeException("API error: ${response.code()} ${response.message()}")
        }

        val body = response.body() ?: return emptyList()

        return body.data
            .filter { isUsableGroqModel(it.id) }
            .map { model ->
                val pricing = getGroqPricing(model.id)
                ModelInfo(
                    id = model.id,
                    displayName = formatGroqModelName(model.id),
                    inputPricePer1M = pricing.first,
                    outputPricePer1M = pricing.second
                )
            }
    }

    /**
     * Check if a Groq model is usable for chat completion.
     */
    private fun isUsableGroqModel(modelId: String): Boolean {
        val usablePatterns = listOf("llama-4", "llama-3", "mixtral")
        val excludePatterns = listOf("guard", "tool-use")

        return usablePatterns.any { modelId.contains(it) } &&
               excludePatterns.none { modelId.contains(it) }
    }

    /**
     * Format Groq model ID to display name.
     */
    private fun formatGroqModelName(modelId: String): String {
        return when {
            modelId.contains("llama-4-scout") -> "Llama 4 Scout"
            modelId.contains("llama-4-maverick") -> "Llama 4 Maverick"
            modelId.contains("llama-3.3-70b") -> "Llama 3.3 70B"
            modelId.contains("llama-3.1-8b") -> "Llama 3.1 8B"
            modelId.contains("mixtral") -> "Mixtral 8x7B"
            else -> modelId
        }
    }

    /**
     * Get pricing for Groq models (per 1M tokens, January 2026).
     */
    private fun getGroqPricing(modelId: String): Pair<Double, Double> {
        return when {
            modelId.contains("llama-4-scout") -> 0.11 to 0.34
            modelId.contains("llama-4-maverick") -> 0.50 to 0.77
            modelId.contains("llama-3.3-70b") -> 0.59 to 0.79
            modelId.contains("llama-3.1-8b") -> 0.05 to 0.08
            modelId.contains("mixtral") -> 0.24 to 0.24
            else -> 0.20 to 0.40  // Default
        }
    }

    /**
     * Fetch models from Mistral API.
     */
    private suspend fun fetchMistralModels(
        apiKey: String?,
        customBaseUrl: String?
    ): List<ModelInfo> {
        if (apiKey.isNullOrBlank()) {
            throw IllegalArgumentException("API key required to fetch Mistral models")
        }

        val baseUrl = customBaseUrl ?: "https://api.mistral.ai"
        val url = "$baseUrl/v1/models"

        val response = openAIApi.listModels(
            url = url,
            authorization = "Bearer $apiKey"
        )

        if (!response.isSuccessful) {
            throw RuntimeException("API error: ${response.code()} ${response.message()}")
        }

        val body = response.body() ?: return emptyList()

        return body.data
            .filter { isUsableMistralModel(it.id) }
            .map { model ->
                val pricing = getMistralPricing(model.id)
                ModelInfo(
                    id = model.id,
                    displayName = formatMistralModelName(model.id),
                    inputPricePer1M = pricing.first,
                    outputPricePer1M = pricing.second
                )
            }
    }

    /**
     * Check if a Mistral model is usable for chat completion.
     */
    private fun isUsableMistralModel(modelId: String): Boolean {
        val chatPatterns = listOf("mistral-large", "mistral-medium", "mistral-small", "codestral", "pixtral")
        return chatPatterns.any { modelId.contains(it) } && !modelId.contains("embed")
    }

    /**
     * Format Mistral model ID to display name.
     */
    private fun formatMistralModelName(modelId: String): String {
        return when {
            modelId.contains("mistral-large-3") -> "Mistral Large 3"
            modelId.contains("mistral-medium-3") -> "Mistral Medium 3"
            modelId.contains("mistral-small") -> "Mistral Small"
            modelId.contains("codestral") -> "Codestral"
            modelId.contains("pixtral") -> "Pixtral (Multimodal)"
            else -> modelId
        }
    }

    /**
     * Get pricing for Mistral models (per 1M tokens, January 2026).
     */
    private fun getMistralPricing(modelId: String): Pair<Double, Double> {
        return when {
            modelId.contains("mistral-large-3") -> 0.50 to 1.50
            modelId.contains("mistral-medium-3") -> 0.40 to 2.00
            modelId.contains("mistral-small") -> 0.10 to 0.30
            modelId.contains("codestral") -> 0.20 to 0.60
            modelId.contains("pixtral") -> 0.40 to 1.20
            else -> 0.50 to 1.50  // Default
        }
    }

    /**
     * Fetch models from DeepSeek API.
     */
    private suspend fun fetchDeepSeekModels(
        apiKey: String?,
        customBaseUrl: String?
    ): List<ModelInfo> {
        if (apiKey.isNullOrBlank()) {
            throw IllegalArgumentException("API key required to fetch DeepSeek models")
        }

        // Note: DeepSeek uses /models not /v1/models
        val baseUrl = customBaseUrl ?: "https://api.deepseek.com"
        val url = "$baseUrl/models"

        val response = openAIApi.listModels(
            url = url,
            authorization = "Bearer $apiKey"
        )

        if (!response.isSuccessful) {
            throw RuntimeException("API error: ${response.code()} ${response.message()}")
        }

        val body = response.body() ?: return emptyList()

        return body.data
            .filter { isUsableDeepSeekModel(it.id) }
            .map { model ->
                val pricing = getDeepSeekPricing(model.id)
                ModelInfo(
                    id = model.id,
                    displayName = formatDeepSeekModelName(model.id),
                    inputPricePer1M = pricing.first,
                    outputPricePer1M = pricing.second
                )
            }
    }

    /**
     * Check if a DeepSeek model is usable for chat completion.
     */
    private fun isUsableDeepSeekModel(modelId: String): Boolean {
        return modelId in listOf("deepseek-chat", "deepseek-reasoner")
    }

    /**
     * Format DeepSeek model ID to display name.
     */
    private fun formatDeepSeekModelName(modelId: String): String {
        return when (modelId) {
            "deepseek-chat" -> "DeepSeek V3.2 (Chat)"
            "deepseek-reasoner" -> "DeepSeek V3.2 (Reasoner)"
            else -> modelId
        }
    }

    /**
     * Get pricing for DeepSeek models (per 1M tokens, January 2026).
     *
     * Note: DeepSeek currently has uniform pricing for all models.
     */
    @Suppress("UNUSED_PARAMETER")
    private fun getDeepSeekPricing(modelId: String): Pair<Double, Double> {
        // Cache miss pricing - uniform for all DeepSeek models
        return 0.28 to 0.42
    }

    /**
     * Fetch models from local Ollama server.
     */
    private suspend fun fetchOllamaModels(
        customBaseUrl: String?
    ): List<ModelInfo> {
        // Ollama's native API is at /api/tags, not the OpenAI-compatible /v1 endpoint
        var ollamaBaseUrl = customBaseUrl ?: "http://localhost:11434"
        if (ollamaBaseUrl.endsWith("/v1")) {
            ollamaBaseUrl = ollamaBaseUrl.dropLast(3)
        }
        val url = "$ollamaBaseUrl/api/tags"

        val response = ollamaApi.listModels(url)

        if (!response.isSuccessful) {
            throw RuntimeException("API error: ${response.code()} ${response.message()}")
        }

        val body = response.body() ?: return emptyList()

        return body.models.map { model ->
            ModelInfo(
                id = model.name,
                displayName = formatOllamaModelName(model.name),
                inputPricePer1M = 0.0,
                outputPricePer1M = 0.0
            )
        }
    }

    /**
     * Format Ollama model name for display.
     *
     * Preserves the full model name including quantization and parameter info
     * (e.g., "llama3.2:8b-q4_0" stays as "llama3.2:8b-q4_0").
     * Only strips ":latest" suffix as it's redundant.
     */
    private fun formatOllamaModelName(name: String): String {
        return if (name.endsWith(":latest")) {
            name.dropLast(7)
        } else {
            name
        }
    }

    /**
     * Cached models with timestamp.
     */
    private data class CachedModels(
        val models: List<ModelInfo>,
        val fetchedAt: Long
    ) {
        fun isExpired(): Boolean {
            return System.currentTimeMillis() - fetchedAt > CACHE_DURATION_MS
        }
    }
}
