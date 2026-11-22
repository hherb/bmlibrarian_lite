// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2026 Dr Horst Herb
// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest
@testable import BioMedLit

/// Answers MANTA requests from a canned status and body, and records the last request body.
private final class MantaStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var answer: (status: Int, body: String) = (200, "{}")
    nonisolated(unsafe) static var failure: URLError?
    nonisolated(unsafe) static var lastBody: Data?
    nonisolated(unsafe) static var lastPath: String?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastPath = request.url?.path
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
            Self.lastBody = data
        } else {
            Self.lastBody = request.httpBody
        }
        if let failure = Self.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: Self.answer.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.answer.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class MantaServiceTests: XCTestCase {
    private let judgeJSON = """
    {"judgement_id": "abc", "revision": "r1", "seconds": 0.1, "prompt_tokens": 512, "truncated": false,
     "relevance": {"probabilities": {"1": 0.7, "2": 0.2, "3": 0.05, "4": 0.03, "5": 0.02},
                   "expected_score": 1.45, "verdict": "out", "cutoff": 1.95},
     "design": {"probabilities": {"rct": 0.9, "other": 0.1}, "answer": "rct", "probability": 0.9}}
    """

    override func setUp() {
        MantaStubURLProtocol.answer = (200, "{}")
        MantaStubURLProtocol.failure = nil
        MantaStubURLProtocol.lastBody = nil
        MantaStubURLProtocol.lastPath = nil
    }

    private func service() -> MantaService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MantaStubURLProtocol.self]
        return MantaService(baseURL: URL(string: "http://127.0.0.1:8765")!, session: URLSession(configuration: config))
    }

    private let request = MantaJudgeRequest(
        app: "macos", question: "q", title: "t", abstract: "", ids: ["pmid": "1"], tasks: ["relevance", "design"])

    func testJudgeDecodes() async throws {
        MantaStubURLProtocol.answer = (200, judgeJSON)
        let judgement = try await service().judge(request)
        XCTAssertEqual(judgement.judgementID, "abc")
        XCTAssertEqual(judgement.revision, "r1")
        XCTAssertEqual(judgement.expectedScore, 1.45)
        XCTAssertEqual(judgement.verdict, "out")
        XCTAssertEqual(judgement.cutoff, 1.95)
        XCTAssertEqual(judgement.relevanceProbabilities["1"], 0.7)
        XCTAssertEqual(judgement.design, "rct")
        XCTAssertEqual(judgement.designProbability, 0.9)
        XCTAssertEqual(judgement.designProbabilities?["other"], 0.1)
        XCTAssertFalse(judgement.truncated)
        XCTAssertEqual(MantaStubURLProtocol.lastPath, "/v1/judge")
    }

    func testJudgeWithoutDesignDecodesNil() async throws {
        MantaStubURLProtocol.answer = (200, """
        {"judgement_id": "abc", "revision": "r1", "seconds": 0.1, "truncated": true,
         "relevance": {"probabilities": {"1": 1.0}, "expected_score": 1.0, "verdict": "out", "cutoff": 1.95}}
        """)
        let judgement = try await service().judge(request)
        XCTAssertNil(judgement.design)
        XCTAssertNil(judgement.designProbability)
        XCTAssertNil(judgement.designProbabilities)
        XCTAssertTrue(judgement.truncated)
    }

    func testNotReadyIsRefused() async {
        MantaStubURLProtocol.answer = (503, #"{"error": "self-test failed: x"}"#)
        do {
            _ = try await service().judge(request)
            XCTFail("expected refusal")
        } catch {
            XCTAssertEqual(error as? MantaServiceError, .refused(status: 503, message: "self-test failed: x"))
        }
    }

    func testConnectionFailureIsUnreachable() async {
        MantaStubURLProtocol.failure = URLError(.cannotConnectToHost)
        do {
            _ = try await service().judge(request)
            XCTFail("expected failure")
        } catch {
            guard case .unreachable = error as? MantaServiceError else {
                return XCTFail("got \(error)")
            }
        }
    }

    func testBadBodyIsUnreadable() async {
        MantaStubURLProtocol.answer = (200, "not json")
        do {
            _ = try await service().judge(request)
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? MantaServiceError, .unreadable)
        }
    }

    func testReferenceBodyIsSnakeCase() async throws {
        MantaStubURLProtocol.answer = (200, #"{"ok": true}"#)
        let reference = MantaReference(
            judgementID: "abc", app: "macos", llmModel: "m", llmScore: 4, llmDesign: nil,
            indexing: MantaIndexing(
                publicationTypes: ["Journal Article"], meshTerms: ["Humans"],
                medlineStatus: "MEDLINE", indexingMethod: nil))
        try await service().reference(reference)
        XCTAssertEqual(MantaStubURLProtocol.lastPath, "/v1/reference")
        let body = try XCTUnwrap(MantaStubURLProtocol.lastBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["judgement_id"] as? String, "abc")
        XCTAssertEqual(json["llm_model"] as? String, "m")
        XCTAssertEqual(json["llm_score"] as? Int, 4)
        XCTAssertTrue(json["llm_design"] is NSNull)
        let indexing = try XCTUnwrap(json["indexing"] as? [String: Any])
        XCTAssertEqual(indexing["mesh_terms"] as? [String], ["Humans"])
        XCTAssertEqual(indexing["publication_types"] as? [String], ["Journal Article"])
        XCTAssertEqual(indexing["medline_status"] as? String, "MEDLINE")
        XCTAssertTrue(indexing["indexing_method"] is NSNull)
    }

    func testReferenceUnknownJudgementIsRefused() async {
        MantaStubURLProtocol.answer = (404, #"{"error": "unknown judgement"}"#)
        let reference = MantaReference(
            judgementID: "x", app: "macos", llmModel: "m", llmScore: nil, llmDesign: nil, indexing: nil)
        do {
            try await service().reference(reference)
            XCTFail("expected refusal")
        } catch {
            XCTAssertEqual(error as? MantaServiceError, .refused(status: 404, message: "unknown judgement"))
        }
    }
}
