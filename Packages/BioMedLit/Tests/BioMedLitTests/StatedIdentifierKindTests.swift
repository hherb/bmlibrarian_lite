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
/// prove is not, and it is what a `PAT…`, `AGR…` or `ETH…` record depends on —
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

    /// Identifier resolution must not carry a preprint exclusion.
    ///
    /// `EuropePMCService.search` appends ` NOT SRC:PPR` to any query that does
    /// not already contain that literal, and this ladder used to let it. The
    /// preprint rung survived only because `src:ppr` happens to contain
    /// `SRC:PPR` as a substring; every other rung went out filtered. Verified
    /// against the live API: the DOI of a `SRC:PPR` record returns one hit, and
    /// none once the exclusion is appended — so the DOI rung, which the ladder
    /// documents as a preprint's recovery path, could not match one at all.
    ///
    /// Asserted on the emitted URL rather than on the outcome, because the
    /// substring coincidence means an outcome assertion passes either way.
    func testIdentifierResolutionDoesNotExcludePreprints() async throws {
        StubURLProtocol.routes = ["search": (200, Data(#"{"resultList": {"result": []}}"#.utf8))]
        StubURLProtocol.stubbed = (404, Data())
        let service = makeService(session: stubbedSession())

        _ = try? await service.fetchFullText(
            pmcId: nil,
            doi: "10.1101/2024.01.01.573813",
            pmid: "",
            primaryKind: nil
        )

        XCTAssertFalse(
            StubURLProtocol.requested("NOT SRC:PPR")
                || StubURLProtocol.requested("NOT%20SRC:PPR")
                || StubURLProtocol.requested("NOT+SRC:PPR")
                || StubURLProtocol.requested("NOT%20SRC%3APPR")
                || StubURLProtocol.requested("NOT+SRC%3APPR"),
            "a lookup by identifier must not filter out preprints: \(StubURLProtocol.requestedURLs)"
        )
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
            pmid: "CN101548780",
            primaryKind: .europePMCSource("pat")
        )

        XCTAssertTrue(
            StubURLProtocol.requested("src:pat") || StubURLProtocol.requested("src%3Apat"),
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

    /// The same accession with nothing stated no longer reaches that fallback.
    ///
    /// It used to, on the shape rule alone — and that is #212: Europe PMC's
    /// theses, case reports and `HIR` records carry bare numeric accessions and
    /// no PubMed ID, so the number went behind the PubMed URL and named a real
    /// but unrelated article. A stated kind, or a PubMed search, is now what
    /// authorises that link.
    func testAnUnstatedNumericAccessionNoLongerReachesThePubMedFallback() async throws {
        StubURLProtocol.routes = ["search": (200, Data(#"{"resultList": {"result": []}}"#.utf8))]
        StubURLProtocol.stubbed = (404, Data())
        let service = makeService(session: stubbedSession())

        do {
            let result = try await service.fetchFullText(pmcId: nil, doi: nil, pmid: accession)
            XCTFail("expected no full text, got \(String(describing: result.webURL))")
        } catch let error as FullTextError {
            guard case .noFullTextAvailable = error else {
                return XCTFail("expected noFullTextAvailable, got \(error)")
            }
        }
    }
}
