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
 * Per-1M-token rates for hosted models, looked up by model ID.
 *
 * The one place prices live. The model picker ([com.bmlibrarian.factchecker.data.remote.llm.ModelFetchService])
 * shows them and the workflow records cost with them via [LLMProvider.pricedModel].
 * Recording cost used to consult only each provider's hardcoded fallback list, so
 * a model chosen from a fetched list that the fallback list lacks was recorded at
 * $0 and never counted against the run or monthly budget.
 */
object ModelPricing {

    /**
     * Rates for a model of a provider.
     *
     * @param providerId The provider ID (e.g. "anthropic").
     * @param modelId The model ID as the provider lists it.
     * @return (input, output) USD per 1M tokens; zero for local Ollama models;
     *   null when the rates cannot be known - a custom endpoint or an unknown provider.
     */
    fun forModel(providerId: String, modelId: String): Pair<Double, Double>? = when (providerId) {
        LLMProvider.ANTHROPIC.id -> getAnthropicPricing(modelId)
        LLMProvider.OPENAI.id -> getOpenAIPricing(modelId)
        LLMProvider.GROQ.id -> getGroqPricing(modelId)
        LLMProvider.MISTRAL.id -> getMistralPricing(modelId)
        LLMProvider.DEEPSEEK.id -> getDeepSeekPricing(modelId)
        LLMProvider.OLLAMA.id -> LOCAL_MODEL_PRICING
        else -> null
    }

    /** Rates for a model running on the user's own Ollama server. */
    private val LOCAL_MODEL_PRICING = 0.0 to 0.0

    /**
     * Anthropic rates per 1M tokens (input, output), September 2026.
     *
     * Matched by substring, longest key first, so "claude-opus-4-8" is not
     * captured by the retired "claude-opus-4" rate. Mirrors the Anthropic rows
     * of the iOS BioMedLit CostCalculator and the desktop constants.anthropic_model_pricing.
     */
    private val ANTHROPIC_PRICING: List<Pair<String, Pair<Double, Double>>> = listOf(
        "claude-fable-5-1" to (10.00 to 50.00),
        "claude-fable-5" to (10.00 to 50.00),
        "claude-mythos-5-1" to (10.00 to 50.00),
        "claude-mythos-5" to (10.00 to 50.00),
        "claude-opus-5-5" to (4.00 to 20.00),
        "claude-opus-5" to (5.00 to 25.00),
        "claude-opus-4-8" to (5.00 to 25.00),
        "claude-opus-4-7" to (5.00 to 25.00),
        "claude-opus-4-6" to (5.00 to 25.00),
        "claude-opus-4-5" to (5.00 to 25.00),
        "claude-opus-4-1" to (15.00 to 75.00),
        "claude-opus-4" to (15.00 to 75.00),
        "claude-sonnet-5" to (2.00 to 10.00),
        "claude-sonnet-4-6" to (3.00 to 15.00),
        "claude-sonnet-4-5" to (3.00 to 15.00),
        "claude-sonnet-4" to (3.00 to 15.00),
        "claude-3-7-sonnet" to (3.00 to 15.00),
        "claude-haiku-4-5" to (1.00 to 5.00),
        "claude-3-haiku" to (0.25 to 1.25),
    ).sortedByDescending { it.first.length }

    /**
     * Rates for a Claude ID missing from [ANTHROPIC_PRICING], by family, checked
     * in order. Each family is quoted at its dearest current rate, so a model
     * released after this table was written is never shown below its peers.
     */
    private val ANTHROPIC_FAMILY_PRICING: List<Pair<String, Pair<Double, Double>>> = listOf(
        "fable" to (10.00 to 50.00),
        "mythos" to (10.00 to 50.00),
        "opus" to (5.00 to 25.00),
        "sonnet" to (3.00 to 15.00),
        "haiku" to (1.00 to 5.00),
    )

    /** Rate for a Claude ID of no known family: the dearest current tier. */
    private val ANTHROPIC_UNKNOWN_FAMILY_PRICING = 10.00 to 50.00

    /**
     * Get pricing for an Anthropic model (per 1M tokens).
     *
     * The previous table stopped at the 4.5 generation and quoted everything
     * newer at a $3/$15 default, overstating Sonnet 5 and understating the
     * Fable tier fivefold.
     *
     * @param modelId The model ID as listed by the API.
     * @return (input, output) USD per 1M tokens.
     */
    fun getAnthropicPricing(modelId: String): Pair<Double, Double> {
        val normalized = modelId.lowercase()
        ANTHROPIC_PRICING.firstOrNull { normalized.contains(it.first) }?.let { return it.second }
        ANTHROPIC_FAMILY_PRICING.firstOrNull { normalized.contains(it.first) }?.let { return it.second }
        return ANTHROPIC_UNKNOWN_FAMILY_PRICING
    }

    /**
     * Get pricing for OpenAI models (per 1M tokens, January 2026).
     *
     * @param modelId The model ID as listed by the API.
     * @return (input, output) USD per 1M tokens; unrecognised IDs get the default.
     */
    fun getOpenAIPricing(modelId: String): Pair<Double, Double> {
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
     * Get pricing for Groq models (per 1M tokens, January 2026).
     *
     * @param modelId The model ID as listed by the API.
     * @return (input, output) USD per 1M tokens; unrecognised IDs get the default.
     */
    fun getGroqPricing(modelId: String): Pair<Double, Double> {
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
     * Get pricing for Mistral models (per 1M tokens, January 2026).
     *
     * @param modelId The model ID as listed by the API.
     * @return (input, output) USD per 1M tokens; unrecognised IDs get the default.
     */
    fun getMistralPricing(modelId: String): Pair<Double, Double> {
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
     * Get pricing for DeepSeek models (per 1M tokens).
     *
     * Peak-hour, cache-miss rates (August 2026). Off-peak rates are half of these,
     * so quoting peak never understates a run. An unrecognised ID gets the flagship
     * rate for the same reason - except one containing "flash", which is priced as
     * V4 Flash. A future cheap tier is therefore quoted at V4 Flash rates until this
     * table is updated: check it when a new generation ships.
     *
     * @param modelId The model ID as listed by the API.
     * @return (input, output) USD per 1M tokens.
     */
    fun getDeepSeekPricing(modelId: String): Pair<Double, Double> {
        return if (modelId.lowercase().contains("flash")) {
            0.44 to 1.32
        } else {
            1.32 to 3.96
        }
    }
}
