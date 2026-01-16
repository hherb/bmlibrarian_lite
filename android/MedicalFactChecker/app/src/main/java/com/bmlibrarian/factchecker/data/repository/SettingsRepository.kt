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

package com.bmlibrarian.factchecker.data.repository

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import com.bmlibrarian.factchecker.domain.model.AppSettings
import com.bmlibrarian.factchecker.domain.model.LLMProvider
import com.bmlibrarian.factchecker.domain.model.SearchProvider
import com.bmlibrarian.factchecker.util.Constants
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Repository for managing application settings.
 *
 * Uses EncryptedSharedPreferences for secure storage of sensitive data
 * like API keys. Non-sensitive preferences use regular SharedPreferences.
 * Provides both individual setting accessors and an observable AppSettings
 * state flow for UI binding.
 *
 * Security architecture:
 * - API keys stored in EncryptedSharedPreferences with AES-256-GCM
 * - Non-sensitive settings stored in regular SharedPreferences
 * - In-memory cache for decrypted API keys to minimize decryption overhead
 *
 * @param context The application context
 */
@Singleton
class SettingsRepository @Inject constructor(
    @ApplicationContext private val context: Context
) {

    private val masterKey: MasterKey by lazy {
        MasterKey.Builder(context)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
    }

    private val encryptedPrefs: SharedPreferences by lazy {
        EncryptedSharedPreferences.create(
            context,
            ENCRYPTED_PREFS_NAME,
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
        )
    }

    private val regularPrefs: SharedPreferences by lazy {
        context.getSharedPreferences(REGULAR_PREFS_NAME, Context.MODE_PRIVATE)
    }

    // In-memory cache for API keys to avoid decryption on every access
    private val apiKeyCache = mutableMapOf<String, String>()

    // Observable settings state for UI binding
    private val _settings = MutableStateFlow(loadSettings())

    /** Observable state flow of current settings. */
    val settings: StateFlow<AppSettings> = _settings.asStateFlow()

    // ==================== Settings State Management ====================

    /**
     * Get current settings (cached).
     *
     * @return Current AppSettings instance
     */
    fun getSettings(): AppSettings = _settings.value

    /**
     * Load settings from SharedPreferences.
     *
     * @return AppSettings populated from stored values
     */
    private fun loadSettings(): AppSettings {
        return AppSettings(
            llmProviderId = regularPrefs.getString(KEY_LLM_PROVIDER, LLMProvider.OPENAI.id)
                ?: LLMProvider.OPENAI.id,
            modelId = regularPrefs.getString(KEY_LLM_MODEL, LLMProvider.OPENAI.defaultModel)
                ?: LLMProvider.OPENAI.defaultModel,
            customBaseUrl = regularPrefs.getString(KEY_CUSTOM_BASE_URL, "") ?: "",
            searchProvider = try {
                SearchProvider.valueOf(
                    regularPrefs.getString(KEY_SEARCH_PROVIDER, SearchProvider.PUBMED.name)
                        ?: SearchProvider.PUBMED.name
                )
            } catch (e: IllegalArgumentException) {
                SearchProvider.PUBMED
            },
            includePreprints = regularPrefs.getBoolean(KEY_INCLUDE_PREPRINTS, false),
            batchSize = regularPrefs.getInt(KEY_BATCH_SIZE, AppSettings.DEFAULT_BATCH_SIZE),
            relevanceThreshold = regularPrefs.getInt(KEY_RELEVANCE_THRESHOLD, Constants.SCORING_MIN_RELEVANT_SCORE),
            targetRelevantDocuments = regularPrefs.getInt(KEY_TARGET_RELEVANT_DOCS, AppSettings.DEFAULT_TARGET_RELEVANT_DOCS),
            maxRunBudgetUsd = regularPrefs.getFloat(KEY_MAX_RUN_BUDGET, Constants.DEFAULT_MAX_RUN_BUDGET_USD).toDouble(),
            monthlyBudgetUsd = regularPrefs.getFloat(KEY_MONTHLY_BUDGET, Constants.DEFAULT_MONTHLY_BUDGET_USD).toDouble(),
            hasAcceptedDisclaimer = regularPrefs.getBoolean(KEY_DISCLAIMER_ACCEPTED, false),
            hasCompletedOnboarding = regularPrefs.getBoolean(KEY_ONBOARDING_COMPLETE, false),
            ncbiEmail = regularPrefs.getString(KEY_NCBI_EMAIL, "") ?: ""
        )
    }

    /**
     * Save entire settings object.
     *
     * @param settings The settings to save
     */
    fun saveSettings(settings: AppSettings) {
        regularPrefs.edit().apply {
            putString(KEY_LLM_PROVIDER, settings.llmProviderId)
            putString(KEY_LLM_MODEL, settings.modelId)
            putString(KEY_CUSTOM_BASE_URL, settings.customBaseUrl)
            putString(KEY_SEARCH_PROVIDER, settings.searchProvider.name)
            putBoolean(KEY_INCLUDE_PREPRINTS, settings.includePreprints)
            putInt(KEY_BATCH_SIZE, settings.batchSize)
            putInt(KEY_RELEVANCE_THRESHOLD, settings.relevanceThreshold)
            putInt(KEY_TARGET_RELEVANT_DOCS, settings.targetRelevantDocuments)
            putFloat(KEY_MAX_RUN_BUDGET, settings.maxRunBudgetUsd.toFloat())
            putFloat(KEY_MONTHLY_BUDGET, settings.monthlyBudgetUsd.toFloat())
            putBoolean(KEY_DISCLAIMER_ACCEPTED, settings.hasAcceptedDisclaimer)
            putBoolean(KEY_ONBOARDING_COMPLETE, settings.hasCompletedOnboarding)
            putString(KEY_NCBI_EMAIL, settings.ncbiEmail)
            apply()
        }
        _settings.value = settings
    }

    /**
     * Update settings using a transform function.
     *
     * @param transform Function that transforms current settings to new settings
     */
    fun updateSettings(transform: (AppSettings) -> AppSettings) {
        saveSettings(transform(_settings.value))
    }

    // ==================== API Key Management (Per-Provider) ====================

    /**
     * Get API key for a specific provider.
     * Returns cached value if available, otherwise decrypts from storage.
     *
     * @param providerId The provider identifier
     * @return The stored API key, or empty string if not set
     */
    fun getApiKey(providerId: String): String {
        return apiKeyCache.getOrPut(providerId) {
            encryptedPrefs.getString(KEY_API_KEY_PREFIX + providerId, "") ?: ""
        }
    }

    /**
     * Get API key for the currently selected provider.
     * This is a convenience method that uses the current provider ID from settings.
     *
     * @return The API key for the current provider
     */
    fun getLlmApiKey(): String {
        return getApiKey(_settings.value.llmProviderId)
    }

    /**
     * Save API key for a specific provider.
     *
     * @param providerId The provider identifier
     * @param apiKey The API key to store
     */
    fun saveApiKey(providerId: String, apiKey: String) {
        encryptedPrefs.edit().apply {
            putString(KEY_API_KEY_PREFIX + providerId, apiKey)
            apply()
        }
        apiKeyCache[providerId] = apiKey
    }

    /**
     * Store the LLM API key for the current provider.
     * Legacy method for backwards compatibility - use saveApiKey() for new code.
     *
     * @param apiKey The API key to store
     */
    fun setLlmApiKey(apiKey: String) {
        saveApiKey(_settings.value.llmProviderId, apiKey)
    }

    /**
     * Check if API key exists for a provider.
     *
     * @param providerId The provider identifier
     * @return true if an API key is stored for this provider
     */
    fun hasApiKey(providerId: String): Boolean {
        return getApiKey(providerId).isNotEmpty()
    }

    /**
     * Delete API key for a provider.
     *
     * @param providerId The provider identifier
     */
    fun deleteApiKey(providerId: String) {
        encryptedPrefs.edit().remove(KEY_API_KEY_PREFIX + providerId).apply()
        apiKeyCache.remove(providerId)
    }

    // ==================== NCBI API Key ====================

    /**
     * Get NCBI API key for PubMed rate limiting bypass.
     *
     * @return The stored NCBI API key, or empty string if not set
     */
    fun getNcbiApiKey(): String {
        return apiKeyCache.getOrPut(KEY_NCBI_API_KEY) {
            encryptedPrefs.getString(KEY_NCBI_API_KEY, "") ?: ""
        }
    }

    /**
     * Save NCBI API key.
     *
     * @param apiKey The NCBI API key
     */
    fun saveNcbiApiKey(apiKey: String) {
        encryptedPrefs.edit().putString(KEY_NCBI_API_KEY, apiKey).apply()
        apiKeyCache[KEY_NCBI_API_KEY] = apiKey
    }

    // ==================== Individual Setting Accessors ====================

    /**
     * Get the selected LLM provider.
     *
     * @return The provider identifier
     */
    fun getLlmProvider(): String = _settings.value.llmProviderId

    /**
     * Set the LLM provider and update default model.
     *
     * @param providerId The provider identifier
     */
    fun setLlmProvider(providerId: String) {
        val provider = LLMProvider.fromId(providerId)
        updateSettings { settings ->
            settings.copy(
                llmProviderId = providerId,
                modelId = provider?.defaultModel ?: settings.modelId
            )
        }
    }

    /**
     * Get the selected LLM model.
     *
     * @return The model identifier
     */
    fun getLlmModel(): String = _settings.value.modelId

    /**
     * Set the LLM model.
     *
     * @param modelId The model identifier
     */
    fun setLlmModel(model: String) {
        updateSettings { it.copy(modelId = model) }
    }

    /**
     * Get the LLM API base URL (for custom endpoints like Ollama).
     *
     * @return The base URL
     */
    fun getLlmBaseUrl(): String {
        return _settings.value.effectiveBaseUrl.ifEmpty { Constants.DEFAULT_OPENAI_BASE_URL }
    }

    /**
     * Set the custom LLM API base URL.
     *
     * @param baseUrl The base URL
     */
    fun setLlmBaseUrl(baseUrl: String) {
        updateSettings { it.copy(customBaseUrl = baseUrl) }
    }

    /**
     * Get the search provider.
     *
     * @return The search provider
     */
    fun getSearchProvider(): SearchProvider = _settings.value.searchProvider

    /**
     * Set the search provider.
     *
     * @param provider The search provider
     */
    fun setSearchProvider(provider: SearchProvider) {
        updateSettings { it.copy(searchProvider = provider) }
    }

    /**
     * Get include preprints setting.
     *
     * @return true if preprints should be included
     */
    fun getIncludePreprints(): Boolean = _settings.value.includePreprints

    /**
     * Set include preprints.
     *
     * @param include Whether to include preprints
     */
    fun setIncludePreprints(include: Boolean) {
        updateSettings { it.copy(includePreprints = include) }
    }

    /**
     * Get batch size for document fetching.
     *
     * @return The batch size
     */
    fun getBatchSize(): Int = _settings.value.batchSize

    /**
     * Set batch size.
     *
     * @param size The batch size
     */
    fun setBatchSize(size: Int) {
        updateSettings { it.copy(batchSize = size) }
    }

    /**
     * Get relevance threshold.
     *
     * @return The minimum score for relevance
     */
    fun getRelevanceThreshold(): Int = _settings.value.relevanceThreshold

    /**
     * Set relevance threshold.
     *
     * @param threshold The minimum score for relevance (1-5)
     */
    fun setRelevanceThreshold(threshold: Int) {
        updateSettings { it.copy(relevanceThreshold = threshold) }
    }

    /**
     * Get target relevant documents count.
     *
     * @return The target number
     */
    fun getTargetRelevantDocuments(): Int = _settings.value.targetRelevantDocuments

    /**
     * Set target relevant documents.
     *
     * @param target The target number of relevant documents
     */
    fun setTargetRelevantDocuments(target: Int) {
        updateSettings { it.copy(targetRelevantDocuments = target) }
    }

    /**
     * Get the NCBI email for PubMed API requests.
     *
     * @return The email address
     */
    fun getNcbiEmail(): String = _settings.value.ncbiEmail

    /**
     * Set the NCBI email.
     *
     * @param email The email address
     */
    fun setNcbiEmail(email: String) {
        updateSettings { it.copy(ncbiEmail = email) }
    }

    // ==================== Budget Settings ====================

    /**
     * Get the maximum budget per run in USD.
     *
     * @return The budget limit
     */
    fun getMaxRunBudgetUsd(): Float = _settings.value.maxRunBudgetUsd.toFloat()

    /**
     * Set the maximum budget per run.
     *
     * @param budget The budget limit in USD
     */
    fun setMaxRunBudgetUsd(budget: Float) {
        updateSettings { it.copy(maxRunBudgetUsd = budget.toDouble()) }
    }

    /**
     * Get the monthly budget limit in USD.
     *
     * @return The monthly budget limit
     */
    fun getMonthlyBudgetUsd(): Float = _settings.value.monthlyBudgetUsd.toFloat()

    /**
     * Set the monthly budget limit.
     *
     * @param budget The monthly budget in USD
     */
    fun setMonthlyBudgetUsd(budget: Float) {
        updateSettings { it.copy(monthlyBudgetUsd = budget.toDouble()) }
    }

    // ==================== Onboarding ====================

    /**
     * Check if onboarding has been completed.
     *
     * @return True if onboarding is complete
     */
    fun isOnboardingComplete(): Boolean = _settings.value.hasCompletedOnboarding

    /**
     * Mark onboarding as complete.
     */
    fun setOnboardingComplete() {
        updateSettings { it.copy(hasCompletedOnboarding = true) }
    }

    /**
     * Check if the medical disclaimer has been accepted.
     *
     * @return True if disclaimer was accepted
     */
    fun isDisclaimerAccepted(): Boolean = _settings.value.hasAcceptedDisclaimer

    /**
     * Mark the medical disclaimer as accepted.
     */
    fun setDisclaimerAccepted() {
        updateSettings { it.copy(hasAcceptedDisclaimer = true) }
    }

    // ==================== Reset ====================

    /**
     * Reset all settings to defaults.
     * Clears both regular and encrypted preferences, including all API keys.
     */
    fun resetToDefaults() {
        // Clear regular prefs
        regularPrefs.edit().clear().apply()

        // Clear encrypted prefs (API keys)
        encryptedPrefs.edit().clear().apply()
        apiKeyCache.clear()

        // Reset to defaults
        _settings.value = AppSettings.DEFAULT
    }

    // ==================== Validation ====================

    /**
     * Check if all required settings are configured.
     *
     * @return true if configuration is complete and valid
     */
    fun isConfigured(): Boolean {
        val s = _settings.value
        return s.isConfigured && (hasApiKey(s.llmProviderId) || !s.requiresApiKey)
    }

    companion object {
        private const val ENCRYPTED_PREFS_NAME = "factchecker_secure_prefs"
        private const val REGULAR_PREFS_NAME = "factchecker_prefs"

        // Encrypted keys prefix
        private const val KEY_API_KEY_PREFIX = "api_key_"
        private const val KEY_NCBI_API_KEY = "ncbi_api_key"

        // Regular keys
        private const val KEY_LLM_PROVIDER = "llm_provider"
        private const val KEY_LLM_MODEL = "llm_model"
        private const val KEY_CUSTOM_BASE_URL = "custom_base_url"
        private const val KEY_SEARCH_PROVIDER = "search_provider"
        private const val KEY_INCLUDE_PREPRINTS = "include_preprints"
        private const val KEY_BATCH_SIZE = "batch_size"
        private const val KEY_RELEVANCE_THRESHOLD = "relevance_threshold"
        private const val KEY_TARGET_RELEVANT_DOCS = "target_relevant_documents"
        private const val KEY_MAX_RUN_BUDGET = "max_run_budget"
        private const val KEY_MONTHLY_BUDGET = "monthly_budget"
        private const val KEY_DISCLAIMER_ACCEPTED = "disclaimer_accepted"
        private const val KEY_ONBOARDING_COMPLETE = "onboarding_complete"
        private const val KEY_NCBI_EMAIL = "ncbi_email"
    }
}
