// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2026 Dr Horst Herb
//
// Licensed under the GNU Affero General Public License, version 3 or later.

import XCTest
@testable import MedicalFactChecker
import BioMedLit

/// CORE's extracted text as a full-text source (#480, stage C).
final class CoreTextDocumentTests: XCTestCase {
    private let text = String(repeating: "x", count: 5000)

    private var coreResult: BioMedLit.FullTextResult {
        BioMedLit.FullTextResult(
            content: .core(text: text), warnings: JATSParseWarnings(), degradation: nil,
            contentKind: .extracted, extractedText: text, localPDFPath: nil,
            extractionCoverage: nil, openAccessShortfall: nil, pdfNotSavedFrom: nil
        )
    }

    private func makeDocument() -> Document {
        Document(pmid: "1", title: "T", abstract: "")
    }

    func testTheSourceIsTheContracts() {
        XCTAssertEqual(AppFullTextSource.core.rawValue, "core")
        XCTAssertEqual(AppFullTextSource.core.displayName, "CORE (extracted text)")
        XCTAssertTrue(AppFullTextSource.core.canDisplayInApp)
        XCTAssertEqual(AppFullTextSource(rawValue: "core"), .core)
    }

    func testCOREsTextReachesTheAppAsPlainContent() {
        let app = BioMedLitAdapters.toAppFullTextResult(coreResult)
        XCTAssertEqual(app.source, .core)
        XCTAssertEqual(app.content, .markdown(text))
        XCTAssertEqual(app.contentKind, .extracted)
    }

    func testAStoredCORETextIsShownAndAnalysed() throws {
        let document = makeDocument()
        document.applyFullTextResult(BioMedLitAdapters.toAppFullTextResult(coreResult))
        XCTAssertEqual(document.fullTextContent, text)
        XCTAssertEqual(document.fullTextSource, "core")
        XCTAssertNil(document.fullTextPDFPath)
        XCTAssertNil(document.fullTextOpenAccessShortfallJSON)
        XCTAssertEqual(document.displayedFullText, .markdown(text))
        XCTAssertEqual(document.analyzableFullText, text)
    }

    func testTheKeyReachesTheService() {
        XCTAssertTrue(BMLFullTextService.create(ncbiEmail: "", coreAPIKey: "k").asksCore)
        XCTAssertFalse(BMLFullTextService.create(ncbiEmail: "", coreAPIKey: "  ").asksCore)
    }
}
