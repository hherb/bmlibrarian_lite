//
//  CostCalculator.swift
//  MedicalFactChecker
//
//  LLM cost estimation based on token usage.
//

import Foundation

/// Calculator for estimating LLM API costs.
///
/// Prices are per 1 million tokens. Update these values as pricing changes.
/// Last updated: January 2026
enum CostCalculator {
    // MARK: - Pricing (per 1M tokens, USD)

    /// Known model pricing configurations.
    /// Prices are per 1 million tokens (input, output) in USD.
    private static let modelPricing: [String: (input: Double, output: Double)] = [
        // OpenAI models (January 2026)
        "gpt-5.2": (2.00, 8.00),
        "gpt-5.2-pro": (24.00, 96.00),
        "gpt-5.1": (2.00, 8.00),
        "gpt-5": (2.00, 8.00),
        "o4-mini": (1.10, 4.40),
        "o3": (2.00, 8.00),
        "o3-pro": (24.00, 96.00),
        "gpt-4o": (2.50, 10.00),
        "gpt-4o-mini": (0.15, 0.60),
        "gpt-4.1": (2.00, 8.00),
        "gpt-4.1-mini": (0.40, 1.60),
        "gpt-4-turbo": (10.00, 30.00),

        // Anthropic models (January 2026)
        "claude-opus-4-5": (5.00, 25.00),
        "claude-sonnet-4-5": (3.00, 15.00),
        "claude-haiku-4-5": (1.00, 5.00),
        "claude-opus-4-1": (15.00, 75.00),
        "claude-opus-4": (15.00, 75.00),
        "claude-sonnet-4": (3.00, 15.00),
        "claude-3-7-sonnet": (3.00, 15.00),
        "claude-3-haiku": (0.25, 1.25),

        // DeepSeek models (January 2026)
        "deepseek-chat": (0.28, 0.42),
        "deepseek-reasoner": (0.28, 0.42),

        // Mistral models (January 2026)
        "mistral-large-3": (0.50, 1.50),
        "mistral-medium-3": (0.40, 2.00),
        "mistral-small": (0.10, 0.30),
        "codestral": (0.20, 0.60),
        "pixtral": (0.40, 1.20),

        // Groq models (January 2026)
        "llama-4-maverick": (0.50, 0.77),
        "llama-4-scout": (0.11, 0.34),
        "llama-3.3-70b": (0.59, 0.79),
        "llama-3.1-8b": (0.05, 0.08),
        "mixtral-8x7b": (0.24, 0.24),
    ]

    /// Default pricing for unknown models.
    private static let defaultPricing: (input: Double, output: Double) = (1.0, 3.0)

    // MARK: - Public Methods

    /// Calculate the cost for a given model and token usage.
    ///
    /// - Parameters:
    ///   - model: The model name (e.g., "gpt-4o-mini").
    ///   - inputTokens: Number of input tokens.
    ///   - outputTokens: Number of output tokens.
    ///   - provider: Optional provider to help determine if local model (free).
    /// - Returns: Estimated cost in USD.
    static func calculateCost(model: String, inputTokens: Int, outputTokens: Int, provider: LLMProvider? = nil) -> Double {
        let pricing = getPricing(for: model, provider: provider)

        let inputCost = Double(inputTokens) * pricing.input / 1_000_000
        let outputCost = Double(outputTokens) * pricing.output / 1_000_000

        return inputCost + outputCost
    }

    /// Common Ollama/local model name patterns (free inference).
    private static let localModelPatterns: [String] = [
        "llama", "mistral", "mixtral", "phi", "gemma", "qwen", "codellama",
        "vicuna", "orca", "wizard", "falcon", "starcoder", "deepseek-coder",
        "neural-chat", "starling", "dolphin", "openchat", "zephyr", "solar",
        "yi", "command-r", "nous-hermes", "tinyllama", "stablelm"
    ]

    /// Get pricing for a model, with fallback to default.
    ///
    /// - Parameter model: The model name.
    /// - Parameter provider: Optional provider to help determine if local model.
    /// - Returns: Tuple of (input price, output price) per 1M tokens.
    static func getPricing(for model: String, provider: LLMProvider? = nil) -> (input: Double, output: Double) {
        // Check if this is a local/Ollama model (free)
        if provider == .ollama {
            return (0, 0)
        }

        // Normalize model name (remove provider prefix, lowercase)
        // Note: .components() returns empty array for empty strings, so use if-let chain
        var normalizedModel = model.lowercased()
        if let lastSlashComponent = normalizedModel.components(separatedBy: "/").last, !lastSlashComponent.isEmpty {
            normalizedModel = lastSlashComponent
        }
        if let lastColonComponent = normalizedModel.components(separatedBy: ":").last, !lastColonComponent.isEmpty {
            normalizedModel = lastColonComponent
        }

        // Check for exact match in known pricing
        if let pricing = modelPricing[normalizedModel] {
            return pricing
        }

        // Check for partial match (e.g., "gpt-4o-mini-2024-07-18" -> "gpt-4o-mini")
        for (key, pricing) in modelPricing {
            if normalizedModel.hasPrefix(key) || normalizedModel.contains(key) {
                return pricing
            }
        }

        // Check if this looks like a local/Ollama model (free)
        for pattern in localModelPatterns {
            if normalizedModel.hasPrefix(pattern) || normalizedModel.contains(pattern) {
                return (0, 0)
            }
        }

        return defaultPricing
    }

    /// Estimate the cost for a typical fact-check run.
    ///
    /// Useful for showing users an estimate before running.
    ///
    /// - Parameters:
    ///   - model: The model name.
    ///   - documentCount: Number of documents to score.
    /// - Returns: Tuple of (min estimate, max estimate) in USD.
    static func estimateRunCost(model: String, documentCount: Int) -> (min: Double, max: Double) {
        // Estimates based on typical token usage:
        // - Query conversion: ~500 input, ~100 output
        // - Scoring per doc: ~800 input, ~100 output
        // - Citation extraction per relevant doc: ~1000 input, ~200 output
        // - Report generation: ~2000 input, ~1500 output

        let pricing = getPricing(for: model)

        // Conservative estimates
        let relevantDocs = max(1, documentCount / 3)  // Assume 1/3 are relevant

        let queryTokens = (input: 500, output: 100)
        let scoringTokens = (input: 800 * documentCount, output: 100 * documentCount)
        let citationTokens = (input: 1000 * relevantDocs, output: 200 * relevantDocs)
        let reportTokens = (input: 2000, output: 1500)

        let totalInput = queryTokens.input + scoringTokens.input + citationTokens.input + reportTokens.input
        let totalOutput = queryTokens.output + scoringTokens.output + citationTokens.output + reportTokens.output

        let estimatedCost = Double(totalInput) * pricing.input / 1_000_000
            + Double(totalOutput) * pricing.output / 1_000_000

        // Return range: 80% to 150% of estimate
        return (min: estimatedCost * 0.8, max: estimatedCost * 1.5)
    }

    /// Format a cost value for display.
    ///
    /// - Parameter cost: Cost in USD.
    /// - Returns: Formatted string (e.g., "$0.0023" or "< $0.01").
    static func formatCost(_ cost: Double) -> String {
        if cost < 0.001 {
            return "< $0.001"
        } else if cost < 0.01 {
            return String(format: "$%.4f", cost)
        } else if cost < 1.0 {
            return String(format: "$%.3f", cost)
        } else {
            return String(format: "$%.2f", cost)
        }
    }
}
