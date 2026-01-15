package com.bmlibrarian.factchecker.data.repository

import android.content.Context
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import com.bmlibrarian.factchecker.util.Constants
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Repository for managing application settings.
 *
 * Uses EncryptedSharedPreferences for secure storage of sensitive data
 * like API keys. Non-sensitive preferences use regular SharedPreferences.
 *
 * Full implementation will be added in Phase 5 (Settings & Security).
 *
 * @param context The application context
 */
class SettingsRepository(private val context: Context) {

    private val masterKey = MasterKey.Builder(context)
        .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
        .build()

    private val encryptedPrefs = EncryptedSharedPreferences.create(
        context,
        ENCRYPTED_PREFS_NAME,
        masterKey,
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
    )

    private val regularPrefs = context.getSharedPreferences(
        REGULAR_PREFS_NAME,
        Context.MODE_PRIVATE
    )

    // Observable state for settings changes
    private val _settingsChanged = MutableStateFlow(0L)

    /** Flow that emits when any setting changes. Observers can use this to react to updates. */
    val settingsChanged: Flow<Long> = _settingsChanged.asStateFlow()

    // ==================== API Keys (Encrypted Storage) ====================

    /**
     * Gets the LLM API key from encrypted storage.
     *
     * @return The stored API key, or empty string if not set
     */
    fun getLlmApiKey(): String {
        return encryptedPrefs.getString(KEY_LLM_API_KEY, "") ?: ""
    }

    /**
     * Stores the LLM API key in encrypted storage.
     *
     * @param apiKey The API key to store
     */
    fun setLlmApiKey(apiKey: String) {
        encryptedPrefs.edit().putString(KEY_LLM_API_KEY, apiKey).apply()
        notifySettingsChanged()
    }

    // ==================== LLM Provider Settings ====================

    /**
     * Gets the selected LLM provider.
     *
     * @return The provider identifier (e.g., "openai", "anthropic", "ollama")
     */
    fun getLlmProvider(): String {
        return regularPrefs.getString(KEY_LLM_PROVIDER, DEFAULT_LLM_PROVIDER) ?: DEFAULT_LLM_PROVIDER
    }

    /**
     * Sets the LLM provider.
     *
     * @param provider The provider identifier
     */
    fun setLlmProvider(provider: String) {
        regularPrefs.edit().putString(KEY_LLM_PROVIDER, provider).apply()
        notifySettingsChanged()
    }

    /**
     * Gets the selected LLM model.
     *
     * @return The model identifier (e.g., "gpt-4", "claude-3-opus")
     */
    fun getLlmModel(): String {
        return regularPrefs.getString(KEY_LLM_MODEL, DEFAULT_LLM_MODEL) ?: DEFAULT_LLM_MODEL
    }

    /**
     * Sets the LLM model.
     *
     * @param model The model identifier
     */
    fun setLlmModel(model: String) {
        regularPrefs.edit().putString(KEY_LLM_MODEL, model).apply()
        notifySettingsChanged()
    }

    /**
     * Gets the LLM API base URL (for custom endpoints like Ollama).
     *
     * @return The base URL
     */
    fun getLlmBaseUrl(): String {
        return regularPrefs.getString(KEY_LLM_BASE_URL, Constants.DEFAULT_OPENAI_BASE_URL)
            ?: Constants.DEFAULT_OPENAI_BASE_URL
    }

    /**
     * Sets the LLM API base URL.
     *
     * @param baseUrl The base URL
     */
    fun setLlmBaseUrl(baseUrl: String) {
        regularPrefs.edit().putString(KEY_LLM_BASE_URL, baseUrl).apply()
        notifySettingsChanged()
    }

    // ==================== NCBI Settings ====================

    /**
     * Gets the NCBI email for PubMed API requests.
     *
     * @return The email address, or empty string if not set
     */
    fun getNcbiEmail(): String {
        return regularPrefs.getString(KEY_NCBI_EMAIL, "") ?: ""
    }

