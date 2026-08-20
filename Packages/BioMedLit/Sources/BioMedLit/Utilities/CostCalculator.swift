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

/// Calculator for estimating LLM API costs.
///
/// Prices are per 1 million tokens. Update these values as pricing changes.
/// Last updated: February 2026
public enum CostCalculator {
    // MARK: - Pricing (per 1M tokens, USD)

    /// Known model pricing configurations.
    /// Prices are per 1 million tokens (input, output) in USD.
    private static let modelPricing: [String: (input: Double, output: Double)] = [
        // OpenAI models (updated February 2026)
        "gpt-5.2": (1.75, 14.00),
        "gpt-5.2-pro": (21.00, 168.00),
        "gpt-5.1": (1.25, 10.00),
        "gpt-5": (1.25, 10.00),
        "o4-mini": (1.10, 4.40),
        "o3": (2.00, 8.00),
        "o3-pro": (20.00, 80.00),
        "gpt-4o": (2.50, 10.00),
        "gpt-4o-mini": (0.15, 0.60),
        "gpt-4.1": (2.00, 8.00),
        "gpt-4.1-mini": (0.40, 1.60),
        "gpt-4-turbo": (10.00, 30.00),

        // Anthropic models (February 2026)
        "claude-opus-4-5": (5.00, 25.00),
        "claude-sonnet-4-5": (3.00, 15.00),
        "claude-haiku-4-5": (1.00, 5.00),
        "claude-opus-4-1": (15.00, 75.00),
        "claude-opus-4": (15.00, 75.00),
        "claude-sonnet-4": (3.00, 15.00),
        "claude-3-7-sonnet": (3.00, 15.00),
        "claude-3-haiku": (0.25, 1.25),

        // DeepSeek models (August 2026) - peak-hour, cache-miss rates.
        // The V3 IDs deepseek-chat / deepseek-reasoner were retired in July 2026.
        "deepseek-v4-flash": (0.44, 1.32),
        "deepseek-v4-pro": (1.32, 3.96),

        // Mistral models (February 2026)
        "mistral-large-3": (0.50, 1.50),
        "mistral-medium-3": (0.40, 2.00),
        "mistral-small": (0.10, 0.30),
        "codestral": (0.30, 0.90),
        "pixtral-large": (2.00, 6.00),
        "pixtral-12b": (0.15, 0.15),

        // Groq models (February 2026)
        "llama-4-maverick": (0.50, 0.77),
        "llama-4-scout": (0.11, 0.34),
        "llama-3.3-70b": (0.59, 0.79),
        "llama-3.1-8b": (0.05, 0.08),
        "mixtral-8x7b": (0.24, 0.24),
    ]

    /// Pricing keys ordered longest first, so the most specific match wins deterministically.
    private static let sortedPricingKeys: [String] = modelPricing.keys.sorted {
        $0.count == $1.count ? $0 < $1 : $0.count > $1.count
    }

    /// Default pricing for unknown models.
    private static let defaultPricing: (input: Double, output: Double) = (1.0, 3.0)

    /// Provider name constant for Ollama (local inference).
    public static let ollamaProviderName = "ollama"

    // MARK: - Cost Estimation Constants

    /// Token estimates for typical workflow steps.
    private enum EstimatedTokens {
        /// Query conversion step: input tokens.
        static let queryInput = 500
        /// Query conversion step: output tokens.
        static let queryOutput = 100
        /// Per-document scoring: input tokens.
        static let scoringInputPerDoc = 800
        /// Per-document scoring: output tokens.
        static let scoringOutputPerDoc = 100
        /// Per-relevant-document citation extraction: input tokens.
        static let citationInputPerDoc = 1000
        /// Per-relevant-document citation extraction: output tokens.
        static let citationOutputPerDoc = 200
        /// Report generation: input tokens.
        static let reportInput = 2000
        /// Report generation: output tokens.
        static let reportOutput = 1500
        /// Assumed fraction of documents that are relevant (1/N).
        static let relevantFractionDivisor = 3
    }

    /// Multipliers for cost estimate range.
    private enum EstimateRange {
        /// Lower bound multiplier (80% of estimate).
        static let lowerBound = 0.8
        /// Upper bound multiplier (150% of estimate).
        static let upperBound = 1.5
    }

    /// Formatting thresholds for cost display.
    private enum FormatThresholds {
        /// Below this, show "< $0.001".
        static let subMillicent = 0.001
        /// Below this, show 4 decimal places.
        static let subCent = 0.01
        /// Below this, show 3 decimal places.
        static let subDollar = 1.0
    }

    // MARK: - Public Methods

