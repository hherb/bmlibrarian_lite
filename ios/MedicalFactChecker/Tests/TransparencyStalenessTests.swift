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
}
