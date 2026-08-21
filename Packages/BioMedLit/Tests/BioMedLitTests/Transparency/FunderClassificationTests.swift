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

/// Industry-funder name matching, measured against the shared labelled corpus.
///
/// `industryFundingDetected` feeds a HIGH-risk rule and HIGH downgrades a
/// paper's quality tier, so a false positive costs more than a false negative.
/// The corpus test at the bottom is what keeps that honest: it measures the
/// classifier against 417 hand-labelled CrossRef and PubMed funder names
/// (bmlib issue #36), shared with the Python implementation.
final class FunderClassificationTests: XCTestCase {

    private func isIndustry(_ name: String) -> Bool {
        FundingAnalyzer.classifyFunder(name: name).isIndustry
    }

    // MARK: - Org suffixes match as words, with or without a trailing dot

    /// The old list tested `\binc\.?\b` as one of several substring-ish patterns,
    /// so the plural company-name form was never reached.
    func testIncWithADot() {
        XCTAssertTrue(isIndustry("Genentech Inc."))
    }

    func testIncWithoutADot() {
        XCTAssertTrue(isIndustry("Pfizer Inc"))
    }

    func testIncUppercased() {
        XCTAssertTrue(isIndustry("PFIZER INC"))
    }

    func testLincolnIsNotACompany() {
        XCTAssertFalse(isIndustry("Lincoln Medical Center"))
    }

    func testSpelledOutSuffixesEarnedInclusion() {
        XCTAssertTrue(isIndustry("Vertex Pharmaceuticals Incorporated"))
        XCTAssertTrue(isIndustry("Takeda Limited"))
    }

    func testLLCEarnedInclusion() {
        XCTAssertTrue(isIndustry("Flatiron Health LLC"))
    }

    func testGmbH() {
        XCTAssertTrue(isIndustry("Boehringer Ingelheim GmbH"))
    }

    // MARK: - Stems match inside a longer word; words must not

    /// Six of the nine mismatches in the alignment doc were the plural:
    /// `\bpharma(?:ceutical)?\b` cannot match "Pharmaceuticals", because the
    /// word boundary lands before the "s".
    func testPharmaceuticalsPlural() {
        XCTAssertTrue(isIndustry("Regeneron Pharmaceuticals"))
    }

    func testPharmaceuticalSingular() {
        XCTAssertTrue(isIndustry("Pharmaceutical Research Institute"))
    }

    func testBarePharmaIsStillIndustry() {
        XCTAssertTrue(isIndustry("Acme Pharma"))
    }

    func testTherapeutics() {
        XCTAssertTrue(isIndustry("Moderna Therapeutics"))
    }

    func testPluralLaboratoriesIsIndustry() {
        XCTAssertTrue(isIndustry("Abbott Laboratories"))
    }

    /// "Key Laboratory" is a Chinese state-lab form and must keep missing.
    func testASingularKeyLaboratoryIsNotIndustry() {
        XCTAssertFalse(isIndustry("Key Laboratory of Molecular Biology"))
    }

    /// "pharma" as a substring reached "Pharmacy", "Pharmacology" and
    /// "Pharmacogenetics", all academic — which is why the stem is narrower.
    func testPharmacyIsNotIndustry() {
        XCTAssertFalse(isIndustry("School of Pharmacy"))
    }

    func testPharmacologyIsNotIndustry() {
        XCTAssertFalse(isIndustry("Institute of Pharmacology"))
    }

    // MARK: - Measured exclusions

    /// "biotech" as a substring scored 0 TP / 4 FP on the corpus, reaching only
    /// an Indian ministry and a UK research council.
    func testBiotechnologyAloneIsNotIndustry() {
        XCTAssertFalse(isIndustry("Department of Biotechnology"))
        XCTAssertFalse(isIndustry("Biotechnology and Biological Sciences Research Council"))
    }

    /// As a bare word it is a company name, so that form is kept.
    func testBareBiotechIsStillIndustry() {
        XCTAssertTrue(isIndustry("Acme Biotech"))
    }

    /// US non-profits use "Corporation" — 1 TP / 1 FP, so only "corp" is a token.
    func testCorporationIsNotAnOrgToken() {
        XCTAssertFalse(isIndustry("Research Corporation for Science Advancement"))
    }

    func testCorpIsAnOrgToken() {
        XCTAssertTrue(isIndustry("Amgen Corp"))
    }

    /// "co" collides with the English prefix in "project co-sponsored by…".
    func testCoIsNotAnOrgToken() {
        XCTAssertFalse(isIndustry("Project co-sponsored by the province"))
    }

    /// Kept where bmlib drops it: 0 TP / 0 FP on the corpus, same as `pharma`,
    /// `biotech`, `corp` and `gmbh`, which bmlib keeps on the reserved-suffix
    /// argument. See `IndustryPatterns.funderNameWords`.
    func testPLCIsAnOrgToken() {
        XCTAssertTrue(isIndustry("Diagnostics PLC"))
        XCTAssertTrue(isIndustry("GlaxoSmithKline plc"))
    }

    /// "labs" collides with "Los Alamos National Labs"; costs "Tempus Labs".
    func testLabsIsNotAnOrgToken() {
        XCTAssertFalse(isIndustry("Los Alamos National Labs"))
    }

    /// "ab" collides with a province code in a name carrying a location.
    func testABIsNotAnOrgToken() {
        XCTAssertFalse(isIndustry("University of Calgary, Calgary, AB, Canada"))
    }

    // MARK: - Public-sector funders

