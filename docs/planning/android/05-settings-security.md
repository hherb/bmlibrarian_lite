# Phase 5: Settings & Security

## Overview

This phase implements the settings management system with secure API key storage. We'll use EncryptedSharedPreferences for sensitive data and standard SharedPreferences for configuration.

**Estimated Duration**: 3-5 days
**Prerequisites**: Phases 1-4 completed
**Deliverable**: Fully functional settings management

## Security Architecture

```
┌─────────────────────────────────────────────────────┐
│                   AppSettings                        │
│  (Observable settings object for UI binding)         │
└─────────────────────┬───────────────────────────────┘
                      │
        ┌─────────────┴─────────────┐
        │                           │
        ▼                           ▼
┌───────────────────┐    ┌──────────────────────────┐
│ SharedPreferences │    │ EncryptedSharedPreferences│
│ (Configuration)   │    │ (API Keys)                │
│                   │    │                           │
│ - Provider ID     │    │ - Anthropic API Key       │
│ - Model ID        │    │ - OpenAI API Key          │
│ - Batch size      │    │ - DeepSeek API Key        │
│ - Thresholds      │    │ - Groq API Key            │
│ - Budget limits   │    │ - Mistral API Key         │
│ - Search provider │    │ - Custom API Key          │
│ - Preprint toggle │    │                           │
└───────────────────┘    └──────────────────────────┘
```

## Tasks

### 5.1 Create Settings Data Class

```kotlin
// domain/model/AppSettings.kt
package com.bmlibrarian.factchecker.domain.model

/**
 * Application settings data class.
 * Mirrors iOS AppSettings model.
 */
data class AppSettings(
    // LLM Configuration
    val llmProviderId: String = LLMProvider.ANTHROPIC.id,
    val modelId: String = LLMProvider.ANTHROPIC.defaultModel,
    val customBaseUrl: String = "",

    // Search Configuration
    val searchProvider: SearchProvider = SearchProvider.PUBMED,
    val includePreprints: Boolean = false,
    val batchSize: Int = 20,
    val relevanceThreshold: Int = 3,
    val targetRelevantDocuments: Int = 10,

    // Budget Configuration
    val maxRunBudgetUsd: Double = 1.0,
    val monthlyBudgetUsd: Double = 10.0,

    // UI Preferences
    val hasAcceptedDisclaimer: Boolean = false,
    val hasCompletedOnboarding: Boolean = false,

    // NCBI Configuration (optional)
    val ncbiEmail: String = "",
    val ncbiApiKey: String = ""
) {
    /**
     * Get the current LLM provider configuration.
     */
    val llmProvider: LLMProvider?
        get() = LLMProvider.fromId(llmProviderId)

    /**
     * Get the model info for cost calculation.
     */
    val modelInfo: ModelInfo?
        get() = llmProvider?.models?.find { it.id == modelId }

    /**
     * Check if settings are configured for use.
     */
    val isConfigured: Boolean
        get() = llmProviderId.isNotEmpty() && modelId.isNotEmpty()

    companion object {
        val DEFAULT = AppSettings()
    }
}
```

### 5.2 Create Settings Repository

