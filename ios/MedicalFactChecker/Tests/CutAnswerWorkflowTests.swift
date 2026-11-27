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

import XCTest
import SwiftData
import BioMedLit
@testable import MedicalFactChecker

/// Answers every request cut at its limit: `length`, with more tokens than any limit asked.
private final class AlwaysCutProtocol: URLProtocol {
    nonisolated(unsafe) static var requests = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests += 1
        let answer: [String: Any] = [
            "choices": [["message": ["role": "assistant", "content": "{\"concepts\": ["], "finish_reason": "length"]],
            "usage": ["prompt_tokens": 100, "completion_tokens": 1_000_000, "total_tokens": 1_000_100],
        ]
        let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: answer))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// #831: a workflow step whose answer is still cut after three retries. The
/// query conversion searches the claim itself; smart search tells the user the
/// answer was cut and is marked as tried, so no later step pays again.
@MainActor
final class CutAnswerWorkflowTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUp() async throws {
        StringArrayTransformer.register()
        container = try ModelContainer(
            for: Schema(versionedSchema: SchemaV2.self),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
        AlwaysCutProtocol.requests = 0
    }

    override func tearDown() async throws {
        context = nil
        container = nil
    }

    private func workflow(for session: FactCheckSession) -> FactCheckWorkflow {
        context.insert(session)
        let workflow = FactCheckWorkflow(modelContext: context, modelContainer: container, settings: .shared)
        workflow.restoreForViewing(session)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AlwaysCutProtocol.self]
        workflow.useServices(
            llm: LLMService(
                baseURL: URL(string: "https://stub.invalid/v1")!, apiKey: "k", model: "m",
                session: URLSession(configuration: config)
            ),
            pubMed: BMLPubMedService.create(from: .shared)
        )
        return workflow
    }

    func testAQueryAnswerStillCutSearchesTheClaimItself() async throws {
        let session = FactCheckSession(claim: "Aspirin prevents stroke")

        try await workflow(for: session).convertClaimToQuery()

        XCTAssertEqual(AlwaysCutProtocol.requests, 4, "asked again three times")
        XCTAssertEqual(
            session.pubmedQuery,
            "Aspirin prevents stroke AND hasabstract \(PubMedFilters.clinicalPublicationFilter)"
        )
    }

    func testAnAlternativeQueryAnswerStillCutSaysSoAndMarksSmartSearchTried() async {
        let session = FactCheckSession(claim: "Aspirin prevents stroke")
        session.pubmedQuery = "aspirin AND stroke"
        session.currentStep = .awaitingUserDecision

        await workflow(for: session).continueWithSmartSearch()

        XCTAssertEqual(AlwaysCutProtocol.requests, 4, "asked again three times")
        XCTAssertTrue(session.smartSearchEnabled, "marked as tried")
        XCTAssertEqual(
            session.errorMessage,
            "The model's answer was cut off at its length limit, so no alternative "
                + "search was run. A model that writes out its reasoning first can use up "
                + "that limit; another model, chosen in Settings, may help."
        )
    }
}
