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

/// Service for fetching available models from LLM provider APIs.
///
/// Supports dynamic model discovery for providers that offer model listing endpoints.
/// Failures are propagated to the caller; substituting a hardcoded list would hide a
/// retired model ID behind a plausible-looking picker, which is how the DeepSeek V3
/// retirement went unnoticed. Returns an empty list for `.custom`, which has no
/// listing endpoint.
actor ModelFetchService {
    // MARK: - Constants

    /// Timeout for model fetch requests.
    private static let requestTimeout: TimeInterval = 10.0

    /// Cache duration for fetched models (1 hour).
    private static let cacheDuration: TimeInterval = 3600

    // MARK: - Cache

    /// Cached models per provider with timestamp.
    private var cache: [LLMProvider: (models: [LLMModel], fetchedAt: Date)] = [:]

    // MARK: - Singleton

    static let shared = ModelFetchService()

    private init() {}

    // MARK: - Public Methods

    /// Fetch available models for a provider.
    ///
    /// Fetches models dynamically from the provider's API, returning cached results
    /// if available and not expired. Failures are propagated rather than papered over
    /// with ``LLMProvider/fallbackModels``: a caller that cannot tell a live line-up
    /// from a hardcoded one cannot tell a retired model ID from a current one either.
    ///
    /// - Parameters:
    ///   - provider: The LLM provider.
    ///   - apiKey: Optional API key for authentication.
    ///   - baseURL: Optional custom base URL.
    /// - Returns: The models the provider currently offers. Empty for `.custom`, which
    ///   has no model listing endpoint.
    /// - Throws: ``ModelFetchError`` or a networking error if the list cannot be retrieved.
    func fetchModels(
        for provider: LLMProvider,
        apiKey: String? = nil,
        baseURL: String? = nil
    ) async throws -> [LLMModel] {
        // Check cache first
        if let cached = cache[provider],
           Date().timeIntervalSince(cached.fetchedAt) < Self.cacheDuration {
            return cached.models
        }

        let models = try await fetchModelsFromAPI(
            provider: provider,
            apiKey: apiKey,
            baseURL: baseURL
        )

        // Only cache a real line-up; an empty result would otherwise make the
        // Refresh button a no-op for a full hour.
        if !models.isEmpty {
            cache[provider] = (models: models, fetchedAt: Date())
        }
        return models
    }

    /// Clear the model cache for a specific provider or all providers.
    ///
    /// - Parameter provider: Optional provider to clear. If nil, clears all caches.
    func clearCache(for provider: LLMProvider? = nil) {
        if let provider = provider {
            cache.removeValue(forKey: provider)
        } else {
            cache.removeAll()
        }
    }

    // MARK: - Private Methods

    /// Fetch models from the provider's API.
    private func fetchModelsFromAPI(
        provider: LLMProvider,
        apiKey: String?,
        baseURL: String?
    ) async throws -> [LLMModel] {
        switch provider {
        case .anthropic:
            return try await fetchAnthropicModels(apiKey: apiKey, baseURL: baseURL)
        case .openai:
            return try await fetchOpenAIModels(apiKey: apiKey, baseURL: baseURL)
        case .groq:
            return try await fetchGroqModels(apiKey: apiKey, baseURL: baseURL)
        case .mistral:
            return try await fetchMistralModels(apiKey: apiKey, baseURL: baseURL)
        case .deepseek:
            return try await fetchDeepSeekModels(apiKey: apiKey, baseURL: baseURL)
        case .ollama:
            return try await fetchOllamaModels(baseURL: baseURL)
        case .custom:
            // Custom providers don't support model fetching
            return []
        }
    }

    /// Decode a model-list response, reporting a shape change as a parse failure.
    ///
    /// A `DecodingError` surfaced as-is reads "The data couldn't be read because it isn't
    /// in the correct format", which is indistinguishable from a network problem and
    /// gives the user nothing to act on. A provider changing its response shape is the
    /// same class of change as retiring a model ID, so it deserves its own message.
    ///
    /// - Parameters:
    ///   - type: The response type to decode.
    ///   - data: The raw response body.
    /// - Returns: The decoded response.
    /// - Throws: `ModelFetchError.parseError` if the body does not match `type`.
    private static func decodeModelList<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ModelFetchError.parseError
        }
    }

    // MARK: - Provider-Specific Fetchers

    /// Fetch models from Anthropic API.
    private func fetchAnthropicModels(apiKey: String?, baseURL: String?) async throws -> [LLMModel] {
        guard let apiKey = apiKey, !apiKey.isEmpty else {
            throw ModelFetchError.noAPIKey
        }

        let url = URL(string: baseURL ?? "https://api.anthropic.com")!
            .appendingPathComponent("v1/models")

        var request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ModelFetchError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw ModelFetchError.apiError(statusCode: httpResponse.statusCode)
        }

        let result = try Self.decodeModelList(AnthropicModelsResponse.self, from: data)

        return result.data
            .filter { isUsableAnthropicModel($0.id) }
            .map { model in
                let pricing = getAnthropicPricing(for: model.id)
                return LLMModel(
                    id: model.id,
                    displayName: formatAnthropicModelName(model.id),
                    description: model.displayName ?? "Anthropic Claude model",
                    inputPrice: pricing.input,
                    outputPrice: pricing.output,
                    isRecommended: model.id.contains("sonnet-4-5")
                )
            }
            .sorted { $0.id > $1.id }  // Newest first
    }

    /// Check if an Anthropic model is usable for chat completion.
    private func isUsableAnthropicModel(_ modelId: String) -> Bool {
        // Filter out deprecated and non-chat models
        !modelId.contains("2024") &&  // Prefer 2025+ models
        (modelId.contains("claude-") && !modelId.contains("instant"))
    }

    /// Format Anthropic model ID to display name.
    private func formatAnthropicModelName(_ modelId: String) -> String {
        // claude-sonnet-4-5-20250929 -> Claude Sonnet 4.5
        let parts = modelId.replacingOccurrences(of: "claude-", with: "")
            .components(separatedBy: "-")

        guard parts.count >= 2 else { return modelId }

        let modelName = parts[0].capitalized  // sonnet, opus, haiku
        var version = parts[1]

        // Handle version like "4-5" -> "4.5"
        if parts.count >= 3, let minor = Int(parts[2]), minor < 10 {
            version = "\(parts[1]).\(minor)"
        }

        return "Claude \(modelName) \(version)"
    }

    /// Get pricing for Anthropic models.
    private func getAnthropicPricing(for modelId: String) -> (input: Double, output: Double) {
        // Pricing per 1M tokens (January 2026)
        if modelId.contains("opus-4-5") {
            return (5.00, 25.00)
        } else if modelId.contains("sonnet-4-5") {
            return (3.00, 15.00)
        } else if modelId.contains("haiku-4-5") {
            return (1.00, 5.00)
        } else if modelId.contains("opus-4-1") || modelId.contains("opus-4-0") {
            return (15.00, 75.00)
        } else if modelId.contains("sonnet-4") || modelId.contains("sonnet-3-7") {
            return (3.00, 15.00)
        } else if modelId.contains("haiku") {
            return (0.25, 1.25)
        }
        return (3.00, 15.00)  // Default
    }

    /// Fetch models from OpenAI API.
    private func fetchOpenAIModels(apiKey: String?, baseURL: String?) async throws -> [LLMModel] {
        guard let apiKey = apiKey, !apiKey.isEmpty else {
            throw ModelFetchError.noAPIKey
        }

        let url = URL(string: baseURL ?? "https://api.openai.com")!
            .appendingPathComponent("v1/models")

        var request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ModelFetchError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw ModelFetchError.apiError(statusCode: httpResponse.statusCode)
        }

        let result = try Self.decodeModelList(OpenAIModelsResponse.self, from: data)

        return result.data
            .filter { isUsableOpenAIModel($0.id) }
            .map { model in
                let pricing = getOpenAIPricing(for: model.id)
                return LLMModel(
                    id: model.id,
                    displayName: formatOpenAIModelName(model.id),
                    description: getOpenAIDescription(for: model.id),
                    inputPrice: pricing.input,
                    outputPrice: pricing.output,
                    isRecommended: model.id == "gpt-5.2" || model.id == "o4-mini"
                )
            }
            .sorted { modelSortOrder($0.id) < modelSortOrder($1.id) }
    }

    /// Check if an OpenAI model is usable for chat completion.
    private func isUsableOpenAIModel(_ modelId: String) -> Bool {
        let chatModels = ["gpt-5", "gpt-4", "o3", "o4"]
        return chatModels.contains { modelId.hasPrefix($0) } &&
               !modelId.contains("realtime") &&
               !modelId.contains("audio") &&
               !modelId.contains("tts") &&
               !modelId.contains("whisper") &&
               !modelId.contains("dall-e") &&
               !modelId.contains("embedding")
    }

    /// Format OpenAI model ID to display name.
    private func formatOpenAIModelName(_ modelId: String) -> String {
        let mapping: [String: String] = [
            "gpt-5.2": "GPT-5.2",
            "gpt-5.2-pro": "GPT-5.2 Pro",
            "gpt-5.1": "GPT-5.1",
            "gpt-5": "GPT-5",
            "gpt-4o": "GPT-4o",
            "gpt-4o-mini": "GPT-4o Mini",
            "gpt-4.1": "GPT-4.1",
            "gpt-4.1-mini": "GPT-4.1 Mini",
            "o4-mini": "o4-mini",
            "o3": "o3",
            "o3-pro": "o3 Pro",
        ]

        for (prefix, name) in mapping {
            if modelId.hasPrefix(prefix) {
                return name
            }
        }
        return modelId.uppercased()
    }

    /// Get description for OpenAI models.
    private func getOpenAIDescription(for modelId: String) -> String {
        if modelId.contains("5.2") {
            return "Flagship model for coding and agentic tasks"
        } else if modelId.contains("o4-mini") {
            return "Fast, cost-efficient reasoning"
        } else if modelId.contains("o3") {
            return "Reasoning model for complex tasks"
        } else if modelId.contains("4o-mini") {
            return "Fast and affordable"
        } else if modelId.contains("4o") {
            return "Most capable GPT-4 model"
        }
        return "OpenAI model"
    }

    /// Get pricing for OpenAI models.
    private func getOpenAIPricing(for modelId: String) -> (input: Double, output: Double) {
        // Pricing per 1M tokens (January 2026)
        if modelId.contains("5.2-pro") {
            return (24.00, 96.00)  // 12x cost of 5.2
        } else if modelId.contains("5.2") || modelId.contains("5.1") {
            return (2.00, 8.00)
        } else if modelId.hasPrefix("o4-mini") {
            return (1.10, 4.40)
        } else if modelId.hasPrefix("o3-pro") {
            return (24.00, 96.00)
        } else if modelId.hasPrefix("o3") {
            return (2.00, 8.00)
        } else if modelId.contains("4o-mini") {
            return (0.15, 0.60)
        } else if modelId.contains("4o") {
            return (2.50, 10.00)
        } else if modelId.contains("4.1-mini") {
            return (0.40, 1.60)
        } else if modelId.contains("4.1") {
            return (2.00, 8.00)
        }
        return (2.00, 8.00)  // Default
    }

    /// Get sort order for OpenAI models.
    private func modelSortOrder(_ modelId: String) -> Int {
        if modelId.contains("5.2") { return 0 }
        if modelId.contains("o4-mini") { return 1 }
        if modelId.contains("o3") { return 2 }
        if modelId.contains("4o") { return 3 }
        return 10
    }

    /// Fetch models from Groq API.
    private func fetchGroqModels(apiKey: String?, baseURL: String?) async throws -> [LLMModel] {
        guard let apiKey = apiKey, !apiKey.isEmpty else {
            throw ModelFetchError.noAPIKey
        }

        let url = URL(string: baseURL ?? "https://api.groq.com/openai")!
            .appendingPathComponent("v1/models")

        var request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ModelFetchError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw ModelFetchError.apiError(statusCode: httpResponse.statusCode)
        }

        let result = try Self.decodeModelList(OpenAIModelsResponse.self, from: data)

        return result.data
            .filter { isUsableGroqModel($0.id) }
            .map { model in
                let pricing = getGroqPricing(for: model.id)
                return LLMModel(
                    id: model.id,
                    displayName: formatGroqModelName(model.id),
                    description: getGroqDescription(for: model.id),
                    inputPrice: pricing.input,
                    outputPrice: pricing.output,
                    isRecommended: model.id.contains("llama-4-maverick")
                )
            }
    }

    /// Check if a Groq model is usable for chat completion.
    private func isUsableGroqModel(_ modelId: String) -> Bool {
        let usableModels = ["llama-4", "llama-3", "mixtral"]
        return usableModels.contains { modelId.contains($0) } &&
               !modelId.contains("guard") &&
               !modelId.contains("tool-use")
    }

    /// Format Groq model ID to display name.
    private func formatGroqModelName(_ modelId: String) -> String {
        if modelId.contains("llama-4-scout") {
            return "Llama 4 Scout"
        } else if modelId.contains("llama-4-maverick") {
            return "Llama 4 Maverick"
        } else if modelId.contains("llama-3.3-70b") {
            return "Llama 3.3 70B"
        } else if modelId.contains("llama-3.1-8b") {
            return "Llama 3.1 8B"
        } else if modelId.contains("mixtral") {
            return "Mixtral 8x7B"
        }
        return modelId
    }

    /// Get description for Groq models.
    private func getGroqDescription(for modelId: String) -> String {
        if modelId.contains("llama-4-scout") {
            return "Multimodal, 109B params, fast inference"
        } else if modelId.contains("llama-4-maverick") {
            return "High quality, 400B params"
        } else if modelId.contains("llama-3.3-70b") {
            return "Versatile 70B model"
        } else if modelId.contains("llama-3.1-8b") {
            return "Fast and efficient"
        }
        return "Fast inference on Groq"
    }

    /// Get pricing for Groq models.
    private func getGroqPricing(for modelId: String) -> (input: Double, output: Double) {
        // Pricing per 1M tokens (January 2026)
        if modelId.contains("llama-4-scout") {
            return (0.11, 0.34)
        } else if modelId.contains("llama-4-maverick") {
            return (0.50, 0.77)
        } else if modelId.contains("llama-3.3-70b") {
            return (0.59, 0.79)
        } else if modelId.contains("llama-3.1-8b") {
            return (0.05, 0.08)
        } else if modelId.contains("mixtral") {
            return (0.24, 0.24)
        }
        return (0.20, 0.40)  // Default
    }

    /// Fetch models from Mistral API.
    private func fetchMistralModels(apiKey: String?, baseURL: String?) async throws -> [LLMModel] {
        guard let apiKey = apiKey, !apiKey.isEmpty else {
            throw ModelFetchError.noAPIKey
        }

        let url = URL(string: baseURL ?? "https://api.mistral.ai")!
            .appendingPathComponent("v1/models")

        var request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ModelFetchError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw ModelFetchError.apiError(statusCode: httpResponse.statusCode)
        }

        let result = try Self.decodeModelList(OpenAIModelsResponse.self, from: data)

        return result.data
            .filter { isUsableMistralModel($0.id) }
            .map { model in
                let pricing = getMistralPricing(for: model.id)
                return LLMModel(
                    id: model.id,
                    displayName: formatMistralModelName(model.id),
                    description: getMistralDescription(for: model.id),
                    inputPrice: pricing.input,
                    outputPrice: pricing.output,
                    isRecommended: model.id.contains("mistral-large")
                )
            }
    }

    /// Check if a Mistral model is usable for chat completion.
    private func isUsableMistralModel(_ modelId: String) -> Bool {
        let chatModels = ["mistral-large", "mistral-medium", "mistral-small", "codestral", "pixtral"]
        return chatModels.contains { modelId.contains($0) } &&
               !modelId.contains("embed")
    }

    /// Format Mistral model ID to display name.
    private func formatMistralModelName(_ modelId: String) -> String {
        if modelId.contains("mistral-large-3") {
            return "Mistral Large 3"
        } else if modelId.contains("mistral-medium-3") {
            return "Mistral Medium 3"
        } else if modelId.contains("mistral-small") {
            return "Mistral Small"
        } else if modelId.contains("codestral") {
            return "Codestral"
        } else if modelId.contains("pixtral") {
            return "Pixtral (Multimodal)"
        }
        return modelId
    }

    /// Get description for Mistral models.
    private func getMistralDescription(for modelId: String) -> String {
        if modelId.contains("mistral-large") {
            return "State-of-the-art multimodal model"
        } else if modelId.contains("mistral-medium") {
            return "Balanced performance and cost"
        } else if modelId.contains("mistral-small") {
            return "Fast and affordable"
        } else if modelId.contains("codestral") {
            return "Optimized for code"
        }
        return "Mistral AI model"
    }

    /// Get pricing for Mistral models.
    private func getMistralPricing(for modelId: String) -> (input: Double, output: Double) {
        // Pricing per 1M tokens (January 2026)
        if modelId.contains("mistral-large-3") {
            return (0.50, 1.50)
        } else if modelId.contains("mistral-medium-3") {
            return (0.40, 2.00)
        } else if modelId.contains("mistral-small") {
            return (0.10, 0.30)
        } else if modelId.contains("codestral") {
            return (0.20, 0.60)
        } else if modelId.contains("pixtral") {
            return (0.40, 1.20)
        }
        return (0.50, 1.50)  // Default
    }

    /// Fetch models from DeepSeek API.
    private func fetchDeepSeekModels(apiKey: String?, baseURL: String?) async throws -> [LLMModel] {
        guard let apiKey = apiKey, !apiKey.isEmpty else {
            throw ModelFetchError.noAPIKey
        }

        let url = URL(string: baseURL ?? "https://api.deepseek.com")!
            .appendingPathComponent("models")

        var request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ModelFetchError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw ModelFetchError.apiError(statusCode: httpResponse.statusCode)
        }

        let result = try Self.decodeModelList(OpenAIModelsResponse.self, from: data)

        return result.data
            .filter { Self.isUsableDeepSeekModel($0.id) }
            .map { model in
                let pricing = Self.getDeepSeekPricing(for: model.id)
                return LLMModel(
                    id: model.id,
                    displayName: Self.formatDeepSeekModelName(model.id),
                    description: Self.getDeepSeekDescription(for: model.id),
                    inputPrice: pricing.input,
                    outputPrice: pricing.output,
                    isRecommended: Self.isRecommendedDeepSeekModel(model.id)
                )
            }
    }

    /// Model ID substrings that mark a DeepSeek model as not usable for chat completion.
    private static let deepSeekNonChatMarkers = ["embed", "rerank", "moderation", "ocr", "tts", "whisper"]

    /// Check if a DeepSeek model is usable for chat completion.
    ///
    /// DeepSeek's `/models` endpoint lists only its chat models, and it renames the
    /// whole line-up between generations: `deepseek-chat` / `deepseek-reasoner` were
    /// retired in July 2026 in favour of `deepseek-v4-flash` / `deepseek-v4-pro`.
    /// Excluding known non-chat families - rather than whitelisting IDs - keeps the
    /// model list working when the next generation ships.
    static func isUsableDeepSeekModel(_ modelId: String) -> Bool {
        let normalized = modelId.lowercased()
        return !normalized.isEmpty && !deepSeekNonChatMarkers.contains { normalized.contains($0) }
    }

    /// Format DeepSeek model ID to display name.
    ///
    /// "deepseek-v4-flash" -> "DeepSeek V4 Flash". IDs that don't carry the vendor
    /// prefix are shown verbatim.
    static func formatDeepSeekModelName(_ modelId: String) -> String {
        let vendorPrefix = "deepseek-"
        guard modelId.lowercased().hasPrefix(vendorPrefix) else { return modelId }

        let words = modelId.dropFirst(vendorPrefix.count)
            .components(separatedBy: "-")
            .filter { !$0.isEmpty }
            .map { component -> String in
                // Version markers such as "v4" read better fully capitalised.
                let isVersionMarker = component.count > 1 &&
                    component.lowercased().hasPrefix("v") &&
                    component.dropFirst().allSatisfy { $0.isNumber || $0 == "." }
                return isVersionMarker ? component.uppercased() : component.capitalized
            }

        return (["DeepSeek"] + words).joined(separator: " ")
    }

    /// Whether a DeepSeek model should be flagged as the recommended default.
    ///
    /// Keyed off the tier marker rather than an exact ID: pinning "deepseek-v4-flash"
    /// would leave nothing recommended the moment DeepSeek renames its line-up, and
    /// the selection would then fall through to whatever the API happened to list
    /// first - possibly the threefold dearer Pro tier.
    ///
    /// - Parameter modelId: The model ID as listed by the provider.
    /// - Returns: True for the cheap general-purpose tier.
    static func isRecommendedDeepSeekModel(_ modelId: String) -> Bool {
        modelId.lowercased().contains("flash")
    }

    /// Get description for DeepSeek models.
    static func getDeepSeekDescription(for modelId: String) -> String {
        let normalized = modelId.lowercased()
        if normalized.contains("flash") {
            return "General purpose, very affordable"
        } else if normalized.contains("pro") {
            return "Flagship quality for harder reasoning"
        }
        return "DeepSeek model"
    }

    /// Get pricing for DeepSeek models.
    ///
    /// Peak-hour, cache-miss rates per 1M tokens (August 2026). Off-peak rates are
    /// half of these, so quoting peak never understates a run. An unrecognised ID
    /// gets the flagship rate for the same reason - except one containing "flash",
    /// which is priced as V4 Flash. A future cheap tier is therefore quoted at V4
    /// Flash rates until this table is updated: check it when a new generation ships.
    static func getDeepSeekPricing(for modelId: String) -> (input: Double, output: Double) {
        if modelId.lowercased().contains("flash") {
            return (0.44, 1.32)
        }
        return (1.32, 3.96)
    }

    /// Fetch models from local Ollama server.
    private func fetchOllamaModels(baseURL: String?) async throws -> [LLMModel] {
        // Ollama's native API is at /api/tags, not the OpenAI-compatible /v1 endpoint
        // Strip /v1 suffix if present to get the base Ollama URL
        var ollamaBaseURL = baseURL ?? "http://localhost:11434"
        if ollamaBaseURL.hasSuffix("/v1") {
            ollamaBaseURL = String(ollamaBaseURL.dropLast(3))
        }
        let url = URL(string: ollamaBaseURL)!
            .appendingPathComponent("api/tags")

        let request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ModelFetchError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw ModelFetchError.apiError(statusCode: httpResponse.statusCode)
        }

        let result = try Self.decodeModelList(OllamaModelsResponse.self, from: data)

        return result.models.map { model in
            LLMModel(
                id: model.name,
                displayName: formatOllamaModelName(model.name),
                description: "Local model, no API cost",
                inputPrice: 0,
                outputPrice: 0,
                isRecommended: model.name.contains("llama")
            )
        }
    }

    /// Format Ollama model name for display.
    ///
    /// Preserves the full model name including quantization and parameter info
    /// (e.g., "llama3.2:8b-q4_0" stays as "llama3.2:8b-q4_0").
    /// Only strips ":latest" suffix as it's redundant.
    private func formatOllamaModelName(_ name: String) -> String {
        // Only strip ":latest" suffix as it's the default and adds no info
        if name.hasSuffix(":latest") {
            return String(name.dropLast(7))
        }
        return name
    }
}

