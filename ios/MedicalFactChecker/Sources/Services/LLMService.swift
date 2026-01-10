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
    static func create(from settings: AppSettings) throws -> LLMService {
        guard let url = URL(string: settings.llmBaseURL) else {
            throw LLMError.invalidConfiguration("Invalid base URL")
        }
        guard !settings.llmAPIKey.isEmpty else {
            throw LLMError.invalidConfiguration("API key not set")
        }
        return LLMService(baseURL: url, apiKey: settings.llmAPIKey, model: settings.llmModel)
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

/// A chat message for the OpenAI-compatible API.
///
/// Represents a single message in the conversation history.
struct ChatMessage: Codable, Sendable {
    /// Role of the message sender: "system", "user", or "assistant".
    let role: String

    /// Content of the message.
    let content: String
}

/// Request body for chat completions endpoint.
///
/// Conforms to the OpenAI chat completions API specification.
struct ChatCompletionRequest: Codable {
    /// Model identifier (e.g., "gpt-4o-mini").
    let model: String

    /// Conversation messages in order.
    let messages: [ChatMessage]

    /// Sampling temperature (0.0-2.0). Lower = more deterministic.
    let temperature: Double?

    /// Maximum tokens to generate in the response.
    let maxTokens: Int?

    /// Optional response format specification.
    let responseFormat: ResponseFormat?
}

/// Response format specification for structured output.
struct ResponseFormat: Codable {
    /// Format type: "text" or "json_object".
    let type: String
}

/// Response from the chat completions API.
struct ChatCompletionResponse: Codable {
    /// List of completion choices (usually just one).
    let choices: [Choice]

    /// Token usage statistics (may be nil for some providers).
    let usage: APIUsage?
}

/// A single choice from the completion response.
struct Choice: Codable {
    /// The generated message.
    let message: ChatMessage

    /// Reason the generation stopped: "stop", "length", etc.
    let finishReason: String?
}

/// Token usage statistics from the API.
struct APIUsage: Codable {
    /// Tokens in the input prompt.
    let promptTokens: Int

    /// Tokens in the generated completion.
    let completionTokens: Int

    /// Total tokens used (prompt + completion).
    let totalTokens: Int
}

/// Processed usage record for internal tracking.
///
/// Provides a simplified view of token usage with cost calculation.
struct LLMUsage: Sendable {
    /// Model used for this request.
    let model: String

    /// Number of input tokens.
    let inputTokens: Int

    /// Number of output tokens.
    let outputTokens: Int

    /// Total tokens used.
    var totalTokens: Int { inputTokens + outputTokens }

    /// Estimated cost in USD based on model pricing.
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
