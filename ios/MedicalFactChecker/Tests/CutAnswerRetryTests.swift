// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2026 Dr Horst Herb
// SPDX-License-Identifier: AGPL-3.0-or-later

import BioMedLit
import Foundation
import Testing
@testable import MedicalFactChecker

/// Answers each chat request with the next scripted reply (a status, text,
/// finish reason and output tokens), in Ollama's native shape on `/api/chat`,
/// and keeps each request's body and token limit.
private final class CutStubProtocol: URLProtocol {
    struct Reply {
        var status = 200
        var content = "answer"
        var finishReason = "stop"
        var outputTokens = 5
        /// Never answers: the request ends only when it is cancelled.
        var hangs = false
    }

    nonisolated(unsafe) static var replies: [Reply] = []
    nonisolated(unsafe) static var maxTokens: [Int] = []
    nonisolated(unsafe) static var bodies: [[String: Any]] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let sent = (try? JSONSerialization.jsonObject(with: Self.body(of: request))) as? [String: Any] ?? [:]
        let ollama = request.url?.path.hasSuffix("/api/chat") == true
        let options = sent["options"] as? [String: Any]
        Self.bodies.append(sent)
        Self.maxTokens.append((ollama ? options?["num_predict"] : sent["max_tokens"]) as? Int ?? 0)
        let reply = Self.replies[min(Self.maxTokens.count, Self.replies.count) - 1]
        if reply.hangs { return }
        let message: [String: Any] = ["role": "assistant", "content": reply.content]
        let choice: [String: Any] = ["message": message, "finish_reason": reply.finishReason]
        let usage: [String: Any] = [
            "prompt_tokens": 100, "completion_tokens": reply.outputTokens, "total_tokens": 100 + reply.outputTokens,
        ]
        let answer: [String: Any] = ollama
            ? [
                "message": message, "done": true, "done_reason": reply.finishReason,
                "prompt_eval_count": 100, "eval_count": reply.outputTokens,
            ]
            : ["choices": [choice], "usage": usage]
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
    private func service(_ replies: [CutStubProtocol.Reply], provider: LLMProvider? = nil) -> LLMService {
        CutStubProtocol.replies = replies
        CutStubProtocol.maxTokens = []
        CutStubProtocol.bodies = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CutStubProtocol.self]
        return LLMService(
            baseURL: URL(string: "https://stub.invalid/v1")!, apiKey: "k", model: "m", provider: provider,
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

    @Test func aRetryThatFailsTransientlyIsTriedOnceNotBackedOff() async throws {
        // a twice-as-long answer can pass the request timeout: re-sending it only adds cost
        let llm = service([
            .init(content: "cut", finishReason: "length", outputTokens: 2048),
            .init(status: 503),
        ])
        let (content, _) = try await llm.chat(messages: [LLMService.userMessage("q")], maxTokens: 2048)
        #expect(content == "cut")
        #expect(CutStubProtocol.maxTokens == [2048, 4096])
    }

    @Test func theRetryAsksWhatTheAnswerWasAskedWithOnlyTheLimitRaised() async throws {
        let llm = service([
            .init(content: "cut", finishReason: "length", outputTokens: 2048),
            .init(content: "whole", outputTokens: 3000),
        ])
        _ = try await llm.chat(
            messages: [LLMService.systemMessage("rubric"), LLMService.userMessage("paper")],
            temperature: 0.3, maxTokens: 2048
        )
        var first = try #require(CutStubProtocol.bodies.first)
        var second = try #require(CutStubProtocol.bodies.last)
        #expect(CutStubProtocol.bodies.count == 2)
        first["max_tokens"] = nil
        second["max_tokens"] = nil
        #expect(NSDictionary(dictionary: first).isEqual(to: second))
    }

    @Test func aCancelledRetryIsACancellationNotTheCutAnswer() async throws {
        let llm = service([
            .init(content: "cut", finishReason: "length", outputTokens: 2048),
            .init(hangs: true),
        ])
        let task = Task { try await llm.chat(messages: [LLMService.userMessage("q")], maxTokens: 2048) }
        while CutStubProtocol.maxTokens.count < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        task.cancel()
        await #expect(throws: CancellationError.self, "a stopped run returns no answer") {
            _ = try await task.value
        }
    }

    @Test func ollamasLengthDoneReasonIsACutAskedAgainWithAContextThatHoldsIt() async throws {
        let llm = service(
            [
                .init(content: "cut", finishReason: "length", outputTokens: 2048),
                .init(content: "whole", outputTokens: 3000),
            ],
            provider: .ollama
        )
        let (content, usage) = try await llm.chat(messages: [LLMService.userMessage("q")], maxTokens: 2048)
        #expect(content == "whole")
        #expect(CutStubProtocol.maxTokens == [2048, 4096])
        let options = try #require(CutStubProtocol.bodies.last?["options"] as? [String: Any])
        #expect(options["num_ctx"] as? Int == OllamaContext.numCtx(contents: ["q"], maxTokens: 4096))
        #expect(usage.outputTokens == 5048)
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
        #expect(LLMService.raisedLimit(finishReason: "length", outputTokens: 2049, maxTokens: 2048) == 4096, "a count past the limit is a cut")
        #expect(LLMService.raisedLimit(finishReason: "length", outputTokens: 8192, maxTokens: 8192) == 16384)
        #expect(LLMService.raisedLimit(finishReason: "length", outputTokens: 12000, maxTokens: 12000) == 16384, "capped")
        #expect(LLMService.raisedLimit(finishReason: "length", outputTokens: 16384, maxTokens: 16384) == nil, "no larger limit")
        #expect(LLMService.raisedLimit(finishReason: "stop", outputTokens: 2048, maxTokens: 2048) == nil)
        #expect(LLMService.raisedLimit(finishReason: nil, outputTokens: 2048, maxTokens: 2048) == nil)
        #expect(LLMService.raisedLimit(finishReason: "length", outputTokens: 0, maxTokens: 2048) == nil, "no count stated")
        #expect(LLMService.raisedLimit(finishReason: "length", outputTokens: 0, maxTokens: 0) == nil)
    }
}
