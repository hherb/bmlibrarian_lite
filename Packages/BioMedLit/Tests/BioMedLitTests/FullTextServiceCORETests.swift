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

private struct ExtractingStub: PDFTextExtracting {
    func extract(from fileURL: URL) -> PDFExtractionResult {
        PDFExtractionResult(
            text: "The article.", success: true, pageCount: 1, convertedPages: 1, warnings: []
        )
    }
}

fileprivate extension RetryConfiguration {
    /// One attempt, no wait: a test of an outcome does not sleep through the
    /// backoff, and a 503 that outlasts it arrives as `serverError`.
    static let noRetry = RetryConfiguration(
        maxAttempts: 1, initialDelay: 0, maxDelay: 0, backoffMultiplier: 1, jitterFactor: 0
    )

    /// Two attempts, no backoff wait: enough to show a retry without sleeping
    /// through ``RetryConfiguration/core``'s delays. Pacing still applies.
    static let oneRetry = RetryConfiguration(
        maxAttempts: 2, initialDelay: 0, maxDelay: 0, backoffMultiplier: 1, jitterFactor: 0
    )
}

/// CORE's extracted text is the last full-text source before the link: asked
/// once, only with the user's key and a DOI, only when no copy was served; its
/// text wins over a held abstract; an unreachable CORE is an unsettled lookup
/// (#480, stage C; the maintainer's decisions of 2026-10-06).
final class FullTextServiceCORETests: XCTestCase {
    private let doi = "10.1159/000513404"
    private let coreHost = "api.core.ac.uk"
    private let repo = "https://repo.example.org/b.pdf"
    private let pdfBody = Data("%PDF-1.7\n".utf8) + Data(repeating: 0x30, count: 64)
    private let bodylessJATS = """
        <article><front><article-meta><title-group><article-title>T</article-title>\
        </title-group><abstract><p>Abstract only.</p></abstract></article-meta></front></article>
        """

    /// The article's cache key: no PMID, so the DOI names it.
    private var cacheKey: ArticleCacheKey {
        ArticleCacheKey(pmid: "", pmcId: nil, doi: doi)!
    }

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        FullTextService.deleteCachedPDF(for: cacheKey)
        // Europe PMC knows no record, so the open-access tiers decide the outcome
        StubURLProtocol.routes["search"] = (200, Data(#"{"resultList": {"result": []}}"#.utf8))
        // Unpaywall knows no copy (OpenAlex's fallback route answers 404 too)
        StubURLProtocol.routes["unpaywall"] = (404, Data())
    }

    override func tearDown() {
        StubURLProtocol.reset()
        FullTextService.deleteCachedPDF(for: cacheKey)
        super.tearDown()
    }

    private func makeService(
        retry: RetryConfiguration = .noRetry,
        email: String = "test@example.org",
        coreAPIKey: String? = "test-core-key",
        coreRetry: RetryConfiguration = .noRetry,
        coreThrottle: CoreThrottle = CoreThrottle(),
        writeCachedPDF: @escaping @Sendable (Data, URL) throws -> Void = FullTextService.writeAtomically
    ) -> FullTextService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        return FullTextService(
            email: email,
            session: session,
            europePMCService: EuropePMCService(session: session),
            extractor: ExtractingStub(),
            europePMCRetry: .noRetry,
            pmcOpenDataRetry: .noRetry,
            openAlexRetry: retry,
            coreAPIKey: coreAPIKey,
            coreRetry: coreRetry,
            coreThrottle: coreThrottle,
            writeCachedPDF: writeCachedPDF
        )
    }

