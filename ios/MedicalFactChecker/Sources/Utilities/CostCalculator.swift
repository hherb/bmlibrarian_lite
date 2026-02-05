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

// NOTE: This file re-exports CostCalculator from the BioMedLit package and adds
// a convenience overload that accepts the app-local LLMProvider type.
// The actual implementation is in Packages/BioMedLit/Sources/BioMedLit/Utilities/CostCalculator.swift

import Foundation
@_exported import enum BioMedLit.CostCalculator

// MARK: - LLMProvider Convenience

extension CostCalculator {
    /// Calculate the cost for a given model and token usage.
    ///
    /// Convenience overload accepting the app-local `LLMProvider` type.
    ///
    /// - Parameters:
    ///   - model: The model name (e.g., "gpt-4o-mini").
    ///   - inputTokens: Number of input tokens.
    ///   - outputTokens: Number of output tokens.
    ///   - provider: Optional LLM provider to help determine if local model (free).
    /// - Returns: Estimated cost in USD.
    static func calculateCost(model: String, inputTokens: Int, outputTokens: Int, provider: LLMProvider?) -> Double {
        calculateCost(model: model, inputTokens: inputTokens, outputTokens: outputTokens, providerName: provider?.rawValue)
    }

    /// Get pricing for a model, with fallback to default.
    ///
    /// Convenience overload accepting the app-local `LLMProvider` type.
    ///
    /// - Parameters:
    ///   - model: The model name.
    ///   - provider: Optional LLM provider to help determine if local model.
    /// - Returns: Tuple of (input price, output price) per 1M tokens.
    static func getPricing(for model: String, provider: LLMProvider?) -> (input: Double, output: Double) {
        getPricing(for: model, providerName: provider?.rawValue)
    }
}
