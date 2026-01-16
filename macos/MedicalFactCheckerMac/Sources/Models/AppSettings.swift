// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2025 Dr Horst Herb
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

import Foundation
import SwiftUI

/// User-configurable settings for the app.
///
/// Uses UserDefaults for persistence and Keychain for sensitive values.
/// API keys are cached in memory to avoid repeated Keychain access.
@Observable
final class AppSettings {
    // MARK: - Singleton

    static let shared = AppSettings()

    // MARK: - LLM Configuration

    /// Selected LLM provider.
    var selectedProvider: LLMProvider {
        didSet {
            UserDefaults.standard.set(selectedProvider.rawValue, forKey: Keys.selectedProvider)
            // Auto-update base URL when provider changes (except for custom)
            if selectedProvider != .custom {
                llmBaseURL = selectedProvider.baseURL
                // Set default model for the new provider
                if let defaultModel = selectedProvider.defaultModel {
                    llmModel = defaultModel.id
                }
            }
        }
    }

    /// Base URL for the OpenAI-compatible API.
    var llmBaseURL: String {
        didSet { UserDefaults.standard.set(llmBaseURL, forKey: Keys.llmBaseURL) }
    }

    /// Model name to use for LLM calls.
    var llmModel: String {
        didSet { UserDefaults.standard.set(llmModel, forKey: Keys.llmModel) }
    }

    /// Cached LLM API keys per provider (stored in Keychain, cached in memory).
    private var _providerAPIKeyCache: [LLMProvider: String] = [:]

    /// API key for the currently selected provider (stored in Keychain, not UserDefaults).
    ///
    /// Keys are stored separately per provider so switching providers preserves each key.
    /// Cached in memory after first access to avoid Keychain latency.
    var llmAPIKey: String {
        get {
            apiKey(for: selectedProvider)
        }
        set {
            setAPIKey(newValue, for: selectedProvider)
        }
    }

    /// Get the API key for a specific provider.
    ///
    /// - Parameter provider: The LLM provider.
    /// - Returns: The stored API key, or empty string if none.
    func apiKey(for provider: LLMProvider) -> String {
        if let cached = _providerAPIKeyCache[provider] {
            return cached
        }
        let keychainKey = Keys.llmAPIKeyPrefix + provider.rawValue
        let loaded = KeychainHelper.load(key: keychainKey) ?? ""
        _providerAPIKeyCache[provider] = loaded
        return loaded
    }

    /// Set the API key for a specific provider.
    ///
    /// - Parameters:
    ///   - key: The API key to store.
    ///   - provider: The LLM provider.
    func setAPIKey(_ key: String, for provider: LLMProvider) {
        _providerAPIKeyCache[provider] = key
        let keychainKey = Keys.llmAPIKeyPrefix + provider.rawValue
        KeychainHelper.save(key: keychainKey, value: key)
    }

    /// Clear all stored API keys for all providers.
    private func clearAllAPIKeys() {
        _providerAPIKeyCache.removeAll()
        for provider in LLMProvider.allCases {
            let keychainKey = Keys.llmAPIKeyPrefix + provider.rawValue
            KeychainHelper.delete(key: keychainKey)
        }
    }

    // MARK: - PubMed Configuration

    /// Email for NCBI API identification (recommended).
    var ncbiEmail: String {
        didSet { UserDefaults.standard.set(ncbiEmail, forKey: Keys.ncbiEmail) }
    }

    /// Cached NCBI API key.
    private var _ncbiAPIKeyCache: String?

    /// NCBI API key for higher rate limits (optional).
    ///
    /// Cached in memory after first access to avoid Keychain latency.
    var ncbiAPIKey: String {
        get {
            if let cached = _ncbiAPIKeyCache {
                return cached
            }
            let loaded = KeychainHelper.load(key: Keys.ncbiAPIKey) ?? ""
            _ncbiAPIKeyCache = loaded
            return loaded
        }
        set {
            _ncbiAPIKeyCache = newValue
            KeychainHelper.save(key: Keys.ncbiAPIKey, value: newValue)
        }
    }

    // MARK: - Search Settings

    /// Selected search provider for literature searches.
    ///
    /// Options: PubMed only, Europe PMC only, or both (merged results).
    var selectedSearchProvider: SearchProvider {
        didSet {
            UserDefaults.standard.set(selectedSearchProvider.rawValue, forKey: Keys.selectedSearchProvider)
        }
    }

