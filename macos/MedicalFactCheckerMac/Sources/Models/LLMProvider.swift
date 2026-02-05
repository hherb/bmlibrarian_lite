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

/// Supported LLM providers with OpenAI-compatible APIs.
///
/// Each provider has a base URL and a list of available models.
/// Use `.custom` for self-hosted or unlisted providers.
///
/// Models can be fetched dynamically using `ModelFetchService.shared.fetchModels(for:)`.
/// The `fallbackModels` property provides hardcoded models when API fetching fails.
enum LLMProvider: String, CaseIterable, Identifiable, Codable {
    case anthropic
    case openai
    case deepseek
    case groq
    case mistral
    case ollama
    case custom

    var id: String { rawValue }

    /// Human-readable display name.
    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic (Claude)"
        case .openai: return "OpenAI"
        case .deepseek: return "DeepSeek"
        case .groq: return "Groq"
        case .mistral: return "Mistral AI"
        case .ollama: return "Ollama (Local)"
        case .custom: return "Custom"
        }
    }

    /// Base URL for the provider's OpenAI-compatible API.
    var baseURL: String {
        switch self {
        case .anthropic: return "https://api.anthropic.com/v1"
        case .openai: return "https://api.openai.com/v1"
        case .deepseek: return "https://api.deepseek.com/v1"
        case .groq: return "https://api.groq.com/openai/v1"
        case .mistral: return "https://api.mistral.ai/v1"
        case .ollama: return "http://localhost:11434/v1"
        case .custom: return ""
        }
    }

    /// Fallback models for this provider (used when API fetching fails).
    ///
    /// These are hardcoded models that serve as fallbacks when dynamic
    /// model fetching is not available or fails.
    /// Last updated: January 2026
    var fallbackModels: [LLMModel] {
        switch self {
        case .anthropic:
            return [
                // Claude 4.5 Series (Latest - January 2026)
                LLMModel(
                    id: "claude-sonnet-4-5-20250929",
                    displayName: "Claude Sonnet 4.5",
                    description: "Best balance of speed and intelligence",
                    inputPrice: 3.00,
                    outputPrice: 15.00,
                    isRecommended: true
                ),
                LLMModel(
                    id: "claude-haiku-4-5-20251001",
                    displayName: "Claude Haiku 4.5",
                    description: "Fastest with near-frontier intelligence",
                    inputPrice: 1.00,
                    outputPrice: 5.00
                ),
                LLMModel(
                    id: "claude-opus-4-5-20251101",
                    displayName: "Claude Opus 4.5",
                    description: "Maximum intelligence, premium model",
                    inputPrice: 5.00,
                    outputPrice: 25.00
                ),
                // Legacy models still available
                LLMModel(
                    id: "claude-sonnet-4-20250514",
                    displayName: "Claude Sonnet 4",
                    description: "Previous generation Sonnet",
                    inputPrice: 3.00,
                    outputPrice: 15.00
                ),
                LLMModel(
                    id: "claude-3-7-sonnet-20250219",
                    displayName: "Claude 3.7 Sonnet",
                    description: "Older Sonnet model",
                    inputPrice: 3.00,
                    outputPrice: 15.00
                ),
            ]

        case .openai:
            return [
                // GPT-5 Series (Latest - January 2026)
                LLMModel(
                    id: "gpt-5.2",
                    displayName: "GPT-5.2",
                    description: "Flagship model for coding and agents",
                    inputPrice: 2.00,
                    outputPrice: 8.00,
                    isRecommended: true
                ),
                LLMModel(
                    id: "o4-mini",
                    displayName: "o4-mini",
                    description: "Fast, cost-efficient reasoning",
                    inputPrice: 1.10,
                    outputPrice: 4.40
                ),
                LLMModel(
                    id: "o3",
                    displayName: "o3",
                    description: "Reasoning for complex tasks",
                    inputPrice: 2.00,
                    outputPrice: 8.00
                ),
                LLMModel(
                    id: "gpt-4o",
                    displayName: "GPT-4o",
                    description: "Capable multimodal model",
                    inputPrice: 2.50,
                    outputPrice: 10.00
                ),
                LLMModel(
                    id: "gpt-4o-mini",
                    displayName: "GPT-4o Mini",
                    description: "Fast and affordable",
                    inputPrice: 0.15,
                    outputPrice: 0.60
                ),
            ]

        case .deepseek:
            return [
                // DeepSeek V3.2 (Latest - January 2026)
                LLMModel(
                    id: "deepseek-chat",
                    displayName: "DeepSeek V3.2 (Chat)",
                    description: "General purpose, very affordable",
                    inputPrice: 0.28,
                    outputPrice: 0.42,
                    isRecommended: true
                ),
                LLMModel(
                    id: "deepseek-reasoner",
                    displayName: "DeepSeek V3.2 (Reasoner)",
                    description: "Step-by-step reasoning mode",
                    inputPrice: 0.28,
                    outputPrice: 0.42
                ),
            ]

        case .groq:
            return [
                // Llama 4 Series (Latest - January 2026)
                LLMModel(
                    id: "llama-4-maverick-17b-128e-instruct",
                    displayName: "Llama 4 Maverick",
                    description: "High quality, 400B total params",
                    inputPrice: 0.50,
                    outputPrice: 0.77,
                    isRecommended: true
                ),
                LLMModel(
                    id: "llama-4-scout-17b-16e-instruct",
                    displayName: "Llama 4 Scout",
                    description: "Fast multimodal, 109B params",
                    inputPrice: 0.11,
                    outputPrice: 0.34
                ),
                LLMModel(
                    id: "llama-3.3-70b-versatile",
                    displayName: "Llama 3.3 70B",
                    description: "Versatile previous gen model",
                    inputPrice: 0.59,
                    outputPrice: 0.79
                ),
                LLMModel(
                    id: "llama-3.1-8b-instant",
                    displayName: "Llama 3.1 8B",
                    description: "Fastest, lowest cost",
                    inputPrice: 0.05,
                    outputPrice: 0.08
                ),
            ]

        case .mistral:
            return [
                // Mistral Latest (January 2026) - using -latest suffixes for API compatibility
                LLMModel(
                    id: "mistral-large-latest",
                    displayName: "Mistral Large",
                    description: "State-of-the-art flagship model",
                    inputPrice: 2.00,
                    outputPrice: 6.00,
                    isRecommended: true
                ),
                LLMModel(
                    id: "mistral-medium-latest",
                    displayName: "Mistral Medium",
                    description: "Balanced performance and cost",
                    inputPrice: 2.70,
                    outputPrice: 8.10
                ),
                LLMModel(
                    id: "mistral-small-latest",
                    displayName: "Mistral Small",
                    description: "Fast and affordable",
                    inputPrice: 0.20,
                    outputPrice: 0.60
                ),
                LLMModel(
                    id: "codestral-latest",
                    displayName: "Codestral",
                    description: "Optimized for code generation",
                    inputPrice: 0.30,
                    outputPrice: 0.90
                ),
                LLMModel(
                    id: "open-mistral-nemo",
                    displayName: "Mistral Nemo",
                    description: "Open-weight 12B model",
                    inputPrice: 0.15,
                    outputPrice: 0.15
                ),
            ]

        case .ollama:
            return [
                LLMModel(
                    id: "llama3.2",
                    displayName: "Llama 3.2",
                    description: "Local inference, no API cost",
                    inputPrice: 0,
                    outputPrice: 0,
                    isRecommended: true
                ),
                LLMModel(
                    id: "llama3.1",
                    displayName: "Llama 3.1",
                    description: "Previous generation Llama",
                    inputPrice: 0,
                    outputPrice: 0
                ),
                LLMModel(
                    id: "mistral",
                    displayName: "Mistral 7B",
                    description: "Compact and fast",
                    inputPrice: 0,
                    outputPrice: 0
                ),
                LLMModel(
                    id: "mixtral",
                    displayName: "Mixtral 8x7B",
                    description: "Mixture of experts model",
                    inputPrice: 0,
                    outputPrice: 0
                ),
                LLMModel(
                    id: "phi3",
                    displayName: "Phi-3",
                    description: "Microsoft's compact model",
                    inputPrice: 0,
                    outputPrice: 0
                ),
            ]

        case .custom:
            return []
        }
    }

    /// Available models for this provider.
    ///
    /// This property returns the fallback models synchronously.
    /// For dynamic model fetching, use `ModelFetchService.shared.fetchModels(for:)`.
    var models: [LLMModel] {
        fallbackModels
    }

    /// Default model for this provider.
    var defaultModel: LLMModel? {
        fallbackModels.first { $0.isRecommended } ?? fallbackModels.first
    }

    /// Whether the provider requires an API key.
    var requiresAPIKey: Bool {
        switch self {
        case .ollama: return false
        case .custom: return true  // May or may not, but assume yes
        default: return true
        }
    }

    /// Whether this provider supports dynamic model fetching.
    var supportsDynamicModelFetching: Bool {
        switch self {
        case .custom: return false
        default: return true
        }
    }

    /// URL to get an API key for this provider.
    var apiKeyURL: URL? {
        switch self {
        case .anthropic:
            return URL(string: "https://console.anthropic.com/settings/keys")
        case .openai:
            return URL(string: "https://platform.openai.com/api-keys")
        case .deepseek:
            return URL(string: "https://platform.deepseek.com/api_keys")
        case .groq:
            return URL(string: "https://console.groq.com/keys")
        case .mistral:
            return URL(string: "https://console.mistral.ai/api-keys")
        case .ollama, .custom:
            return nil
        }
    }

    /// Brief description of the provider.
    var providerDescription: String {
        switch self {
        case .anthropic:
            return "Claude models by Anthropic. Tested and recommended for this app."
        case .openai:
            return "GPT-5 and o-series reasoning models."
        case .deepseek:
            return "DeepSeek V3.2 - high quality at very affordable prices."
        case .groq:
            return "Ultra-fast inference for Llama 4 and other open models."
        case .mistral:
            return "European AI with strong multilingual support."
        case .ollama:
            return "Run models locally on your Mac. No API costs, full privacy."
        case .custom:
            return "Configure any OpenAI-compatible API endpoint."
        }
    }
}

// MARK: - LLM Model

/// A specific LLM model available from a provider.
struct LLMModel: Identifiable, Equatable {
    /// Model identifier to send to the API (e.g., "gpt-4o-mini").
    let id: String

    /// Human-readable name for display.
    let displayName: String

    /// Brief description of the model.
    let description: String

    /// Price per 1M input tokens in USD.
    let inputPrice: Double

    /// Price per 1M output tokens in USD.
    let outputPrice: Double

    /// Whether this model is recommended for this provider.
    var isRecommended: Bool = false

    /// Formatted price string for display.
    var priceDescription: String {
        if inputPrice == 0 && outputPrice == 0 {
            return "Free (local)"
        }
        return "$\(formatPrice(inputPrice))/$\(formatPrice(outputPrice)) per 1M tokens"
    }

    private func formatPrice(_ price: Double) -> String {
        if price < 1 {
            return String(format: "%.2f", price)
        }
        return String(format: "%.0f", price)
    }
}
