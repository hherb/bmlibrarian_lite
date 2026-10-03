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
    /// The DOI link the chain falls back to for `fetch()`'s DOI.
    private static let doiLink = URL(string: "https://doi.org/10.1/landing")!

    /// Unpaywall's answer for the DOI: a landing page and no PDF URL.
    private static let landingOnlyAnswer = #"""
    {"best_oa_location": {"url": "https://repo.example.org/item/95934", "url_for_pdf": null,
                          "url_for_landing_page": "https://repo.example.org/item/95934",
                          "host_type": "repository"},
     "oa_locations": [{"url": "https://repo.example.org/item/95934", "url_for_pdf": null,
                       "url_for_landing_page": "https://repo.example.org/item/95934"}]}
    """#

    /// A Europe PMC deposit with an abstract and no body.
    private static let abstractOnlyDeposit = Data("""
    <article><front><article-meta>
      <title-group><article-title>A trial</article-title></title-group>
      <abstract><p>Background and findings only.</p></abstract>
    </article-meta></front></article>
    """.utf8)

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

    private func fetch(
        email: String = "test@example.org", pmcId: String? = nil
    ) async throws -> FullTextResult {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        let service = FullTextService(
            email: email,
            session: session,
            europePMCService: EuropePMCService(session: session),
            extractor: ExtractingStub()
        )
        return try await service.fetchFullText(pmcId: pmcId, doi: "10.1/landing", pmid: Self.pmid)
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

    /// An answer below 400 is decoded, as Python's `raise_for_status` lets it
    /// through: a 204's empty body could not be read, and is no error status
    /// Unpaywall answered with ("did not serve it").
    func testAnEmptyUnpaywallAnswerIsUnreadableNotAnAnswer() async throws {
        StubURLProtocol.routes = routes(unpaywall: "", unpaywallStatus: 204)

        let result = try await fetch()

        XCTAssertEqual(
            result.openAccessShortfall,
            OpenAccessShortfall(source: .unpaywall, failure: .malformedResponse)
        )
    }

    /// Unpaywall refuses a missing address with 422, which would read as
    /// "Unpaywall did not serve it": not asked, it is reported as not configured,
    /// with the advice that goes with that (#466).
    func testAnUnpaywallWithNoEmailIsNotAskedAndIsReportedAsNotConfigured() async throws {
        StubURLProtocol.routes = routes()

        let result = try await fetch(email: "  ")

        XCTAssertEqual(result.openAccessShortfall, .unpaywallNotConfigured)
        XCTAssertFalse(StubURLProtocol.requested("unpaywall"))
    }

    /// The abstract the chain falls back to carries the shortfall too: it is no
    /// more an answer about a free copy than the publisher link is.
    func testTheAbstractFallbackCarriesTheShortfall() async throws {
        var stubs = routes(unpaywallStatus: 503)
        stubs["fullTextXML"] = (200, Self.abstractOnlyDeposit)
        StubURLProtocol.routes = stubs

        let result = try await fetch(pmcId: "PMC1")

        XCTAssertEqual(result.contentKind, .abstract)
        XCTAssertEqual(
            result.openAccessShortfall,
            OpenAccessShortfall(source: .unpaywall, failure: .httpStatus(503))
        )
    }

    /// A PDF link the chain could not download carries the shortfall too: a
    /// link to a copy we did not fetch says nothing about a free one (#475).
    func testAnUndownloadedPDFLinkCarriesTheShortfall() async throws {
        let render = "https://europepmc.org/articles/PMC12759138?pdf=render"
        let search = #"""
        {"resultList": {"result": [{
          "id": "1", "pmid": "1", "pmcid": "PMC12759138", "inPMC": "Y",
          "fullTextUrlList": {"fullTextUrl": [
            {"documentStyle": "pdf", "site": "Europe_PMC", "url": "\#(render)",
             "availability": "Open access", "availabilityCode": "OA"}
          ]}
        }]}}
        """#
        var stubs = routes(unpaywallStatus: 503)
        stubs["search"] = (200, Data(search.utf8))
        stubs["fullTextXML"] = (404, Data())
        stubs["pdf=render"] = (403, Data("Forbidden".utf8))
        StubURLProtocol.routes = stubs

        let result = try await fetch()

        guard case .europePMCPDF(let pdfURL) = result.content else {
            return XCTFail("expected the undownloaded render link, got \(result.content)")
        }
        XCTAssertEqual(pdfURL.absoluteString, render)
        XCTAssertNil(result.localPDFPath, "the render was refused, so nothing was downloaded")
        XCTAssertEqual(
            result.openAccessShortfall,
            OpenAccessShortfall(source: .unpaywall, failure: .httpStatus(503))
        )
    }

    /// A landing page whose address cannot be fetched is a page we did not
    /// read, not one that declares no PDF: Python's `requests` refuses the
    /// same addresses and records a failed request (#474).
    func testALandingPageThatCannotBeFetchedIsUnsettled() async throws {
        for address in ["ftp://repo.example.org/item/95934", "/item/95934", "file:///item/95934"] {
            StubURLProtocol.reset()
            let answer = #"{"best_oa_location": {"url": "\#(address)", "url_for_pdf": null}}"#
            StubURLProtocol.routes = routes(unpaywall: answer)

            let result = try await fetch()

            XCTAssertEqual(result.content, .doi(webURL: Self.doiLink), address)
            XCTAssertEqual(
                result.openAccessShortfall,
                OpenAccessShortfall(source: .landingPage, failure: .requestFailed),
                address
            )
            XCTAssertEqual(landingPageReads, 0, address)
        }
    }

    /// The same for a `url_for_pdf`: Unpaywall named a copy we cannot fetch,
    /// which leaves it unassessed (#474). The address is never asked for, and
    /// the reader gets the DOI link rather than a link we will not open.
    func testAPDFAddressThatCannotBeFetchedIsUnsettled() async throws {
        let answer = #"{"best_oa_location": {"url_for_pdf": "ftp://repo.example.org/a.pdf"}}"#
        StubURLProtocol.routes = routes(unpaywall: answer)

        let result = try await fetch()

        XCTAssertEqual(result.content, .doi(webURL: Self.doiLink))
        XCTAssertEqual(
            result.openAccessShortfall,
            OpenAccessShortfall(source: .unpaywall, failure: .requestFailed)
        )
        XCTAssertFalse(StubURLProtocol.requested("repo.example.org/a.pdf"))
    }

    /// The control: an absolute http(s) address is accepted, whatever case
    /// its scheme is written in.
    func testAFetchableAddressIsAnAbsoluteHTTPURL() {
        XCTAssertNotNil(UnpaywallLandingPage.fetchableURL(Self.landing))
        XCTAssertNotNil(UnpaywallLandingPage.fetchableURL("HTTP://repo.example.org/a"))
        for address in ["ftp://repo.example.org/a", "/a", "repo.example.org/a", "https://", "mailto:a@b.org"] {
            XCTAssertNil(UnpaywallLandingPage.fetchableURL(address), address)
        }
    }

    /// The chain refuses to call a full text absent while the Unpaywall tier
    /// left a free copy unassessed, as it does for Europe PMC (#475). Tested
    /// on the decision itself: every fallback the chain returns after the
    /// tier carries the shortfall, so it reaches the decision with one only
    /// when no fallback at all could be built, and the DOI link always builds
    /// on the iOS 17 / macOS 14 Foundation, which percent-encodes what it
    /// would once have refused.
    func testAnExhaustedChainWithAnUnsettledCopyIsNotAnAbsence() {
        let shortfall = OpenAccessShortfall(source: .unpaywall, failure: .httpStatus(429))
        let error = FullTextService.exhaustedChainError(
            primarySlot: "", primaryKind: nil, europePMCShortfall: nil,
            openAccessShortfall: shortfall, articleName: "a test article"
        )

        guard case .openAccessNotEstablished(let carried) = error else {
            return XCTFail("expected openAccessNotEstablished, got \(error)")
        }
        XCTAssertEqual(carried, shortfall)
        XCTAssertFalse(error.isRetryable)
        XCTAssertEqual(
            error.errorDescription,
            "No source provided this article's full text. Unpaywall (HTTP 429 Too Many Requests) "
                + "could not be asked, so a freely available copy may exist. Whether this document "
                + "is open access was not established."
        )
    }

    /// An unclassified primary slot is named before either shortfall, Europe
    /// PMC's before the open-access one (#434), and with nothing unsettled the
    /// chain's answer is an absence: the controls.
    func testAnExhaustedChainNamesEuropePMCFirstAndOtherwiseIsAnAbsence() {
        let unclassified = FullTextService.exhaustedChainError(
            primarySlot: "889149", primaryKind: nil, europePMCShortfall: .timeout,
            openAccessShortfall: .unpaywallNotConfigured, articleName: "a test article"
        )
        guard case .identifierKindUnresolved("889149") = unclassified else {
            return XCTFail("expected the unresolved kind, got \(unclassified)")
        }

        let both = FullTextService.exhaustedChainError(
            primarySlot: "", primaryKind: nil, europePMCShortfall: .timeout,
            openAccessShortfall: .unpaywallNotConfigured, articleName: "a test article"
        )
        guard case .absenceNotEstablished(.timeout) = both else {
            return XCTFail("expected Europe PMC's shortfall, got \(both)")
        }

        let neither = FullTextService.exhaustedChainError(
            primarySlot: "", primaryKind: nil, europePMCShortfall: nil,
            openAccessShortfall: nil, articleName: "a test article"
        )
        guard case .noFullTextAvailable = neither else {
            return XCTFail("expected noFullTextAvailable, got \(neither)")
        }
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
