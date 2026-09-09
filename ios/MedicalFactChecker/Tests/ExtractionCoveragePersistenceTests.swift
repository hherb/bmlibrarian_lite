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

import BioMedLit
import SwiftData
import XCTest
@testable import MedicalFactChecker

/// A partial extraction has to survive the same hops a truncated parse does.
///
/// The parse-warnings channel exists because a loss that lived only on the
/// in-flight result vanished when the viewer was reopened, and never reached
/// macOS at all — which renders only from the `Document`. Extraction coverage
/// arrived on exactly that footing: computed, logged, and dropped.
final class ExtractionCoveragePersistenceTests: XCTestCase {
    /// The app registers this at launch; a test that opens a `ModelContainer`
    /// has to do it too, or `Document`'s transformable attributes trap before
    /// the store is built.
    override func setUp() {
        super.setUp()
        StringArrayTransformer.register()
    }

    private func makeDocument() -> Document {
        Document(pmid: "12345678", title: "A Study", abstract: "")
    }

    private func extractedResult(
        convertedPages: Int,
        pageCount: Int,
        localPath: String = "/tmp/a.pdf"
    ) -> AppFullTextResult {
        AppFullTextResult(
            content: .pdfURL(URL(fileURLWithPath: localPath)),
            source: .unpaywall,
            contentKind: .extracted,
            extractedText: "recovered prose",
            localPDFPath: localPath,
            extractionCoverage: PDFExtractionCoverage(
                convertedPages: convertedPages, pageCount: pageCount
            )
        )
    }

    // MARK: - The adapter

    func testTheAdapterCarriesCoverageOntoTheAppResult() {
        let result = BioMedLitAdapters.toAppFullTextResult(
            BMLFullTextResult(
                content: .unpaywall(pdfURL: URL(string: "https://example.org/a.pdf")!),
                contentKind: .extracted,
                extractedText: "prose",
                localPDFPath: "/tmp/a.pdf",
                extractionCoverage: PDFExtractionCoverage(convertedPages: 10, pageCount: 14)
            )
        )

        XCTAssertEqual(result.extractionCoverage?.convertedPages, 10)
        XCTAssertEqual(result.extractionCoverage?.pageCount, 14)
    }

    /// The cached PDF, not the remote URL. The iOS viewers render the live
    /// result, so mapping this to the remote URL sent them back over the network
    /// for bytes the service had just written to disk.
    func testTheAdapterPrefersTheCachedFileOverTheRemoteURL() {
        let result = BioMedLitAdapters.toAppFullTextResult(
            BMLFullTextResult(
                content: .unpaywall(pdfURL: URL(string: "https://example.org/a.pdf")!),
                contentKind: .extracted,
                extractedText: "prose",
                localPDFPath: "/tmp/cached.pdf",
                extractionCoverage: PDFExtractionCoverage(convertedPages: 1, pageCount: 1)
            )
        )

        XCTAssertEqual(result.pdfURL?.path, "/tmp/cached.pdf")
        XCTAssertEqual(result.pdfURL?.isFileURL, true)
    }

    /// With nothing cached there is nothing to prefer, so the remote URL stands.
    func testTheAdapterFallsBackToTheRemoteURLWhenNothingWasCached() {
        let result = BioMedLitAdapters.toAppFullTextResult(
            BMLFullTextResult(
                content: .unpaywall(pdfURL: URL(string: "https://example.org/a.pdf")!)
            )
        )

        XCTAssertEqual(result.pdfURL?.absoluteString, "https://example.org/a.pdf")
    }

    // MARK: - The document

    func testApplyingAnExtractedResultStoresItsCoverage() {
        let document = makeDocument()
        document.applyFullTextResult(extractedResult(convertedPages: 10, pageCount: 14))

        XCTAssertEqual(document.fullTextExtractedPages, 10)
        XCTAssertEqual(document.fullTextTotalPages, 14)
        XCTAssertEqual(document.cachedRetrievalNotice.extractionCoverage?.convertedPages, 10)
        XCTAssertEqual(document.cachedRetrievalNotice.extractionCoverage?.pageCount, 14)
    }

    /// Cleared, not merely set. A re-fetch that recovered the whole article must
    /// not inherit the previous attempt's shortfall and keep warning about it.
    func testASubsequentCompleteResultClearsTheEarlierShortfall() {
        let document = makeDocument()
        document.applyFullTextResult(extractedResult(convertedPages: 3, pageCount: 12))
        document.applyFullTextResult(
            AppFullTextResult(
                content: .html(content: "<p>whole</p>", markdown: "whole"),
                source: .europePMC,
                contentKind: .fulltext
            )
        )

        XCTAssertNil(document.fullTextExtractedPages)
        XCTAssertNil(document.fullTextTotalPages)
        XCTAssertNil(document.cachedRetrievalNotice.extractionCoverage)
    }