```kotlin
// data/repository/SettingsRepository.kt
package com.bmlibrarian.factchecker.data.repository

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import com.bmlibrarian.factchecker.domain.model.AppSettings
import com.bmlibrarian.factchecker.domain.model.LLMProvider
import com.bmlibrarian.factchecker.domain.model.SearchProvider
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Repository for managing application settings.
 * Uses SharedPreferences for config and EncryptedSharedPreferences for API keys.
 */
@Singleton
class SettingsRepository @Inject constructor(
    @ApplicationContext private val context: Context
) {

    companion object {
        private const val PREFS_NAME = "medical_factchecker_settings"
        private const val ENCRYPTED_PREFS_NAME = "medical_factchecker_secure"

        // SharedPreferences keys
        private const val KEY_LLM_PROVIDER_ID = "llm_provider_id"
        private const val KEY_MODEL_ID = "model_id"
        private const val KEY_CUSTOM_BASE_URL = "custom_base_url"
        private const val KEY_SEARCH_PROVIDER = "search_provider"
        private const val KEY_INCLUDE_PREPRINTS = "include_preprints"
        private const val KEY_BATCH_SIZE = "batch_size"
        private const val KEY_RELEVANCE_THRESHOLD = "relevance_threshold"
        private const val KEY_TARGET_RELEVANT_DOCS = "target_relevant_documents"
        private const val KEY_MAX_RUN_BUDGET = "max_run_budget_usd"
        private const val KEY_MONTHLY_BUDGET = "monthly_budget_usd"
        private const val KEY_DISCLAIMER_ACCEPTED = "disclaimer_accepted"
        private const val KEY_ONBOARDING_COMPLETED = "onboarding_completed"
        private const val KEY_NCBI_EMAIL = "ncbi_email"

        // Encrypted keys prefixes
        private const val KEY_API_KEY_PREFIX = "api_key_"
        private const val KEY_NCBI_API_KEY = "ncbi_api_key"
    }

    // Regular SharedPreferences for non-sensitive settings
    private val prefs: SharedPreferences by lazy {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    }

    // Encrypted SharedPreferences for API keys
    private val encryptedPrefs: SharedPreferences by lazy {
        val masterKey = MasterKey.Builder(context)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()

        EncryptedSharedPreferences.create(
            context,
            ENCRYPTED_PREFS_NAME,
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
        )
    }

    // In-memory cache of API keys to avoid decryption on every access
    private val apiKeyCache = mutableMapOf<String, String>()

    // Observable settings state
    private val _settings = MutableStateFlow(loadSettings())
    val settings: StateFlow<AppSettings> = _settings.asStateFlow()

    /**
     * Get current settings (cached).
     */
    fun getSettings(): AppSettings = _settings.value

    /**
     * Load settings from SharedPreferences.
     */
    private fun loadSettings(): AppSettings {
        return AppSettings(
            llmProviderId = prefs.getString(KEY_LLM_PROVIDER_ID, LLMProvider.ANTHROPIC.id) ?: LLMProvider.ANTHROPIC.id,
            modelId = prefs.getString(KEY_MODEL_ID, LLMProvider.ANTHROPIC.defaultModel) ?: LLMProvider.ANTHROPIC.defaultModel,
            customBaseUrl = prefs.getString(KEY_CUSTOM_BASE_URL, "") ?: "",
            searchProvider = SearchProvider.valueOf(
                prefs.getString(KEY_SEARCH_PROVIDER, SearchProvider.PUBMED.name) ?: SearchProvider.PUBMED.name
            ),
            includePreprints = prefs.getBoolean(KEY_INCLUDE_PREPRINTS, false),
            batchSize = prefs.getInt(KEY_BATCH_SIZE, 20),
            relevanceThreshold = prefs.getInt(KEY_RELEVANCE_THRESHOLD, 3),
            targetRelevantDocuments = prefs.getInt(KEY_TARGET_RELEVANT_DOCS, 10),
            maxRunBudgetUsd = prefs.getFloat(KEY_MAX_RUN_BUDGET, 1.0f).toDouble(),
            monthlyBudgetUsd = prefs.getFloat(KEY_MONTHLY_BUDGET, 10.0f).toDouble(),
            hasAcceptedDisclaimer = prefs.getBoolean(KEY_DISCLAIMER_ACCEPTED, false),
            hasCompletedOnboarding = prefs.getBoolean(KEY_ONBOARDING_COMPLETED, false),
            ncbiEmail = prefs.getString(KEY_NCBI_EMAIL, "") ?: ""
        )
    }

    /**
     * Save settings to SharedPreferences.
     */
    fun saveSettings(settings: AppSettings) {
        prefs.edit().apply {
            putString(KEY_LLM_PROVIDER_ID, settings.llmProviderId)
            putString(KEY_MODEL_ID, settings.modelId)
            putString(KEY_CUSTOM_BASE_URL, settings.customBaseUrl)
            putString(KEY_SEARCH_PROVIDER, settings.searchProvider.name)
            putBoolean(KEY_INCLUDE_PREPRINTS, settings.includePreprints)
            putInt(KEY_BATCH_SIZE, settings.batchSize)
            putInt(KEY_RELEVANCE_THRESHOLD, settings.relevanceThreshold)
            putInt(KEY_TARGET_RELEVANT_DOCS, settings.targetRelevantDocuments)
            putFloat(KEY_MAX_RUN_BUDGET, settings.maxRunBudgetUsd.toFloat())
            putFloat(KEY_MONTHLY_BUDGET, settings.monthlyBudgetUsd.toFloat())
            putBoolean(KEY_DISCLAIMER_ACCEPTED, settings.hasAcceptedDisclaimer)
            putBoolean(KEY_ONBOARDING_COMPLETED, settings.hasCompletedOnboarding)
            putString(KEY_NCBI_EMAIL, settings.ncbiEmail)
            apply()
        }
        _settings.value = settings
    }

    /**
     * Update specific settings.
     */
    fun updateSettings(transform: (AppSettings) -> AppSettings) {
        saveSettings(transform(_settings.value))
    }

    // API Key Management

    /**
     * Get API key for a provider.
     * Returns cached value if available, otherwise decrypts from storage.
     */
    fun getApiKey(providerId: String): String {
        return apiKeyCache.getOrPut(providerId) {
            encryptedPrefs.getString(KEY_API_KEY_PREFIX + providerId, "") ?: ""
        }
    }

    /**
     * Get API key for the currently selected provider.
     */
    val apiKey: String
        get() = getApiKey(_settings.value.llmProviderId)

    /**
     * Save API key for a provider.
     */
    fun saveApiKey(providerId: String, apiKey: String) {
        encryptedPrefs.edit().apply {
            putString(KEY_API_KEY_PREFIX + providerId, apiKey)
            apply()
        }
        apiKeyCache[providerId] = apiKey
    }

    /**
     * Check if API key exists for a provider.
     */
    fun hasApiKey(providerId: String): Boolean {
        return getApiKey(providerId).isNotEmpty()
    }

    /**
     * Delete API key for a provider.
     */
    fun deleteApiKey(providerId: String) {
        encryptedPrefs.edit().remove(KEY_API_KEY_PREFIX + providerId).apply()
        apiKeyCache.remove(providerId)
    }

    /**
     * Get NCBI API key (for PubMed rate limiting).
     */
    fun getNcbiApiKey(): String {
        return apiKeyCache.getOrPut(KEY_NCBI_API_KEY) {
            encryptedPrefs.getString(KEY_NCBI_API_KEY, "") ?: ""
        }
    }

    /**
     * Save NCBI API key.
     */
    fun saveNcbiApiKey(apiKey: String) {
        encryptedPrefs.edit().putString(KEY_NCBI_API_KEY, apiKey).apply()
        apiKeyCache[KEY_NCBI_API_KEY] = apiKey
    }

    // Convenience Methods

    /**
     * Set LLM provider and update default model.
     */
    fun setLLMProvider(providerId: String) {
        val provider = LLMProvider.fromId(providerId)
        updateSettings { settings ->
            settings.copy(
                llmProviderId = providerId,
                modelId = provider?.defaultModel ?: settings.modelId
            )
        }
    }

    /**
     * Set selected model.
     */
    fun setModel(modelId: String) {
        updateSettings { it.copy(modelId = modelId) }
    }

    /**
     * Mark disclaimer as accepted.
     */
    fun acceptDisclaimer() {
        updateSettings { it.copy(hasAcceptedDisclaimer = true) }
    }

    /**
     * Mark onboarding as completed.
     */
    fun completeOnboarding() {
        updateSettings { it.copy(hasCompletedOnboarding = true) }
    }

    /**
     * Reset all settings to defaults.
     */
    fun resetToDefaults() {
        // Clear regular prefs
        prefs.edit().clear().apply()

        // Clear encrypted prefs (API keys)
        encryptedPrefs.edit().clear().apply()
        apiKeyCache.clear()

        // Reset to defaults
        _settings.value = AppSettings.DEFAULT
    }
}
```

