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
}

/// OpenAlex is asked for the PDFs Unpaywall did not name, only when no
/// Unpaywall copy was served; each PDF it names is tried once; what it could
/// not settle is told in chain order (#480, stage B; the maintainer's
/// decisions of 2026-10-05).
final class FullTextServiceOpenAlexTests: XCTestCase {
    private let doi = "10.1/locations"
    private let walled = "https://walled.example.org/a.pdf"
    private let repo = "https://repo.example.org/b.pdf"
    private let pdfBody = Data("%PDF-1.7\n".utf8) + Data(repeating: 0x30, count: 64)

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
    }

    override func tearDown() {
        StubURLProtocol.reset()
        FullTextService.deleteCachedPDF(for: cacheKey)
        super.tearDown()
    }

    private func makeService(
        retry: RetryConfiguration = .noRetry,
        email: String = "test@example.org",
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
            writeCachedPDF: writeCachedPDF
        )
    }

    private func fetch(email: String = "test@example.org") async throws -> FullTextResult {
        try await makeService(email: email).fetchFullText(pmcId: nil, doi: doi, pmid: "")
    }

    private func unpaywall(_ pdfs: [String]) -> Data {
        let locations = pdfs.map { ["url_for_pdf": $0, "url": $0] }
        let body: [String: Any] = ["best_oa_location": locations.first as Any, "oa_locations": locations]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    private func openAlex(_ urls: [String]) -> Data {
        let body: [String: Any] = ["locations": urls.map { ["pdf_url": $0] }]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    func testOpenAlexIsNotAskedWhenUnpaywallsPDFServes() async throws {
        StubURLProtocol.routes["unpaywall"] = (200, unpaywall([repo]))
        StubURLProtocol.routes["repo.example.org"] = (200, pdfBody)
        _ = try await fetch()
        XCTAssertFalse(StubURLProtocol.requested("api.openalex.org"))
    }

    func testAPDFOpenAlexNamesServesWhenUnpaywallsIsRefused() async throws {
        StubURLProtocol.routes["unpaywall"] = (200, unpaywall([walled]))
        StubURLProtocol.routes["walled.example.org"] = (403, Data())
        StubURLProtocol.routes["api.openalex.org"] = (200, openAlex([repo]))
        StubURLProtocol.routes["repo.example.org"] = (200, pdfBody)
        let result = try await fetch()
        XCTAssertEqual(result.content, .openAlex(pdfURL: URL(string: repo)!))
        XCTAssertEqual(result.source, .openAlex)
        XCTAssertNil(result.openAccessShortfall)
    }

    /// OpenAlex's copy served and not cached settles the question as
    /// Unpaywall's does: its link is kept, Unpaywall's refusal is not told.
    func testAnOpenAlexCopyNotCachedSettlesTheQuestion() async throws {
        StubURLProtocol.routes["unpaywall"] = (200, unpaywall([walled]))
        StubURLProtocol.routes["walled.example.org"] = (403, Data())
        StubURLProtocol.routes["api.openalex.org"] = (200, openAlex([repo]))
        StubURLProtocol.routes["repo.example.org"] = (200, pdfBody)
        let result = try await makeService(writeCachedPDF: { _, _ in
            throw CocoaError(.fileWriteOutOfSpace)
        }).fetchFullText(pmcId: nil, doi: doi, pmid: "")
        XCTAssertEqual(result.content, .openAlex(pdfURL: URL(string: repo)!))
        XCTAssertNil(result.openAccessShortfall)
        XCTAssertEqual(result.pdfNotSavedFrom, repo)
    }

    func testAPDFBothNameIsRequestedOnce() async throws {
        StubURLProtocol.routes["unpaywall"] = (200, unpaywall([walled]))
        StubURLProtocol.routes["walled.example.org"] = (403, Data())
        StubURLProtocol.routes["api.openalex.org"] = (200, openAlex([walled]))
        _ = try await fetch()
        XCTAssertEqual(StubURLProtocol.requestedURLs.filter { $0.contains("walled.example.org") }.count, 1)
    }

    func testAnUnreachableOpenAlexIsTheShortfallWhenNothingElseIs() async throws {
        StubURLProtocol.routes["unpaywall"] = (404, Data())
        StubURLProtocol.routes["api.openalex.org"] = (503, Data())
        let result = try await fetch()
        XCTAssertEqual(result.content, .doi(webURL: URL(string: "https://doi.org/\(doi)")!))
        XCTAssertEqual(result.openAccessShortfall, OpenAccessShortfall(source: .openAlex, failure: .httpStatus(503)))
    }

    func testOpenAlexKnowingNoWorkAddsNothing() async throws {
        StubURLProtocol.routes["unpaywall"] = (404, Data())
        // the default fallback route answers OpenAlex 404
        let result = try await fetch()
        XCTAssertNil(result.openAccessShortfall)
        XCTAssertTrue(StubURLProtocol.requested("api.openalex.org"))
    }

    func testARefusedOpenAlexPDFIsRecordedUnderItsCopy() async throws {
        StubURLProtocol.routes["unpaywall"] = (404, Data())
        StubURLProtocol.routes["api.openalex.org"] = (200, openAlex([repo]))
        StubURLProtocol.routes["repo.example.org"] = (403, Data())
        let result = try await fetch()
        XCTAssertEqual(
            result.openAccessShortfall,
            OpenAccessShortfall(source: .openAlexPDF, failure: .httpStatus(403), address: repo)
        )
    }

    func testEveryRefusalIsToldInChainOrder() async throws {
        StubURLProtocol.routes["unpaywall"] = (200, unpaywall([walled]))
        StubURLProtocol.routes["walled.example.org"] = (403, Data())
        StubURLProtocol.routes["api.openalex.org"] = (200, openAlex([repo]))
        StubURLProtocol.routes["repo.example.org"] = (404, Data())
        let result = try await fetch()
        XCTAssertEqual(
            result.openAccessShortfall?.notice,
            "Failed to obtain a PDF from the following tried sources: walled.example.org, named by Unpaywall "
                + "(HTTP 403 Forbidden); repo.example.org, named by OpenAlex (HTTP 404 Not Found). "
                + "Whether this document is open access was not established."
        )
    }

    func testTheRequestIsTheContracts() async throws {
        StubURLProtocol.routes["unpaywall"] = (404, Data())
        _ = try await fetch(email: "test@example.org")
        let asked = try XCTUnwrap(StubURLProtocol.requestedURLs.first { $0.contains("api.openalex.org") })
        XCTAssertEqual(
            asked,
            "https://api.openalex.org/works/doi:10.1%2Flocations?select=locations&mailto=test%40example.org"
        )
    }

    /// The control for the contact: a blank email asks without `mailto`.
    func testABlankEmailAsksWithoutMailto() async throws {
        StubURLProtocol.routes["unpaywall"] = (404, Data())
        _ = try? await fetch(email: "  ")
        let asked = try XCTUnwrap(StubURLProtocol.requestedURLs.first { $0.contains("api.openalex.org") })
        XCTAssertEqual(asked, "https://api.openalex.org/works/doi:10.1%2Flocations?select=locations")
    }

    func testTheContractsStatuses() async throws {
        let rows = try XCTUnwrap(OpenAlexContract.load()["status"] as? [[String: Any]])
        XCTAssertFalse(rows.isEmpty, "an empty table would pass vacuously")
        for row in rows {
            StubURLProtocol.reset()
            let status = row["status"] as! Int
            StubURLProtocol.routes["api.openalex.org"] = (
                status, status == 200 ? openAlex([repo]) : Data()
            )
            let fetch = try await makeService(retry: .noRetry).fetchOpenAlexPDFURLs(doi: doi)
            switch row["outcome"] as! String {
            case "served": XCTAssertEqual(fetch, .served([repo]), "\(status)")
            case "absent": XCTAssertEqual(fetch, .absent, "\(status)")
            default: XCTAssertEqual(fetch, .unreachable(.httpStatus(status)), "\(status)")
            }
        }
    }

    func testAnAnswerWeCannotReadIsMalformed() async throws {
        StubURLProtocol.routes["api.openalex.org"] = (200, Data("not json".utf8))
        let fetch = try await makeService(retry: .noRetry).fetchOpenAlexPDFURLs(doi: doi)
        XCTAssertEqual(fetch, .unreachable(.malformedResponse))
    }

    func testATransportFailureIsUnreachableOfItsKind() async throws {
        StubURLProtocol.failures["api.openalex.org"] = URLError(.timedOut)
        let fetch = try await makeService(retry: .noRetry).fetchOpenAlexPDFURLs(doi: doi)
        XCTAssertEqual(fetch, .unreachable(.timeout))
    }

    func testNoDOINoOpenAlex() async throws {
        _ = try? await makeService().fetchFullText(pmcId: nil, doi: nil, pmid: "123")
        XCTAssertFalse(StubURLProtocol.requested("api.openalex.org"))
    }
}
