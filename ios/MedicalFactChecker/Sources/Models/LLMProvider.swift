//
//  LLMProvider.swift
//  MedicalFactChecker
//
//  LLM provider presets with pre-configured models and endpoints.
//

import Foundation

/// Supported LLM providers with OpenAI-compatible APIs.
///
/// Each provider has a base URL and a list of available models.
/// Use `.custom` for self-hosted or unlisted providers.
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

    /// Available models for this provider.
    var models: [LLMModel] {
        switch self {
        case .anthropic:
            return [
                LLMModel(
                    id: "claude-sonnet-4-20250514",
                    displayName: "Claude Sonnet 4",
                    description: "Best balance of speed and intelligence",
                    inputPrice: 3.00,
                    outputPrice: 15.00,
                    isRecommended: true
                ),
                LLMModel(
                    id: "claude-3-5-sonnet-20241022",
                    displayName: "Claude 3.5 Sonnet",
                    description: "Fast and capable",
                    inputPrice: 3.00,
                    outputPrice: 15.00
                ),
                LLMModel(
                    id: "claude-3-5-haiku-20241022",
                    displayName: "Claude 3.5 Haiku",
                    description: "Fastest, most affordable",
                    inputPrice: 0.80,
                    outputPrice: 4.00
                ),
                LLMModel(
                    id: "claude-3-haiku-20240307",
                    displayName: "Claude 3 Haiku",
                    description: "Budget-friendly option",
                    inputPrice: 0.25,
                    outputPrice: 1.25
                ),
            ]

        case .openai:
            return [
                LLMModel(
                    id: "gpt-4o",
                    displayName: "GPT-4o",
                    description: "Most capable OpenAI model",
                    inputPrice: 2.50,
                    outputPrice: 10.00,
                    isRecommended: true
                ),
                LLMModel(
                    id: "gpt-4o-mini",
                    displayName: "GPT-4o Mini",
                    description: "Fast and affordable",
                    inputPrice: 0.15,
                    outputPrice: 0.60
                ),
                LLMModel(
                    id: "gpt-4-turbo",
                    displayName: "GPT-4 Turbo",
                    description: "Powerful with large context",
                    inputPrice: 10.00,
                    outputPrice: 30.00
                ),
                LLMModel(
                    id: "gpt-3.5-turbo",
                    displayName: "GPT-3.5 Turbo",
                    description: "Legacy model, very fast",
                    inputPrice: 0.50,
                    outputPrice: 1.50
                ),
            ]

        case .deepseek:
            return [
                LLMModel(
                    id: "deepseek-chat",
                    displayName: "DeepSeek Chat",
                    description: "General purpose, very affordable",
                    inputPrice: 0.14,
                    outputPrice: 0.28,
                    isRecommended: true
                ),
                LLMModel(
                    id: "deepseek-coder",
                    displayName: "DeepSeek Coder",
                    description: "Optimized for code tasks",
                    inputPrice: 0.14,
                    outputPrice: 0.28
                ),
            ]

        case .groq:
            return [
                LLMModel(
                    id: "llama-3.3-70b-versatile",
                    displayName: "Llama 3.3 70B",
                    description: "Most capable Llama model",
                    inputPrice: 0.59,
                    outputPrice: 0.79,
                    isRecommended: true
                ),
                LLMModel(
                    id: "llama-3.1-8b-instant",
                    displayName: "Llama 3.1 8B",
                    description: "Fastest, lowest cost",
                    inputPrice: 0.05,
                    outputPrice: 0.08
                ),
                LLMModel(
                    id: "mixtral-8x7b-32768",
                    displayName: "Mixtral 8x7B",
                    description: "Good balance of speed and quality",
                    inputPrice: 0.24,
                    outputPrice: 0.24
                ),
            ]

        case .mistral:
            return [
                LLMModel(
                    id: "mistral-large-latest",
                    displayName: "Mistral Large",
                    description: "Most capable Mistral model",
                    inputPrice: 4.00,
                    outputPrice: 12.00,
                    isRecommended: true
                ),
                LLMModel(
                    id: "mistral-medium-latest",
                    displayName: "Mistral Medium",
                    description: "Balanced performance",
                    inputPrice: 2.70,
                    outputPrice: 8.10
                ),
                LLMModel(
                    id: "mistral-small-latest",
                    displayName: "Mistral Small",
                    description: "Fast and affordable",
                    inputPrice: 1.00,
                    outputPrice: 3.00
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

    /// Default model for this provider.
    var defaultModel: LLMModel? {
        models.first { $0.isRecommended } ?? models.first
    }

    /// Whether the provider requires an API key.
    var requiresAPIKey: Bool {
        switch self {
        case .ollama: return false
        case .custom: return true  // May or may not, but assume yes
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
            return "GPT models including the powerful GPT-4o family."
        case .deepseek:
            return "High-quality models at very affordable prices."
        case .groq:
            return "Ultra-fast inference for open-source models."
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
