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

/// Pins *which* corpus names the classifier gets right and wrong, not just how
/// many.
///
/// `FunderClassificationTests` asserts floors — precision ≥ 0.95, recall ≥ 0.65.
/// Floors leave a gap: nothing says which funders. Swapping one recognised
/// funder for another leaves both metrics identical.
///
/// So the composition is pinned here. Both lists are expected to change — that is
/// the point. A change is a deliberate edit to this file with the new name in the
/// diff, rather than a silent drift underneath an unmoved average.
final class FunderCorpusCompositionTests: XCTestCase {

    // MARK: - What the classifier catches today

    /// The industry funders the matcher recognises: ten by a legal suffix or a
    /// company-form stem, and thirteen by brand (#394).
    private static let expectedTruePositives: Set<String> = [
        "AbbVie",
        "Amgen",
        "Astex Pharmaceuticals, Inc.",
        "AstraZeneca",
        "AstraZeneca.",
        "Bristol Myers Squibb",
        "Cardinal Health, LLC",
        "Chia Tai Tianqing Pharmaceutical Group Co., Ltd.",
        "Chugai Pharmaceutical Co., Ltd",
        "Dr. Reddy's Laboratories, Hyderabad, India",
        "Geneos Therapeutics",
        "ImmVira Co., Limited",
        "Janssen Scientific Affairs",
        "La Roche Posay",
        "Merck & Co.; Merck Sharp & Dohme",
        "NanOlogy, LLC",
        "Natera, Inc",
        "Pfizer",
        "Pfizer and Jazz",
        "Roche",
        "Roche Sweden AB",
        "Teva",
        "Treatment Technologies and Insights, Incorporated",
    ]

    /// The one false positive, and the whole reason precision is 0.958 rather
    /// than 1.0: a Chinese state heritage studio whose name contains
    /// "Pharmaceutical".
    private static let expectedFalsePositives: Set<String> = [
        "National Inheritance Studio of Veteran Pharmaceutical Workers of Zhong Lingyun",
    ]

    /// The industry funders the matcher misses — the recall debt, written down.
    /// None is a drug or device maker the brand list names: technology,
    /// diagnostics, finance and energy companies named without a legal suffix.
    ///
    /// This list is a record of known cost, not an endorsement. Removing a name
    /// from it because the matcher improved is the expected kind of edit.
    private static let expectedFalseNegatives: Set<String> = [
        "Arima Genomics",
        "Diaceutics",
        "Guardant Health",
        "Invitae Corporation",
        "Lockheed Martin",
        "Lån & Spar",
        "NVIDIA",
        "Personalis",
        "PetroChina Major Science and Technology Project",
        "Siemens Healthineers",
        "Tempus Labs",
        "TerumoBCT",
    ]

    // MARK: - Tests

    func testTruePositiveCompositionIsUnchanged() throws {
        XCTAssertEqual(try classify().truePositives, Self.expectedTruePositives)
    }

    func testFalsePositiveCompositionIsUnchanged() throws {
        XCTAssertEqual(try classify().falsePositives, Self.expectedFalsePositives)
    }

    func testFalseNegativeCompositionIsUnchanged() throws {
        XCTAssertEqual(try classify().falseNegatives, Self.expectedFalseNegatives)
    }

    /// The labelled corpus itself: 417 entries, of which 35 are industry. Pinned
    /// because every figure above is a fraction of these. Re-audited for #394
    /// (five commercial entities had been labelled not_industry, five names moved
    /// to ambiguous), so it now differs from bmlib's copy until bmlib takes the
    /// same corrections.
    func testTheLabelledCorpusIsUnchanged() throws {
        let entries = try loadEntries()

        XCTAssertEqual(entries.count, 417)
        XCTAssertEqual(entries.filter { $0.label == "industry" }.count, 35)
        XCTAssertEqual(entries.filter { $0.label == "not_industry" }.count, 372)
        XCTAssertEqual(entries.filter { $0.label == "ambiguous" }.count, 10)
    }

    // MARK: - Corpus

    private struct FunderCorpus: Decodable {
        struct Entry: Decodable {
            let name: String
            let label: String
        }
        let entries: [Entry]
    }

    /// Locates the shared corpus by walking up from this source file, the same
    /// rule the other parity suites use.
    private static let corpusURL: URL? = {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory
                .appendingPathComponent("doc/cross_platform/transparency_parity/funder_names.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }()

    private func loadEntries() throws -> [FunderCorpus.Entry] {
        let url = try XCTUnwrap(
            Self.corpusURL,
            "could not locate doc/cross_platform/transparency_parity/funder_names.json above \(#filePath)"
        )
        return try JSONDecoder().decode(FunderCorpus.self, from: Data(contentsOf: url)).entries
    }

    /// Runs the real classifier over every non-ambiguous corpus entry.
    ///
    /// - Returns: The names the classifier called right and wrong, by category.
    private func classify() throws -> (
        truePositives: Set<String>,
        falsePositives: Set<String>,
        falseNegatives: Set<String>
    ) {
        var truePositives: Set<String> = []
        var falsePositives: Set<String> = []
        var falseNegatives: Set<String> = []

        for entry in try loadEntries() where entry.label != "ambiguous" {
            let classifiedAsIndustry = FundingAnalyzer.classifyFunder(name: entry.name).isIndustry
            let labelledIndustry = entry.label == "industry"

            switch (classifiedAsIndustry, labelledIndustry) {
            case (true, true): truePositives.insert(entry.name)
            case (true, false): falsePositives.insert(entry.name)
            case (false, true): falseNegatives.insert(entry.name)
            case (false, false): break
            }
        }

        return (truePositives, falsePositives, falseNegatives)
    }
}
