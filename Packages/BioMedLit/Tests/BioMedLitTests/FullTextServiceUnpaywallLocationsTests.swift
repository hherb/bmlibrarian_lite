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

/// Every PDF Unpaywall names is tried, in Unpaywall's order; every failure is
/// told; a copy served but not saved ends the walk with a caching note
/// (#480, stage B; the maintainer's decisions of 2026-10-05).
final class FullTextServiceUnpaywallLocationsTests: XCTestCase {
    private let doi = "10.1/locations"
    private let first = "https://walled.example.org/a.pdf"
    private let second = "https://repo.example.org/b.pdf"
    private let pdfBody = Data("%PDF-1.7\n".utf8) + Data(repeating: 0x30, count: 64)

    /// The article's cache key: no PMID, so the DOI names it.
    private var cacheKey: ArticleCacheKey {
        ArticleCacheKey(pmid: "", pmcId: nil, doi: doi)!
    }

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        FullTextService.deleteCachedPDF(for: cacheKey)
        // Europe PMC knows no record, so the Unpaywall tier decides the outcome
        StubURLProtocol.routes["search"] = (200, Data(#"{"resultList": {"result": []}}"#.utf8))
    }

    override func tearDown() {
        StubURLProtocol.reset()
        FullTextService.deleteCachedPDF(for: cacheKey)
        super.tearDown()
    }

    private func fetch() async throws -> FullTextResult {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        return try await FullTextService(
            email: "test@example.org",
            session: session,
            europePMCService: EuropePMCService(session: session),
            extractor: ExtractingStub()
        ).fetchFullText(pmcId: nil, doi: doi, pmid: "")
    }

    private func unpaywall(_ pdfs: [String]) -> Data {
        let locations = pdfs.map { ["url_for_pdf": $0, "url": $0] }
        let body: [String: Any] = ["best_oa_location": locations.first as Any, "oa_locations": locations]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    func testASecondLocationIsTriedWhenTheFirstIsRefused() async throws {
        StubURLProtocol.routes["unpaywall"] = (200, unpaywall([first, second]))
        StubURLProtocol.routes["walled.example.org"] = (403, Data())
        StubURLProtocol.routes["repo.example.org"] = (200, pdfBody)

        let result = try await fetch()

        XCTAssertEqual(result.content, .unpaywall(pdfURL: URL(string: second)!))
        XCTAssertNil(result.openAccessShortfall, "a served copy settles it")
    }

    func testEveryLocationRefusedIsToldEachByItsHost() async throws {
        StubURLProtocol.routes["unpaywall"] = (200, unpaywall([first, second]))
        StubURLProtocol.routes["walled.example.org"] = (403, Data())
        StubURLProtocol.routes["repo.example.org"] = (503, Data())

        let result = try await fetch()

        XCTAssertEqual(result.content, .doi(webURL: URL(string: "https://doi.org/\(doi)")!))
        XCTAssertEqual(
            result.openAccessShortfall,
            OpenAccessShortfall(source: .pdf, failure: .httpStatus(403), address: first)
                .appending(OpenAccessShortfall(source: .pdf, failure: .httpStatus(503), address: second))
        )
        XCTAssertNil(result.pdfNotSavedFrom, "a refusal is the source's, not a caching problem")
    }

    func testTheRepeatedBestLocationIsRequestedOnce() async throws {
        StubURLProtocol.routes["unpaywall"] = (200, unpaywall([first, first]))
        StubURLProtocol.routes["walled.example.org"] = (403, Data())

        _ = try await fetch()

        // A PDF download retries only transport errors (`.pdfDownload` with
        // `retryOnlyTransient`), so a 403 is one request: two would mean the
        // repeated location was tried twice
        XCTAssertEqual(StubURLProtocol.requestedURLs.filter { $0.contains("walled.example.org") }.count, 1)
    }

    func testAnUnfetchableAddressIsListedAndTheNextTried() async throws {
        StubURLProtocol.routes["unpaywall"] = (200, unpaywall(["ftp://repo.example.org/x.pdf", second]))
        StubURLProtocol.routes["repo.example.org"] = (200, pdfBody)

        let result = try await fetch()

        XCTAssertEqual(result.content, .unpaywall(pdfURL: URL(string: second)!))
        XCTAssertNil(result.openAccessShortfall)
    }

    /// The control for the walk's refusal of an unfetchable address: alone, it
    /// is listed with its address, against the PDF, not Unpaywall.
    func testAnUnfetchableAddressAloneIsListedWithItsAddress() async throws {
        let unfetchable = "ftp://repo.example.org/x.pdf"
        StubURLProtocol.routes["unpaywall"] = (200, unpaywall([unfetchable]))

        let result = try await fetch()

        XCTAssertEqual(
            result.openAccessShortfall,
            OpenAccessShortfall(source: .pdf, failure: .requestFailed, address: unfetchable)
        )
    }

    /// `.notCached` needs a cache write that fails, which no test can cause
    /// (`pdfCacheDirectory` is a fixed location), so the rules are pinned
    /// where the chain applies them.
    func testAServedButUncachedCopySettlesTheQuestion() {
        let refused = OpenAccessShortfall(source: .pdf, failure: .httpStatus(403), address: first)
        XCTAssertNil(FullTextService.settledOpenAccessShortfall(refused, copyServed: true))
        XCTAssertEqual(FullTextService.settledOpenAccessShortfall(refused, copyServed: false), refused)
        let link = FullTextResult(content: .unpaywall(pdfURL: URL(string: second)!), degradation: nil)
            .noting(openAccessShortfall: nil, pdfNotSavedFrom: second)
        XCTAssertNil(link.openAccessShortfall, "the init's assert holds")
        XCTAssertEqual(link.pdfNotSavedFrom, second)
    }
}