    func testAGovernmentAgency() {
        XCTAssertFalse(isIndustry("Ministry of Science and Technology"))
    }

    func testACharity() {
        XCTAssertFalse(isIndustry("Wellcome Trust"))
    }

    func testAnEmptyName() {
        XCTAssertFalse(isIndustry(""))
    }

    // MARK: - Known-funder DOI still wins

    func testKnownIndustryFunderDOI() {
        let (isIndustry, confidence) = FundingAnalyzer.classifyFunder(
            name: "Pfizer",
            doi: "10.13039/100004319"
        )
        XCTAssertTrue(isIndustry)
        XCTAssertEqual(confidence, 1.0)
    }

    // MARK: - The alignment doc's evidence table

    /// The 17 names in `doc/cross_platform/ios_bmlib_alignment.md` §1.4, which
    /// recorded nine disagreements between Swift and bmlib. Pinned so the table
    /// in that document stays true of the code it describes.
    func testAgreesWithBmlibOnTheDocumentedTable() {
        let expected: [(name: String, isIndustry: Bool)] = [
            ("Department of Biotechnology", false),
            ("Biotechnology and Biological Sciences Research Council", false),
            ("Research Corporation for Science Advancement", false),
            ("Vertex Pharmaceuticals Incorporated", true),
            ("Regeneron Pharmaceuticals", true),
            ("Moderna Therapeutics", true),
            ("Abbott Laboratories", true),
            ("Tempus Labs, LLC", true),
            ("Flatiron Health LLC", true),
            ("Pfizer Inc", true),
            ("Genentech, Inc.", true),
            ("Ministry of Science and Technology", false),
            ("Lincoln Medical Center", false),
            ("University of Calgary, Calgary, AB, Canada", false),
            ("Key Laboratory of Molecular Biology", false),
            ("Novo Nordisk A/S", false),
            ("Bristol-Myers Squibb Company", false),
        ]

        for (name, want) in expected {
            XCTAssertEqual(isIndustry(name), want, name)
        }
    }

    // MARK: - The labelled corpus

    /// Floors one notch below the measured figures, so an unrelated refactor does
    /// not have to move them but a real regression trips. Measured against the
    /// committed corpus: precision 0.909, recall 0.333 — identical to what
    /// bmlib's `_is_industry_funder` scores on the same names.
    private static let minPrecision = 0.90
    private static let minRecall = 0.30

    /// What the matcher this replaced scored on the same corpus.
    private static let previousPrecision = 0.455
    private static let previousRecall = 0.167

    private struct FunderCorpus: Decodable {
        struct Entry: Decodable {
            let name: String
            let source: String
            let label: String
            let reason: String?
        }
        let entries: [Entry]
    }

    /// Shared, language-neutral corpus, located by walking up from this source
    /// file — the same rule `TransparencyParityTests` uses, so Swift and Python
    /// read the same bytes rather than per-platform copies.
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

    private func loadCorpus() throws -> [FunderCorpus.Entry] {
        let url = try XCTUnwrap(
            Self.corpusURL,
            "could not locate doc/cross_platform/transparency_parity/funder_names.json above \(#filePath)"
        )
        return try JSONDecoder().decode(FunderCorpus.self, from: Data(contentsOf: url)).entries
    }

    /// `(truePositives, falsePositives, falseNegatives)` over the non-ambiguous
    /// entries. Ambiguous names are kept in the file with a reason and excluded
    /// from the numbers — scoring an undecidable name would only add noise.
    private func scoreCorpus() throws -> (tp: Int, fp: Int, fn: Int) {
        var tp = 0, fp = 0, fn = 0
        for entry in try loadCorpus() where entry.label != "ambiguous" {
            let gold = entry.label == "industry"
            let flagged = isIndustry(entry.name)
            if flagged && gold {
                tp += 1
            } else if flagged {
                fp += 1
            } else if gold {
                fn += 1
            }
        }
        return (tp, fp, fn)
    }

    func testTheCorpusIsPresentAndLabelled() throws {
        let entries = try loadCorpus()

        XCTAssertTrue(Set(entries.map(\.label)).isSubset(of: ["industry", "not_industry", "ambiguous"]))
        XCTAssertGreaterThanOrEqual(entries.filter { $0.label == "industry" }.count, 25)
        XCTAssertTrue(entries.allSatisfy { ["crossref", "pubmed", "both"].contains($0.source) })
        // Every ambiguous entry carries its reason rather than being dropped.
        XCTAssertTrue(entries.filter { $0.label == "ambiguous" }.allSatisfy { $0.reason?.isEmpty == false })
    }

    func testPrecisionMeetsTheFloor() throws {
        let (tp, fp, _) = try scoreCorpus()
        let precision = Double(tp) / Double(tp + fp)

        XCTAssertGreaterThanOrEqual(precision, Self.minPrecision, "precision fell to \(precision)")
    }

    func testRecallMeetsTheFloor() throws {
        let (tp, _, fn) = try scoreCorpus()
        let recall = Double(tp) / Double(tp + fn)

        XCTAssertGreaterThanOrEqual(recall, Self.minRecall, "recall fell to \(recall)")
    }

    /// The ship rule from bmlib's design: gain recall without losing precision.
    func testItBeatsTheMatcherItReplaced() throws {
        let (tp, fp, fn) = try scoreCorpus()
        let precision = Double(tp) / Double(tp + fp)
        let recall = Double(tp) / Double(tp + fn)

        XCTAssertGreaterThan(precision, Self.previousPrecision)
        XCTAssertGreaterThan(recall, Self.previousRecall)
    }
}
