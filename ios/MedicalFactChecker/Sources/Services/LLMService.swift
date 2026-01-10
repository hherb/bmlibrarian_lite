//
//  LLMService.swift
//  MedicalFactChecker
//
//  OpenAI-compatible LLM API client with token tracking.
//

import Foundation

/// Service for interacting with OpenAI-compatible LLM APIs.
///
/// Handles chat completions with automatic token tracking and cost calculation.
/// Thread-safe using Swift's actor model.
actor LLMService {
    // MARK: - Configuration

    private var baseURL: URL
    private var apiKey: String
    private var model: String
    private let session: URLSession

    // MARK: - Usage Tracking

    /// Callback for recording usage after each API call.
    var onUsageRecorded: ((LLMUsage) -> Void)?

    // MARK: - Initialization

    init(baseURL: URL, apiKey: String, model: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: config)
    }

    /// Create service from current app settings.
    convenience init(settings: AppSettings) throws {
        guard let url = URL(string: settings.llmBaseURL) else {
            throw LLMError.invalidConfiguration("Invalid base URL")
        }
        guard !settings.llmAPIKey.isEmpty else {
            throw LLMError.invalidConfiguration("API key not set")
        }
        self.init(baseURL: url, apiKey: settings.llmAPIKey, model: settings.llmModel)
    }

    // MARK: - Configuration Updates

    func updateConfiguration(baseURL: URL, apiKey: String, model: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
    }

    // MARK: - Chat Completion

    /// Send a chat completion request to the LLM.
    ///
    /// - Parameters:
    ///   - messages: Array of chat messages.
    ///   - temperature: Sampling temperature (0.0-2.0).
    ///   - maxTokens: Maximum tokens in response.
    ///   - jsonMode: Whether to request JSON output format.
    /// - Returns: Tuple of (response content, usage statistics).
    func chat(
        messages: [ChatMessage],
        temperature: Double = 0.1,
        maxTokens: Int = 1024,
        jsonMode: Bool = false
    ) async throws -> (content: String, usage: LLMUsage) {
        let endpoint = baseURL.appendingPathComponent("chat/completions")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ChatCompletionRequest(
            model: model,
            messages: messages,
            temperature: temperature,
            maxTokens: maxTokens,
            responseFormat: jsonMode ? ResponseFormat(type: "json_object") : nil
        )

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            // Try to parse error message
            if let errorBody = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorBody["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw LLMError.apiError(statusCode: httpResponse.statusCode, message: message)
            }
            throw LLMError.httpError(statusCode: httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let result = try decoder.decode(ChatCompletionResponse.self, from: data)

        guard let content = result.choices.first?.message.content else {
            throw LLMError.emptyResponse
        }

        // Create usage record
        let usage = LLMUsage(
            model: model,
            inputTokens: result.usage?.promptTokens ?? 0,
            outputTokens: result.usage?.completionTokens ?? 0
        )

        // Notify callback
        onUsageRecorded?(usage)

        return (content, usage)
    }

    /// Convenience method that returns just the content string.
    func chatContent(
        messages: [ChatMessage],
        temperature: Double = 0.1,
        maxTokens: Int = 1024,
        jsonMode: Bool = false
    ) async throws -> String {
        let (content, _) = try await chat(
            messages: messages,
            temperature: temperature,
            maxTokens: maxTokens,
            jsonMode: jsonMode
        )
        return content
    }

    // MARK: - System Prompt Helpers

    /// Create a system message.
    static func systemMessage(_ content: String) -> ChatMessage {
        ChatMessage(role: "system", content: content)
    }

    /// Create a user message.
    static func userMessage(_ content: String) -> ChatMessage {
        ChatMessage(role: "user", content: content)
    }

    /// Create an assistant message.
    static func assistantMessage(_ content: String) -> ChatMessage {
        ChatMessage(role: "assistant", content: content)
    }
}

// MARK: - Supporting Types

/// A chat message for the LLM API.
struct ChatMessage: Codable, Sendable {
    let role: String
    let content: String
}

/// Request body for chat completions.
struct ChatCompletionRequest: Codable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double?
    let maxTokens: Int?
    let responseFormat: ResponseFormat?
}

/// Response format specification.
struct ResponseFormat: Codable {
    let type: String
}

/// Response from chat completions API.
struct ChatCompletionResponse: Codable {
    let choices: [Choice]
    let usage: APIUsage?
}

/// A choice in the chat completion response.
struct Choice: Codable {
    let message: ChatMessage
    let finishReason: String?
}

/// Token usage from the API response.
struct APIUsage: Codable {
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int
}

/// Processed usage record for tracking.
struct LLMUsage: Sendable {
    let model: String
    let inputTokens: Int
    let outputTokens: Int

    var totalTokens: Int { inputTokens + outputTokens }

    var estimatedCostUSD: Double {
        CostCalculator.calculateCost(
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens
        )
    }
}

// MARK: - Errors

/// Errors that can occur during LLM API calls.
enum LLMError: LocalizedError {
    case invalidConfiguration(String)
    case invalidResponse
    case httpError(statusCode: Int)
    case apiError(statusCode: Int, message: String)
    case emptyResponse
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let reason):
            return "Invalid LLM configuration: \(reason)"
        case .invalidResponse:
            return "Invalid response from LLM API"
        case .httpError(let code):
            return "HTTP error \(code) from LLM API"
        case .apiError(let code, let message):
            return "API error \(code): \(message)"
        case .emptyResponse:
            return "Empty response from LLM API"
        case .parseError(let reason):
            return "Failed to parse LLM response: \(reason)"
        }
    }
}