    /// Whether to include preprints when using Europe PMC.
    ///
    /// Preprints are non-peer-reviewed articles from servers like bioRxiv and medRxiv.
    /// Only effective when selectedSearchProvider is .europePMC or .both.
    var includePreprints: Bool {
        didSet { UserDefaults.standard.set(includePreprints, forKey: Keys.includePreprints) }
    }

    /// Number of documents to fetch per batch.
    var batchSize: Int {
        didSet { UserDefaults.standard.set(batchSize, forKey: Keys.batchSize) }
    }

    /// Minimum number of relevant documents before prompting for more.
    var minRelevantDocuments: Int {
        didSet { UserDefaults.standard.set(minRelevantDocuments, forKey: Keys.minRelevantDocuments) }
    }

    /// Minimum score (1-5) to consider a document "relevant".
    var minScoreThreshold: Int {
        didSet { UserDefaults.standard.set(minScoreThreshold, forKey: Keys.minScoreThreshold) }
    }

    // MARK: - Embedding Scoring

    /// Enable semantic similarity scoring using NLEmbedding (alongside LLM scoring).
    var embeddingScoringEnabled: Bool {
        didSet { UserDefaults.standard.set(embeddingScoringEnabled, forKey: Keys.embeddingScoringEnabled) }
    }

    // MARK: - Budget Settings

    /// Maximum cost (USD) per fact-check run.
    var maxRunBudgetUSD: Double {
        didSet { UserDefaults.standard.set(maxRunBudgetUSD, forKey: Keys.maxRunBudgetUSD) }
    }

    /// Maximum monthly spending (USD).
    var monthlyBudgetUSD: Double {
        didSet { UserDefaults.standard.set(monthlyBudgetUSD, forKey: Keys.monthlyBudgetUSD) }
    }

    // MARK: - Initialization

    private init() {
        let defaults = UserDefaults.standard

        // Determine provider first (need local variable before any self access)
        let detectedProvider: LLMProvider
        if let providerString = defaults.string(forKey: Keys.selectedProvider),
           let provider = LLMProvider(rawValue: providerString) {
            detectedProvider = provider
        } else {
            // Migration: detect provider from existing URL if available
            let existingURL = defaults.string(forKey: Keys.llmBaseURL) ?? ""
            detectedProvider = Self.detectProvider(from: existingURL) ?? .anthropic
        }

        // Calculate provider-aware defaults using local variable
        let defaultURL = detectedProvider.baseURL.isEmpty
            ? "https://api.anthropic.com/v1"
            : detectedProvider.baseURL
        let defaultModel = detectedProvider.defaultModel?.id ?? "claude-sonnet-4-5-20250929"

        // Initialize all stored properties
        self.selectedProvider = detectedProvider
        self.llmBaseURL = defaults.string(forKey: Keys.llmBaseURL) ?? defaultURL
        self.llmModel = defaults.string(forKey: Keys.llmModel) ?? defaultModel
        self.ncbiEmail = defaults.string(forKey: Keys.ncbiEmail) ?? ""

        // Search provider settings
        if let searchProviderString = defaults.string(forKey: Keys.selectedSearchProvider),
           let searchProvider = SearchProvider(rawValue: searchProviderString) {
            self.selectedSearchProvider = searchProvider
        } else {
            self.selectedSearchProvider = .pubmed  // Default to PubMed for backward compatibility
        }
        self.includePreprints = defaults.bool(forKey: Keys.includePreprints)

        self.batchSize = defaults.object(forKey: Keys.batchSize) as? Int ?? 20
        self.minRelevantDocuments = defaults.object(forKey: Keys.minRelevantDocuments) as? Int ?? 5
        self.minScoreThreshold = defaults.object(forKey: Keys.minScoreThreshold) as? Int ?? 3
        self.embeddingScoringEnabled = defaults.bool(forKey: Keys.embeddingScoringEnabled)

        self.maxRunBudgetUSD = defaults.object(forKey: Keys.maxRunBudgetUSD) as? Double ?? 1.0
        self.monthlyBudgetUSD = defaults.object(forKey: Keys.monthlyBudgetUSD) as? Double ?? 10.0

        // Migrate legacy single API key to per-provider storage
        migrateLegacyAPIKeyIfNeeded(for: detectedProvider)
    }

