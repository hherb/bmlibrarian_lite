// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2026 Dr Horst Herb
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import MedicalFactChecker

/// #760: Ollama is asked on its native `/api/chat`, with a `num_ctx` that holds
/// the request and no silent cut when it still does not fit.
struct OllamaChatTests {
    private let ollamaRoot = URL(string: "http://mac.local:11434/v1")!

    @Test func ollamaIsAskedOnTheNativeChatEndpoint() async throws {
        let ollama = LLMService(baseURL: ollamaRoot, apiKey: "", model: "llama3.2", provider: .ollama)
        #expect(try await ollama.chatEndpoint.absoluteString == "http://mac.local:11434/api/chat")

        // control: other providers keep the OpenAI-compatible endpoint
        let openAI = LLMService(baseURL: URL(string: "https://api.openai.com/v1")!, apiKey: "k", model: "m", provider: .openai)
        #expect(try await openAI.chatEndpoint.absoluteString == "https://api.openai.com/v1/chat/completions")
    }

    @Test func ollamaIsSentAContextThatHoldsTheRequest() async throws {
        let ollama = LLMService(baseURL: ollamaRoot, apiKey: "", model: "llama3.2", provider: .ollama)
        // 6,000 code points each: either message alone fits 8192, both need 16384
        let half = String(repeating: "a", count: 6_000)
        let body = try await ollama.requestBody(
            messages: [LLMService.systemMessage(half), LLMService.userMessage(half)],
            temperature: 0.1,
            maxTokens: 4096
        )
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "llama3.2")
        #expect(json["stream"] as? Bool == false)
        #expect(json["truncate"] as? Bool == false)
        #expect(json["shift"] as? Bool == false)
        let options = try #require(json["options"] as? [String: Any])
        #expect(options["num_ctx"] as? Int == 16384)
        #expect(options["num_predict"] as? Int == 4096)
        #expect(options["temperature"] as? Double == 0.1)
        #expect(json["max_tokens"] == nil, "the OpenAI field is not the native API's")
    }

    @Test func otherProvidersAreSentNoOllamaOptions() async throws {
        let openAI = LLMService(baseURL: URL(string: "https://api.openai.com/v1")!, apiKey: "k", model: "m", provider: .openai)
        let body = try await openAI.requestBody(messages: [LLMService.userMessage("hi")], temperature: 0.1, maxTokens: 10)
        let json = String(decoding: body, as: UTF8.self)
        #expect(!json.contains("num_ctx") && !json.contains("shift"), "\(json)")
        #expect(json.contains("\"max_tokens\":10"))
    }

    @Test func anOllamaReplyIsRead() async throws {
        let ollama = LLMService(baseURL: ollamaRoot, apiKey: "", model: "llama3.2", provider: .ollama)
        let reply = Data("""
        {"model":"llama3.2","message":{"role":"assistant","content":"Score: 4"},
         "done":true,"done_reason":"stop","prompt_eval_count":3022,"eval_count":5}
        """.utf8)
        let decoded = try await ollama.decodeReply(reply)
        #expect(decoded.content == "Score: 4")
        #expect(decoded.inputTokens == 3022)
        #expect(decoded.outputTokens == 5)

        await #expect(throws: LLMError.self) {
            try await ollama.decodeReply(Data(#"{"done":true}"#.utf8))
        }
    }

    @Test func everyErrorBodyShapeGivesItsReason() {
        let overflow = "request (3022 tokens) exceeds the available context size (1024 tokens), try increasing it"
        #expect(LLMService.apiErrorMessage(from: Data(#"{"error":"\#(overflow)"}"#.utf8)) == overflow)
        #expect(LLMService.apiErrorMessage(from: Data(#"{"error":{"message":"bad key","type":"x"}}"#.utf8)) == "bad key")
        #expect(LLMService.apiErrorMessage(from: Data(#"{"message":"slow down"}"#.utf8)) == "slow down")
        // control: a body without a reason gives none, so the status alone is raised
        #expect(LLMService.apiErrorMessage(from: Data(#"{"detail":1}"#.utf8)) == nil)
        #expect(LLMService.apiErrorMessage(from: Data("<html>502</html>".utf8)) == nil)
    }
}
