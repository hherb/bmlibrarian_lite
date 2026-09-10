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
@testable import BioMedLit

/// The kind Europe PMC stated has to reach the retrieval chain, not merely
/// exist beside it.
///
/// Every case here uses an identifier whose *shape* says something different
/// from what the record said, because that is the only way to tell a carried
/// kind from a re-derived one. The shapes are contrived; the mechanism they
/// prove is not, and it is what a `NBK…`, `PAT…` or `AGR…` record depends on —
/// each of those matches nothing when asked under `src:med`, which is where the
/// shape rule sends everything it cannot name (#209).
///
/// A net installed where production never runs is not installed (#175), so these
/// go through `fetchFullText` rather than through the query builder alone.
final class StatedIdentifierKindTests: XCTestCase {
    private let accession = "1287966"

    private func makeService(session: URLSession) -> FullTextService {
        FullTextService(
            email: "test@example.org",
            session: session,
            europePMCService: EuropePMCService(session: session)
        )
    }

    private func stubbedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    /// A stated preprint is asked for under `src:ppr` even though its accession
    /// is all digits, which the shape rule reads as a PubMed ID.
    func testAStatedPreprintIsAskedForUnderThePreprintSource() async throws {
        StubURLProtocol.routes = ["search": (200, Data(#"{"resultList": {"result": []}}"#.utf8))]
        StubURLProtocol.stubbed = (404, Data())
        let service = makeService(session: stubbedSession())

        _ = try? await service.fetchFullText(
            pmcId: nil,
            doi: nil,
            pmid: accession,
            primaryKind: .preprint
        )

        XCTAssertTrue(
            StubURLProtocol.requested("src:ppr") || StubURLProtocol.requested("src%3Appr"),
            "the stated kind must decide the source: \(StubURLProtocol.requestedURLs)"
        )
    }

    /// The sources the shape rule cannot name at all. Carried, the record is
    /// asked for in its own terms; guessed, it goes to `src:med` and matches
    /// nothing, which reads exactly like an article Europe PMC never held.
    func testAStatedSourceTokenIsAskedForUnderItself() async throws {
        StubURLProtocol.routes = ["search": (200, Data(#"{"resultList": {"result": []}}"#.utf8))]
        StubURLProtocol.stubbed = (404, Data())
        let service = makeService(session: stubbedSession())

        _ = try? await service.fetchFullText(
            pmcId: nil,
            doi: nil,
            pmid: "NBK1234",
            primaryKind: .europePMCSource("nbk")
        )

        XCTAssertTrue(
            StubURLProtocol.requested("src:nbk") || StubURLProtocol.requested("src%3Anbk"),
            "an unmodelled source must be asked for under itself: \(StubURLProtocol.requestedURLs)"
        )
    }

    /// The last resort pastes the primary slot after the PubMed base URL, and
    /// only a PubMed ID may go there. An all-digits accession passes the shape
    /// test, so without the stated kind a preprint whose accession is numeric
    /// would be handed to the reader as a PubMed link that names no article —
    /// the defect the last resort was fixed for once already (#202).
    func testAStatedNonPubMedKindIsNeverPastedAfterThePubMedURL() async throws {
        StubURLProtocol.routes = ["search": (200, Data(#"{"resultList": {"result": []}}"#.utf8))]
        StubURLProtocol.stubbed = (404, Data())
        let service = makeService(session: stubbedSession())

        do {
            let result = try await service.fetchFullText(
                pmcId: nil,
                doi: nil,
                pmid: accession,
                primaryKind: .preprint
            )
            XCTFail("expected no full text, got \(result.source) at \(String(describing: result.webURL))")
        } catch let error as FullTextError {
            guard case .noFullTextAvailable = error else {
                return XCTFail("expected noFullTextAvailable, got \(error)")
            }
        }
    }

    /// The same accession with nothing stated keeps the shape rule's answer, so
    /// a document stored before the kind was recorded behaves exactly as it did.
    func testAnUnstatedNumericAccessionStillReachesThePubMedFallback() async throws {
        StubURLProtocol.routes = ["search": (200, Data(#"{"resultList": {"result": []}}"#.utf8))]
        StubURLProtocol.stubbed = (404, Data())
        let service = makeService(session: stubbedSession())

        let result = try await service.fetchFullText(pmcId: nil, doi: nil, pmid: accession)

        XCTAssertEqual(
            result.webURL,
            URL(string: "\(BioMedLitConstants.pubmedWebBaseURL)/\(accession)/")
        )
    }
}
