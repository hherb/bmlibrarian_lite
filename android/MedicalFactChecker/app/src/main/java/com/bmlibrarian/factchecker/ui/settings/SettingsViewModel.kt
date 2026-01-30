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

package com.bmlibrarian.factchecker.ui.settings

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.bmlibrarian.factchecker.data.local.AppDatabase
import com.bmlibrarian.factchecker.data.repository.SettingsRepository
import com.bmlibrarian.factchecker.domain.model.AppSettings
import com.bmlibrarian.factchecker.domain.model.LLMProvider
import com.bmlibrarian.factchecker.domain.model.ModelInfo
import com.bmlibrarian.factchecker.domain.model.SearchProvider
import com.bmlibrarian.factchecker.util.Constants
import com.bmlibrarian.factchecker.util.CostCalculator
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import javax.inject.Inject

/**
 * ViewModel for the Settings screen.
 *
 * Provides reactive state for settings UI and handles all settings-related
 * user interactions. Bridges the gap between the SettingsRepository and
 * Compose UI, providing computed properties and validation.
 *
 * @param settingsRepository Repository for settings persistence
 */
@HiltViewModel
class SettingsViewModel @Inject constructor(
    private val settingsRepository: SettingsRepository,
    private val llmService: com.bmlibrarian.factchecker.data.remote.llm.LLMService,
    private val database: AppDatabase
) : ViewModel() {

    // ==================== Observable State ====================

    /** Current application settings. */
    val settings: StateFlow<AppSettings> = settingsRepository.settings

    /** Current API key input field value. */
    private val _apiKeyInput = MutableStateFlow("")
    val apiKeyInput: StateFlow<String> = _apiKeyInput.asStateFlow()

    /** Current NCBI API key input field value. */
    private val _ncbiApiKeyInput = MutableStateFlow("")
    val ncbiApiKeyInput: StateFlow<String> = _ncbiApiKeyInput.asStateFlow()

    /** Status message for user feedback. */
    private val _statusMessage = MutableStateFlow<String?>(null)
    val statusMessage: StateFlow<String?> = _statusMessage.asStateFlow()

    /** Whether a connection test is in progress. */
    private val _isTestingConnection = MutableStateFlow(false)
    val isTestingConnection: StateFlow<Boolean> = _isTestingConnection.asStateFlow()

    /** Available LLM providers. */
    val providers: List<LLMProvider> = LLMProvider.ALL_PROVIDERS

    /** Available search providers. */
    val searchProviders: List<SearchProvider> = SearchProvider.entries

    // ==================== Computed Properties ====================

    /** Current provider's available models. */
    val currentModels: StateFlow<List<ModelInfo>> = settings.map { s ->
        s.llmProvider?.models ?: emptyList()
    }.stateIn(
        viewModelScope,
        SharingStarted.WhileSubscribed(FLOW_TIMEOUT_MS),
        emptyList()
    )

    /** Whether the current provider has an API key configured. */
    val hasApiKey: StateFlow<Boolean> = settings.map { s ->
        settingsRepository.hasApiKey(s.llmProviderId)
    }.stateIn(
        viewModelScope,
        SharingStarted.WhileSubscribed(FLOW_TIMEOUT_MS),
        false
    )

    /** Whether the current provider requires an API key. */
    val requiresApiKey: StateFlow<Boolean> = settings.map { s ->
        s.requiresApiKey
    }.stateIn(
        viewModelScope,
        SharingStarted.WhileSubscribed(FLOW_TIMEOUT_MS),
        true
    )

    /** Estimated cost per run based on current model. */
    val estimatedCostPerRun: StateFlow<String> = settings.map { s ->
        val modelInfo = s.modelInfo
        if (modelInfo != null) {
            val cost = CostCalculator.estimateWorkflowCost(
                modelInfo = modelInfo,
                documentCount = s.batchSize
            )
            CostCalculator.formatCost(cost)
        } else {
            "N/A"
        }
    }.stateIn(
        viewModelScope,
        SharingStarted.WhileSubscribed(FLOW_TIMEOUT_MS),
        "N/A"
    )

    /** Validation errors for current settings. */
    val validationErrors: StateFlow<List<String>> = settings.map { s ->
        s.validate()
    }.stateIn(
        viewModelScope,
        SharingStarted.WhileSubscribed(FLOW_TIMEOUT_MS),
        emptyList()
    )

    /** Whether settings are valid and complete. */
    val isConfigured: StateFlow<Boolean> = settings.map { s ->
        settingsRepository.isConfigured()
    }.stateIn(
        viewModelScope,
        SharingStarted.WhileSubscribed(FLOW_TIMEOUT_MS),
        false
    )

    // ==================== Initialization ====================

    init {
        // Load initial API key for current provider
        viewModelScope.launch {
            _apiKeyInput.value = settingsRepository.getApiKey(settings.value.llmProviderId)
            _ncbiApiKeyInput.value = settingsRepository.getNcbiApiKey()
        }
    }

    // ==================== Provider & Model Actions ====================

    /**
     * Set the LLM provider.
     * Also updates the model to the provider's default and loads its API key.
     *
     * @param providerId The provider identifier
     */
    fun setProvider(providerId: String) {
        settingsRepository.setLlmProvider(providerId)
        // Load existing API key for this provider
        _apiKeyInput.value = settingsRepository.getApiKey(providerId)
        showStatus("Provider changed to ${LLMProvider.fromId(providerId)?.displayName ?: providerId}")
    }

    /**
     * Set the model.
     *
     * @param modelId The model identifier
     */
    fun setModel(modelId: String) {
        settingsRepository.setLlmModel(modelId)
    }

    /**
     * Set custom base URL for custom provider.
     *
     * @param url The API base URL
     */
    fun setCustomBaseUrl(url: String) {
        settingsRepository.setLlmBaseUrl(url)
    }

    // ==================== API Key Actions ====================

    /**
     * Update the API key input field.
     *
     * @param value The new input value
     */
    fun updateApiKeyInput(value: String) {
        _apiKeyInput.value = value
    }

    /**
     * Save the API key for the current provider.
     */
    fun saveApiKey() {
        val providerId = settings.value.llmProviderId
        val apiKey = _apiKeyInput.value.trim()

        if (apiKey.isEmpty()) {
            showStatus("API key cannot be empty")
            return
        }

        settingsRepository.saveApiKey(providerId, apiKey)
        showStatus("API key saved")
    }

    /**
     * Clear the API key for the current provider.
     */
    fun clearApiKey() {
        val providerId = settings.value.llmProviderId
        settingsRepository.deleteApiKey(providerId)
        _apiKeyInput.value = ""
        showStatus("API key removed")
    }

    /**
     * Test the LLM connection with a simple request.
     *
     * Sends a minimal request to verify the API key works.
     */
    fun testConnection() {
        if (_isTestingConnection.value) return

        val apiKey = settingsRepository.getLlmApiKey()
        if (apiKey.isEmpty()) {
            showStatus("Please save an API key first")
            return
        }

        viewModelScope.launch {
            _isTestingConnection.value = true
            try {
                val provider = LLMProvider.fromId(settings.value.llmProviderId) ?: LLMProvider.OPENAI
                val model = settings.value.modelId

                val result = llmService.chat(
                    provider = provider,
                    apiKey = apiKey,
                    model = model,
                    systemPrompt = "You are a helpful assistant.",
                    userPrompt = "Say 'OK' to confirm the connection works.",
                    maxTokens = 10,
                    temperature = 0.0
                )

                if (result.isSuccess) {
                    showStatus("✓ Connection successful!")
                } else {
                    val error = result.exceptionOrNull()
                    showStatus("✗ Connection failed: ${error?.message ?: "Unknown error"}")
                }
            } catch (e: Exception) {
                showStatus("✗ Connection failed: ${e.message ?: "Unknown error"}")
            } finally {
                _isTestingConnection.value = false
            }
        }
    }

    /**
     * Update the NCBI API key input field.
     *
     * @param value The new input value
     */
    fun updateNcbiApiKeyInput(value: String) {
        _ncbiApiKeyInput.value = value
    }

    /**
     * Save the NCBI API key.
     */
    fun saveNcbiApiKey() {
        val apiKey = _ncbiApiKeyInput.value.trim()
        settingsRepository.saveNcbiApiKey(apiKey)
        showStatus(if (apiKey.isNotEmpty()) "NCBI API key saved" else "NCBI API key cleared")
    }

    // ==================== Search Settings Actions ====================

    /**
     * Set the search provider.
     *
     * @param provider The search provider
     */
    fun setSearchProvider(provider: SearchProvider) {
        settingsRepository.setSearchProvider(provider)
    }

    /**
     * Set include preprints.
     *
     * @param include Whether to include preprints in search
     */
    fun setIncludePreprints(include: Boolean) {
        settingsRepository.setIncludePreprints(include)
    }

    /**
     * Set the batch size.
     *
     * @param size Number of documents per batch
     */
    fun setBatchSize(size: Int) {
        val clampedSize = size.coerceIn(AppSettings.MIN_BATCH_SIZE, AppSettings.MAX_BATCH_SIZE)
        settingsRepository.setBatchSize(clampedSize)
    }

    /**
     * Set the relevance threshold.
     *
     * @param threshold Minimum score for relevance (1-5)
     */
    fun setRelevanceThreshold(threshold: Int) {
        val clampedThreshold = threshold.coerceIn(
            Constants.SCORING_MIN_SCORE,
            Constants.SCORING_MAX_SCORE
        )
        settingsRepository.setRelevanceThreshold(clampedThreshold)
    }

    /**
     * Set the target relevant documents.
     *
     * @param target Target number of relevant documents
     */
    fun setTargetRelevantDocuments(target: Int) {
        val clampedTarget = target.coerceIn(
            AppSettings.MIN_TARGET_RELEVANT_DOCS,
            AppSettings.MAX_TARGET_RELEVANT_DOCS
        )
        settingsRepository.setTargetRelevantDocuments(clampedTarget)
    }

    /**
     * Set embedding scoring enabled/disabled.
     *
     * @param enabled Whether to enable embedding-based similarity scoring
     */
    fun setEmbeddingEnabled(enabled: Boolean) {
        settingsRepository.setEmbeddingEnabled(enabled)
    }

    // ==================== Budget Settings Actions ====================

    /**
     * Set the maximum run budget.
     *
     * @param budgetUsd Maximum budget per run in USD
     */
    fun setMaxRunBudget(budgetUsd: Double) {
        settingsRepository.setMaxRunBudgetUsd(budgetUsd.toFloat())
    }

    /**
     * Set the monthly budget.
     *
     * @param budgetUsd Monthly budget limit in USD
     */
    fun setMonthlyBudget(budgetUsd: Double) {
        settingsRepository.setMonthlyBudgetUsd(budgetUsd.toFloat())
    }

    // ==================== NCBI Settings Actions ====================

    /**
     * Set the NCBI email.
     *
     * @param email Email for NCBI API requests
     */
    fun setNcbiEmail(email: String) {
        settingsRepository.setNcbiEmail(email)
    }

    // ==================== Embedding Scoring Actions ====================

    /**
     * Enable or disable on-device embedding scoring.
     *
     * @param enabled Whether to enable embedding scoring
     */
    fun setEmbeddingEnabled(enabled: Boolean) {
        settingsRepository.setEmbeddingEnabled(enabled)
    }

    /**
     * Enable or disable HyDE generation.
     *
     * @param enabled Whether to enable HyDE
     */
    fun setHydeEnabled(enabled: Boolean) {
        settingsRepository.setHydeEnabled(enabled)
    }

    // ==================== Parallel Processing Settings ====================

    /**
     * Set the parallel concurrency level for document processing.
     *
     * @param concurrency Number of concurrent operations (1-10)
     */
    fun setParallelConcurrency(concurrency: Int) {
        settingsRepository.setParallelConcurrency(concurrency)
    }

    // ==================== Onboarding Actions ====================

    /**
     * Accept the medical disclaimer.
     */
    fun acceptDisclaimer() {
        settingsRepository.setDisclaimerAccepted()
    }

    /**
     * Complete the onboarding flow.
     */
    fun completeOnboarding() {
        settingsRepository.setOnboardingComplete()
    }

    // ==================== Reset Actions ====================

    /**
     * Reset all settings to defaults.
     * This clears all stored API keys and preferences.
     */
    fun resetToDefaults() {
        settingsRepository.resetToDefaults()
        _apiKeyInput.value = ""
        _ncbiApiKeyInput.value = ""
        showStatus("Settings reset to defaults")
    }

    /**
     * Clear all session data from the database.
     * This removes all sessions, documents, citations, and reports,
     * but keeps user settings and API keys.
     */
    fun clearAllData() {
        viewModelScope.launch {
            try {
                withContext(Dispatchers.IO) {
                    database.clearAllTables()
                }
                showStatus("All data cleared successfully")
            } catch (e: Exception) {
                showStatus("Error clearing data: ${e.message}")
            }
        }
    }

    // ==================== Status Message Handling ====================

    /**
     * Show a status message to the user.
     *
     * @param message The message to display
     */
    private fun showStatus(message: String) {
        _statusMessage.value = message
    }

    /**
     * Clear the status message.
     */
    fun clearStatusMessage() {
        _statusMessage.value = null
    }

    companion object {
        /** Timeout for StateFlow sharing. */
        private const val FLOW_TIMEOUT_MS = 5000L
    }
}
