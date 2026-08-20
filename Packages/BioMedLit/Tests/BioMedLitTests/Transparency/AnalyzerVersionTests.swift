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

/// Tests for the stored-result analyzer version stamp.
///
/// The Europe PMC availability allow-list, the JATS caption/unsectioned-body
/// fixes and the recalibrated funder patterns all move stored transparency
/// scores. A result stamped with the analyzer version that produced it lets the
/// UI tell a stale verdict from a current one and offer a re-run, rather than
/// showing two documents' scores that silently disagree.
final class AnalyzerVersionTests: XCTestCase {

    private func makeResult() -> TransparencyResult {
        var builder = TransparencyResultBuilder(pmid: "12345678")
        builder.title = "A Study"
        return builder.build()
    }

    // MARK: - Stamping

    func testBuiltResultCarriesTheCurrentAnalyzerVersion() {
        XCTAssertEqual(makeResult().analyzerVersion, TransparencyConstants.analyzerVersion)
    }

    func testBuiltResultIsNotStale() {
        XCTAssertFalse(makeResult().isStale)
    }

    /// The explicit-score overload is used by callers that scored elsewhere; it
    /// must stamp the same version rather than leaving the result unversioned.
    func testExplicitScoreBuildAlsoStamps() {
        var builder = TransparencyResultBuilder(pmid: "1")
        let result = builder.build(score: 60, riskLevel: .medium, riskIndicators: [])

        XCTAssertEqual(result.analyzerVersion, TransparencyConstants.analyzerVersion)
    }

    // MARK: - Staleness

    func testAnOlderVersionIsStale() {
        var builder = TransparencyResultBuilder(pmid: "1")
        let result = builder.build()
        let older = TransparencyResult(
            pmid: result.pmid,
            transparencyScore: result.transparencyScore,
            riskLevel: result.riskLevel,
            analyzerVersion: TransparencyConstants.analyzerVersion - 1
        )

        XCTAssertTrue(older.isStale)
    }

    /// Results stored before versioning existed decode with no version at all.
    /// They predate the fixes by definition, so they must read as stale.
    func testAResultWithNoVersionIsStale() {
        let unversioned = TransparencyResult(pmid: "1", analyzerVersion: nil)

        XCTAssertNil(unversioned.analyzerVersion)
        XCTAssertTrue(unversioned.isStale)
    }

    // MARK: - Round-tripping stored JSON

    func testVersionSurvivesEncodeDecode() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(makeResult())
        let decoded = try decoder.decode(TransparencyResult.self, from: data)

        XCTAssertEqual(decoded.analyzerVersion, TransparencyConstants.analyzerVersion)
        XCTAssertFalse(decoded.isStale)
    }

    /// JSON written before the field existed must still decode — the stored
    /// column is free-form JSON, so a required field would strand every
    /// pre-existing analysis behind a decode failure that reads as "never analysed".
    func testJSONWrittenBeforeVersioningStillDecodes() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(makeResult())
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object.removeValue(forKey: "analyzerVersion")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try decoder.decode(TransparencyResult.self, from: legacyData)

        XCTAssertNil(decoded.analyzerVersion)
        XCTAssertTrue(decoded.isStale)
        XCTAssertEqual(decoded.pmid, "12345678")
    }
}