### 5.3 Create Cost Calculator Utility

```kotlin
// util/CostCalculator.kt
package com.bmlibrarian.factchecker.util

import com.bmlibrarian.factchecker.domain.model.LLMProvider
import com.bmlibrarian.factchecker.domain.model.ModelInfo

/**
 * Utility for calculating LLM API costs.
 */
object CostCalculator {

    /**
     * Calculate cost for token usage.
     *
     * @param modelInfo Model pricing information
     * @param inputTokens Number of input/prompt tokens
     * @param outputTokens Number of output/completion tokens
     * @return Cost in USD
     */
    fun calculateCost(
        modelInfo: ModelInfo?,
        inputTokens: Int,
        outputTokens: Int
    ): Double {
        if (modelInfo == null) return 0.0
        return modelInfo.calculateCost(inputTokens, outputTokens)
    }

    /**
     * Calculate cost using provider and model IDs.
     */
    fun calculateCost(
        providerId: String,
        modelId: String,
        inputTokens: Int,
        outputTokens: Int
    ): Double {
        val provider = LLMProvider.fromId(providerId) ?: return 0.0
        val modelInfo = provider.models.find { it.id == modelId } ?: return 0.0
        return calculateCost(modelInfo, inputTokens, outputTokens)
    }

    /**
     * Estimate cost for a fact-check run.
     * Based on average token usage per operation.
     */
    fun estimateRunCost(
        modelInfo: ModelInfo?,
        documentCount: Int,
        relevantDocumentCount: Int = (documentCount * 0.3).toInt()
    ): Double {
        if (modelInfo == null) return 0.0

        // Average token estimates per operation
        val queryConversionTokens = Pair(200, 100) // input, output
        val scoringTokensPerDoc = Pair(800, 150)
        val citationTokensPerDoc = Pair(1000, 300)
        val reportTokens = Pair(2000, 1500)

        var totalCost = 0.0

        // Query conversion (1x)
        totalCost += modelInfo.calculateCost(queryConversionTokens.first, queryConversionTokens.second)

        // Scoring (per document)
        totalCost += documentCount * modelInfo.calculateCost(
            scoringTokensPerDoc.first,
            scoringTokensPerDoc.second
        )

        // Citation extraction (per relevant document)
        totalCost += relevantDocumentCount * modelInfo.calculateCost(
            citationTokensPerDoc.first,
            citationTokensPerDoc.second
        )

        // Report generation (1x)
        totalCost += modelInfo.calculateCost(reportTokens.first, reportTokens.second)

        return totalCost
    }

    /**
     * Format cost for display.
     */
    fun formatCost(costUsd: Double): String {
        return when {
            costUsd < 0.01 -> "< $0.01"
            costUsd < 1.0 -> String.format("$%.2f", costUsd)
            else -> String.format("$%.2f", costUsd)
        }
    }

    /**
     * Format cost with currency symbol.
     */
    fun formatCostFull(costUsd: Double): String {
        return String.format("$%.4f USD", costUsd)
    }
}
```

