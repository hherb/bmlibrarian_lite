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

/// Cross-platform parity drift guard for the data-availability classifier (#105).
///
/// Swift, Python and Kotlin each carry their own transcription of the same pattern
/// lists and restriction labels. Before this guard existed, parity was maintained
/// by convention: each platform asserted only its *own* literals, so an edit to one
/// language could silently diverge from the other two.
///
/// The contract lives in two language-neutral fixtures under
/// `doc/cross_platform/transparency_parity/`, loaded here and by the Python
/// (`tests/test_transparency_parity.py`) and Kotlin (`TransparencyParityTest.kt`)
/// suites:
///
/// - `data_availability_patterns.json` — the pattern lists and label map, asserted
///   string-for-string.
/// - `data_availability_cases.json` — worked `statement -> (level, restrictions)`
///   cases, asserted behaviourally. Catches divergence a string comparison cannot
///   see: a regex-engine difference, or a pattern spelled identically but compiled
///   with different options.
final class TransparencyParityTests: XCTestCase {

    // MARK: - Fixture loading

    private struct PatternManifest: Decodable {
        struct LabelEntry: Decodable {
            let pattern: String
            let label: String
        }

        let patterns: [String: [String]]
        let restrictionLabels: [LabelEntry]

        enum CodingKeys: String, CodingKey {
            case patterns
            case restrictionLabels = "restriction_labels"
        }
    }

    private struct CaseFixture: Decodable {
        struct Case: Decodable {
            let id: String
            let statement: String?
            let disclosureLevel: DataDisclosureLevel
            let restrictions: [String]
            let why: String?

            enum CodingKeys: String, CodingKey {
                case id
                case statement
                case disclosureLevel = "disclosure_level"
                case restrictions
                case why
            }
        }

        let cases: [Case]
    }

    /// Directory holding the shared, language-neutral parity fixtures.
    ///
    /// Located by walking up from this source file rather than by bundling the
    /// files as test resources: all three platforms must read the *same* bytes, so
    /// copying them into a per-platform resource bundle would reintroduce exactly
    /// the divergence this guard exists to prevent.
    private static let fixtureDirectory: URL = {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory
                .appendingPathComponent("doc/cross_platform/transparency_parity")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            directory = directory.deletingLastPathComponent()
        }
        fatalError("could not locate doc/cross_platform/transparency_parity above \(#filePath)")
    }()

    private func loadFixture<T: Decodable>(_ filename: String, as type: T.Type) throws -> T {
        let url = Self.fixtureDirectory.appendingPathComponent(filename)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func loadManifest() throws -> PatternManifest {
        try loadFixture("data_availability_patterns.json", as: PatternManifest.self)
    }

    private func loadCases() throws -> [CaseFixture.Case] {
        try loadFixture("data_availability_cases.json", as: CaseFixture.self).cases
    }

    // MARK: - Pattern manifest parity

    func testFullOpenPatternsMatchManifest() throws {
        let manifest = try loadManifest()
        XCTAssertEqual(DataRepositoryPatterns.fullOpenPatterns, manifest.patterns["full_open"])
    }

    func testNegatedOpennessPatternsMatchManifest() throws {
        let manifest = try loadManifest()
        XCTAssertEqual(
            DataRepositoryPatterns.negatedOpennessPatterns,
            manifest.patterns["negated_openness"]
        )
    }

    func testRestrictedPatternsMatchManifest() throws {
        let manifest = try loadManifest()
        XCTAssertEqual(DataRepositoryPatterns.restrictedPatterns, manifest.patterns["restricted"])
    }

    func testStrongRefusalPatternsMatchManifest() throws {
        let manifest = try loadManifest()
        XCTAssertEqual(
            DataRepositoryPatterns.strongRefusalPatterns,
            manifest.patterns["strong_refusal"]
        )
    }

    func testEffectivelyUnavailablePatternsMatchManifest() throws {
        let manifest = try loadManifest()
        XCTAssertEqual(
            DataRepositoryPatterns.effectivelyUnavailablePatterns,
            manifest.patterns["effectively_unavailable"]
        )
    }

    func testRestrictionLabelsMatchManifest() throws {
        let manifest = try loadManifest()
        let expected = Dictionary(
            uniqueKeysWithValues: manifest.restrictionLabels.map { ($0.pattern, $0.label) }
        )
        XCTAssertEqual(DataRepositoryPatterns.restrictionLabels, expected)
    }

    // MARK: - Behavioural case parity

    func testEveryFixtureCaseClassifiesAsSpecified() throws {
        let cases = try loadCases()
        XCTAssertFalse(cases.isEmpty, "behavioural fixture is empty")

        for testCase in cases {
            let result = DataAvailabilityAnalyzer.analyze(statement: testCase.statement)
            let context = [testCase.id, testCase.why].compactMap { $0 }.joined(separator: ": ")

            XCTAssertEqual(
                result.disclosureLevel,
                testCase.disclosureLevel,
                "disclosure level — \(context)"
            )
            XCTAssertEqual(
                result.restrictions,
                testCase.restrictions,
                "restrictions — \(context)"
            )
        }
    }
}
