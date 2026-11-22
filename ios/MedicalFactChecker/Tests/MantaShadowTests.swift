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
import XCTest
@testable import MedicalFactChecker

private let judgedJSON = """
{"judgement_id": "J", "revision": "r1", "seconds": 0.1, "truncated": false,
 "relevance": {"probabilities": {"1": 0.7, "2": 0.3}, "expected_score": 1.3, "verdict": "out", "cutoff": 1.95},
 "design": {"probabilities": {"rct": 0.9, "other": 0.1}, "answer": "rct", "probability": 0.9}}
"""

private func judgement(_ id: String) -> MantaJudgement {
    let json = judgedJSON.replacingOccurrences(of: "\"J\"", with: "\"\(id)\"")
    // swiftlint:disable:next force_try
    return try! JSONDecoder().decode(MantaJudgement.self, from: Data(json.utf8))
}

/// A `MantaJudging` that records calls in order, and can throw or hold a judge until released.
private actor StubJudge: MantaJudging {
    private(set) var calls: [String] = []
    private(set) var references: [MantaReference] = []
    var judgeError: Error?
    private var holding = false
    private var held: CheckedContinuation<Void, Never>?
    private var arrived: CheckedContinuation<Void, Never>?

    func failJudge(with error: Error) { judgeError = error }

    /// The next judge waits until ``release()``.
    func hold() { holding = true }

    /// Returns once a held judge has started.
    func waitUntilHeld() async {
        if held != nil { return }
        await withCheckedContinuation { arrived = $0 }
    }

    func release() { held?.resume(); held = nil }

    func judge(_ request: MantaJudgeRequest) async throws -> MantaJudgement {
        let pmid = request.ids["pmid"] ?? "?"
        calls.append("judge \(pmid)")
        if holding {
            holding = false
            await withCheckedContinuation { cont in
                held = cont
                arrived?.resume()
                arrived = nil
            }
        }
        if let judgeError { throw judgeError }
        return judgement("j-\(pmid)")
    }

    func reference(_ reference: MantaReference) async throws {
        calls.append("reference \(reference.judgementID)")
        references.append(reference)
    }
}

/// Collects delivered results on the main actor.
@MainActor
private final class Results {
    var all: [MantaShadowResult] = []
    var expectation: XCTestExpectation?

    func take(_ result: MantaShadowResult) {
        all.append(result)
        expectation?.fulfill()
    }
}

private func item(_ pmid: String, score: Int = 4) -> MantaShadowItem {
    MantaShadowItem(
        pmid: pmid, claim: "Does X help Y?", title: "T\(pmid)", abstract: "A", ids: ["pmid": pmid],
        llmScore: score, llmModel: "claude-test",
        indexing: MantaIndexing(
            publicationTypes: ["Journal Article"], meshTerms: ["Humans"], medlineStatus: "MEDLINE",
            indexingMethod: "Manual"))
}