### 5.4 Create Settings ViewModel

```kotlin
// ui/settings/SettingsViewModel.kt
package com.bmlibrarian.factchecker.ui.settings

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.bmlibrarian.factchecker.data.repository.SettingsRepository
import com.bmlibrarian.factchecker.domain.model.AppSettings
import com.bmlibrarian.factchecker.domain.model.LLMProvider
import com.bmlibrarian.factchecker.domain.model.SearchProvider
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * ViewModel for the Settings screen.
 */
@HiltViewModel
class SettingsViewModel @Inject constructor(
    private val settingsRepository: SettingsRepository
) : ViewModel() {

    // Settings state
    val settings: StateFlow<AppSettings> = settingsRepository.settings

    // UI state for API key input
    private val _apiKeyInput = MutableStateFlow("")
    val apiKeyInput: StateFlow<String> = _apiKeyInput

    // Available providers
    val providers = LLMProvider.ALL_PROVIDERS

    // Current provider's models
    val currentModels: StateFlow<List<com.bmlibrarian.factchecker.domain.model.ModelInfo>> =
        settings.map { settings ->
            settings.llmProvider?.models ?: emptyList()
        }.stateIn(
            viewModelScope,
            SharingStarted.WhileSubscribed(5000),
            emptyList()
        )

    // Check if current provider has API key configured
    val hasApiKey: StateFlow<Boolean> = settings.map { settings ->
        settingsRepository.hasApiKey(settings.llmProviderId)
    }.stateIn(
        viewModelScope,
        SharingStarted.WhileSubscribed(5000),
        false
    )

    /**
     * Set the LLM provider.
     */
    fun setProvider(providerId: String) {
        settingsRepository.setLLMProvider(providerId)
        // Load existing API key for this provider
        _apiKeyInput.value = settingsRepository.getApiKey(providerId)
    }

    /**
     * Set the model.
     */
    fun setModel(modelId: String) {
        settingsRepository.setModel(modelId)
    }

    /**
     * Update API key input field.
     */
    fun updateApiKeyInput(value: String) {
        _apiKeyInput.value = value
    }

    /**
     * Save the API key.
     */
    fun saveApiKey() {
        val providerId = settings.value.llmProviderId
        settingsRepository.saveApiKey(providerId, _apiKeyInput.value)
    }

    /**
     * Set search provider.
     */
    fun setSearchProvider(provider: SearchProvider) {
        settingsRepository.updateSettings { it.copy(searchProvider = provider) }
    }

    /**
     * Set include preprints.
     */
    fun setIncludePreprints(include: Boolean) {
        settingsRepository.updateSettings { it.copy(includePreprints = include) }
    }

    /**
     * Set batch size.
     */
    fun setBatchSize(size: Int) {
        settingsRepository.updateSettings { it.copy(batchSize = size) }
    }

    /**
     * Set relevance threshold.
     */
    fun setRelevanceThreshold(threshold: Int) {
        settingsRepository.updateSettings { it.copy(relevanceThreshold = threshold) }
    }

    /**
     * Set target relevant documents.
     */
    fun setTargetRelevantDocuments(target: Int) {
        settingsRepository.updateSettings { it.copy(targetRelevantDocuments = target) }
    }

    /**
     * Set maximum run budget.
     */
    fun setMaxRunBudget(budgetUsd: Double) {
        settingsRepository.updateSettings { it.copy(maxRunBudgetUsd = budgetUsd) }
    }

    /**
     * Set monthly budget.
     */
    fun setMonthlyBudget(budgetUsd: Double) {
        settingsRepository.updateSettings { it.copy(monthlyBudgetUsd = budgetUsd) }
    }

    /**
     * Set custom base URL (for custom provider).
     */
    fun setCustomBaseUrl(url: String) {
        settingsRepository.updateSettings { it.copy(customBaseUrl = url) }
    }

    /**
     * Set NCBI email.
     */
    fun setNcbiEmail(email: String) {
        settingsRepository.updateSettings { it.copy(ncbiEmail = email) }
    }

    /**
     * Save NCBI API key.
     */
    fun saveNcbiApiKey(apiKey: String) {
        settingsRepository.saveNcbiApiKey(apiKey)
    }

    /**
     * Reset all settings to defaults.
     */
    fun resetToDefaults() {
        settingsRepository.resetToDefaults()
        _apiKeyInput.value = ""
    }

    /**
     * Check if all required settings are configured.
     */
    fun isConfigured(): Boolean {
        val s = settings.value
        return s.isConfigured && settingsRepository.hasApiKey(s.llmProviderId)
    }

    init {
        // Load initial API key for current provider
        viewModelScope.launch {
            _apiKeyInput.value = settingsRepository.getApiKey(settings.value.llmProviderId)
        }
    }
}
```

