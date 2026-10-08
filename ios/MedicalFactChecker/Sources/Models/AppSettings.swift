// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2026 Dr Horst Herb
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

    /// Where the API keys are kept: the Keychain, or a test's stand-in.
    private let secretStore: any SecretStore

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
        let loaded = secretStore.load(key: keychainKey) ?? ""
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
        _ = secretStore.save(key: keychainKey, value: key)
    }

    /// Clear all stored API keys for all providers.
    private func clearAllAPIKeys() {
        _providerAPIKeyCache.removeAll()
        for provider in LLMProvider.allCases {
            let keychainKey = Keys.llmAPIKeyPrefix + provider.rawValue
            _ = secretStore.delete(key: keychainKey)
        }
    }

    // MARK: - PubMed Configuration

    /// Email for NCBI API identification (recommended).
    var ncbiEmail: String {
        didSet { UserDefaults.standard.set(ncbiEmail, forKey: Keys.ncbiEmail) }
    }

    /// Cached NCBI API key.
    private var _ncbiAPIKeyCache: String?

    /// NCBI API key for higher rate limits (optional): the stored key.
    ///
    /// Cached in memory after first access to avoid Keychain latency. Changed
    /// only through ``saveNCBIAPIKey(_:)``, so it never reads as saved when
    /// the save failed.
    var ncbiAPIKey: String {
        if let cached = _ncbiAPIKeyCache {
            return cached
        }
        let loaded = secretStore.load(key: Keys.ncbiAPIKey) ?? ""
        _ncbiAPIKeyCache = loaded
        return loaded
    }

    /// Store the NCBI API key, then cache it; an empty key removes it.
    ///
    /// - Parameter key: The key to store.
    /// - Returns: Whether it was stored. On failure the key stored before is
    ///   kept and stays the one in use (the store logs why).
    @discardableResult
    func saveNCBIAPIKey(_ key: String) -> Bool {
        guard secretStore.save(key: Keys.ncbiAPIKey, value: key) else { return false }
        _ncbiAPIKeyCache = key
        return true
    }

    /// Cached CORE API key.
    private var _coreAPIKeyCache: String?

    /// CORE API key (optional), which lets the app read the text CORE extracted (#480):
    /// the stored key.
    ///
    /// Cached in memory after first access to avoid Keychain latency. Changed
    /// only through ``saveCOREAPIKey(_:)``, so it never reads as saved when
    /// the save failed.
    var coreAPIKey: String {
        if let cached = _coreAPIKeyCache {
            return cached
        }
        let loaded = secretStore.load(key: Keys.coreAPIKey) ?? ""
        _coreAPIKeyCache = loaded
        return loaded
    }

    /// Store the CORE API key, then cache it; an empty key removes it.
    ///
    /// - Parameter key: The key to store.
    /// - Returns: Whether it was stored. On failure the key stored before is
    ///   kept and stays the one in use (the store logs why).
    @discardableResult
    func saveCOREAPIKey(_ key: String) -> Bool {
        guard secretStore.save(key: Keys.coreAPIKey, value: key) else { return false }
        _coreAPIKeyCache = key
        return true
    }

    /// Cached Elsevier API key.
    private var _elsevierAPIKeyCache: String?

    /// Elsevier API key (optional), which lets the app download the PDFs of
    /// Elsevier articles the user is entitled to (#480, stage C2): the stored key.
    ///
    /// Cached in memory after first access to avoid Keychain latency. Changed
    /// only through ``saveElsevierAPIKey(_:)``, so it never reads as saved when
    /// the save failed. Sent only in Elsevier's request header, never in a URL,
    /// a log line or a stored record.
    var elsevierAPIKey: String {
        if let cached = _elsevierAPIKeyCache {
            return cached
        }
        let loaded = secretStore.load(key: Keys.elsevierAPIKey) ?? ""
        _elsevierAPIKeyCache = loaded
        return loaded
    }

    /// Store the Elsevier API key, then cache it; an empty key removes it.
    ///
    /// - Parameter key: The key to store.
    /// - Returns: Whether it was stored. On failure the key stored before is
    ///   kept and stays the one in use (the store logs why).
    @discardableResult
    func saveElsevierAPIKey(_ key: String) -> Bool {
        guard secretStore.save(key: Keys.elsevierAPIKey, value: key) else { return false }
        _elsevierAPIKeyCache = key
        return true
    }

    /// Cached Elsevier institutional token.
    private var _elsevierInstTokenCache: String?

    /// Elsevier institutional token (optional), which lets the Elsevier key use
    /// the user's institution's subscriptions away from its network (#480,
    /// stage C2): the stored token.
    ///
    /// Cached in memory after first access to avoid Keychain latency. Changed
    /// only through ``saveElsevierInstToken(_:)``, so it never reads as saved
    /// when the save failed. Never sent without a key.
    var elsevierInstToken: String {
        if let cached = _elsevierInstTokenCache {
            return cached
        }
        let loaded = secretStore.load(key: Keys.elsevierInstToken) ?? ""
        _elsevierInstTokenCache = loaded
        return loaded
    }

    /// Store the Elsevier institutional token, then cache it; an empty token
    /// removes it.
    ///
    /// - Parameter token: The token to store.
    /// - Returns: Whether it was stored. On failure the token stored before is
    ///   kept and stays the one in use (the store logs why).
    @discardableResult
    func saveElsevierInstToken(_ token: String) -> Bool {
        guard secretStore.save(key: Keys.elsevierInstToken, value: token) else { return false }
        _elsevierInstTokenCache = token
        return true
    }

    /// What the settings say when an API key could not be stored, in place
    /// of "saved".
    ///
    /// - Parameter keyName: The key's service ("CORE", "NCBI", "Elsevier").
    /// - Returns: The message: not saved, and the key in use is unchanged.
    static func keySaveFailureMessage(keyName: String) -> String {
        saveFailureMessage(credential: "\(keyName) API key", noun: "key")
    }

    /// What the settings say when a token could not be stored, in place of
    /// "saved".
    ///
    /// - Parameter tokenName: What the token is ("Elsevier institutional").
    /// - Returns: The message: not saved, and the token in use is unchanged.
    static func tokenSaveFailureMessage(tokenName: String) -> String {
        saveFailureMessage(credential: "\(tokenName) token", noun: "token")
    }

    /// The not-saved message for one credential.
    ///
    /// - Parameters:
    ///   - credential: The credential, named in full ("CORE API key").
    ///   - noun: What it is, for "the … in use" ("key", "token").
    /// - Returns: The message: not saved, and the credential in use is unchanged.
    private static func saveFailureMessage(credential: String, noun: String) -> String {
        "The \(credential) could not be saved to the Keychain, so the \(noun) in use is unchanged. "
            + "Please try again."
    }

    /// The settings' explanation of the Elsevier API key, verbatim on every
    /// platform (#480, stage C2).
    static let elsevierAPIKeyExplanation =
        "Optional. A free Elsevier API key (dev.elsevier.com) lets the app download the PDFs of "
        + "Elsevier articles you are entitled to: open-access articles anywhere, subscribed ones "
        + "from your institution's network."

    /// The settings' explanation of the Elsevier institutional token, verbatim
    /// on every platform (#480, stage C2).
    static let elsevierInstTokenExplanation =
        "Optional. An institutional token from Elsevier lets the key use your institution's "
        + "subscriptions away from its network."

    // MARK: - Search Settings

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

    /// Fetch full text automatically for the most relevant papers: those at or
    /// above `WorkflowConstants.fullTextAutoFetchMinScore` (and the user's threshold).
    ///
    /// Those papers influence the report most, so their full text is retrieved
    /// before citation extraction and transparency analysis, and both read it.
    var autoFetchFullTextEnabled: Bool {
        didSet { UserDefaults.standard.set(autoFetchFullTextEnabled, forKey: Keys.autoFetchFullTextEnabled) }
    }

    // MARK: - Search Provider Settings

    /// Selected search provider for literature searches.
    var selectedSearchProvider: SearchProvider {
        didSet { UserDefaults.standard.set(selectedSearchProvider.rawValue, forKey: Keys.selectedSearchProvider) }
    }

    /// Whether to include preprints when using Europe PMC.
    var includePreprints: Bool {
        didSet { UserDefaults.standard.set(includePreprints, forKey: Keys.includePreprints) }
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

    // MARK: - Parallel Processing Settings

    /// User override for maximum concurrent LLM requests.
    ///
    /// When nil (default), concurrency is auto-detected based on the provider:
    /// - Cloud APIs (Anthropic, OpenAI, etc.): 3 concurrent requests
    /// - Local inference (Ollama): 1 (sequential)
    ///
    /// Set to a specific value to override auto-detection. Values less than 1
    /// are treated as nil (auto-detect).
    var maxConcurrentRequests: Int? {
        get {
            let stored = UserDefaults.standard.integer(forKey: Keys.maxConcurrentRequests)
            return stored > 0 ? stored : nil
        }
        set {
            if let value = newValue, value > 0 {
                UserDefaults.standard.set(value, forKey: Keys.maxConcurrentRequests)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.maxConcurrentRequests)
            }
        }
    }

    // MARK: - Initialization

    /// Load the settings. The app uses ``shared``.
    ///
    /// - Parameter secretStore: Where the API keys are kept. Defaults to the
    ///   Keychain; a test passes a stand-in, having no Keychain entitlement.
    init(secretStore: any SecretStore = KeychainSecretStore()) {
        self.secretStore = secretStore
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

        self.batchSize = defaults.object(forKey: Keys.batchSize) as? Int ?? 20
        self.minRelevantDocuments = defaults.object(forKey: Keys.minRelevantDocuments) as? Int ?? 5
        self.minScoreThreshold = defaults.object(forKey: Keys.minScoreThreshold) as? Int ?? 3

        // Search provider settings
        if let providerString = defaults.string(forKey: Keys.selectedSearchProvider),
           let searchProvider = SearchProvider(rawValue: providerString) {
            self.selectedSearchProvider = searchProvider
        } else {
            self.selectedSearchProvider = .pubmed
        }
        self.includePreprints = defaults.bool(forKey: Keys.includePreprints)
        self.autoFetchFullTextEnabled = defaults.bool(forKey: Keys.autoFetchFullTextEnabled)

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
        if let legacyKey = secretStore.load(key: Keys.llmAPIKeyLegacy), !legacyKey.isEmpty {
            // Save to new per-provider key
            setAPIKey(legacyKey, for: provider)
            // Delete legacy key
            _ = secretStore.delete(key: Keys.llmAPIKeyLegacy)
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
        static let coreAPIKey = "core_api_key"
        static let elsevierAPIKey = "elsevier_api_key"
        static let elsevierInstToken = "elsevier_insttoken"
        static let batchSize = "batch_size"
        static let minRelevantDocuments = "min_relevant_documents"
        static let minScoreThreshold = "min_score_threshold"
        static let selectedSearchProvider = "selected_search_provider"
        static let includePreprints = "include_preprints"
        static let autoFetchFullTextEnabled = "auto_fetch_full_text_enabled"
        static let embeddingScoringEnabled = "embedding_scoring_enabled"
        static let maxRunBudgetUSD = "max_run_budget_usd"
        static let monthlyBudgetUSD = "monthly_budget_usd"
        static let maxConcurrentRequests = "max_concurrent_requests"
    }

    // MARK: - Search Options Builder

    /// Build SearchOptions from current settings.
    ///
    /// - Parameter overrideProvider: Optional provider to use instead of the selected one.
    /// - Returns: Configured search options.
    func buildSearchOptions(overrideProvider: SearchProvider? = nil) -> SearchOptions {
        SearchOptions(
            provider: overrideProvider ?? selectedSearchProvider,
            includePreprints: includePreprints,
            maxResults: batchSize
        )
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
        // A failed removal keeps the stored key in use (the store logs why)
        saveNCBIAPIKey("")
        saveCOREAPIKey("")
        saveElsevierAPIKey("")
        saveElsevierInstToken("")
        batchSize = 20
        minRelevantDocuments = 5
        minScoreThreshold = 3
        selectedSearchProvider = .pubmed
        includePreprints = false
        autoFetchFullTextEnabled = false
        embeddingScoringEnabled = false
        maxRunBudgetUSD = 1.0
        monthlyBudgetUSD = 10.0
        maxConcurrentRequests = nil
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
