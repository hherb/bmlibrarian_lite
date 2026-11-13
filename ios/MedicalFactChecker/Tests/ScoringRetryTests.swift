// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2026 Dr Horst Herb
// SPDX-License-Identifier: AGPL-3.0-or-later

import BioMedLit
import Foundation
import Testing
@testable import MedicalFactChecker

/// Answers each chat request with the next canned reply and keeps each
/// request's last turn, so the real scoring loop runs offline.
private final class StubChatURLProtocol: URLProtocol {
    nonisolated(unsafe) static var replies: [String] = []
    nonisolated(unsafe) static var asked: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let sent = (try? JSONSerialization.jsonObject(with: Self.body(of: request))) as? [String: Any]
        let messages = sent?["messages"] as? [[String: Any]]
        Self.asked.append(messages?.last?["content"] as? String ?? "")
        let reply = Self.replies[min(Self.asked.count, Self.replies.count) - 1]
        let payload = try! JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["role": "assistant", "content": reply], "finish_reason": "stop"]],
        ])
        let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
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

/// #761: a scoring retry follows an unreadable reply, so it asks with the
/// correction note instead of re-sending the identical request.
struct ScoringRetryTests {
    @Test func theScoringLoopAsksAgainWithTheNote() async {
        StubChatURLProtocol.replies = ["I cannot say.", #"{"score": 4, "explanation": "on topic"}"#]
        StubChatURLProtocol.asked = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubChatURLProtocol.self]
        let llm = LLMService(
            baseURL: URL(string: "https://stub.invalid/v1")!, apiKey: "k", model: "m",
            session: URLSession(configuration: config)
        )
        let input = ScoringInput(
            pmid: "1", title: "Title", abstract: "Abstract.", authors: "Author A", year: 2020, journal: "Journal"
        )

        let results = await ParallelScoringService(llmService: llm, maxConcurrent: 1)
            .scoreDocuments([input], claim: "A claim", onProgress: { _, _, _ in })

        #expect(results.map(\.score) == [4])
        let asked = StubChatURLProtocol.asked
        #expect(asked.count == 2)
        #expect(asked.first?.contains(ResponseParser.jsonCorrectionNote) == false)
        #expect(asked.last == "\(asked.first ?? "")\n\n\(ResponseParser.jsonCorrectionNote)")
    }

    @Test func theFirstAttemptAsksAsWritten() {
        let sent = ParallelScoringService.scoringMessages("task", attempt: 0)
        #expect(sent.map(\.role) == ["user"])
        #expect(sent.map(\.content) == ["task"])
    }

    @Test func everyLaterAttemptCarriesTheNote() {
        for attempt in 1...2 {
            let sent = ParallelScoringService.scoringMessages("task", attempt: attempt)
            #expect(sent.map(\.role) == ["user"])
            #expect(sent.map(\.content) == ["task\n\n\(ResponseParser.jsonCorrectionNote)"])
        }
    }
}
