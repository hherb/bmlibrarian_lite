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

    /// The shared CORE contract, `doc/cross_platform/fulltext_parity/core_fulltext.json`,
    /// found by walking up from this file to the repository's root.
    private func loadContract() throws -> [String: Any] {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while true {
            let candidate = directory.appendingPathComponent(
                "doc/cross_platform/fulltext_parity/core_fulltext.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try XCTUnwrap(
                    JSONSerialization.jsonObject(with: Data(contentsOf: candidate)) as? [String: Any])
            }
            let parent = directory.deletingLastPathComponent()
            if parent == directory
                || FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) {
                // A failure, not a skip: a test that cannot read the contract pins nothing
                return try XCTUnwrap(nil as [String: Any]?, "core_fulltext.json not found")
            }
            directory = parent
        }
    }

    func testTheSourceIsTheContracts() throws {
        let contract = try loadContract()
        let source = try XCTUnwrap(contract["source"] as? String)
        XCTAssertEqual(AppFullTextSource.core.rawValue, source)
        XCTAssertEqual(AppFullTextSource.core.displayName, contract["source_label"] as? String)
        XCTAssertTrue(AppFullTextSource.core.canDisplayInApp)
        XCTAssertEqual(AppFullTextSource(rawValue: source), .core)
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
