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
        unpaywallStatus: Int = 200,
        page: (Int, String)? = nil
    ) -> [String: (status: Int, body: Data)] {
        var routes: [String: (status: Int, body: Data)] = [
            "search": (200, Data(#"{"resultList": {"result": []}}"#.utf8)),
            "unpaywall": (unpaywallStatus, Data(unpaywall.utf8)),
            "Okazaki_2025.pdf": (200, Self.pdfBytes),
        ]
        if let page {
            routes["item/95934"] = (page.0, Data(page.1.utf8))
        }
        return routes
    }

    /// How many times the landing page was asked for.
    private var landingPageReads: Int {
        StubURLProtocol.requestedURLs.filter { $0.contains("item/95934") }.count
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
            landingPageReads, 1,
            "the page is read once, as a page, and never downloaded as a PDF"
        )
        XCTAssertNil(result.openAccessShortfall, "a page that declares nothing has answered")
    }

    /// A refusal is the page's answer: no PDF, no retry, nothing unsettled.
    func testARefusingLandingPageOffersNoPDF() async throws {
        StubURLProtocol.routes = routes(page: (403, "Forbidden"))

        let result = try await fetch()

        XCTAssertNotEqual(result.source, .unpaywall)
        XCTAssertEqual(landingPageReads, 1)
        XCTAssertNil(result.openAccessShortfall)
    }

    /// A server fault is retried, and one that outlasts the retries is a page
    /// that could not answer: the chain goes on, and its fallback says so.
    func testAFailingLandingPageIsRetriedThenLeftUnsettled() async throws {
        StubURLProtocol.routes = routes(page: (503, "busy"))

        let result = try await fetch()

        XCTAssertNotEqual(result.source, .unpaywall)
        XCTAssertEqual(landingPageReads, RetryConfiguration.networkDefault.maxAttempts)
        XCTAssertEqual(
            result.openAccessShortfall,
            OpenAccessShortfall(source: .landingPage, failure: .httpStatus(503))
        )
    }

    /// A 501 is no throttle, so it is not retried, but it is still a server
    /// fault and not the page's answer (Python's `web_page_status_unsettled`).
    func testAnUnretriedServerFaultIsStillUnsettled() async throws {
        StubURLProtocol.routes = routes(page: (501, "not implemented"))

        let result = try await fetch()

        XCTAssertEqual(landingPageReads, 1)
        XCTAssertEqual(
            result.openAccessShortfall,
            OpenAccessShortfall(source: .landingPage, failure: .httpStatus(501))
        )
    }

    /// A page that cannot be reached is not a page without a PDF.
    func testAnUnreachableLandingPageIsUnsettled() async throws {
        StubURLProtocol.routes = routes()
        StubURLProtocol.failures = ["item/95934": URLError(.timedOut)]

        let result = try await fetch()

        XCTAssertNotEqual(result.source, .unpaywall)
        XCTAssertEqual(
            result.openAccessShortfall, OpenAccessShortfall(source: .landingPage, failure: .timeout)
        )
    }

    /// Cancelled while reading the page: the cancellation propagates, rather
    /// than reading as a page without a PDF and ending on the DOI link.
    func testCancellingWhileReadingTheLandingPagePropagates() async {
        StubURLProtocol.routes = routes()
        StubURLProtocol.failures = ["item/95934": URLError(.cancelled)]

        do {
            _ = try await fetch()
            XCTFail("a cancelled landing-page read returned a result")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    /// The base a relative PDF resolves against is the page served after
    /// redirects, not the handle asked for: the handle.net case of #464.
    func testARelativePDFResolvesAgainstThePageServedAfterRedirects() async throws {
        let final = "https://repo.example.org/view/abc/page"
        StubURLProtocol.routes = routes()
        StubURLProtocol.redirects = ["item/95934": final]
        StubURLProtocol.routes["view/abc/page"] = (
            200, Data(#"<meta name="citation_pdf_url" content="./Okazaki_2025.pdf">"#.utf8)
        )

        let result = try await fetch()

        XCTAssertEqual(
            result.pdfURL?.absoluteString, "https://repo.example.org/view/abc/Okazaki_2025.pdf"
        )
    }

    /// A "landing page" served as a PDF is the PDF: a bitstream link.
    func testALandingPageServedAsAPDFIsThePDF() async throws {
        StubURLProtocol.routes = routes()
        StubURLProtocol.routes["item/95934"] = (200, Self.pdfBytes)
        StubURLProtocol.headers = ["item/95934": ["Content-Type": "application/pdf"]]

        let result = try await fetch()

        XCTAssertEqual(result.source, .unpaywall)
        XCTAssertEqual(result.pdfURL?.absoluteString, Self.landing)
        XCTAssertEqual(result.extractedText, "The article.")
    }

    /// Neither HTML nor a PDF: the page's answer that it declares nothing,
    /// and its body is not read for a tag.
    func testALandingPageOfAnotherTypeDeclaresNothing() async throws {
        StubURLProtocol.routes = routes(page: (200, Self.declaringPage))
        StubURLProtocol.headers = ["item/95934": ["Content-Type": "application/json"]]

        let result = try await fetch()

        XCTAssertNotEqual(result.source, .unpaywall)
        XCTAssertNil(result.openAccessShortfall)
    }

    /// A page is read only up to its cap: a tag past it is not seen.
    func testALandingPageIsReadOnlyUpToItsCap() async throws {
        let padding = "<!--" + String(repeating: "x", count: BioMedLitConstants.landingPageMaxBytes) + "-->"
        StubURLProtocol.routes = routes(page: (200, padding + Self.declaringPage))

        let result = try await fetch()

        XCTAssertNotEqual(result.source, .unpaywall)
        XCTAssertNil(result.openAccessShortfall)
    }

    /// The control: the same padding after the tag leaves it readable.
    func testATagBeforeTheCapIsRead() async throws {
        let padding = "<!--" + String(repeating: "x", count: BioMedLitConstants.landingPageMaxBytes) + "-->"
        StubURLProtocol.routes = routes(page: (200, Self.declaringPage + padding))

        let result = try await fetch()

        XCTAssertEqual(result.pdfURL?.absoluteString, Self.pdf)
    }

    /// A page is read by the charset it declares, not always as UTF-8.
    func testALandingPageIsReadByItsDeclaredCharset() async throws {
        let page = #"<meta name="citation_pdf_url" content="/files/論文.pdf">"#
        StubURLProtocol.routes = routes()
        StubURLProtocol.routes["item/95934"] = (200, page.data(using: .shiftJIS)!)
        StubURLProtocol.headers = ["item/95934": ["Content-Type": "text/html; charset=Shift_JIS"]]

        _ = try await fetch()

        XCTAssertTrue(
            StubURLProtocol.requested("/files/%E8%AB%96%E6%96%87.pdf"),
            "\(StubURLProtocol.requestedURLs)"
        )
    }

    /// Unpaywall itself throttled past its retries: unsettled, not "no copy".
    func testAThrottledUnpaywallIsUnsettled() async throws {
        StubURLProtocol.routes = routes(unpaywallStatus: 429)

        let result = try await fetch()

        XCTAssertEqual(
            result.openAccessShortfall,
            OpenAccessShortfall(source: .unpaywall, failure: .httpStatus(429))
        )
        XCTAssertFalse(StubURLProtocol.requested("item/95934"))
    }

    /// Any error status but 404 leaves the copy unassessed, as Python records it:
    /// a 408 is an answer ("did not serve it"), a 501 or a Cloudflare 520 is
    /// not, and neither says Unpaywall holds no copy (#466).
    func testAnyUnpaywallErrorStatusButNotFoundIsUnsettled() async throws {
        for status in [408, 403, 501, 520] {
            StubURLProtocol.routes = routes(unpaywallStatus: status)

            let result = try await fetch()

            XCTAssertEqual(
                result.openAccessShortfall,
                OpenAccessShortfall(source: .unpaywall, failure: .httpStatus(status)),
                "HTTP \(status)"
            )
        }
    }

    /// An Unpaywall answer that will not decode has told us nothing.
    func testAnUnreadableUnpaywallAnswerIsUnsettled() async throws {
        StubURLProtocol.routes = routes(unpaywall: "<html>maintenance</html>")

        let result = try await fetch()

        XCTAssertEqual(
            result.openAccessShortfall,
            OpenAccessShortfall(source: .unpaywall, failure: .malformedResponse)
        )
    }

    /// The control: Unpaywall's 404 is its answer that it knows no copy.
    func testUnpaywallKnowingNoCopyLeavesNothingUnsettled() async throws {
        StubURLProtocol.routes = routes(unpaywallStatus: 404)

        let result = try await fetch()

        XCTAssertNil(result.openAccessShortfall)
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
