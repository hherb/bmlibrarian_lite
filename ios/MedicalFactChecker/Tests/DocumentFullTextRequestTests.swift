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

/// Records every URL a fetch reaches for, and answers nothing useful, so a test
/// can ask what was requested rather than what came back.
private final class StubFetchURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestedURLs: [String] = []
    nonisolated(unsafe) static var searchBody = Data(#"{"resultList": {"result": []}}"#.utf8)

    static func reset() {
        requestedURLs = []
    }

    static func requested(_ fragment: String) -> Bool {
        requestedURLs.contains { $0.contains(fragment) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let urlString = request.url?.absoluteString ?? ""
        Self.requestedURLs.append(urlString)

        let isSearch = urlString.contains("search")
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: isSearch ? 200 : 404,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if isSearch {
            client?.urlProtocol(self, didLoad: Self.searchBody)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Five views run this same retrieval, and #186 was fixed on one of them before
/// anyone noticed the other four had drifted.
///
/// So the identifiers a document hands the retrieval chain live in one place.
/// The kind matters most here: stored on the document but not passed on, it
/// would be a field written for nobody, and the chain would go on guessing from
/// the accession's shape (#209).
final class DocumentFullTextRequestTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StringArrayTransformer.register()
        StubFetchURLProtocol.reset()
    }

    override func tearDown() {
        StubFetchURLProtocol.reset()
        super.tearDown()
    }

    private func stubbedService() -> BMLFullTextService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubFetchURLProtocol.self]
        let session = URLSession(configuration: config)
        return BMLFullTextService(
            email: "test@example.org",
            session: session,
            europePMCService: BMLEuropePMCService(session: session)
        )
    }

    /// The document's stored kind decides the source its identifier is asked
    /// for under. This accession is all digits, so the shape rule would call it
    /// a PubMed ID and ask `src:med`, which matches no preprint.
    func testAStoredPreprintKindReachesTheQuery() async throws {
        let document = Document(pmid: "1287966", title: "A preprint", abstract: "")
        document.identifierKind = .preprint

        _ = try? await stubbedService().fetchFullText(for: document)

        XCTAssertTrue(
            StubFetchURLProtocol.requested("src:ppr")
                || StubFetchURLProtocol.requested("src%3Appr"),
            "the document's kind must reach the query: \(StubFetchURLProtocol.requestedURLs)"
        )
    }

    /// A document stored before the kind existed keeps the shape rule, so this
    /// change costs nothing for the records already on disk.
    func testADocumentWithNoStoredKindStillUsesTheShapeRule() async throws {
        let document = Document(pmid: "PPR1287966", title: "A preprint", abstract: "")

        _ = try? await stubbedService().fetchFullText(for: document)

        XCTAssertTrue(
            StubFetchURLProtocol.requested("src:ppr")
                || StubFetchURLProtocol.requested("src%3Appr"),
            "an unstated kind must fall back to the shape: \(StubFetchURLProtocol.requestedURLs)"
        )
    }

    /// The other identifiers still travel: the seam replaces five hand-written
    /// argument lists, and dropping one of them would cost an article its PMC
    /// rung silently.
    func testTheDocumentsOtherIdentifiersStillReachTheChain() async throws {
        let document = Document(pmid: "", title: "A PMC-only article", abstract: "")
        document.pmcId = "PMC1082889"

        _ = try? await stubbedService().fetchFullText(for: document)

        XCTAssertTrue(
            StubFetchURLProtocol.requested("PMC1082889"),
            "the PMC rung must be asked: \(StubFetchURLProtocol.requestedURLs)"
        )
    }
}