// MARK: - Response Types

/// Response from Anthropic models API.
private struct AnthropicModelsResponse: Decodable {
    let data: [AnthropicModel]
}

/// Individual model from Anthropic API.
private struct AnthropicModel: Decodable {
    let id: String
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }
}

/// Response from OpenAI-compatible models API (also used by Groq, Mistral, DeepSeek).
private struct OpenAIModelsResponse: Decodable {
    let data: [OpenAIModel]
}

/// Individual model from OpenAI-compatible API.
private struct OpenAIModel: Decodable {
    let id: String
}

/// Response from Ollama models API.
private struct OllamaModelsResponse: Decodable {
    let models: [OllamaModel]
}

/// Individual model from Ollama API.
private struct OllamaModel: Decodable {
    let name: String
}

// MARK: - Errors

/// Errors that can occur during model fetching.
enum ModelFetchError: LocalizedError {
    case noAPIKey
    case apiError(statusCode: Int)
    case invalidResponse
    case parseError

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "API key required to fetch models"
        case .apiError(let statusCode):
            if statusCode == 401 || statusCode == 403 {
                return "Model list request rejected (HTTP \(statusCode)) - check the API key"
            }
            return "Model list request failed (HTTP \(statusCode))"
        case .invalidResponse:
            return "The server did not return an HTTP response - check the base URL"
        case .parseError:
            return "The provider's model list was not in the expected format"
        }
    }
}
