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

    /// Pattern/label contract, asserted string-for-string.
    private static let patternsFixture = "data_availability_patterns.json"

    /// Worked `statement -> (level, restrictions)` cases, asserted behaviourally.
    private static let casesFixture = "data_availability_cases.json"

    /// Failure to reach the shared contract at all, as distinct from a parity failure.
    ///
    /// Kept separate so the message names the cause — a checkout that does not
    /// contain the contract directory — instead of surfacing as an opaque decode
    /// or file-not-found error from `Foundation`.
    private enum FixtureError: Error, CustomStringConvertible {
        /// The upward walk for the contract directory found no candidate.
        ///
        /// - Parameter origin: Source path the walk started from, for the message.
        case directoryNotFound(origin: String)

        /// Human-readable cause, surfaced by XCTest when the error goes unhandled.
        var description: String {
            switch self {
            case let .directoryNotFound(origin):
                return "could not locate doc/cross_platform/transparency_parity above \(origin)"
            }
        }
    }

    /// Directory holding the shared, language-neutral parity fixtures.
    ///
    /// Located by walking up from this source file rather than by bundling the
    /// files as test resources: all three platforms must read the *same* bytes, so
    /// copying them into a per-platform resource bundle would reintroduce exactly
    /// the divergence this guard exists to prevent.
    ///
    /// `nil` rather than a `fatalError` when the walk comes up empty — which it
    /// would if this package were ever consumed outside the monorepo. Trapping
    /// there kills the whole test process; surfacing it as a thrown error lets the
    /// parity tests fail individually and leaves the rest of the suite readable.
    private static let fixtureDirectory: URL? = {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory
                .appendingPathComponent("doc/cross_platform/transparency_parity")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }()

    /// Read and decode one shared fixture from the contract directory.
    ///
    /// - Parameter filename: File name within `fixtureDirectory`.
    /// - Returns: The decoded fixture.
    /// - Throws: `FixtureError.directoryNotFound` if the contract directory is not
    ///   in this checkout, or a `Foundation` read/decode error if the file is
    ///   missing or malformed.
    private static func decodeFixture<T: Decodable>(_ filename: String) throws -> T {
        guard let directory = fixtureDirectory else {
            throw FixtureError.directoryNotFound(origin: #filePath)
        }
        let data = try Data(contentsOf: directory.appendingPathComponent(filename))
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// The pattern/label contract, decoded once per test run.
    ///
    /// Six assertions read the manifest; re-reading and re-decoding the file for
    /// each of them was pure overhead. Stored as a `Result` because a static
    /// stored property cannot itself throw — the error is rethrown at `get()`, so
    /// an unreadable contract still fails each test individually rather than
    /// trapping the process.
    private static let manifest = Result<PatternManifest, Error> {
        try decodeFixture(patternsFixture)
    }

    /// The behavioural cases, decoded once per test run. See `manifest`.
    private static let caseFixture = Result<CaseFixture, Error> {
        try decodeFixture(casesFixture)
    }

    /// The shared pattern/label contract.
    ///
    /// - Returns: The decoded manifest.
    /// - Throws: Whatever decoding it raised, rethrown on every access.
    private func loadManifest() throws -> PatternManifest {
        try Self.manifest.get()
    }

    /// The shared behavioural cases.
    ///
    /// - Returns: Every worked case, in fixture order.
    /// - Throws: Whatever decoding it raised, rethrown on every access.
    private func loadCases() throws -> [CaseFixture.Case] {
        try Self.caseFixture.get().cases
    }

    // MARK: - Drift reporting

    /// Assert a pattern tier equals the shared contract, reporting only what drifted.
    ///
    /// A plain `XCTAssertEqual` on these lists dumps both in full — 27 patterns of
    /// dense regex — which buries the one entry that actually changed. Pointing at
    /// the differing index is what makes the failure actionable.
    private func assertTierMatchesContract(
        _ actual: [String],
        tier: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let expected = try XCTUnwrap(
            loadManifest().patterns[tier],
            "shared contract has no '\(tier)' tier",
            file: file,
            line: line
        )
        guard actual != expected else { return }

        var message = "'\(tier)' has drifted from the shared contract"
        if actual.count != expected.count {
            message += " (Swift has \(actual.count) patterns, contract has \(expected.count))"
        }
        let differences = zip(actual, expected).enumerated()
            .filter { $0.element.0 != $0.element.1 }
            .map { "  [\($0.offset)] Swift:    \($0.element.0)\n       contract: \($0.element.1)" }
        if !differences.isEmpty {
            message += ":\n" + differences.joined(separator: "\n")
        }
        XCTFail(message, file: file, line: line)
    }

    // MARK: - Pattern manifest parity

    func testFullOpenPatternsMatchContract() throws {
        try assertTierMatchesContract(
            DataRepositoryPatterns.fullOpenPatterns,
            tier: "full_open"
        )
    }

    func testNegatedOpennessPatternsMatchContract() throws {
        try assertTierMatchesContract(
            DataRepositoryPatterns.negatedOpennessPatterns,
            tier: "negated_openness"
        )
    }

    func testRestrictedPatternsMatchContract() throws {
        try assertTierMatchesContract(
            DataRepositoryPatterns.restrictedPatterns,
            tier: "restricted"
        )
    }

    func testStrongRefusalPatternsMatchContract() throws {
        try assertTierMatchesContract(
            DataRepositoryPatterns.strongRefusalPatterns,
            tier: "strong_refusal"
        )
    }

    func testEffectivelyUnavailablePatternsMatchContract() throws {
        try assertTierMatchesContract(
            DataRepositoryPatterns.effectivelyUnavailablePatterns,
            tier: "effectively_unavailable"
        )
    }

    func testRestrictionLabelsMatchContract() throws {
        let entries = try loadManifest().restrictionLabels

        // `Dictionary(uniqueKeysWithValues:)` traps on a duplicate key, which in a
        // hand-edited contract would abort the test process instead of reporting a
        // fixable mistake. (Kotlin's `associate` is the opposite hazard: it keeps
        // the last entry and says nothing.)
        let duplicates = Dictionary(grouping: entries, by: \.pattern)
            .filter { $0.value.count > 1 }
            .keys
            .sorted()
        guard duplicates.isEmpty else {
            XCTFail("shared contract has duplicate label patterns:\n  "
                + duplicates.joined(separator: "\n  "))
            return
        }

        let expected = Dictionary(uniqueKeysWithValues: entries.map { ($0.pattern, $0.label) })
        let actual = DataRepositoryPatterns.restrictionLabels
        guard actual != expected else { return }

        var differences: [String] = []
        for pattern in Set(actual.keys).union(expected.keys).sorted() {
            switch (actual[pattern], expected[pattern]) {
            case let (swift?, contract?) where swift != contract:
                differences.append("  \(pattern)\n       Swift: \(swift)\n    contract: \(contract)")
            case (let swift?, nil):
                differences.append("  \(pattern)\n       Swift only: \(swift)")
            case (nil, let contract?):
                differences.append("  \(pattern)\n    contract only: \(contract)")
            default:
                continue
            }
        }
        XCTFail("restriction labels have drifted from the shared contract:\n"
            + differences.joined(separator: "\n"))
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
