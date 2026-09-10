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

/// Serves a fixed extraction result, so the tier logic can be tested without a
/// real PDF.
private struct StubExtractor: PDFTextExtracting {
    let result: PDFExtractionResult
    func extract(from fileURL: URL) -> PDFExtractionResult { result }
}

/// How much of a PDF yielded text has to reach the *caller*, not only the log.
///
/// This is #181 on a second channel. The parse-warnings channel exists because a
/// truncated JATS render was displayed exactly like a whole article; extraction
/// then reintroduced the same silence for PDFs, computing `convertedPages`,
/// `pageCount` and `isComplete` and passing all three to `logger.warning`. A
/// ten-of-fourteen-page extraction reached the transparency analyzer as the
/// article, and the pages that fail to extract are disproportionately the last
/// ones — where funding, competing-interest and data-availability statements
/// live.
final class PDFExtractionCoverageTests: XCTestCase {
    private static let pdfBytes = Data([0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x34])
    private static let pmid = "coverage-test-99101"

    /// The name this article's cached PDFs are filed under.
    private static let cacheKey = ArticleCacheKey(pmid: pmid, pmcId: nil, doi: nil)!

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

    private func makeService(extractor: PDFTextExtracting) -> FullTextService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        return FullTextService(
            email: "test@example.org",
            session: session,
            europePMCService: EuropePMCService(session: session),
            extractor: extractor
        )
    }

    private func stubUnpaywallAndPDF() {
        StubURLProtocol.routes = [
            "unpaywall": (
                200,
                Data(#"{"best_oa_location":{"url_for_pdf":"https://example.org/a.pdf"}}"#.utf8)
            ),
            "a.pdf": (200, Self.pdfBytes),
        ]
    }

    // MARK: - The value type

    func testCoverageIsIncompleteWhenAPageGaveNothing() {
        let coverage = PDFExtractionCoverage(convertedPages: 10, pageCount: 14)
        XCTAssertFalse(coverage.isComplete)
        XCTAssertEqual(coverage.ratio, 10.0 / 14.0, accuracy: 0.0001)
    }

    func testCoverageIsCompleteWhenEveryPageGaveText() {
        XCTAssertTrue(PDFExtractionCoverage(convertedPages: 3, pageCount: 3).isComplete)
    }

    /// A document with no pages is not a complete extraction. Answering `true`
    /// would report the emptiest possible result as the most successful kind,
    /// which is the case `PDFExtractionResult.isComplete`'s third clause exists
    /// for.
    func testAZeroPageDocumentIsNotComplete() {
        let coverage = PDFExtractionCoverage(convertedPages: 0, pageCount: 0)
        XCTAssertFalse(coverage.isComplete)
        XCTAssertEqual(coverage.ratio, 0)
    }

    /// The extractor's own result and the value it hands onward cannot disagree,
    /// because the second is derived from the first rather than assembled beside
    /// it.
    func testTheExtractionResultDerivesItsCoverage() {
        let result = PDFExtractionResult(
            text: "prose", success: true, pageCount: 4, convertedPages: 3, warnings: []
        )
        XCTAssertEqual(result.coverage.convertedPages, 3)
        XCTAssertEqual(result.coverage.pageCount, 4)
        XCTAssertEqual(result.completionRatio, result.coverage.ratio)
        XCTAssertFalse(result.isComplete)
    }

    // MARK: - The channel

    /// The defect this file is named for: a partial extraction must arrive at
    /// the caller carrying its page counts.
    func testAPartialExtractionReportsItsCoverageToTheCaller() async throws {
        stubUnpaywallAndPDF()
        let extractor = StubExtractor(result: PDFExtractionResult(
            text: "the first ten pages", success: true, pageCount: 14, convertedPages: 10,
            warnings: ["page 11 yielded no text"]
        ))

        let result = try await makeService(extractor: extractor)
            .fetchFullText(pmcId: "PMC1", doi: "10.1/x", pmid: Self.pmid)

        XCTAssertEqual(result.contentKind, .extracted)
        XCTAssertEqual(result.extractionCoverage?.convertedPages, 10)
        XCTAssertEqual(result.extractionCoverage?.pageCount, 14)
        XCTAssertEqual(
            result.extractionCoverage?.isComplete, false,
            "the reader has to be able to tell this from a whole article"
        )
    }

    /// A whole extraction still reports coverage. The banner decides whether to
    /// say anything; the service does not get to withhold the figure, because a
    /// caller that cannot see "14 of 14" cannot distinguish it from a build that
    /// never measured.
    func testACompleteExtractionReportsCompleteCoverage() async throws {
        stubUnpaywallAndPDF()
        let extractor = StubExtractor(result: PDFExtractionResult(
            text: "all of it", success: true, pageCount: 6, convertedPages: 6, warnings: []
        ))

        let result = try await makeService(extractor: extractor)
            .fetchFullText(pmcId: "PMC1", doi: "10.1/x", pmid: Self.pmid)

        XCTAssertEqual(result.extractionCoverage?.isComplete, true)
        XCTAssertEqual(result.extractionCoverage?.pageCount, 6)
    }

    /// A scan recovers no text and still reports coverage — `0` of however many
    /// pages. That combination is the point rather than an edge case: a scan
    /// renders as an ordinary document, so without the figure the reader has no
    /// way to learn that every analysis of the article ran on no text at all.
    func testAScanReportsZeroCoverageAlongsideNoText() async throws {
        stubUnpaywallAndPDF()
        let extractor = StubExtractor(result: PDFExtractionResult(
            text: "", success: true, pageCount: 12, convertedPages: 0,
            warnings: ["page 1 yielded no text"]
        ))

        let result = try await makeService(extractor: extractor)
            .fetchFullText(pmcId: "PMC1", doi: "10.1/x", pmid: Self.pmid)

        XCTAssertEqual(result.contentKind, FullTextContentKind.none)
        XCTAssertNil(result.extractedText)
        XCTAssertEqual(result.extractionCoverage?.convertedPages, 0)
        XCTAssertEqual(result.extractionCoverage?.pageCount, 12)
        XCTAssertNotNil(result.localPDFPath, "the file is still real and still worth showing")
    }

    /// A password-protected document reports coverage too. PDFKit counts its
    /// pages even though it hands back no text, and the reader would otherwise
    /// be shown a document that renders as blank pages with nothing to say why
    /// no analysis of it found anything.
    func testALockedDocumentReportsZeroOfItsPageCount() async throws {
        stubUnpaywallAndPDF()
        let extractor = StubExtractor(result: PDFExtractionResult(
            text: "", success: false, pageCount: 9, convertedPages: 0, warnings: [],
            errorMessage: "the PDF is password-protected"
        ))

        let result = try await makeService(extractor: extractor)
            .fetchFullText(pmcId: "PMC1", doi: "10.1/x", pmid: Self.pmid)

        XCTAssertEqual(result.extractionCoverage?.convertedPages, 0)
        XCTAssertEqual(result.extractionCoverage?.pageCount, 9)
    }

    /// A document that could not be opened at all reports no coverage: there is
    /// no page count to report, and inventing `0 of 0` would dress a failed read
    /// as a measured one. The reason went to the log.
    func testAnUnreadableDocumentReportsNoCoverage() async throws {
        stubUnpaywallAndPDF()
        let extractor = StubExtractor(result: PDFExtractionResult(
            text: "", success: false, pageCount: 0, convertedPages: 0, warnings: [],
            errorMessage: "the PDF is password-protected"
        ))

        let result = try await makeService(extractor: extractor)
            .fetchFullText(pmcId: "PMC1", doi: "10.1/x", pmid: Self.pmid)

        XCTAssertEqual(result.contentKind, FullTextContentKind.none)
        XCTAssertNil(result.extractionCoverage)
    }
}