    /// Calculate the cost for a given model and token usage.
    ///
    /// - Parameters:
    ///   - model: The model name (e.g., "gpt-4o-mini").
    ///   - inputTokens: Number of input tokens.
    ///   - outputTokens: Number of output tokens.
    ///   - providerName: Optional provider name to help determine if local model (free).
    ///     Pass "ollama" for local Ollama models.
    /// - Returns: Estimated cost in USD.
    public static func calculateCost(model: String, inputTokens: Int, outputTokens: Int, providerName: String? = nil) -> Double {
        let pricing = getPricing(for: model, providerName: providerName)

        let inputCost = Double(inputTokens) * pricing.input / 1_000_000
        let outputCost = Double(outputTokens) * pricing.output / 1_000_000

        return inputCost + outputCost
    }

    /// Get pricing for a model, with fallback to default.
    ///
    /// - Parameters:
    ///   - model: The model name.
    ///   - providerName: Optional provider name to help determine if local model.
    /// - Returns: Tuple of (input price, output price) per 1M tokens.
    public static func getPricing(for model: String, providerName: String? = nil) -> (input: Double, output: Double) {
        // Ollama models are free unless they end with ':cloud'
        if providerName?.lowercased() == ollamaProviderName && !model.lowercased().hasSuffix(":cloud") {
            return (0, 0)
        }

        // Normalize model name: remove org prefix (before slash), lowercase
        var normalizedModel = model.lowercased()
        if let lastSlashComponent = normalizedModel.components(separatedBy: "/").last, !lastSlashComponent.isEmpty {
            normalizedModel = lastSlashComponent
        }

        // Try exact match with full normalized name (may include colon tag)
        if let pricing = modelPricing[normalizedModel] {
            return pricing
        }

        // Try without version/tag suffix (e.g., "codestral:latest" → "codestral")
        let colonComponents = normalizedModel.components(separatedBy: ":")
        let withoutTag = colonComponents.first ?? normalizedModel
        if colonComponents.count > 1, !withoutTag.isEmpty, let pricing = modelPricing[withoutTag] {
            return pricing
        }

        // Check for partial match (e.g., "gpt-4o-mini-2024-07-18" → "gpt-4o-mini")
        // Try both the full name and the name without tag
        // Longest key first, and in a fixed order. Dictionary iteration order is
        // unspecified in Swift, and several keys match the same ID - "claude-opus-4-5-
        // 20251101" matches both "claude-opus-4-5" and "claude-opus-4", whose rates
        // differ threefold - so iterating the dictionary directly quoted a price that
        // depended on hash seeding. The longest match is also the most specific one.
        let candidates = colonComponents.count > 1 ? [normalizedModel, withoutTag] : [normalizedModel]
        for candidate in candidates {
            for key in sortedPricingKeys {
                if candidate.hasPrefix(key) || candidate.contains(key) {
                    return modelPricing[key] ?? defaultPricing
                }
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
    public static func estimateRunCost(model: String, documentCount: Int) -> (min: Double, max: Double) {
        // Estimates based on typical token usage:
        // - Query conversion: ~500 input, ~100 output
        // - Scoring per doc: ~800 input, ~100 output
        // - Citation extraction per relevant doc: ~1000 input, ~200 output
        // - Report generation: ~2000 input, ~1500 output

        let pricing = getPricing(for: model)

        // Conservative estimates
        let relevantDocs = max(1, documentCount / EstimatedTokens.relevantFractionDivisor)

        let queryTokens = (input: EstimatedTokens.queryInput, output: EstimatedTokens.queryOutput)
        let scoringTokens = (input: EstimatedTokens.scoringInputPerDoc * documentCount,
                             output: EstimatedTokens.scoringOutputPerDoc * documentCount)
        let citationTokens = (input: EstimatedTokens.citationInputPerDoc * relevantDocs,
                              output: EstimatedTokens.citationOutputPerDoc * relevantDocs)
        let reportTokens = (input: EstimatedTokens.reportInput, output: EstimatedTokens.reportOutput)

        let totalInput = queryTokens.input + scoringTokens.input + citationTokens.input + reportTokens.input
        let totalOutput = queryTokens.output + scoringTokens.output + citationTokens.output + reportTokens.output

        let estimatedCost = Double(totalInput) * pricing.input / 1_000_000
            + Double(totalOutput) * pricing.output / 1_000_000

        return (min: estimatedCost * EstimateRange.lowerBound, max: estimatedCost * EstimateRange.upperBound)
    }

    /// Format a cost value for display.
    ///
    /// - Parameter cost: Cost in USD.
    /// - Returns: Formatted string (e.g., "$0.0023" or "< $0.01").
    public static func formatCost(_ cost: Double) -> String {
        if cost < FormatThresholds.subMillicent {
            return "< $0.001"
        } else if cost < FormatThresholds.subCent {
            return String(format: "$%.4f", cost)
        } else if cost < FormatThresholds.subDollar {
            return String(format: "$%.3f", cost)
        } else {
            return String(format: "$%.2f", cost)
        }
    }
}
