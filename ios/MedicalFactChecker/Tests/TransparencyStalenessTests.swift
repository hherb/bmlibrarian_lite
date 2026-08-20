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
import BioMedLit
@testable import MedicalFactChecker

/// Tests for recognising a stored transparency result that predates the current analyzer.
final class TransparencyStalenessTests: XCTestCase {

    private func makeDocument() -> Document {
        Document(pmid: "12345678", title: "A Study", abstract: "")
    }

    func testDocumentWithNoAnalysisIsNotStale() {
        let document = makeDocument()

        XCTAssertFalse(document.hasTransparencyAnalysis)
        XCTAssertFalse(document.transparencyAnalysisIsStale)
    }

    func testFreshlyStoredAnalysisIsNotStale() {
        let document = makeDocument()
        var builder = TransparencyResultBuilder(pmid: "12345678")
        builder.title = "A Study"
        document.storeTransparencyResult(builder.build())

        XCTAssertTrue(document.hasTransparencyAnalysis)
        XCTAssertFalse(document.transparencyAnalysisIsStale)
    }

    /// Stored JSON written before the version field existed: the analysis is
    /// still readable, but its score is not comparable with a current one.
    func testAnalysisStoredBeforeVersioningIsStale() throws {
        let document = makeDocument()
        var builder = TransparencyResultBuilder(pmid: "12345678")
        builder.title = "A Study"
        document.storeTransparencyResult(builder.build())

        let json = try XCTUnwrap(document.transparencyResultJSON)
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        object.removeValue(forKey: "analyzerVersion")
        document.transparencyResultJSON = String(
            data: try JSONSerialization.data(withJSONObject: object),
            encoding: .utf8
        )

        XCTAssertTrue(document.hasTransparencyAnalysis)
        XCTAssertNotNil(document.transparencyResult, "legacy JSON must still decode")
        XCTAssertTrue(document.transparencyAnalysisIsStale)
    }

    /// Stored JSON that is present but unreadable is not the same as no analysis.
    ///
    /// Reading it as absent left the document in a state it could never leave:
    /// `transparencyResult` is nil so nothing renders, staleness was false so
    /// nothing warned, and `hasTransparencyAnalysis` reads the raw string and
    /// returns true, so the workflow filtered it out of re-analysis permanently.
    func testUndecodableStoredJSONCountsAsStale() {
        let document = makeDocument()
        document.transparencyResultJSON = #"{"this":"is not a TransparencyResult"}"#

        XCTAssertTrue(document.hasTransparencyAnalysis)
        XCTAssertNil(document.transparencyResult)
        XCTAssertTrue(
            document.transparencyAnalysisIsStale,
            "unreadable stored JSON must be re-runnable, not silently inert"
        )
    }

    /// A newer result arriving by CloudKit sync from a device on a later build is
    /// not stale, and must not be offered for a re-analysis that would downgrade it.
    func testAnalysisFromANewerAnalyzerIsNotStale() throws {
        let document = makeDocument()
        document.storeTransparencyResult(
            TransparencyResult(
                pmid: "12345678",
                analyzerVersion: TransparencyConstants.analyzerVersion + 1
            )
        )

        XCTAssertFalse(document.transparencyAnalysisIsStale)
    }

    // MARK: - Storing

    /// The write is reported, so the re-analysis path can say when it did not
    /// happen instead of clearing its spinner and leaving the stale notice up.
    func testStoringReportsSuccess() {
        let document = makeDocument()
        var builder = TransparencyResultBuilder(pmid: "12345678")
        builder.title = "A Study"

        XCTAssertTrue(document.storeTransparencyResult(builder.build()))
    }

    // MARK: - Eligibility

    func testADocumentWithAPMIDCanBeAnalyzed() {
        XCTAssertTrue(makeDocument().canAnalyzeTransparency)
    }

    func testADocumentWithNeitherPMIDNorDOICannotBeAnalyzed() {
        let document = Document(pmid: "", title: "A Study", abstract: "")
        document.doi = nil

        XCTAssertFalse(document.canAnalyzeTransparency)
    }
}