    /**
     * Sets the NCBI email.
     *
     * @param email The email address
     */
    fun setNcbiEmail(email: String) {
        regularPrefs.edit().putString(KEY_NCBI_EMAIL, email).apply()
        notifySettingsChanged()
    }

    // ==================== Budget Settings ====================

    /**
     * Gets the maximum budget per run in USD.
     *
     * @return The budget limit
     */
    fun getMaxRunBudgetUsd(): Float {
        return regularPrefs.getFloat(KEY_MAX_RUN_BUDGET, Constants.DEFAULT_MAX_RUN_BUDGET_USD)
    }

    /**
     * Sets the maximum budget per run.
     *
     * @param budget The budget limit in USD
     */
    fun setMaxRunBudgetUsd(budget: Float) {
        regularPrefs.edit().putFloat(KEY_MAX_RUN_BUDGET, budget).apply()
        notifySettingsChanged()
    }

    /**
     * Gets the monthly budget limit in USD.
     *
     * @return The monthly budget limit
     */
    fun getMonthlyBudgetUsd(): Float {
        return regularPrefs.getFloat(KEY_MONTHLY_BUDGET, Constants.DEFAULT_MONTHLY_BUDGET_USD)
    }

    /**
     * Sets the monthly budget limit.
     *
     * @param budget The monthly budget in USD
     */
    fun setMonthlyBudgetUsd(budget: Float) {
        regularPrefs.edit().putFloat(KEY_MONTHLY_BUDGET, budget).apply()
        notifySettingsChanged()
    }

    // ==================== Onboarding ====================

    /**
     * Checks if onboarding has been completed.
     *
     * @return True if onboarding is complete
     */
    fun isOnboardingComplete(): Boolean {
        return regularPrefs.getBoolean(KEY_ONBOARDING_COMPLETE, false)
    }

    /**
     * Marks onboarding as complete.
     */
    fun setOnboardingComplete() {
        regularPrefs.edit().putBoolean(KEY_ONBOARDING_COMPLETE, true).apply()
        notifySettingsChanged()
    }

    /**
     * Checks if the medical disclaimer has been accepted.
     *
     * @return True if disclaimer was accepted
     */
    fun isDisclaimerAccepted(): Boolean {
        return regularPrefs.getBoolean(KEY_DISCLAIMER_ACCEPTED, false)
    }

    /**
     * Marks the medical disclaimer as accepted.
     */
    fun setDisclaimerAccepted() {
        regularPrefs.edit().putBoolean(KEY_DISCLAIMER_ACCEPTED, true).apply()
        notifySettingsChanged()
    }

    // ==================== Private Helpers ====================

    private fun notifySettingsChanged() {
        _settingsChanged.value = System.currentTimeMillis()
    }

    companion object {
        private const val ENCRYPTED_PREFS_NAME = "factchecker_secure_prefs"
        private const val REGULAR_PREFS_NAME = "factchecker_prefs"

        // Encrypted keys
        private const val KEY_LLM_API_KEY = "llm_api_key"

        // Regular keys
        private const val KEY_LLM_PROVIDER = "llm_provider"
        private const val KEY_LLM_MODEL = "llm_model"
        private const val KEY_LLM_BASE_URL = "llm_base_url"
        private const val KEY_NCBI_EMAIL = "ncbi_email"
        private const val KEY_MAX_RUN_BUDGET = "max_run_budget"
        private const val KEY_MONTHLY_BUDGET = "monthly_budget"
        private const val KEY_ONBOARDING_COMPLETE = "onboarding_complete"
        private const val KEY_DISCLAIMER_ACCEPTED = "disclaimer_accepted"

        // Defaults - string defaults are kept here; numeric defaults use Constants directly
        private const val DEFAULT_LLM_PROVIDER = "openai"
        private const val DEFAULT_LLM_MODEL = "gpt-4o-mini"
    }
}
