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

/// The Unpaywall tier reads a landing page; it never downloads one as the PDF
/// (#464).
///
/// PMID 40608933's only open-access copy is in a university repository, and
/// Unpaywall gives no `url_for_pdf` for it. The tier took `urlForPdf ?? url`,
/// downloaded the repository's HTML page as the PDF, failed, and returned the
/// page as an Unpaywall full text with no text in it, so the transparency
/// analysis had nothing to read while the reader was shown "View Full Text".
final class UnpaywallLandingPageServiceTests: XCTestCase {
    private static let pdfBytes = Data([0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x34])
    private static let pmid = "landing-page-test-40608933"
    private static let cacheKey = ArticleCacheKey(pmid: pmid, pmcId: nil, doi: nil)!

    private static let landing = "https://repo.example.org/item/95934"
    private static let pdf = "https://repo.example.org/files/Okazaki_2025.pdf"

    /// Unpaywall's answer for the DOI: a landing page and no PDF URL.
    private static let landingOnlyAnswer = #"""
    {"best_oa_location": {"url": "https://repo.example.org/item/95934", "url_for_pdf": null,
                          "url_for_landing_page": "https://repo.example.org/item/95934",
                          "host_type": "repository"},
     "oa_locations": [{"url": "https://repo.example.org/item/95934", "url_for_pdf": null,
                       "url_for_landing_page": "https://repo.example.org/item/95934"}]}
    """#

    private static let declaringPage = #"""
    <head><meta name="citation_pdf_url" content="../files/Okazaki_2025.pdf" /></head>
    """#

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        FullTextService.deleteCachedPDF(for: Self.cacheKey)
    }

    override func tearDown() {
        StubURLProtocol.reset()
        FullTextService.deleteCachedPDF(for: Self.cacheKey)
        super.tearDown()
    }

    private func fetch() async throws -> FullTextResult {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        let service = FullTextService(
            email: "test@example.org",
            session: session,
            europePMCService: EuropePMCService(session: session),
            extractor: ExtractingStub()
        )
        return try await service.fetchFullText(pmcId: nil, doi: "10.1/landing", pmid: Self.pmid)
    }

    /// Europe PMC knows no record, so the Unpaywall tier decides the outcome.
    private func routes(
        unpaywall: String = landingOnlyAnswer,
        page: (Int, String)? = nil
    ) -> [String: (status: Int, body: Data)] {
        var routes: [String: (status: Int, body: Data)] = [
            "search": (200, Data(#"{"resultList": {"result": []}}"#.utf8)),
            "unpaywall": (200, Data(unpaywall.utf8)),
            "Okazaki_2025.pdf": (200, Self.pdfBytes),
        ]
        if let page {
            routes["item/95934"] = (page.0, Data(page.1.utf8))
        }
        return routes
    }

    func testThePDFALandingPageDeclaresIsDownloadedAndRead() async throws {
        StubURLProtocol.routes = routes(page: (200, Self.declaringPage))

        let result = try await fetch()

        XCTAssertEqual(result.source, .unpaywall)
        XCTAssertEqual(result.contentKind, .extracted)
        XCTAssertEqual(result.extractedText, "The article.")
        XCTAssertEqual(result.pdfURL?.absoluteString, Self.pdf)
    }

    /// The defect itself: a page declaring nothing is not the article's PDF,
    /// so the chain ends on the DOI page rather than on the landing page
    /// dressed as an Unpaywall PDF.
    func testALandingPageIsNeverReturnedAsThePDF() async throws {
        StubURLProtocol.routes = routes(page: (200, "<head><title>An item</title></head>"))

        let result = try await fetch()

        XCTAssertNotEqual(result.source, .unpaywall)
        XCTAssertNotEqual(result.pdfURL?.absoluteString, Self.landing)
        XCTAssertEqual(
            StubURLProtocol.requestedURLs.filter { $0.contains("item/95934") }.count, 1,
            "the page is read once, as a page, and never downloaded as a PDF"
        )
    }

    /// A refusal is the page's answer: no PDF, and no retry.
    func testARefusingLandingPageOffersNoPDF() async throws {
        StubURLProtocol.routes = routes(page: (403, "Forbidden"))

        let result = try await fetch()

        XCTAssertNotEqual(result.source, .unpaywall)
        XCTAssertEqual(StubURLProtocol.requestedURLs.filter { $0.contains("item/95934") }.count, 1)
    }

    /// A server fault is retried, and one that outlasts the retries offers no
    /// PDF rather than ending the chain.
    func testAFailingLandingPageIsRetriedThenOffersNoPDF() async throws {
        StubURLProtocol.routes = routes(page: (503, "busy"))

        let result = try await fetch()

        XCTAssertNotEqual(result.source, .unpaywall)
        XCTAssertEqual(
            StubURLProtocol.requestedURLs.filter { $0.contains("item/95934") }.count,
            RetryConfiguration.networkDefault.maxAttempts
        )
    }

    /// The control: a `url_for_pdf` is downloaded without reading any page.
    func testAPDFURLIsUsedWithoutReadingTheLandingPage() async throws {
        let answer = #"{"best_oa_location": {"url": "\#(Self.pdf)", "url_for_pdf": "\#(Self.pdf)", "url_for_landing_page": "\#(Self.landing)"}}"#
        StubURLProtocol.routes = routes(unpaywall: answer, page: (200, Self.declaringPage))

        let result = try await fetch()

        XCTAssertEqual(result.source, .unpaywall)
        XCTAssertEqual(result.pdfURL?.absoluteString, Self.pdf)
        XCTAssertFalse(StubURLProtocol.requested("item/95934"))
    }
}
