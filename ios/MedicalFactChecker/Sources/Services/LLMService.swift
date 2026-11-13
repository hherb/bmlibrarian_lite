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

import BioMedLit
import Foundation

/// Service for interacting with OpenAI-compatible LLM APIs, and Ollama's native `/api/chat`.
///
/// Handles chat completions with automatic token tracking, cost calculation,
/// and retry logic with exponential backoff for transient failures.
/// Thread-safe using Swift's actor model.
actor LLMService {
    // MARK: - Constants

    /// Maximum number of retry attempts for failed requests.
    private static let maxRetries = 3

    /// Base delay in seconds for exponential backoff.
    private static let baseDelaySeconds: Double = 1.0

    /// Maximum delay in seconds between retries.
    private static let maxDelaySeconds: Double = 10.0

    // MARK: - Timeout Configuration

    /// Default timeout in seconds for individual requests.
    private static let defaultRequestTimeout: TimeInterval = 60

    /// Default timeout in seconds for total resource operations.
    private static let defaultResourceTimeout: TimeInterval = 120

    /// Extended timeout in seconds for individual requests (for slower providers like Ollama).
    private static let extendedRequestTimeout: TimeInterval = 120

    /// Extended timeout in seconds for total resource operations (for slower providers like Ollama).
    private static let extendedResourceTimeout: TimeInterval = 300

    // MARK: - Configuration

    private var baseURL: URL
    private var apiKey: String
    private var model: String
    private var provider: LLMProvider?
    private let session: URLSession

    // MARK: - Usage Tracking

    /// Callback for recording usage after each API call.
    var onUsageRecorded: ((LLMUsage) -> Void)?

    // MARK: - Initialization

    /// - Parameter session: The session requests go through; a test passes one
    ///   with a stub protocol. Nil builds one with the provider's timeouts.
    init(
        baseURL: URL, apiKey: String, model: String, provider: LLMProvider? = nil,
        session: URLSession? = nil
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.provider = provider

        // Use extended timeouts for Ollama since local models can be slower,
        // especially for report generation with longer outputs
        let useExtendedTimeout = provider == .ollama
        let requestTimeout = useExtendedTimeout ? Self.extendedRequestTimeout : Self.defaultRequestTimeout
        let resourceTimeout = useExtendedTimeout ? Self.extendedResourceTimeout : Self.defaultResourceTimeout

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = resourceTimeout
        self.session = session ?? URLSession(configuration: config)
    }

    /// Create service from current app settings.
    static func create(from settings: AppSettings) throws -> LLMService {
        guard let url = URL(string: settings.llmBaseURL) else {
            throw LLMError.invalidConfiguration("Invalid base URL")
        }
        // Only require API key for providers that need it (not Ollama)
        if settings.selectedProvider.requiresAPIKey && settings.llmAPIKey.isEmpty {
            throw LLMError.invalidConfiguration("API key not set")
        }
        return LLMService(
            baseURL: url,
            apiKey: settings.llmAPIKey,
            model: settings.llmModel,
            provider: settings.selectedProvider
        )
    }

    // MARK: - Configuration Updates

    /// Point this service at a different provider and model.
    ///
    /// `provider` is required rather than defaulted: it decides whether DeepSeek is sent
    /// the opt-out from thinking mode, so omitting it would silently re-enable
    /// chain-of-thought and make scoring ignore `temperature`. A caller that genuinely
    /// has no provider must pass `nil` deliberately.
    ///
    /// - Parameters:
    ///   - baseURL: API base URL.
    ///   - apiKey: API key for the provider.
    ///   - model: Model ID to send.
    ///   - provider: The provider being configured.
    func updateConfiguration(baseURL: URL, apiKey: String, model: String, provider: LLMProvider?) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.provider = provider
    }

    // MARK: - Chat Completion

    /// Send a chat completion request to the LLM with automatic retry.
    ///
    /// Retries up to `maxRetries` times with exponential backoff for transient failures
    /// (network errors, rate limits, server errors).
    ///
    /// - Parameters:
    ///   - messages: Array of chat messages.
    ///   - temperature: Sampling temperature (0.0-2.0).
    ///   - maxTokens: Maximum tokens in response.
    ///   - jsonMode: Ignored - included for API compatibility. Request JSON in prompts instead.
    /// - Returns: Tuple of (response content, usage statistics).
    func chat(
        messages: [ChatMessage],
        temperature: Double = 0.1,
        maxTokens: Int = 1024,
        jsonMode: Bool = false
    ) async throws -> (content: String, usage: LLMUsage) {
        var lastError: Error?

        for attempt in 0..<Self.maxRetries {
            do {
                return try await performChatRequest(
                    messages: messages,
                    temperature: temperature,
                    maxTokens: maxTokens
                )
            } catch {
                lastError = error

                // Check if error is retryable
                guard isRetryableError(error) else {
                    print("[LLMService] Non-retryable error: \(error.localizedDescription)")
                    throw error
                }

                // Don't retry after the last attempt
                if attempt < Self.maxRetries - 1 {
                    let delay = calculateBackoffDelay(attempt: attempt)
                    print("[LLMService] Attempt \(attempt + 1) failed: \(error.localizedDescription). Retrying in \(String(format: "%.1f", delay))s...")
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }

        print("[LLMService] All \(Self.maxRetries) attempts failed")
        throw lastError ?? LLMError.invalidResponse
    }

    /// Perform the actual chat request without retry logic.
    private func performChatRequest(
        messages: [ChatMessage],
        temperature: Double,
        maxTokens: Int
    ) async throws -> (content: String, usage: LLMUsage) {
        let endpoint = try chatEndpoint

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        request.httpBody = try requestBody(messages: messages, temperature: temperature, maxTokens: maxTokens)

        // Debug: log the request body
        #if DEBUG
        if let requestBody = request.httpBody,
           let requestString = String(data: requestBody, encoding: .utf8) {
            print("[LLMService] Request to \(endpoint): \(requestString)")
        }
        #endif

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            if let message = Self.apiErrorMessage(from: data) {
                print("[LLMService] API error \(httpResponse.statusCode): \(message)")
                throw LLMError.apiError(statusCode: httpResponse.statusCode, message: message)
            }
            if let rawBody = String(data: data, encoding: .utf8) {
                print("[LLMService] API error \(httpResponse.statusCode), raw: \(rawBody)")
            }
            throw LLMError.httpError(statusCode: httpResponse.statusCode)
        }

        let reply = try decodeReply(data)

        // Create usage record
        let usage = LLMUsage(
            model: model,
            provider: provider,
            inputTokens: reply.inputTokens,
            outputTokens: reply.outputTokens
        )

        // Notify callback
        onUsageRecorded?(usage)

        return (reply.content, usage)
    }

    /// The URL chat requests are posted to.
    ///
    /// Ollama is asked on its native `/api/chat`, beside the configured `/v1` root:
    /// the OpenAI-compatible endpoint takes no `num_ctx`, so a long prompt was cut
    /// to the server's default context without a word (#760). Every other
    /// provider is asked on `chat/completions`.
    ///
    /// - Throws: `LLMError.invalidConfiguration` if Ollama's native root is not a
    ///   URL; falling back to `/v1` would bring the silent cut back.
    var chatEndpoint: URL {
        get throws {
            guard provider == .ollama else {
                return baseURL.appendingPathComponent("chat/completions")
            }
            guard let root = URL(string: OllamaContext.nativeRoot(baseURL.absoluteString)) else {
                throw LLMError.invalidConfiguration("Ollama URL has no native API root: \(baseURL)")
            }
            return root.appendingPathComponent("api/chat")
        }
    }

    /// The reason an error response's body gives, in any shape a provider uses.
    ///
    /// - Parameter data: The non-200 response's body.
    /// - Returns: `{"error": {"message": "..."}}` (OpenAI, Mistral), then
    ///   `{"error": "..."}` (Ollama, e.g. a prompt over `num_ctx`, #760), then
    ///   `{"message": "..."}`; nil when the body has none of them.
    static func apiErrorMessage(from data: Data) -> String? {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let error = body["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        return body["error"] as? String ?? body["message"] as? String
    }

    /// A successful reply's text and token counts.
    ///
    /// - Parameter data: The 200 response's body.
    /// - Returns: The reply's text and its input and output tokens (0 when unstated).
    /// - Throws: `LLMError.emptyResponse` when the reply holds no message, or a
    ///   `DecodingError` when the body is not the provider's reply shape.
    func decodeReply(_ data: Data) throws -> (content: String, inputTokens: Int, outputTokens: Int) {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        if provider == .ollama {
            let result = try decoder.decode(OllamaChatResponse.self, from: data)
            guard let content = result.message?.content else {
                throw LLMError.emptyResponse
            }
            return (content, result.promptEvalCount ?? 0, result.evalCount ?? 0)
        }
        let result = try decoder.decode(ChatCompletionResponse.self, from: data)
        guard let content = result.choices.first?.message.content else {
            throw LLMError.emptyResponse
        }
        return (content, result.usage?.promptTokens ?? 0, result.usage?.completionTokens ?? 0)
    }

    // MARK: - Retry Helpers

    /// Determine if an error is retryable.
    ///
    /// Retryable errors include:
    /// - Network/connection errors
    /// - Rate limiting (429)
    /// - Server errors (500, 502, 503, 504)
    /// - Timeouts
    ///
    /// Non-retryable errors include:
    /// - Authentication errors (401, 403)
    /// - Bad request (400)
    /// - Not found (404)
    /// - Invalid configuration
    private func isRetryableError(_ error: Error) -> Bool {
        // Check for URL errors (network issues, timeouts)
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .networkConnectionLost, .notConnectedToInternet,
                 .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                return true
            default:
                return false
            }
        }

        // Check for LLM-specific errors
        if let llmError = error as? LLMError {
            switch llmError {
            case .httpError(let statusCode):
                return isRetryableStatusCode(statusCode)
            case .apiError(let statusCode, _):
                return isRetryableStatusCode(statusCode)
            case .invalidResponse, .emptyResponse:
                // These might be transient issues
                return true
            case .invalidConfiguration, .parseError:
                // These won't be fixed by retrying
                return false
            }
        }

        // Default: retry for unknown errors (could be transient)
        return true
    }

    /// Check if an HTTP status code is retryable.
    private func isRetryableStatusCode(_ statusCode: Int) -> Bool {
        switch statusCode {
        case 429:  // Rate limited
            return true
        case 500, 502, 503, 504:  // Server errors
            return true
        default:
            return false
        }
    }

    /// Chain-of-thought setting to send for the configured provider, if it has one.
    ///
    /// DeepSeek V4 enables thinking mode by default: it spends output tokens on
    /// reasoning and silently ignores `temperature`, which this app relies on for
    /// repeatable scoring. Opt out explicitly. Other providers do not understand the
    /// field and may reject it, so they are sent nothing.
    var thinkingConfig: ThinkingConfig? {
        provider == .deepseek ? .disabled : nil
    }

    /// The encoded chat body this service sends (chat-completions, or Ollama's native one).
    ///
    /// Claude Opus 4.7 and later answer 400 to `temperature`, on Anthropic's
    /// OpenAI-compatible endpoint too (#758), so Claude is sent none and samples at
    /// the API default; a nil temperature is left out of the body. `response_format`
    /// is never sent: not every provider supports it (Anthropic doesn't), so prompts
    /// ask for JSON explicitly.
    ///
    /// Ollama is sent its native `/api/chat` body instead: the temperature and
    /// token limit as `options`, with a `num_ctx` sized to hold the request
    /// (`OllamaContext`), and `truncate`/`shift` off so a prompt that still does
    /// not fit is refused with a 400 rather than cut in the middle (#760).
    ///
    /// - Parameters:
    ///   - messages: The conversation to send.
    ///   - temperature: The temperature the caller asked for.
    ///   - maxTokens: Maximum tokens to generate.
    /// - Returns: The JSON body, snake-cased.
    /// - Throws: An `EncodingError` if the body cannot be encoded.
    func requestBody(messages: [ChatMessage], temperature: Double, maxTokens: Int) throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        if provider == .ollama {
            let options = OllamaOptions(
                temperature: temperature,
                numPredict: maxTokens,
                numCtx: OllamaContext.numCtx(contents: messages.map(\.content), maxTokens: maxTokens)
            )
            return try encoder.encode(
                OllamaChatRequest(model: model, messages: messages, stream: false, truncate: false, shift: false, options: options)
            )
        }
        let body = ChatCompletionRequest(
            model: model,
            messages: messages,
            temperature: provider == .anthropic ? nil : temperature,
            maxTokens: maxTokens,
            responseFormat: nil,
            thinking: thinkingConfig
        )
        return try encoder.encode(body)
    }

    /// Calculate backoff delay with exponential increase and jitter.
    ///
    /// - Parameter attempt: The current attempt number (0-indexed).
    /// - Returns: Delay in seconds before the next retry.
    private func calculateBackoffDelay(attempt: Int) -> Double {
        // Exponential backoff: base * 2^attempt
        let exponentialDelay = Self.baseDelaySeconds * pow(2.0, Double(attempt))

        // Cap at maximum delay
        let cappedDelay = min(exponentialDelay, Self.maxDelaySeconds)

        // Add jitter (±25%) to prevent thundering herd
        let jitter = cappedDelay * Double.random(in: -0.25...0.25)

        return cappedDelay + jitter
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

    // MARK: - API Testing

    /// Test the API connection with a minimal request.
    ///
    /// Sends a simple "Hello" message to verify the API key and endpoint are valid.
    /// Uses minimal tokens to reduce cost.
    ///
    /// - Parameters:
    ///   - baseURL: The API base URL.
    ///   - apiKey: The API key to test.
    ///   - model: The model to use for the test.
    ///   - provider: The provider being tested, so provider-specific request options
    ///     (such as DeepSeek's thinking mode) match a real call.
    /// - Returns: A success message with the model's response.
    /// - Throws: LLMError if the test fails.
    static func testConnection(
        baseURL: URL,
        apiKey: String,
        model: String,
        provider: LLMProvider?
    ) async throws -> String {
        let service = LLMService(baseURL: baseURL, apiKey: apiKey, model: model, provider: provider)
        let (response, _) = try await service.chat(
            messages: [userMessage("Say 'OK' if you can read this.")],
            temperature: 0.0,
            maxTokens: 10
        )
        return response
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

    /// Optional chain-of-thought setting. Only sent to providers that understand it.
    let thinking: ThinkingConfig?
}

/// Response format specification for structured output.
struct ResponseFormat: Codable {
    /// Format type: "text" or "json_object".
    let type: String
}

/// Chain-of-thought setting for providers that expose one (currently DeepSeek).
struct ThinkingConfig: Codable {
    /// Toggle value: "enabled" or "disabled".
    let type: String

    /// Turn chain-of-thought off.
    static let disabled = ThinkingConfig(type: "disabled")
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

/// Request body for Ollama's native `/api/chat` (#760).
struct OllamaChatRequest: Codable {
    /// Model name (e.g., "llama3.2").
    let model: String

    /// Conversation messages in order.
    let messages: [ChatMessage]

    /// Always false: the reply is read whole.
    let stream: Bool

    /// Always false: no message is dropped to fit the context.
    let truncate: Bool

    /// Always false: a prompt over `num_ctx` is a 400, never cut in the middle.
    let shift: Bool

    /// Sampling and context options.
    let options: OllamaOptions
}

/// The `options` of an Ollama chat request.
struct OllamaOptions: Codable {
    /// Sampling temperature.
    let temperature: Double

    /// Maximum tokens to generate.
    let numPredict: Int

    /// Context size, from `OllamaContext.numCtx`.
    let numCtx: Int
}

/// Reply from Ollama's native `/api/chat` (non-streamed).
struct OllamaChatResponse: Codable {
    /// The generated message.
    let message: ChatMessage?

    /// Tokens Ollama read from the prompt.
    let promptEvalCount: Int?

    /// Tokens generated.
    let evalCount: Int?

    /// Why generation stopped: "stop", "length", etc.
    let doneReason: String?
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

    /// Provider used for this request.
    let provider: LLMProvider?

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
            outputTokens: outputTokens,
            provider: provider
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
