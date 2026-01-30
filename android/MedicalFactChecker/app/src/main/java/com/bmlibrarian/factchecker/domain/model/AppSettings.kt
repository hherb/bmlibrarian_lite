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

import com.bmlibrarian.factchecker.util.Constants

/**
 * Application settings data class.
 *
 * Encapsulates all user-configurable settings for the app. This class is
 * immutable and changes are made by creating a copy with modified values.
 * Mirrors iOS AppSettings model for cross-platform consistency.
 *
 * @property llmProviderId Selected LLM provider identifier (e.g., "anthropic", "openai")
 * @property modelId Selected model identifier within the provider
 * @property customBaseUrl Custom API base URL for the "custom" provider
 * @property searchProvider Which literature database(s) to search
 * @property includePreprints Whether to include preprint servers in search
 * @property batchSize Number of documents to fetch per search batch
 * @property relevanceThreshold Minimum score for a document to be considered relevant (1-5)
 * @property targetRelevantDocuments Target number of relevant documents before stopping
 * @property maxRunBudgetUsd Maximum budget per fact-check run in USD
 * @property monthlyBudgetUsd Maximum monthly spending limit in USD
 * @property hasAcceptedDisclaimer Whether user has accepted the medical disclaimer
 * @property hasCompletedOnboarding Whether user has completed the onboarding flow
 * @property ncbiEmail Email for NCBI API requests (recommended for higher rate limits)
 * @property embeddingEnabled Whether to compute embedding-based similarity scores
 */
data class AppSettings(
    val llmProviderId: String = LLMProvider.OPENAI.id,
    val modelId: String = LLMProvider.OPENAI.defaultModel,
    val customBaseUrl: String = "",
    val searchProvider: SearchProvider = SearchProvider.PUBMED,
    val includePreprints: Boolean = false,
    val batchSize: Int = DEFAULT_BATCH_SIZE,
    val relevanceThreshold: Int = Constants.SCORING_MIN_RELEVANT_SCORE,
    val targetRelevantDocuments: Int = DEFAULT_TARGET_RELEVANT_DOCS,
    val maxRunBudgetUsd: Double = Constants.DEFAULT_MAX_RUN_BUDGET_USD.toDouble(),
    val monthlyBudgetUsd: Double = Constants.DEFAULT_MONTHLY_BUDGET_USD.toDouble(),
    val hasAcceptedDisclaimer: Boolean = false,
    val hasCompletedOnboarding: Boolean = false,
    val ncbiEmail: String = "",
    val unpaywallEmail: String = "",
    val embeddingEnabled: Boolean = true
) {
    /**
     * Get the current LLM provider configuration.
     *
     * @return The LLMProvider instance, or null if provider ID is invalid
     */
    val llmProvider: LLMProvider?
        get() = LLMProvider.fromId(llmProviderId)

    /**
     * Get the model info for cost calculation.
     *
     * @return The ModelInfo instance, or null if model ID is invalid
     */
    val modelInfo: ModelInfo?
        get() = llmProvider?.getModel(modelId)

    /**
     * Check if settings are configured for use.
     *
     * Configuration is valid when both provider and model are set.
     * Note: API key validation is handled separately by SettingsRepository.
     *
     * @return true if basic configuration is complete
     */
    val isConfigured: Boolean
        get() = llmProviderId.isNotEmpty() && modelId.isNotEmpty()

    /**
     * Check if the selected provider requires an API key.
     *
     * Local providers like Ollama don't require API keys.
     *
     * @return true if an API key is required
     */
    val requiresApiKey: Boolean
        get() = llmProvider?.requiresApiKey ?: true

    /**
     * Get the base URL for the current provider.
     *
     * For custom providers, returns the customBaseUrl. For others,
     * returns the provider's default baseUrl.
     *
     * @return The API base URL to use
     */
    val effectiveBaseUrl: String
        get() = if (llmProviderId == LLMProvider.CUSTOM.id) {
            customBaseUrl
        } else {
            llmProvider?.baseUrl ?: ""
        }

    /**
     * Validate settings and return any errors.
     *
     * @return List of validation error messages, empty if valid
     */
    fun validate(): List<String> {
        val errors = mutableListOf<String>()

        if (llmProviderId.isEmpty()) {
            errors.add("LLM provider must be selected")
        }

        if (modelId.isEmpty() && llmProviderId != LLMProvider.CUSTOM.id) {
            errors.add("Model must be selected")
        }

        if (llmProviderId == LLMProvider.CUSTOM.id && customBaseUrl.isEmpty()) {
            errors.add("Custom base URL must be provided for custom provider")
        }

        if (batchSize < MIN_BATCH_SIZE || batchSize > MAX_BATCH_SIZE) {
            errors.add("Batch size must be between $MIN_BATCH_SIZE and $MAX_BATCH_SIZE")
        }

        if (relevanceThreshold < Constants.SCORING_MIN_SCORE ||
            relevanceThreshold > Constants.SCORING_MAX_SCORE) {
            errors.add("Relevance threshold must be between ${Constants.SCORING_MIN_SCORE} and ${Constants.SCORING_MAX_SCORE}")
        }

        if (targetRelevantDocuments < MIN_TARGET_RELEVANT_DOCS ||
            targetRelevantDocuments > MAX_TARGET_RELEVANT_DOCS) {
            errors.add("Target relevant documents must be between $MIN_TARGET_RELEVANT_DOCS and $MAX_TARGET_RELEVANT_DOCS")
        }

        if (maxRunBudgetUsd <= 0) {
            errors.add("Maximum run budget must be greater than 0")
        }

        if (monthlyBudgetUsd <= 0) {
            errors.add("Monthly budget must be greater than 0")
        }

        if (maxRunBudgetUsd > monthlyBudgetUsd) {
            errors.add("Maximum run budget cannot exceed monthly budget")
        }

        return errors
    }

    companion object {
        /** Default instance with all default values. */
        val DEFAULT = AppSettings()

        /** Default batch size for document fetching. */
        const val DEFAULT_BATCH_SIZE = 20

        /** Minimum allowed batch size. */
        const val MIN_BATCH_SIZE = 5

        /** Maximum allowed batch size. */
        const val MAX_BATCH_SIZE = 100

        /** Default target number of relevant documents. */
        const val DEFAULT_TARGET_RELEVANT_DOCS = 10

        /** Minimum target relevant documents. */
        const val MIN_TARGET_RELEVANT_DOCS = 3

        /** Maximum target relevant documents. */
        const val MAX_TARGET_RELEVANT_DOCS = 50
    }
}
