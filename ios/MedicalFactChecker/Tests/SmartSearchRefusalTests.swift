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
@testable import MedicalFactChecker

/// Answers every request with a refusal: empty text, `content_filter`.
private final class RefusingProtocol: URLProtocol {
    nonisolated(unsafe) static var requests = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests += 1
        let answer: [String: Any] = [
            "choices": [["message": ["role": "assistant", "content": ""], "finish_reason": "content_filter"]],
            "usage": ["prompt_tokens": 100, "completion_tokens": 0, "total_tokens": 100],
        ]
        let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: answer))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// #819: a refused alternative-query answer is a refusal, not a model that
/// could not be asked. The user is told the model declined, as the desktop
/// says, and smart search is marked as tried, so no later step asks the same
/// model and pays again.
@MainActor
final class SmartSearchRefusalTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUp() async throws {
        StringArrayTransformer.register()
        container = try ModelContainer(
            for: Schema(versionedSchema: SchemaV2.self),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
        RefusingProtocol.requests = 0
    }

    override func tearDown() async throws {
        context = nil
        container = nil
    }

    func testARefusedAlternativeQueryAnswerSaysTheModelDeclinedAndMarksSmartSearchTried() async {
        let session = FactCheckSession(claim: "Aspirin prevents stroke")
        session.pubmedQuery = "aspirin AND stroke"
        session.currentStep = .awaitingUserDecision
        context.insert(session)
        let workflow = FactCheckWorkflow(modelContext: context, modelContainer: container, settings: .shared)
        workflow.restoreForViewing(session)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RefusingProtocol.self]
        workflow.useServices(
            llm: LLMService(
                baseURL: URL(string: "https://stub.invalid/v1")!, apiKey: "k", model: "m",
                session: URLSession(configuration: config)
            ),
            pubMed: BMLPubMedService.create(from: .shared)
        )

        await workflow.continueWithSmartSearch()

        XCTAssertEqual(RefusingProtocol.requests, 1, "a refusal is never asked again")
        XCTAssertTrue(session.smartSearchEnabled, "marked as tried")
        XCTAssertEqual(
            session.errorMessage,
            "The model declined to propose alternative search queries, so no alternative search was run. "
                + "Another model, chosen in Settings, may answer."
        )
    }
}