### 5.5 Update AppModule for Settings

```kotlin
// di/AppModule.kt (updated)
package com.bmlibrarian.factchecker.di

import android.content.Context
import com.bmlibrarian.factchecker.data.repository.SettingsRepository
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton

/**
 * Hilt module providing application-wide dependencies.
 */
@Module
@InstallIn(SingletonComponent::class)
object AppModule {

    // SettingsRepository uses @Inject constructor with @Singleton,
    // so Hilt will provide it automatically.
    // This module can be used for additional app-wide dependencies.
}
```

## Verification Checklist

- [ ] Settings load correctly from SharedPreferences
- [ ] Settings save correctly to SharedPreferences
- [ ] API keys are stored encrypted
- [ ] API keys are cached in memory after first read
- [ ] Settings flow emits updates when values change
- [ ] All providers' API keys can be stored separately
- [ ] Reset to defaults clears all settings and keys
- [ ] SettingsViewModel exposes correct state
- [ ] Cost calculator produces accurate estimates

## Testing

### Unit Tests

```kotlin
// test/data/repository/SettingsRepositoryTest.kt
@Test
fun `settings persist across repository instances`() {
    val repo1 = SettingsRepository(context)
    repo1.updateSettings { it.copy(batchSize = 50) }

    val repo2 = SettingsRepository(context)
    assertEquals(50, repo2.getSettings().batchSize)
}

@Test
fun `API keys are stored separately per provider`() {
    val repo = SettingsRepository(context)

    repo.saveApiKey("anthropic", "key-anthropic")
    repo.saveApiKey("openai", "key-openai")

    assertEquals("key-anthropic", repo.getApiKey("anthropic"))
    assertEquals("key-openai", repo.getApiKey("openai"))
}

@Test
fun `reset clears all settings and keys`() {
    val repo = SettingsRepository(context)
    repo.updateSettings { it.copy(batchSize = 100) }
    repo.saveApiKey("anthropic", "test-key")

    repo.resetToDefaults()

    assertEquals(20, repo.getSettings().batchSize) // Default
    assertEquals("", repo.getApiKey("anthropic"))
}
```

### Cost Calculator Tests

```kotlin
// test/util/CostCalculatorTest.kt
@Test
fun `calculateCost returns correct value`() {
    val modelInfo = ModelInfo("test", "Test", 3.0, 15.0) // $3/1M input, $15/1M output

    val cost = CostCalculator.calculateCost(modelInfo, 1000, 500)

    // (1000 / 1_000_000) * 3.0 + (500 / 1_000_000) * 15.0
    // = 0.003 + 0.0075 = 0.0105
    assertEquals(0.0105, cost, 0.0001)
}

@Test
fun `formatCost handles small amounts`() {
    assertEquals("< $0.01", CostCalculator.formatCost(0.001))
    assertEquals("$0.05", CostCalculator.formatCost(0.05))
    assertEquals("$1.23", CostCalculator.formatCost(1.234))
}
```

## Next Phase

Continue to [Phase 6: UI - Navigation & FactCheck](./06-ui-factcheck.md)
