//
//  AppSettings.swift
//  MedicalFactChecker
//
//  User-configurable app settings with persistence.
//

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

    /// Base URL for the OpenAI-compatible API.
    var llmBaseURL: String {
        didSet { UserDefaults.standard.set(llmBaseURL, forKey: Keys.llmBaseURL) }
    }

    /// Model name to use for LLM calls.
    var llmModel: String {
        didSet { UserDefaults.standard.set(llmModel, forKey: Keys.llmModel) }
    }

    /// Cached LLM API key (stored in Keychain, cached in memory).
    private var _llmAPIKeyCache: String?

    /// API key (stored in Keychain, not UserDefaults).
    ///
    /// Cached in memory after first access to avoid Keychain latency.
    var llmAPIKey: String {
        get {
            if let cached = _llmAPIKeyCache {
                return cached
            }
            let loaded = KeychainHelper.load(key: Keys.llmAPIKey) ?? ""
            _llmAPIKeyCache = loaded
            return loaded
        }
        set {
            _llmAPIKeyCache = newValue
            KeychainHelper.save(key: Keys.llmAPIKey, value: newValue)
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

        // Load values with defaults
        self.llmBaseURL = defaults.string(forKey: Keys.llmBaseURL)
            ?? "https://api.openai.com/v1"
        self.llmModel = defaults.string(forKey: Keys.llmModel)
            ?? "gpt-4o-mini"
        self.ncbiEmail = defaults.string(forKey: Keys.ncbiEmail) ?? ""

        self.batchSize = defaults.object(forKey: Keys.batchSize) as? Int ?? 20
        self.minRelevantDocuments = defaults.object(forKey: Keys.minRelevantDocuments) as? Int ?? 5
        self.minScoreThreshold = defaults.object(forKey: Keys.minScoreThreshold) as? Int ?? 3

        self.maxRunBudgetUSD = defaults.object(forKey: Keys.maxRunBudgetUSD) as? Double ?? 1.0
        self.monthlyBudgetUSD = defaults.object(forKey: Keys.monthlyBudgetUSD) as? Double ?? 10.0
    }

    // MARK: - Keys

    private enum Keys {
        static let llmBaseURL = "llm_base_url"
        static let llmModel = "llm_model"
        static let llmAPIKey = "llm_api_key"
        static let ncbiEmail = "ncbi_email"
        static let ncbiAPIKey = "ncbi_api_key"
        static let batchSize = "batch_size"
        static let minRelevantDocuments = "min_relevant_documents"
        static let minScoreThreshold = "min_score_threshold"
        static let maxRunBudgetUSD = "max_run_budget_usd"
        static let monthlyBudgetUSD = "monthly_budget_usd"
    }

    // MARK: - Validation

    /// Check if LLM is properly configured.
    var isLLMConfigured: Bool {
        !llmBaseURL.isEmpty && !llmModel.isEmpty && !llmAPIKey.isEmpty
    }

    /// Check if settings are valid for running a fact-check.
    var isReadyToRun: Bool {
        isLLMConfigured && batchSize > 0 && maxRunBudgetUSD > 0
    }

    // MARK: - Reset

    /// Reset all settings to defaults.
    func resetToDefaults() {
        llmBaseURL = "https://api.openai.com/v1"
        llmModel = "gpt-4o-mini"
        llmAPIKey = ""
        ncbiEmail = ""
        ncbiAPIKey = ""
        batchSize = 20
        minRelevantDocuments = 5
        minScoreThreshold = 3
        maxRunBudgetUSD = 1.0
        monthlyBudgetUSD = 10.0
    }
}
