// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2025 Dr Horst Herb
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

/// Serves a fixed extraction result, so the tier logic can be tested without a
/// real PDF and without PDFKit's behaviour being part of the subject.
private struct StubExtractor: PDFTextExtracting {
    let result: PDFExtractionResult
    func extract(from fileURL: URL) -> PDFExtractionResult { result }
}

/// A PDF used to reach the reader and stop there: `applyFullTextResult` set
/// `fullTextContent = nil` for it, so transparency analysis saw nothing at all
/// for a PDF-sourced article.
final class FullTextServiceExtractionTests: XCTestCase {
    private static let bodyless = Data("""
    <article><front><article-meta>
      <title-group><article-title>A trial</article-title></title-group>
      <abstract><p>Background and findings only.</p></abstract>
    </article-meta></front></article>
    """.utf8)

    private static let pdfBytes = Data([0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x34])

    /// A Europe PMC search result that names both a PMC ID and a free PDF render
    /// URL, so identifier resolution (which only `pmcId: nil` triggers) yields
    /// the `pdfRenderURL` the Europe PMC PDF branch needs — the only route to
    /// that branch, since a caller cannot pass `pdfRenderURL` directly.
    private static let searchResponseWithPDFRender = #"""
    {"resultList": {"result": [{
      "id": "1", "pmid": "42", "pmcid": "PMC1", "inPMC": "Y",
      "fullTextUrlList": {"fullTextUrl": [
        {"documentStyle": "pdf", "site": "Europe_PMC",
         "url": "https://europepmc.org/articles/PMC1/pdf",
         "availability": "Open access", "availabilityCode": "OA"}
      ]}
    }]}}
    """#

    private func makeService(
        extractor: PDFTextExtracting,
        extractPDFText: Bool = true
    ) -> FullTextService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        // The identifier resolver gets the same stubbed session as the service
        // itself. Left at its default, `EuropePMCService()` opens a real
        // `URLSession` of its own, so every test below that passes `pmcId: nil`
        // (which is most of them) would resolve over the live network instead
        // of `StubURLProtocol` — slow at best, and a hang with no connectivity.
        return FullTextService(
            email: "test@example.org",
            session: session,
            europePMCService: EuropePMCService(session: session),
            extractor: extractor,
            extractPDFText: extractPDFText
        )
    }

    private func stubUnpaywallAndPDF() {
        StubURLProtocol.routes = [
            "unpaywall": (200, Data(#"{"best_oa_location":{"url_for_pdf":"https://example.org/a.pdf"}}"#.utf8)),
            "a.pdf": (200, Self.pdfBytes),
        ]
    }

    /// The PMID most tests in this file fetch for.
    ///
    /// Deliberately not a number. The service caches into the *real* user
    /// Application Support directory, and `clearCache` deletes every entry for
    /// these identifiers — so naming them "1" and "42", as this once did, meant
    /// running the suite destroyed the cached PDFs of two real PubMed articles
    /// on the developer's own machine. No real article has this identifier.
    private static let primaryPMID = "extraction-test-99001"

    /// A second PMID, for the one test that must not share a cache entry with
    /// the rest.
    private static let secondaryPMID = "extraction-test-99002"

    /// Every PMID any test in this file fetches for.
    ///
    /// Cleared before and after each test: these leave files on the machine
    /// that runs them otherwise, and once `downloadAndCachePDF` consults the
    /// cache, a leftover entry from an earlier run silently skips the download
    /// a later test is asserting on.
    private static let cachedPMIDs = [primaryPMID, secondaryPMID]

    private static func clearCache() {
        for pmid in cachedPMIDs {
            // Through the service's own deletion, which knows that one article
            // holds an entry per source URL and that quarantined entries carry
            // a second extension. Rebuilding the filename here would have to
            // repeat the key derivation, and would silently stop matching the
            // day that changed.
            FullTextService.deleteCachedPDF(for: pmid)
        }
    }

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        Self.clearCache()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        Self.clearCache()
        super.tearDown()
    }

    func testAnUnpaywallPDFContributesItsText() async throws {
        stubUnpaywallAndPDF()
        let extractor = StubExtractor(result: PDFExtractionResult(
            text: "Recovered prose.", success: true, pageCount: 1, convertedPages: 1, warnings: []
        ))
        let result = try await makeService(extractor: extractor)
            .fetchFullText(pmcId: nil, doi: "10.1/x", pmid: Self.primaryPMID)

        XCTAssertEqual(result.source, .unpaywall)
        XCTAssertEqual(result.contentKind, .extracted)
        XCTAssertEqual(result.extractedText, "Recovered prose.")
        XCTAssertNotNil(result.localPDFPath, "the PDF is cached, and the viewer opens the file")
    }

    /// A scan. The link is still worth having, and claiming extracted text for
    /// it would be a lie the analyzer would act on.
    func testAPDFThatYieldsNothingContributesNoText() async throws {
        stubUnpaywallAndPDF()
        let extractor = StubExtractor(result: PDFExtractionResult(
            text: "", success: true, pageCount: 3, convertedPages: 0, warnings: ["page 1 yielded no text"]
        ))
        let result = try await makeService(extractor: extractor)
            .fetchFullText(pmcId: nil, doi: "10.1/x", pmid: Self.primaryPMID)

        XCTAssertEqual(result.source, .unpaywall)
        XCTAssertEqual(result.contentKind, FullTextContentKind.none)
        XCTAssertNil(result.extractedText)
        XCTAssertNotNil(
            result.localPDFPath,
            "the file downloaded and cached fine; only extraction came up empty"
        )
    }

    /// And when an abstract was held back, it is better than nothing — bmlib's
    /// rule that a PDF tier succeeds as soon as it has a URL, so a download that
    /// gave no text must not discard an abstract already in hand.
    func testAPDFThatYieldsNothingFallsBackToTheHeldAbstract() async throws {
        StubURLProtocol.stubbed = (200, Self.bodyless)
        StubURLProtocol.routes = [
            "unpaywall": (200, Data(#"{"best_oa_location":{"url_for_pdf":"https://example.org/a.pdf"}}"#.utf8)),
            "a.pdf": (200, Self.pdfBytes),
        ]
        let extractor = StubExtractor(result: PDFExtractionResult(
            text: "", success: false, pageCount: 0, convertedPages: 0, warnings: [],
            errorMessage: "the PDF is password-protected"
        ))
        let result = try await makeService(extractor: extractor)
            .fetchFullText(pmcId: "PMC1", doi: "10.1/x", pmid: Self.primaryPMID)

        XCTAssertEqual(result.contentKind, .abstract)
        XCTAssertNotNil(result.markdown)
    }

    /// The positive counterpart, moved here from Task 4: a held abstract must
    /// not beat a PDF tier that genuinely recovers text. Only this task can make
    /// that case, because only here does a stub extractor let the PDF tier
    /// actually succeed — Task 4 could only prove what happens when it does not.
    func testAPDFBeatsAHeldAbstract() async throws {
        StubURLProtocol.stubbed = (200, Self.bodyless)
        stubUnpaywallAndPDF()
        let extractor = StubExtractor(result: PDFExtractionResult(
            text: "Recovered prose.", success: true, pageCount: 1, convertedPages: 1, warnings: []
        ))
        let result = try await makeService(extractor: extractor)
            .fetchFullText(pmcId: "PMC1", doi: "10.1/x", pmid: Self.primaryPMID)

        XCTAssertEqual(result.source, .unpaywall)
        XCTAssertEqual(result.contentKind, .extracted)
        XCTAssertEqual(result.extractedText, "Recovered prose.")
    }

    /// The flag turns the download off entirely, mirroring bmlib's
    /// `convert_pdfs`. The link still comes back.
    func testTheFlagOffReturnsTheLinkAlone() async throws {
        stubUnpaywallAndPDF()
        let extractor = StubExtractor(result: PDFExtractionResult(
            text: "Recovered prose.", success: true, pageCount: 1, convertedPages: 1, warnings: []
        ))
        let result = try await makeService(extractor: extractor, extractPDFText: false)
            .fetchFullText(pmcId: nil, doi: "10.1/x", pmid: Self.primaryPMID)

        XCTAssertEqual(result.source, .unpaywall)
        XCTAssertEqual(result.contentKind, FullTextContentKind.none)
        XCTAssertNil(result.extractedText)
        XCTAssertNil(result.localPDFPath)
        XCTAssertNotNil(result.pdfURL, "the reader can still open it")
    }

    /// The Europe PMC PDF tier's own fall-through, not the Unpaywall tier's.
    ///
    /// Every test above reaches a PDF tier through Unpaywall, so the Europe PMC
    /// PDF branch's `if text == nil, abstractOnly != nil` fall-through — the
    /// branch that used to `return` unconditionally, the load-bearing defect
    /// Task 4's review flagged — was only verified by reading. `pmcId: nil` with
    /// no explicit PMC ID forces identifier resolution, which is the only way to
    /// populate `pdfRenderURL` and so the only way a test reaches this branch.
    func testAnEuropePMCPDFThatYieldsNothingFallsBackToTheHeldAbstract() async throws {
        // A pmid this file's other tests do not use. `setUp` clears it, so a
        // stale cache file from a previous run cannot make the download
        // assertion below pass for the wrong reason.
        let pmid = Self.secondaryPMID
        // Named through the service's own key derivation, not rebuilt here: an
        // entry is keyed on the source URL as well as the article, and a
        // hand-built `<pmid>.pdf` would look for a file that is never written.
        let renderURL = URL(string: "https://europepmc.org/articles/PMC1/pdf")!
        let cachedFile = FullTextService.pdfCacheDirectory
            .appendingPathComponent(
                FullTextService.cacheFilename(pmid: pmid, url: renderURL)
            )

        StubURLProtocol.routes = [
            "search": (200, Data(Self.searchResponseWithPDFRender.utf8)),
            "fullTextXML": (200, Self.bodyless),
            "articles/PMC1/pdf": (200, Self.pdfBytes),
        ]
        let extractor = StubExtractor(result: PDFExtractionResult(
            text: "", success: true, pageCount: 2, convertedPages: 0,
            warnings: ["page 1 yielded no text", "page 2 yielded no text"]
        ))
        // No DOI, so a bug that skipped the Europe PMC PDF branch entirely could
        // not be masked by falling through to an Unpaywall tier instead.
        let result = try await makeService(extractor: extractor)
            .fetchFullText(pmcId: nil, doi: nil, pmid: pmid)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: cachedFile.path),
            "the Europe PMC PDF must actually have been downloaded (and so extracted) "
                + "for this to test the tier's fall-through rather than a branch that "
                + "pdfRenderURL resolution failed to reach"
        )
        XCTAssertEqual(
            result.contentKind, .abstract,
            "a no-text extraction from this tier must not beat the held abstract"
        )
        XCTAssertNotNil(result.markdown)
    }

    /// The critical case: a cancellation during the PDF *binary* download must
    /// propagate like every other cancellation in this file, not be swallowed
    /// the way an ordinary download failure is. Collapsing the two would let a
    /// cancelled fetch return a normal, non-throwing link-only result — which a
    /// caller then caches as this article's full text for a fetch it never
    /// actually completed.
    ///
    /// `StubURLProtocol.failures` isolates the one call this guards: the
    /// Unpaywall JSON answers normally, so only `downloadAndCachePDF`'s
    /// `session.data(from:)` for the PDF binary itself is cancelled.
    func testACancelledPDFDownloadDoesNotFallThrough() async {
        StubURLProtocol.routes = [
            "unpaywall": (200, Data(#"{"best_oa_location":{"url_for_pdf":"https://example.org/a.pdf"}}"#.utf8)),
        ]
        StubURLProtocol.failures = ["a.pdf": URLError(.cancelled)]
        let extractor = StubExtractor(result: PDFExtractionResult(
            text: "Recovered prose.", success: true, pageCount: 1, convertedPages: 1, warnings: []
        ))

        do {
            _ = try await makeService(extractor: extractor)
                .fetchFullText(pmcId: nil, doi: "10.1/x", pmid: Self.primaryPMID)
            XCTFail("a cancelled PDF download returned a fallback instead of propagating")
        } catch {
            XCTAssertTrue(
                error is CancellationError,
                "expected cancellation to propagate, got \(error)"
            )
        }
    }
}