    func testClearingTheCacheClearsTheCoverage() {
        let document = makeDocument()
        document.applyFullTextResult(extractedResult(convertedPages: 3, pageCount: 12))
        document.clearFullTextCache()

        XCTAssertNil(document.fullTextExtractedPages)
        XCTAssertNil(document.cachedRetrievalNotice.extractionCoverage)
    }

    /// A half-written pair describes nothing. Reporting "0 of 12" for it would
    /// invent a figure rather than admit to not having one.
    func testAHalfWrittenPairReportsNoCoverage() {
        let document = makeDocument()
        document.applyFullTextResult(extractedResult(convertedPages: 3, pageCount: 12))
        document.fullTextTotalPages = nil

        XCTAssertNil(document.cachedRetrievalNotice.extractionCoverage)
    }

    /// A scan stores its coverage too — `0` of however many pages — so the
    /// reader is told that nothing in the document reached any analysis.
    func testAScanStoresZeroCoverage() {
        let document = makeDocument()
        document.applyFullTextResult(
            AppFullTextResult(
                content: .pdfURL(URL(fileURLWithPath: "/tmp/scan.pdf")),
                source: .unpaywall,
                contentKind: .none,
                localPDFPath: "/tmp/scan.pdf",
                extractionCoverage: PDFExtractionCoverage(convertedPages: 0, pageCount: 12)
            )
        )

        XCTAssertEqual(document.cachedRetrievalNotice.extractionCoverage?.convertedPages, 0)
        XCTAssertEqual(document.cachedRetrievalNotice.extractionCoverage?.pageCount, 12)
    }

    /// Coverage belongs to a PDF. A parsed article has none, and a record that
    /// somehow held both must not describe the article's own text as a partial
    /// extraction.
    func testAParsedArticleReportsNoCoverage() {
        let document = makeDocument()
        document.applyFullTextResult(
            AppFullTextResult(
                content: .html(content: "<p>x</p>", markdown: "x"),
                source: .europePMC,
                contentKind: .fulltext
            )
        )
        document.fullTextExtractedPages = 2
        document.fullTextTotalPages = 9

        XCTAssertNil(document.cachedRetrievalNotice.extractionCoverage)
        XCTAssertNil(document.cachedFullTextResult?.extractionCoverage)
    }

    // MARK: - The store

    /// The hop nothing else covers: the two new columns are `@Model` attributes,
    /// and a record written by this build has to come back out of a real store
    /// carrying them. Every other test here works on an in-memory `Document`
    /// that never sees SwiftData.
    func testCoverageSurvivesAStoreRoundTrip() throws {
        let container = try ModelContainer(
            for: Document.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)

        let document = makeDocument()
        document.applyFullTextResult(extractedResult(convertedPages: 10, pageCount: 14))
        context.insert(document)
        try context.save()

        let refetched = try XCTUnwrap(
            try ModelContext(container).fetch(FetchDescriptor<Document>()).first
        )
        XCTAssertEqual(refetched.fullTextExtractedPages, 10)
        XCTAssertEqual(refetched.fullTextTotalPages, 14)
        XCTAssertEqual(refetched.cachedRetrievalNotice.extractionCoverage?.isComplete, false)
    }

    /// A record written before these columns existed opens and reads as "no
    /// extraction measured", rather than as a complete one or a decode failure.
    /// Optional scalars are what make that lightweight migration possible.
    func testARecordWithNoCoverageColumnsReadsAsUnmeasured() throws {
        let container = try ModelContainer(
            for: Document.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)

        let document = makeDocument()
        document.applyFullTextResult(extractedResult(convertedPages: 10, pageCount: 14))
        // Exactly what a pre-migration row looks like: the text and kind are
        // there, the counts are not.
        document.fullTextExtractedPages = nil
        document.fullTextTotalPages = nil
        context.insert(document)
        try context.save()

        let refetched = try XCTUnwrap(
            try ModelContext(container).fetch(FetchDescriptor<Document>()).first
        )
        XCTAssertEqual(refetched.fullTextContentKindRaw, FullTextContentKind.extracted.rawValue)
        XCTAssertNil(
            refetched.cachedRetrievalNotice.extractionCoverage,
            "silence, not a claim that the extraction was whole"
        )
    }
}