    /// Migrate legacy single API key to the per-provider storage format.
    ///
    /// This runs once to move any existing API key from the old single-key storage
    /// to the new per-provider format. The key is assigned to the detected provider.
    private func migrateLegacyAPIKeyIfNeeded(for provider: LLMProvider) {
        let defaults = UserDefaults.standard

        // Skip if already migrated
        guard !defaults.bool(forKey: Keys.apiKeyMigrated) else { return }

        // Check for legacy key
        if let legacyKey = KeychainHelper.load(key: Keys.llmAPIKeyLegacy), !legacyKey.isEmpty {
            // Save to new per-provider key
            setAPIKey(legacyKey, for: provider)
            // Delete legacy key
            KeychainHelper.delete(key: Keys.llmAPIKeyLegacy)
        }

        // Mark as migrated
        defaults.set(true, forKey: Keys.apiKeyMigrated)
    }

    // MARK: - Keys

    private enum Keys {
        static let selectedProvider = "selected_provider"
        static let llmBaseURL = "llm_base_url"
        static let llmModel = "llm_model"
        static let llmAPIKeyPrefix = "llm_api_key_"
        static let llmAPIKeyLegacy = "llm_api_key"
        static let apiKeyMigrated = "api_key_migrated_v1"
        static let ncbiEmail = "ncbi_email"
        static let ncbiAPIKey = "ncbi_api_key"
        static let selectedSearchProvider = "selected_search_provider"
        static let includePreprints = "include_preprints"
        static let batchSize = "batch_size"
        static let minRelevantDocuments = "min_relevant_documents"
        static let minScoreThreshold = "min_score_threshold"
        static let embeddingScoringEnabled = "embedding_scoring_enabled"
        static let maxRunBudgetUSD = "max_run_budget_usd"
        static let monthlyBudgetUSD = "monthly_budget_usd"
    }

    // MARK: - Validation

    /// Check if LLM is properly configured.
    ///
    /// Validates that required settings are present based on the selected provider.
    /// Providers like Ollama don't require an API key.
    var isLLMConfigured: Bool {
        let hasBaseURL = !llmBaseURL.isEmpty
        let hasModel = !llmModel.isEmpty
        let hasAPIKeyIfRequired = !selectedProvider.requiresAPIKey || !llmAPIKey.isEmpty
        return hasBaseURL && hasModel && hasAPIKeyIfRequired
    }

    /// Check if settings are valid for running a fact-check.
    var isReadyToRun: Bool {
        isLLMConfigured && batchSize > 0 && maxRunBudgetUSD > 0
    }

    // MARK: - Reset

    /// Reset all settings to defaults.
    func resetToDefaults() {
        selectedProvider = .anthropic
        llmBaseURL = LLMProvider.anthropic.baseURL
        llmModel = LLMProvider.anthropic.defaultModel?.id ?? "claude-sonnet-4-5-20250929"
        clearAllAPIKeys()
        ncbiEmail = ""
        ncbiAPIKey = ""
        selectedSearchProvider = .pubmed
        includePreprints = false
        batchSize = 20
        minRelevantDocuments = 5
        minScoreThreshold = 3
        embeddingScoringEnabled = false
        maxRunBudgetUSD = 1.0
        monthlyBudgetUSD = 10.0
    }

    // MARK: - Search Options Builder

    /// Build SearchOptions from current settings.
    ///
    /// Creates a SearchOptions struct configured with the current user preferences.
    /// Use this when initiating a search to ensure consistent configuration.
    ///
    /// - Parameter overrideProvider: Optional provider to use instead of settings.
    /// - Returns: Configured SearchOptions.
    func buildSearchOptions(overrideProvider: SearchProvider? = nil) -> SearchOptions {
        SearchOptions(
            provider: overrideProvider ?? selectedSearchProvider,
            includePreprints: includePreprints,
            maxResults: batchSize,
            offset: 0
        )
    }

    // MARK: - Provider Detection

    /// Detect provider from an existing base URL for migration.
    ///
    /// - Parameter url: The base URL string.
    /// - Returns: The detected provider, or nil if unknown.
    private static func detectProvider(from url: String) -> LLMProvider? {
        let lowercased = url.lowercased()

        if lowercased.contains("anthropic.com") {
            return .anthropic
        } else if lowercased.contains("openai.com") {
            return .openai
        } else if lowercased.contains("deepseek.com") {
            return .deepseek
        } else if lowercased.contains("groq.com") {
            return .groq
        } else if lowercased.contains("mistral.ai") {
            return .mistral
        } else if lowercased.contains("localhost") || lowercased.contains("127.0.0.1") {
            return .ollama
        } else if !url.isEmpty {
            return .custom
        }

        return nil
    }
}
