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
enum CostCalculator {
    // MARK: - Pricing (per 1M tokens, USD)

    /// Known model pricing configurations.
    private static let modelPricing: [String: (input: Double, output: Double)] = [
        // OpenAI models
        "gpt-4o": (2.50, 10.00),
        "gpt-4o-mini": (0.15, 0.60),
        "gpt-4-turbo": (10.00, 30.00),
        "gpt-4": (30.00, 60.00),
        "gpt-3.5-turbo": (0.50, 1.50),

        // Anthropic models
        "claude-3-opus": (15.00, 75.00),
        "claude-3-sonnet": (3.00, 15.00),
        "claude-3-haiku": (0.25, 1.25),
        "claude-3-5-sonnet": (3.00, 15.00),

        // DeepSeek models
        "deepseek-chat": (0.14, 0.28),
        "deepseek-coder": (0.14, 0.28),

        // Mistral models
        "mistral-large": (4.00, 12.00),
        "mistral-medium": (2.70, 8.10),
        "mistral-small": (1.00, 3.00),
        "mistral-tiny": (0.25, 0.25),

        // Groq models (often free/cheap)
        "llama-3.1-70b": (0.59, 0.79),
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
    /// - Returns: Estimated cost in USD.
    static func calculateCost(model: String, inputTokens: Int, outputTokens: Int) -> Double {
        let pricing = getPricing(for: model)

        let inputCost = Double(inputTokens) * pricing.input / 1_000_000
        let outputCost = Double(outputTokens) * pricing.output / 1_000_000

        return inputCost + outputCost
    }

    /// Get pricing for a model, with fallback to default.
    ///
    /// - Parameter model: The model name.
    /// - Returns: Tuple of (input price, output price) per 1M tokens.
    static func getPricing(for model: String) -> (input: Double, output: Double) {
        // Normalize model name (remove provider prefix, lowercase)
        let normalizedModel = model
            .lowercased()
            .components(separatedBy: "/").last ?? model
            .components(separatedBy: ":").last ?? model

        // Check for exact match
        if let pricing = modelPricing[normalizedModel] {
            return pricing
        }

        // Check for partial match (e.g., "gpt-4o-mini-2024-07-18" -> "gpt-4o-mini")
        for (key, pricing) in modelPricing {
            if normalizedModel.hasPrefix(key) || normalizedModel.contains(key) {
                return pricing
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
