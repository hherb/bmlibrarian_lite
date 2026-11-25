// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2026 Dr Horst Herb
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import MedicalFactChecker

/// Answers each chat request with the next scripted reply (a status, text,
/// finish reason and output tokens) and keeps each request's token limit.
private final class CutStubProtocol: URLProtocol {
    struct Reply {
        var status = 200
        var content = "answer"
        var finishReason = "stop"
        var outputTokens = 5
    }

    nonisolated(unsafe) static var replies: [Reply] = []
    nonisolated(unsafe) static var maxTokens: [Int] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let sent = (try? JSONSerialization.jsonObject(with: Self.body(of: request))) as? [String: Any]
        Self.maxTokens.append(sent?["max_tokens"] as? Int ?? 0)
        let reply = Self.replies[min(Self.maxTokens.count, Self.replies.count) - 1]
        let message: [String: Any] = ["role": "assistant", "content": reply.content]
        let choice: [String: Any] = ["message": message, "finish_reason": reply.finishReason]
        let usage: [String: Any] = [
            "prompt_tokens": 100, "completion_tokens": reply.outputTokens, "total_tokens": 100 + reply.outputTokens,
        ]
        let answer: [String: Any] = ["choices": [choice], "usage": usage]
        let refusal: [String: Any] = ["error": ["message": "refused"]]
        let payload = try! JSONSerialization.data(withJSONObject: reply.status == 200 ? answer : refusal)
        let http = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// A protocol sees the body as a stream, not as `httpBody`.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// #822: an answer cut at its token limit is asked once more with twice the
/// limit, as the desktop does (#825).
@Suite(.serialized)
struct CutAnswerRetryTests {
    private func service(_ replies: [CutStubProtocol.Reply]) -> LLMService {
        CutStubProtocol.replies = replies
        CutStubProtocol.maxTokens = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CutStubProtocol.self]
        return LLMService(
            baseURL: URL(string: "https://stub.invalid/v1")!, apiKey: "k", model: "m",
            session: URLSession(configuration: config)
        )
    }

    @Test func aCutAnswerIsAskedOnceMoreWithTwiceTheLimit() async throws {
        let llm = service([
            .init(content: "{\"score\":", finishReason: "length", outputTokens: 2048),
            .init(content: "{\"score\": 4}", outputTokens: 2300),
        ])
        let (content, usage) = try await llm.chat(messages: [LLMService.userMessage("q")], maxTokens: 2048)
        #expect(content == "{\"score\": 4}")
        #expect(CutStubProtocol.maxTokens == [2048, 4096])
        #expect(usage.inputTokens == 200, "both requests are paid for")
        #expect(usage.outputTokens == 4348)
    }

    @Test func aRetryCutAgainIsReturnedAsWritten() async throws {
        let llm = service([
            .init(content: "first", finishReason: "length", outputTokens: 2048),
            .init(content: "second", finishReason: "length", outputTokens: 4096),
        ])
        let (content, _) = try await llm.chat(messages: [LLMService.userMessage("q")], maxTokens: 2048)
        #expect(content == "second")
        #expect(CutStubProtocol.maxTokens == [2048, 4096], "asked once more, never twice")
    }

    @Test func aFailedRetryKeepsTheCutAnswer() async throws {
        let llm = service([
            .init(content: "cut", finishReason: "length", outputTokens: 2048),
            .init(status: 400),
        ])
        let (content, usage) = try await llm.chat(messages: [LLMService.userMessage("q")], maxTokens: 2048)
        #expect(content == "cut")
        #expect(usage.outputTokens == 2048)
        #expect(CutStubProtocol.maxTokens == [2048, 4096])
    }

    @Test func anAnswerCutShortOfItsLimitIsNotAskedAgain() async throws {
        // the context window ran out: a larger limit does not change that
        let llm = service([.init(content: "cut", finishReason: "length", outputTokens: 900)])
        let (content, _) = try await llm.chat(messages: [LLMService.userMessage("q")], maxTokens: 2048)
        #expect(content == "cut")
        #expect(CutStubProtocol.maxTokens == [2048])
    }

    @Test func aFinishedAnswerAndTheConnectionTestAreAskedOnce() async throws {
        // control: a whole answer is not asked again
        var llm = service([.init(outputTokens: 2048)])
        _ = try await llm.chat(messages: [LLMService.userMessage("q")], maxTokens: 2048)
        #expect(CutStubProtocol.maxTokens == [2048])

        llm = service([.init(content: "O", finishReason: "length", outputTokens: 10)])
        _ = try await llm.chat(messages: [LLMService.userMessage("q")], maxTokens: 10, retryingCut: false)
        #expect(CutStubProtocol.maxTokens == [10])
    }

    @Test func theRaisedLimitFollowsTheDesktopRule() {
        #expect(LLMService.raisedLimit(finishReason: "length", outputTokens: 2048, maxTokens: 2048) == 4096)
        #expect(LLMService.raisedLimit(finishReason: "max_tokens", outputTokens: 2048, maxTokens: 2048) == 4096)
        #expect(LLMService.raisedLimit(finishReason: "length", outputTokens: 8192, maxTokens: 8192) == 16384)
        #expect(LLMService.raisedLimit(finishReason: "length", outputTokens: 12000, maxTokens: 12000) == 16384, "capped")
        #expect(LLMService.raisedLimit(finishReason: "length", outputTokens: 16384, maxTokens: 16384) == nil, "no larger limit")
        #expect(LLMService.raisedLimit(finishReason: "stop", outputTokens: 2048, maxTokens: 2048) == nil)
        #expect(LLMService.raisedLimit(finishReason: nil, outputTokens: 2048, maxTokens: 2048) == nil)
        #expect(LLMService.raisedLimit(finishReason: "length", outputTokens: 0, maxTokens: 2048) == nil, "no count stated")
        #expect(LLMService.raisedLimit(finishReason: "length", outputTokens: 0, maxTokens: 0) == nil)
    }
}
