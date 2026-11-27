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
        /// Nil is sent as `null`: the model wrote no text (#830).
        var content: String? = "answer"
        var finishReason = "stop"
        var outputTokens = 5
        /// The error body's message, for a status other than 200.
        var message = "refused"
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
        Self.maxTokens.append(
            (ollama ? options?["num_predict"] : sent["max_tokens"] ?? sent["max_completion_tokens"]) as? Int ?? 0
        )
        let reply = Self.replies[min(Self.maxTokens.count, Self.replies.count) - 1]
        if reply.hangs { return }
        let message: [String: Any] = ["role": "assistant", "content": reply.content ?? NSNull()]
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
        let refusal: [String: Any] = ["error": ["message": reply.message]]
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

/// #831 (after #822): an answer cut at its token limit is asked again up to
/// three times, each with twice the last limit, never past the model's
/// maximum; one still cut fails, quoting its text, as on the desktop (#825).
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

    private func cut(_ content: String?, _ outputTokens: Int) -> CutStubProtocol.Reply {
        .init(content: content, finishReason: "length", outputTokens: outputTokens)
    }

    /// The cut error `body` throws, or nil (recorded as an issue) when it throws none.
    private func cutError(
        _ body: () async throws -> Void
    ) async -> (maxTokens: Int, outputTokens: Int, content: String, after: String, description: String)? {
        do {
            try await body()
            Issue.record("a cut answer was returned as an answer")
        } catch let error as LLMError {
            if case let .cut(_, maxTokens, outputTokens, content, after) = error {
                return (maxTokens, outputTokens, content, after, error.localizedDescription)
            }
            Issue.record("threw \(error), not the cut error")
        } catch {
            Issue.record("threw \(error), not the cut error")
        }
        return nil
    }

    private func ask(_ llm: LLMService, maxTokens: Int = 2048) async throws -> (content: String, usage: LLMUsage) {
        try await llm.chat(messages: [LLMService.userMessage("q")], maxTokens: maxTokens)
    }

    @Test func aCutAnswerIsAskedAgainWithTwiceTheLimit() async throws {
        let llm = service([cut("{\"score\":", 2048), .init(content: "{\"score\": 4}", outputTokens: 2300)])
        let (content, usage) = try await ask(llm)
        #expect(content == "{\"score\": 4}")
        #expect(CutStubProtocol.maxTokens == [2048, 4096])
        #expect(usage.inputTokens == 200, "both requests are paid for")
        #expect(usage.outputTokens == 4348)
    }

    @Test func eachRetryDoublesTheLimitAndTheThirdRetryIsTheLast() async throws {
        let llm = service([cut("a", 2048), cut("b", 4096), cut("c", 8192), cut("d", 16384), .init()])
        let error = await cutError { _ = try await ask(llm) }
        #expect(CutStubProtocol.maxTokens == [2048, 4096, 8192, 16384], "three retries, never a fourth")
        #expect(error?.content == "d", "the last answer is quoted")
        #expect(error?.maxTokens == 16384)
        #expect(error?.after == "")
    }

    @Test func anAnswerWholeOnTheThirdRetryIsReturnedWithEveryRequestsUsage() async throws {
        let llm = service([cut("a", 2048), cut("b", 4096), cut("c", 8192), .init(content: "whole", outputTokens: 9000)])
        let (content, usage) = try await ask(llm)
        #expect(content == "whole")
        #expect(usage.inputTokens == 400)
        #expect(usage.outputTokens == 2048 + 4096 + 8192 + 9000)
    }

    @Test func aFailedRetryFailsAsTheCutAnswerNamingTheFailure() async throws {
        let llm = service([cut("cut", 2048), .init(status: 400, message: "sk-secret is not a valid key")])
        let error = await cutError { _ = try await ask(llm) }
        #expect(CutStubProtocol.maxTokens == [2048, 4096])
        #expect(error?.content == "cut")
        #expect(error?.after == "; asking again with 4096 tokens failed (HTTP 400)")
        #expect(error?.description.contains("sk-secret") == false, "never the provider's text")
    }

    @Test func aRetryThatFailsTransientlyIsTriedOnceNotBackedOff() async throws {
        // a long answer can pass the request timeout: re-sending it only adds cost
        let llm = service([cut("cut", 2048), .init(status: 503)])
        let error = await cutError { _ = try await ask(llm) }
        #expect(CutStubProtocol.maxTokens == [2048, 4096])
        #expect(error?.after == "; asking again with 4096 tokens failed (HTTP 503)")
    }

    @Test func aRefusedLimitIsAskedAgainWithinTheStatedMaximum() async throws {
        let refusal = "max_tokens: 8192 > 6000, which is the maximum allowed number of output tokens for m"
        let llm = service([
            cut("a", 2048), cut("b", 4096), .init(status: 400, message: refusal), .init(content: "whole", outputTokens: 5000),
        ])
        let (content, usage) = try await ask(llm)
        #expect(content == "whole")
        #expect(CutStubProtocol.maxTokens == [2048, 4096, 8192, 6000])
        #expect(usage.outputTokens == 2048 + 4096 + 5000, "the refused request generated nothing")
    }

    @Test func anAnswerCutAtTheStatedMaximumFails() async throws {
        let refusal = "max_tokens is too large: 8192. This model supports at most 6000 completion tokens, whereas you provided 8192."
        let llm = service([cut("a", 2048), cut("b", 4096), .init(status: 400, message: refusal), cut("c", 6000), .init()])
        let error = await cutError { _ = try await ask(llm) }
        #expect(CutStubProtocol.maxTokens == [2048, 4096, 8192, 6000], "no larger limit is allowed")
        #expect(error?.content == "c")
        #expect(error?.maxTokens == 6000)
    }

    @Test func aStatedMaximumAboveTheRaisedLimitIsAFailedRetry() async throws {
        let refusal = "max_tokens: 4096 > 9000, which is the maximum allowed number of output tokens for m"
        let llm = service([cut("cut", 2048), .init(status: 400, message: refusal)])
        let error = await cutError { _ = try await ask(llm) }
        #expect(CutStubProtocol.maxTokens == [2048, 4096], "asking within 9000 changes nothing")
        #expect(error?.after == "; asking again with 4096 tokens failed (HTTP 400)")
    }

    @Test func aStatedMaximumEqualToTheRaisedLimitIsAFailedRetry() async throws {
        let refusal = "max_tokens: 4096 > 4096, which is the maximum allowed number of output tokens for m"
        let llm = service([cut("cut", 2048), .init(status: 400, message: refusal)])
        let error = await cutError { _ = try await ask(llm) }
        #expect(CutStubProtocol.maxTokens == [2048, 4096], "asking within 4096 is asking the same again")
        #expect(error?.after == "; asking again with 4096 tokens failed (HTTP 400)")
    }

    @Test func theRetryAsksWhatTheAnswerWasAskedWithOnlyTheLimitRaised() async throws {
        let llm = service([cut("cut", 2048), .init(content: "whole", outputTokens: 3000)])
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
        let llm = service([cut("cut", 2048), cut("cut", 4096), .init(hangs: true)])
        let task = Task { try await ask(llm) }
        while CutStubProtocol.maxTokens.count < 3 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        task.cancel()
        await #expect(throws: CancellationError.self, "a stopped run returns no answer") {
            _ = try await task.value
        }
    }

    @Test func ollamasLengthDoneReasonIsACutAskedAgainWithAContextThatHoldsIt() async throws {
        let llm = service([cut("cut", 2048), .init(content: "whole", outputTokens: 3000)], provider: .ollama)
        let (content, usage) = try await ask(llm)
        #expect(content == "whole")
        #expect(CutStubProtocol.maxTokens == [2048, 4096])
        let options = try #require(CutStubProtocol.bodies.last?["options"] as? [String: Any])
        #expect(options["num_ctx"] as? Int == OllamaContext.numCtx(contents: ["q"], maxTokens: 4096))
        #expect(usage.outputTokens == 5048)
    }

    @Test func ollamasRetryFitsTheLargestContextBesideThePrompt() async throws {
        // the stub states 100 prompt tokens
        let room = BioMedLitConstants.ollamaMaxNumCtx - 100 - BioMedLitConstants.ollamaTemplateTokens
        let llm = service([cut("cut", 600_000), .init(content: "whole", outputTokens: 700_000)], provider: .ollama)
        _ = try await ask(llm, maxTokens: 600_000)
        #expect(CutStubProtocol.maxTokens == [600_000, room])
    }

    @Test func anAnswerCutShortOfItsLimitFailsUnasked() async throws {
        // the context window ran out: a larger limit does not change that
        let llm = service([cut("cut", 900)])
        let error = await cutError { _ = try await ask(llm) }
        #expect(CutStubProtocol.maxTokens == [2048])
        #expect(error?.content == "cut")
    }

    @Test func aFinishedAnswerAndTheConnectionTestAreAskedOnce() async throws {
        // control: a whole answer is not asked again
        var llm = service([.init(outputTokens: 2048)])
        _ = try await ask(llm)
        #expect(CutStubProtocol.maxTokens == [2048])

        llm = service([cut("O", 10)])
        let (content, _) = try await llm.chat(messages: [LLMService.userMessage("q")], maxTokens: 10, retryingCut: false)
        #expect(content == "O", "the connection test reads any text as a working connection")
        #expect(CutStubProtocol.maxTokens == [10])
    }

    @Test func theRaisedLimitFollowsTheDesktopRule() {
        #expect(LLMService.raisedLimit(finishReason: "length", outputTokens: 2048, maxTokens: 2048) == 4096)
        #expect(LLMService.raisedLimit(finishReason: "max_tokens", outputTokens: 2048, maxTokens: 2048) == 4096)
        #expect(LLMService.raisedLimit(finishReason: "length", outputTokens: 2049, maxTokens: 2048) == 4096, "a count past the limit is a cut")
        #expect(LLMService.raisedLimit(finishReason: "length", outputTokens: 16384, maxTokens: 16384) == 32768, "no fixed cap")
        #expect(LLMService.raisedLimit(finishReason: "length", outputTokens: 8192, maxTokens: 8192, room: 10000) == 10000, "capped by the room")
        #expect(LLMService.raisedLimit(finishReason: "length", outputTokens: 8192, maxTokens: 8192, room: 8192) == nil, "no larger limit")
        #expect(LLMService.raisedLimit(finishReason: "length", outputTokens: 8192, maxTokens: 8192, attempt: 2) == 16384)
        #expect(LLMService.raisedLimit(finishReason: "length", outputTokens: 8192, maxTokens: 8192, attempt: 3) == nil, "three retries spent")
        #expect(LLMService.raisedLimit(finishReason: "stop", outputTokens: 2048, maxTokens: 2048) == nil)
        #expect(LLMService.raisedLimit(finishReason: nil, outputTokens: 2048, maxTokens: 2048) == nil)
        #expect(LLMService.raisedLimit(finishReason: "length", outputTokens: 0, maxTokens: 2048) == nil, "no count stated")
        #expect(LLMService.raisedLimit(finishReason: "length", outputTokens: 0, maxTokens: 0) == nil)
    }

    @Test func eachProbedRefusalStatesItsMaximum() {
        let probed = [
            ("max_tokens: 10000000 > 64000, which is the maximum allowed number of output tokens for claude-sonnet-4-5-20250929", 64000),
            ("max_tokens is too large: 10000000. This model supports at most 128000 completion tokens, whereas you provided 10000000.", 128_000),
            ("Invalid max_tokens value, the valid range of max_tokens is [1, 393216] (request_id: ec74ea79)", 393_216),
        ]
        for (message, maximum) in probed {
            #expect(LLMService.statedOutputMaximum(LLMError.apiError(statusCode: 400, message: message)) == maximum)
        }
        #expect(LLMService.statedOutputMaximum(message: "Unsupported parameter: 'max_tokens'") == nil)
        #expect(
            LLMService.statedOutputMaximum(LLMError.apiError(statusCode: 429, message: probed[0].0)) == nil,
            "only a 400 refuses a limit"
        )
    }

    @Test func theCutErrorQuotesTheAnswerInTheDesktopsWords() {
        let error = LLMError.cut(model: "m", maxTokens: 2048, outputTokens: 2048, content: "{\"score\":", after: "")
        #expect(error.localizedDescription == "The answer from m reached its token limit (2048 tokens) and is incomplete. The answer as cut:\n\n{\"score\":")
        let unknownLimit = LLMError.cut(model: "m", maxTokens: 0, outputTokens: 700, content: "", after: "; x")
        #expect(unknownLimit.localizedDescription == "The answer from m reached its token limit (700 tokens generated) and is incomplete; x. The answer as cut:\n\n")
    }

    @Test func timeoutsGrowWithTheLimit() {
        #expect(LLMService.timeoutScale(maxTokens: 10) == 1)
        #expect(LLMService.timeoutScale(maxTokens: 8192) == 1)
        #expect(LLMService.timeoutScale(maxTokens: 8193) == 2)
        #expect(LLMService.timeoutScale(maxTokens: 65536) == 8)
        #expect(LLMService.timeouts(provider: .openai, maxTokens: 2048) == .init(request: 60, resource: 120))
        #expect(LLMService.timeouts(provider: .ollama, maxTokens: 16384) == .init(request: 240, resource: 600))
    }

    @Test func openAIIsSentItsOwnLimitParameterAndOthersMaxTokens() async throws {
        _ = try await ask(service([.init()], provider: .openai))
        #expect(CutStubProtocol.bodies.last?["max_completion_tokens"] as? Int == 2048)
        #expect(CutStubProtocol.bodies.last?["max_tokens"] == nil, "gpt-5 answers 400 to max_tokens")
        for provider in [LLMProvider.deepseek, .anthropic, .groq, .mistral, .custom] {
            _ = try await ask(service([.init()], provider: provider))
            #expect(CutStubProtocol.bodies.last?["max_tokens"] as? Int == 2048)
            #expect(CutStubProtocol.bodies.last?["max_completion_tokens"] == nil)
        }
    }

    @Test func aCutAlternativeQueryAnswerIsToldInTheDesktopsWords() {
        #expect(SmartSearchError.cutOff.localizedDescription.hasPrefix(
            "The model's answer was cut off at its length limit, so no alternative search was run."
        ))
    }

    // MARK: - #830: a cut answer with no text

    @Test func aTextlessCutAnswerIsAskedAgainWithTwiceTheLimit() async throws {
        let llm = service([cut(nil, 2048), .init(content: "{\"score\": 4}", outputTokens: 2300)])
        let (content, usage) = try await ask(llm)
        #expect(content == "{\"score\": 4}")
        #expect(CutStubProtocol.maxTokens == [2048, 4096])
        #expect(usage.outputTokens == 4348)
    }

    @Test func anEmptyCutAnswerIsAskedAgainToo() async throws {
        // Ollama and some compatible endpoints send "" rather than null
        let llm = service([cut("", 2048), .init(content: "whole", outputTokens: 3000)], provider: .ollama)
        let (content, _) = try await ask(llm)
        #expect(content == "whole")
        #expect(CutStubProtocol.maxTokens == [2048, 4096])
    }

    @Test func aTextlessAnswerStillCutFailsAsACutNamingItsLimit() async throws {
        let llm = service([cut(nil, 2048), cut(nil, 4096), cut(nil, 8192), cut(nil, 16384)])
        let error = await cutError { _ = try await ask(llm) }
        #expect(error?.content == "")
        #expect(error?.maxTokens == 16384)
        let unretried = await cutError {
            _ = try await self.service([self.cut(nil, 4096)])
                .chat(messages: [LLMService.userMessage("q")], maxTokens: 4096, retryingCut: false)
        }
        #expect(unretried?.maxTokens == 4096, "with no text there is nothing to return")
    }

    @Test func aTextlessCutAnswerWhoseRetryFailsThrows() async throws {
        let llm = service([cut(nil, 2048), .init(status: 400)])
        _ = await cutError { _ = try await ask(llm) }
        #expect(CutStubProtocol.maxTokens == [2048, 4096])
    }

    @Test func aTextlessReplyIsAnAnswerOnlyWhenCut() async throws {
        let llm = service([])
        let cut = Data(#"{"choices":[{"message":{"role":"assistant","content":null},"finish_reason":"length"}]}"#.utf8)
        #expect(try await llm.decodeReply(cut).content == "")
        let finished = Data(#"{"choices":[{"message":{"role":"assistant","content":null},"finish_reason":"stop"}]}"#.utf8)
        do {
            _ = try await llm.decodeReply(finished)
            Issue.record("a finished textless reply was read as an answer")
        } catch LLMError.emptyResponse {}
    }

    // MARK: - #819: a refusal is a refusal

    @Test func aRefusalThrowsAsOneWhateverTextCameWithItAndIsAskedOnce() async throws {
        for reply in [
            CutStubProtocol.Reply(content: nil, finishReason: "refusal"),
            CutStubProtocol.Reply(content: "", finishReason: "content_filter"),
            CutStubProtocol.Reply(content: "partial", finishReason: "refusal"),
        ] {
            do {
                _ = try await ask(service([reply]))
                Issue.record("a refusal was returned as an answer")
            } catch LLMError.refused {}
            #expect(CutStubProtocol.maxTokens == [2048], "never retried")
        }
    }

    @Test func anEmptyHydeAnswerFallsBackLikeAnyFailure() throws {
        #expect(throws: LLMError.self) { try FactCheckWorkflow.hypotheticalDocument(fromAnswer: " \n ") }
        #expect(try FactCheckWorkflow.hypotheticalDocument(fromAnswer: " A passage.\n") == "A passage.")
    }

    @Test func aCutAnswerWhoseRetryIsRefusedThrowsTheRefusal() async throws {
        // the desktop raises the retry's refusal too, never the cut answer
        let llm = service([cut("cut", 2048), .init(content: nil, finishReason: "refusal")])
        do {
            _ = try await ask(llm)
            Issue.record("the cut answer was kept over a refusal")
        } catch LLMError.refused {}
        #expect(CutStubProtocol.maxTokens == [2048, 4096])
    }
}