    private func hit(_ text: String, doi: String? = nil) -> Data {
        let object: [String: Any] = ["results": [["doi": doi ?? self.doi, "fullText": text]]]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private func unpaywall(_ pdfs: [String]) -> Data {
        let locations = pdfs.map { ["url_for_pdf": $0, "url": $0] }
        let body: [String: Any] = ["best_oa_location": locations.first as Any, "oa_locations": locations]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    private var longText: String { String(repeating: "x", count: BioMedLitConstants.coreMinFullTextCharacters) }

    /// How many requests went to CORE.
    private var coreRequests: Int {
        StubURLProtocol.requestedURLs.filter { URL(string: $0)?.host == coreHost }.count
    }

    func testCOREsTextIsTheFullTextWhenNothingElseHasIt() async throws {
        StubURLProtocol.routes[coreHost] = (200, hit(longText))
        let result = try await makeService().fetchFullText(pmcId: nil, doi: doi, pmid: "1")
        XCTAssertEqual(result.content, .core(text: longText))
        XCTAssertEqual(result.contentKind, .extracted)
        XCTAssertEqual(result.extractedText, longText)
        XCTAssertNil(result.openAccessShortfall)
        XCTAssertNil(result.localPDFPath)
        // Asked once, after OpenAlex
        XCTAssertEqual(coreRequests, 1)
        let openAlexIndex = try XCTUnwrap(
            StubURLProtocol.requestedURLs.firstIndex { $0.contains("api.openalex.org") })
        let coreIndex = try XCTUnwrap(
            StubURLProtocol.requestedURLs.firstIndex { URL(string: $0)?.host == coreHost })
        XCTAssertLessThan(openAlexIndex, coreIndex)
    }

    func testTheKeyTravelsInTheHeaderAlone() async throws {
        StubURLProtocol.routes[coreHost] = (200, hit(longText))
        _ = try await makeService().fetchFullText(pmcId: nil, doi: doi, pmid: "1")
        let index = try XCTUnwrap(
            StubURLProtocol.requestedURLs.firstIndex { URL(string: $0)?.host == coreHost })
        XCTAssertEqual(StubURLProtocol.requestedHeaders[index]["Authorization"], "Bearer test-core-key")
        XCTAssertFalse(StubURLProtocol.requestedURLs[index].contains("test-core-key"))
    }

    func testAnotherArticlesTextIsNeverServed() async throws {
        StubURLProtocol.routes[coreHost] = (200, hit(longText, doi: "10.1159/999999"))
        let result = try await makeService().fetchFullText(pmcId: nil, doi: doi, pmid: "1")
        XCTAssertNotEqual(result.content.source, .core)
        // The control that CORE was asked and its answer read
        XCTAssertEqual(coreRequests, 1)
    }

    func testAnUnreachableCOREIsAnUnsettledLookup() async throws {
        StubURLProtocol.routes[coreHost] = (503, Data())
        let result = try await makeService().fetchFullText(pmcId: nil, doi: doi, pmid: "1")
        XCTAssertEqual(result.openAccessShortfall?.entries.last?.source, .core)
        XCTAssertEqual(result.openAccessShortfall?.entries.last?.reason, .failed(.httpStatus(503)))
    }

    func testTheSourceIsTheContracts() throws {
        let contract = try COREContract.load()
        XCTAssertEqual(contract["source"] as? String, FullTextSource.core.rawValue)
        XCTAssertEqual(contract["source_label"] as? String, FullTextSource.core.displayName)
    }

    func testWithoutAKeyCOREIsNeverAsked() async throws {
        let result = try await makeService(coreAPIKey: nil).fetchFullText(pmcId: nil, doi: doi, pmid: "1")
        XCTAssertEqual(coreRequests, 0)
        XCTAssertNil(result.openAccessShortfall)
        XCTAssertFalse(makeService(coreAPIKey: "   ").asksCore)
        // The control: a key, trimmed, is one
        XCTAssertTrue(makeService(coreAPIKey: " test-core-key ").asksCore)
    }

    func testCOREKnowingNothingAddsNothing() async throws {
        // Set rather than left to the fallback route: CORE's URL holds
        // `/search/`, so setUp's Europe PMC `search` route would answer it.
        StubURLProtocol.routes[coreHost] = (200, Data(#"{"results": []}"#.utf8))
        let result = try await makeService().fetchFullText(pmcId: nil, doi: doi, pmid: "1")
        XCTAssertFalse(result.openAccessShortfall?.entries.contains { $0.source == .core } ?? false)
        // The control that CORE was asked
        XCTAssertEqual(coreRequests, 1)
    }

    func testTwo429sPauseCOREAcrossServices() async throws {
        let throttle = CoreThrottle()
        StubURLProtocol.routes[coreHost] = (429, Data())
        _ = try await makeService(coreThrottle: throttle).fetchFullText(pmcId: nil, doi: doi, pmid: "1")
        _ = try await makeService(coreThrottle: throttle).fetchFullText(pmcId: nil, doi: doi, pmid: "2")
        let before = coreRequests
        XCTAssertEqual(before, 2)
        let third = try await makeService(coreThrottle: throttle).fetchFullText(pmcId: nil, doi: doi, pmid: "3")
        XCTAssertEqual(coreRequests, before)
        XCTAssertEqual(third.openAccessShortfall?.entries.last?.reason, .failed(.httpStatus(429)))
    }

    /// The first 401 is told as a refused key, and no service sharing the
    /// throttle asks CORE again (#498).
    func testA401RefusesTheKeyAcrossServices() async throws {
        let throttle = CoreThrottle()
        StubURLProtocol.routes[coreHost] = (401, Data())
        let first = try await makeService(coreThrottle: throttle).fetchFullText(pmcId: nil, doi: doi, pmid: "1")
        XCTAssertEqual(coreRequests, 1)
        XCTAssertTrue(throttle.isKeyRefused)
        let second = try await makeService(coreThrottle: throttle).fetchFullText(pmcId: nil, doi: doi, pmid: "2")
        XCTAssertEqual(coreRequests, 1, "a refused key sends nothing")
        for result in [first, second] {
            let last = try XCTUnwrap(result.openAccessShortfall?.entries.last)
            XCTAssertEqual(last.source, .core)
            XCTAssertEqual(last.reason, .keyRefused)
            XCTAssertNil(last.address)
            XCTAssertFalse(result.openAccessShortfall?.notice.contains("HTTP 401") ?? true)
            XCTAssertTrue(
                result.openAccessShortfall?.notice
                    .contains("CORE (the key in the settings was refused) could not be asked") ?? false
            )
        }
        // Blocks a settled absence: the chain ends on an unsettled open-access copy
        XCTAssertEqual(second.openAccessShortfall, .coreKeyRefused)
    }

    /// The control: a 403 is an ordinary answer, and CORE is asked again.
    func testA403IsAnOrdinaryAnswerAndRefusesNothing() async throws {
        let throttle = CoreThrottle()
        StubURLProtocol.routes[coreHost] = (403, Data())
        let first = try await makeService(coreThrottle: throttle).fetchFullText(pmcId: nil, doi: doi, pmid: "1")
        _ = try await makeService(coreThrottle: throttle).fetchFullText(pmcId: nil, doi: doi, pmid: "2")
        XCTAssertEqual(coreRequests, 2)
        XCTAssertFalse(throttle.isKeyRefused)
        XCTAssertEqual(first.openAccessShortfall?.entries.last?.reason, .failed(.httpStatus(403)))
    }

    /// Refused and paused, a fetch is told the key: the cause the reader can act on.
    func testARefusedKeyIsToldBeforeAPause() async throws {
        let throttle = CoreThrottle()
        for status in [429, 429, BioMedLitConstants.coreKeyRefusedStatus] { throttle.record(endedOn: status) }
        StubURLProtocol.routes[coreHost] = (200, hit(longText))
        let fetch = try await makeService(coreThrottle: throttle).fetchCoreText(doi: doi, apiKey: "test-core-key")
        XCTAssertEqual(fetch, .keyRefused)
        XCTAssertEqual(coreRequests, 0)
    }

    func testACopyServedButNotCachedMeansCOREIsNotAsked() async throws {
        // FullTextServiceOpenAlexTests' "served but not cached" setup: an
        // Unpaywall PDF route answering %PDF and a `writeCachedPDF` that throws.
        StubURLProtocol.routes["unpaywall"] = (200, unpaywall([repo]))
        StubURLProtocol.routes["repo.example.org"] = (200, pdfBody)
        StubURLProtocol.routes[coreHost] = (200, hit(longText))
        let result = try await makeService(writeCachedPDF: { _, _ in
            throw CocoaError(.fileWriteOutOfSpace)
        }).fetchFullText(pmcId: nil, doi: doi, pmid: "")
        XCTAssertEqual(coreRequests, 0)
        // The control that the copy was served and not cached
        XCTAssertEqual(result.content, .unpaywall(pdfURL: URL(string: repo)!))
        XCTAssertEqual(result.pdfNotSavedFrom, repo)
    }

    func testCOREsTextWinsOverAHeldAbstract() async throws {
        // FullTextServicePMCOpenDataTests' body-less Europe PMC deposit route
        StubURLProtocol.routes["fullTextXML"] = (200, Data(bodylessJATS.utf8))
        StubURLProtocol.routes[coreHost] = (200, hit(longText))
        let result = try await makeService().fetchFullText(pmcId: "PMC1", doi: doi, pmid: "1")
        XCTAssertEqual(result.content, .core(text: longText))
        XCTAssertEqual(result.contentKind, .extracted)
        // The control that the abstract was held: Europe PMC served it
        XCTAssertTrue(StubURLProtocol.requested("fullTextXML"))
    }

    /// The control for the test above: without a key the held abstract is
    /// what comes back.
    func testWithoutAKeyTheHeldAbstractStands() async throws {
        StubURLProtocol.routes["fullTextXML"] = (200, Data(bodylessJATS.utf8))
        StubURLProtocol.routes[coreHost] = (200, hit(longText))
        let result = try await makeService(coreAPIKey: nil).fetchFullText(pmcId: "PMC1", doi: doi, pmid: "1")
        XCTAssertEqual(result.source, .europePMC)
        XCTAssertEqual(result.contentKind, .abstract)
    }

    /// Every row of the shared contract's status table gets its outcome here:
    /// 200 serves the text, 401 refuses the key (#498), every other status (404
    /// and 403 included) is unreachable.
    func testEveryStatusRowOfTheContractGetsItsOutcome() async throws {
        let rows = try XCTUnwrap(COREContract.load()["status"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(rows.count, 9, "status table lost rows")
        for row in rows {
            let status = try XCTUnwrap(row["status"] as? Int)
            StubURLProtocol.reset()
            StubURLProtocol.routes[coreHost] = (status, status == 200 ? hit(longText) : Data())
            let fetch = try await makeService(coreThrottle: CoreThrottle())
                .fetchCoreText(doi: doi, apiKey: "test-core-key")
            switch row["outcome"] as? String {
            case "served":
                XCTAssertEqual(fetch, .served(longText), "status \(status)")
            case "key_refused":
                XCTAssertEqual(fetch, .keyRefused, "status \(status)")
            default:
                XCTAssertEqual(fetch, .unreachable(.httpStatus(status)), "status \(status)")
            }
        }
    }

    /// Requests to api.core.ac.uk are paced at ``BioMedLitConstants/coreMinimumInterval``
    /// (0.4 per second), a retry included. A lower bound only, so a slow machine
    /// cannot fail it.
    func testRequestsArePaced() async throws {
        StubURLProtocol.sequences[coreHost] = [(503, Data()), (200, hit(longText))]
        let service = makeService(coreRetry: .oneRetry)
        let start = Date()
        let fetch = try await service.fetchCoreText(doi: doi, apiKey: "test-core-key")
        XCTAssertEqual(fetch, .served(longText))
        XCTAssertEqual(coreRequests, 2)
        // Two requests: one paced gap at the least.
        XCTAssertGreaterThanOrEqual(
            Date().timeIntervalSince(start), BioMedLitConstants.coreMinimumInterval * 0.9
        )
    }
}
