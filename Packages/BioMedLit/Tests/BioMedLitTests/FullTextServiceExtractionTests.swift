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
/// `fullTextContent = nil` for it, so transparency analysis and report
/// generation saw nothing at all for a PDF-sourced article.
final class FullTextServiceExtractionTests: XCTestCase {
    private static let bodyless = Data("""
    <article><front><article-meta>
      <title-group><article-title>A trial</article-title></title-group>
      <abstract><p>Background and findings only.</p></abstract>
    </article-meta></front></article>
    """.utf8)

    private static let pdfBytes = Data([0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x34])

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

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testAnUnpaywallPDFContributesItsText() async throws {
        stubUnpaywallAndPDF()
        let extractor = StubExtractor(result: PDFExtractionResult(
            text: "Recovered prose.", success: true, pageCount: 1, convertedPages: 1, warnings: []
        ))
        let result = try await makeService(extractor: extractor)
            .fetchFullText(pmcId: nil, doi: "10.1/x", pmid: "1")

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
            .fetchFullText(pmcId: nil, doi: "10.1/x", pmid: "1")

        XCTAssertEqual(result.source, .unpaywall)
        XCTAssertEqual(result.contentKind, FullTextContentKind.none)
        XCTAssertNil(result.extractedText)
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
            .fetchFullText(pmcId: "PMC1", doi: "10.1/x", pmid: "1")

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
            .fetchFullText(pmcId: "PMC1", doi: "10.1/x", pmid: "1")

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
            .fetchFullText(pmcId: nil, doi: "10.1/x", pmid: "1")

        XCTAssertEqual(result.source, .unpaywall)
        XCTAssertEqual(result.contentKind, FullTextContentKind.none)
        XCTAssertNil(result.extractedText)
        XCTAssertNil(result.localPDFPath)
        XCTAssertNotNil(result.pdfURL, "the reader can still open it")
    }
}