final class MantaShadowTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StringArrayTransformer.register()
    }

    @MainActor
    private func shadow(_ stub: StubJudge, _ results: Results) -> MantaShadow {
        MantaShadow(service: stub, onResult: { results.take($0) })
    }

    @MainActor
    func testItemsRunInOrderAndPostReference() async {
        let stub = StubJudge()
        let results = Results()
        let done = expectation(description: "two results")
        done.expectedFulfillmentCount = 2
        results.expectation = done
        let shadow = shadow(stub, results)

        await shadow.observe(item("1", score: 4))
        await shadow.observe(item("2", score: 2))
        await fulfillment(of: [done], timeout: 5)

        let calls = await stub.calls
        XCTAssertEqual(calls, ["judge 1", "reference j-1", "judge 2", "reference j-2"])
        let references = await stub.references
        XCTAssertEqual(references.map(\.llmScore), [4, 2])
        XCTAssertEqual(references.map(\.llmModel), ["claude-test", "claude-test"])
        XCTAssertEqual(references.map(\.app), ["macos", "macos"])
        XCTAssertEqual(references.first?.indexing?.indexingMethod, "Manual")
        XCTAssertEqual(results.all.map(\.pmid), ["1", "2"])
        XCTAssertTrue(results.all.allSatisfy(\.referencePosted))
        guard case .judged(let j) = results.all.first?.outcome else { return XCTFail("not judged") }
        XCTAssertEqual(j.judgementID, "j-1")
    }

    @MainActor
    func testUnreachableHasNoReference() async {
        let stub = StubJudge()
        await stub.failJudge(with: MantaServiceError.unreachable("Could not connect"))
        let results = Results()
        let done = expectation(description: "one result")
        results.expectation = done
        let shadow = shadow(stub, results)

        await shadow.observe(item("1"))
        await fulfillment(of: [done], timeout: 5)

        let calls = await stub.calls
        XCTAssertEqual(calls, ["judge 1"])
        XCTAssertFalse(results.all[0].referencePosted)
        guard case .unreachable(let message) = results.all[0].outcome else { return XCTFail("not unreachable") }
        XCTAssertEqual(message, "Could not connect")
    }

    @MainActor
    func testRefusedIsFailedWithStatus() async {
        let stub = StubJudge()
        await stub.failJudge(with: MantaServiceError.refused(status: 503, message: "model loading"))
        let results = Results()
        let done = expectation(description: "one result")
        results.expectation = done
        let shadow = shadow(stub, results)

        await shadow.observe(item("1"))
        await fulfillment(of: [done], timeout: 5)

        guard case .failed(let message) = results.all[0].outcome else { return XCTFail("not failed") }
        XCTAssertEqual(message, "503: model loading")
    }

    @MainActor
    func testCancelDropsPending() async {
        let stub = StubJudge()
        await stub.hold()
        let results = Results()
        let shadow = shadow(stub, results)

        await shadow.observe(item("1"))
        await shadow.observe(item("2"))
        await stub.waitUntilHeld()
        await shadow.cancel()
        await stub.release()

        // A later item still runs, so its result proves the dropped ones never arrive.
        let done = expectation(description: "the later item")
        results.expectation = done
        await shadow.observe(item("3"))
        await fulfillment(of: [done], timeout: 5)

        let calls = await stub.calls
        XCTAssertFalse(calls.contains("judge 2"), "a pending item is dropped")
        XCTAssertEqual(results.all.map(\.pmid), ["3"], "the in-flight item delivers nothing")
    }

    /// `MantaService` reports a cancelled request as unreachable; a stopped run must not store that.
    @MainActor
    func testCancelledInFlightUnreachableIsNotDelivered() async {
        let stub = StubJudge()
        await stub.hold()
        await stub.failJudge(with: MantaServiceError.unreachable("cancelled"))
        let results = Results()
        let shadow = shadow(stub, results)

        await shadow.observe(item("1"))
        await stub.waitUntilHeld()
        await shadow.cancel()
        await stub.release()

        await stub.failJudge(with: MantaServiceError.unreachable("down"))
        let done = expectation(description: "the later item")
        results.expectation = done
        await shadow.observe(item("2"))
        await fulfillment(of: [done], timeout: 5)

        XCTAssertEqual(results.all.map(\.pmid), ["2"])
    }

    func testApplyMantaJudged() throws {
        let document = Document(pmid: "1", title: "T", abstract: "")
        let at = Date(timeIntervalSince1970: 1_000)
        document.applyManta(
            MantaShadowResult(pmid: "1", outcome: .judged(judgement("J")), judgedAt: at, referencePosted: true),
            serverURL: "http://127.0.0.1:8765")

        XCTAssertEqual(document.mantaOutcome, "judged")
        XCTAssertEqual(document.mantaJudgementID, "J")
        XCTAssertEqual(document.mantaServerURL, "http://127.0.0.1:8765")
        XCTAssertEqual(document.mantaRevision, "r1")
        XCTAssertEqual(document.mantaExpectedScore, 1.3)
        XCTAssertEqual(document.mantaVerdict, "out")
        XCTAssertEqual(document.mantaCutoff, 1.95)
        XCTAssertEqual(document.mantaDesign, "rct")
        XCTAssertEqual(document.mantaDesignProbability, 0.9)
        XCTAssertEqual(document.mantaJudgedAt, at)
        XCTAssertNil(document.mantaError)
        let relevance = try JSONDecoder().decode(
            [String: Double].self, from: Data(try XCTUnwrap(document.mantaRelevanceJSON).utf8))
        XCTAssertEqual(relevance, ["1": 0.7, "2": 0.3])
        let design = try JSONDecoder().decode(
            [String: Double].self, from: Data(try XCTUnwrap(document.mantaDesignJSON).utf8))
        XCTAssertEqual(design, ["rct": 0.9, "other": 0.1])
    }

    func testApplyMantaUnreachable() {
        let document = Document(pmid: "1", title: "T", abstract: "")
        document.applyManta(
            MantaShadowResult(pmid: "1", outcome: .judged(judgement("J")), judgedAt: Date(), referencePosted: true),
            serverURL: "u")
        let long = String(repeating: "x", count: WorkflowConstants.mantaErrorMaxLength + 50)

        document.applyManta(
            MantaShadowResult(pmid: "1", outcome: .unreachable(long), judgedAt: Date(), referencePosted: false),
            serverURL: "u")

        XCTAssertEqual(document.mantaOutcome, "unreachable")
        XCTAssertEqual(document.mantaError?.count, WorkflowConstants.mantaErrorMaxLength)
        XCTAssertNil(document.mantaJudgementID)
        XCTAssertNil(document.mantaExpectedScore)
        XCTAssertNil(document.mantaRelevanceJSON)
        XCTAssertNil(document.mantaVerdict)
        XCTAssertNil(document.mantaCutoff)
        XCTAssertNil(document.mantaDesign)
        XCTAssertNil(document.mantaDesignProbability)
        XCTAssertNil(document.mantaDesignJSON)
        XCTAssertNotNil(document.mantaJudgedAt)
    }

    func testAdapterKeepsMesh() {
        let metadata = BioMedLitAdapters.toUnifiedArticleMetadata(
            BMLSearchArticle(
                pmid: "12345678", title: "An article", abstract: "", authors: "", journal: "", year: "2026",
                source: .pubmed, meshTerms: ["Humans", "Aspirin"], medlineStatus: "MEDLINE",
                indexingMethod: "Automated"),
            appProvider: .pubmed, batchNumber: 1, resultPosition: 0)
        let document = Document(pmid: "12345678", title: "An article", abstract: "")

        document.applySearchMetadata(metadata, provider: .pubmed)

        XCTAssertEqual(document.meshTerms, ["Humans", "Aspirin"])
        XCTAssertEqual(document.medlineStatus, "MEDLINE")
        XCTAssertEqual(document.indexingMethod, "Automated")
    }
}
