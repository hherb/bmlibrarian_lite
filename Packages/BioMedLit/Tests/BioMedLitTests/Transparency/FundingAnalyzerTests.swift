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

/// Unit tests for FundingAnalyzer pure functions.
final class FundingAnalyzerTests: XCTestCase {

    // MARK: - Funder Classification Tests

    /// Test classification of known industry funder by DOI.
    func testClassifyKnownIndustryFunderByDOI() {
        let (isIndustry, confidence) = FundingAnalyzer.classifyFunder(
            name: "Pfizer",
            doi: "10.13039/100004319"
        )
        XCTAssertTrue(isIndustry)
        XCTAssertEqual(confidence, 1.0)
    }

    /// Test classification with different known industry DOIs.
    func testClassifyMultipleKnownIndustryFunderDOIs() {
        let testCases: [(name: String, doi: String)] = [
            ("AstraZeneca", "10.13039/100004325"),
            ("Novartis", "10.13039/100004336"),
            ("Roche", "10.13039/100004339"),
            ("Merck", "10.13039/100004334"),
        ]

        for (name, doi) in testCases {
            let (isIndustry, confidence) = FundingAnalyzer.classifyFunder(name: name, doi: doi)
            XCTAssertTrue(isIndustry, "Expected \(name) to be classified as industry")
            XCTAssertEqual(confidence, 1.0, "Expected confidence 1.0 for known DOI")
        }
    }

    /// Test classification of government funder (NIH).
    func testClassifyGovernmentFunderNIH() {
        let (isIndustry, confidence) = FundingAnalyzer.classifyFunder(
            name: "National Institutes of Health"
        )
        XCTAssertFalse(isIndustry)
        XCTAssertGreaterThan(confidence, 0.8)
    }

    /// Test classification of various government funders.
    func testClassifyGovernmentFunders() {
        let governmentFunders = [
            "NIH",
            "National Science Foundation",
            "NSF",
            "Centers for Disease Control",
            "CDC",
            "Veterans Affairs",
            "Medical Research Council",
        ]

        for funder in governmentFunders {
            let (isIndustry, _) = FundingAnalyzer.classifyFunder(name: funder)
            XCTAssertFalse(isIndustry, "Expected '\(funder)' to not be classified as industry")
        }
    }

    /// Test classification of academic funder.
    func testClassifyAcademicFunder() {
        let (isIndustry, confidence) = FundingAnalyzer.classifyFunder(
            name: "Harvard University"
        )
        XCTAssertFalse(isIndustry)
        XCTAssertGreaterThan(confidence, 0.7)
    }

    /// Test classification of various academic funders.
    func testClassifyAcademicFunders() {
        let academicFunders = [
            "University of Oxford",
            "Stanford Medical School",
            "Johns Hopkins Hospital",
            "Massachusetts General Hospital",
        ]

        for funder in academicFunders {
            let (isIndustry, _) = FundingAnalyzer.classifyFunder(name: funder)
            XCTAssertFalse(isIndustry, "Expected '\(funder)' to not be classified as industry")
        }
    }

    /// Test classification of corporate entity by suffix.
    func testClassifyCorporateBySuffix() {
        let (isIndustry, confidence) = FundingAnalyzer.classifyFunder(
            name: "Unknown Biotech Inc."
        )
        XCTAssertTrue(isIndustry)
        XCTAssertGreaterThan(confidence, 0.6)
    }

    /// Test classification of various corporate suffixes.
    func testClassifyCorporateSuffixes() {
        let corporateNames = [
            "Acme Pharma Inc.",
            "BioMed Corp.",
            "MedDevice Ltd.",
            "HealthTech GmbH",
            "Diagnostics PLC",
        ]

        for name in corporateNames {
            let (isIndustry, _) = FundingAnalyzer.classifyFunder(name: name)
            XCTAssertTrue(isIndustry, "Expected '\(name)' to be classified as industry")
        }
    }

    /// Test classification of unknown funder.
    func testClassifyUnknownFunder() {
        let (isIndustry, confidence) = FundingAnalyzer.classifyFunder(
            name: "Some Foundation"
        )
        XCTAssertFalse(isIndustry)
        XCTAssertLessThan(confidence, 0.5)
    }

    /// Test that government pattern takes precedence over corporate suffix.
    func testGovernmentTakesPrecedenceOverCorporateSuffix() {
        // "Veterans Affairs" could match "Veterans" but should not be industry
        let (isIndustry, _) = FundingAnalyzer.classifyFunder(
            name: "Department of Veterans Affairs"
        )
        XCTAssertFalse(isIndustry)
    }

    // MARK: - CreateFunderInfo Tests

    /// Test createFunderInfo returns correct structure.
    func testCreateFunderInfo() {
        let funderInfo = FundingAnalyzer.createFunderInfo(
            name: "Pfizer Inc.",
            doi: "10.13039/100004319",
            awardNumbers: ["R01-123456", "P50-789012"]
        )

        XCTAssertEqual(funderInfo.name, "Pfizer Inc.")
        XCTAssertEqual(funderInfo.funderDOI, "10.13039/100004319")
        XCTAssertEqual(funderInfo.awardNumbers.count, 2)
        XCTAssertTrue(funderInfo.isIndustry)
        XCTAssertEqual(funderInfo.confidence, 1.0)
    }

    /// Test createFunderInfo with no optional parameters.
    func testCreateFunderInfoMinimal() {
        let funderInfo = FundingAnalyzer.createFunderInfo(name: "Unknown Foundation")

        XCTAssertEqual(funderInfo.name, "Unknown Foundation")
        XCTAssertNil(funderInfo.funderDOI)
        XCTAssertTrue(funderInfo.awardNumbers.isEmpty)
        XCTAssertFalse(funderInfo.isIndustry)
    }

    // MARK: - Sponsor Type Tests

    /// Test determineSponsorType with industry-only funders.
    func testDetermineSponsorTypeIndustryOnly() {
        let funders = [
            FunderInfo(name: "Pfizer", isIndustry: true, confidence: 1.0),
            FunderInfo(name: "Novartis", isIndustry: true, confidence: 1.0),
        ]
        XCTAssertEqual(FundingAnalyzer.determineSponsorType(from: funders), .industry)
    }

    /// Test determineSponsorType with mixed funders.
    func testDetermineSponsorTypeMixed() {
        let funders = [
            FunderInfo(name: "Pfizer", isIndustry: true, confidence: 1.0),
            FunderInfo(name: "National Institutes of Health", isIndustry: false, confidence: 0.9),
        ]
        XCTAssertEqual(FundingAnalyzer.determineSponsorType(from: funders), .mixed)
    }

    /// Test determineSponsorType with government funders only.
    func testDetermineSponsorTypeGovernment() {
        let funders = [
            FunderInfo(name: "National Institutes of Health", isIndustry: false, confidence: 0.9),
            FunderInfo(name: "NIH", isIndustry: false, confidence: 0.85),
        ]
        XCTAssertEqual(FundingAnalyzer.determineSponsorType(from: funders), .government)
    }

    /// Test determineSponsorType with academic funders only.
    func testDetermineSponsorTypeAcademic() {
        let funders = [
            FunderInfo(name: "Harvard University", isIndustry: false, confidence: 0.8),
        ]
        XCTAssertEqual(FundingAnalyzer.determineSponsorType(from: funders), .academic)
    }

    /// Test determineSponsorType with nonprofit funders.
    func testDetermineSponsorTypeNonprofit() {
        let funders = [
            FunderInfo(name: "American Heart Association", isIndustry: false, confidence: 0.3),
        ]
        XCTAssertEqual(FundingAnalyzer.determineSponsorType(from: funders), .nonprofit)
    }

    /// Test determineSponsorType with empty list.
    func testDetermineSponsorTypeEmpty() {
        XCTAssertEqual(FundingAnalyzer.determineSponsorType(from: []), .unknown)
    }

    // MARK: - Industry Funding Status Tests

    /// Test industryFundingStatus when industry funding is detected.
    func testIndustryFundingStatusDetected() {
        let funders = [
            FunderInfo(name: "NIH", isIndustry: false, confidence: 0.9),
            FunderInfo(name: "Pfizer", isIndustry: true, confidence: 1.0),
        ]
        let (detected, confidence) = FundingAnalyzer.industryFundingStatus(from: funders)
        XCTAssertTrue(detected)
        XCTAssertEqual(confidence, 1.0)
    }

    /// Test industryFundingStatus when no industry funding.
    func testIndustryFundingStatusNotDetected() {
        let funders = [
            FunderInfo(name: "NIH", isIndustry: false, confidence: 0.9),
        ]
        let (detected, confidence) = FundingAnalyzer.industryFundingStatus(from: funders)
        XCTAssertFalse(detected)
        XCTAssertEqual(confidence, 0.0)
    }

    /// Test industryFundingStatus returns max confidence.
    func testIndustryFundingStatusReturnsMaxConfidence() {
        let funders = [
            FunderInfo(name: "Company A", isIndustry: true, confidence: 0.7),
            FunderInfo(name: "Company B", isIndustry: true, confidence: 0.9),
            FunderInfo(name: "Company C", isIndustry: true, confidence: 0.8),
        ]
        let (detected, confidence) = FundingAnalyzer.industryFundingStatus(from: funders)
        XCTAssertTrue(detected)
        XCTAssertEqual(confidence, 0.9)
    }

    // MARK: - Merge Tests

    /// Test mergeFunders removes duplicates.
    func testMergeFundersRemovesDuplicates() {
        let list1 = [FunderInfo(name: "Pfizer", isIndustry: true, confidence: 0.7)]
        let list2 = [FunderInfo(name: "pfizer", isIndustry: true, confidence: 1.0)]

        let merged = FundingAnalyzer.mergeFunders(list1, list2)

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.confidence, 1.0) // Kept higher confidence
    }

    /// Test mergeFunders preserves distinct funders.
    func testMergeFundersPreservesDistinct() {
        let list1 = [FunderInfo(name: "Pfizer", isIndustry: true, confidence: 1.0)]
        let list2 = [FunderInfo(name: "Novartis", isIndustry: true, confidence: 1.0)]

        let merged = FundingAnalyzer.mergeFunders(list1, list2)

        XCTAssertEqual(merged.count, 2)
    }

    /// Test mergeFunders with empty lists.
    func testMergeFundersEmptyLists() {
        let merged = FundingAnalyzer.mergeFunders([], [])
        XCTAssertTrue(merged.isEmpty)
    }

    // MARK: - Trial Sponsor Update Tests

    /// Test updateSponsorType from unknown to industry.
    func testUpdateSponsorTypeUnknownToIndustry() {
        let updated = FundingAnalyzer.updateSponsorType(.unknown, withTrialSponsorClass: "INDUSTRY")
        XCTAssertEqual(updated, .industry)
    }

    /// Test updateSponsorType from government to mixed.
    func testUpdateSponsorTypeGovernmentToMixed() {
        let updated = FundingAnalyzer.updateSponsorType(.government, withTrialSponsorClass: "INDUSTRY")
        XCTAssertEqual(updated, .mixed)
    }

    /// Test updateSponsorType industry remains industry.
    func testUpdateSponsorTypeIndustryNoChange() {
        let updated = FundingAnalyzer.updateSponsorType(.industry, withTrialSponsorClass: "INDUSTRY")
        XCTAssertEqual(updated, .industry)
    }

    /// Test updateSponsorType with nil sponsor class.
    func testUpdateSponsorTypeNilSponsorClass() {
        let updated = FundingAnalyzer.updateSponsorType(.government, withTrialSponsorClass: nil)
        XCTAssertEqual(updated, .government)
    }

    /// Test updateSponsorType with non-industry sponsor class.
    func testUpdateSponsorTypeNonIndustrySponsorClass() {
        let updated = FundingAnalyzer.updateSponsorType(.unknown, withTrialSponsorClass: "NIH")
        XCTAssertEqual(updated, .unknown)
    }

    // MARK: - CrossRef Parsing Tests

    /// Test parseCrossRefFunders with valid data.
    func testParseCrossRefFunders() {
        let crossRefData: [[String: Any]] = [
            [
                "name": "Pfizer Inc.",
                "DOI": "10.13039/100004319",
                "award": ["R01-123456"],
            ],
            [
                "name": "NIH",
            ],
        ]

        let funders = FundingAnalyzer.parseCrossRefFunders(crossRefData)

        XCTAssertEqual(funders.count, 2)
        XCTAssertEqual(funders[0].name, "Pfizer Inc.")
        XCTAssertEqual(funders[0].funderDOI, "10.13039/100004319")
        XCTAssertTrue(funders[0].isIndustry)
        XCTAssertEqual(funders[1].name, "NIH")
        XCTAssertFalse(funders[1].isIndustry)
    }

    /// Test parseCrossRefFunders with nil input.
    func testParseCrossRefFundersNil() {
        let funders = FundingAnalyzer.parseCrossRefFunders(nil)
        XCTAssertTrue(funders.isEmpty)
    }

    /// Test parseCrossRefFunders filters entries without name.
    func testParseCrossRefFundersFiltersInvalid() {
        let crossRefData: [[String: Any]] = [
            ["DOI": "10.13039/100004319"], // Missing name
            ["name": "Valid Funder"],
        ]

        let funders = FundingAnalyzer.parseCrossRefFunders(crossRefData)
        XCTAssertEqual(funders.count, 1)
    }

    // MARK: - PubMed Parsing Tests

    /// Test parsePubMedGrants with valid data.
    func testParsePubMedGrants() {
        let pubMedData: [[String: String?]] = [
            ["agency": "National Cancer Institute", "grant_id": "R01-CA123456"],
            ["agency": "NHLBI", "grant_id": nil],
        ]

        let funders = FundingAnalyzer.parsePubMedGrants(pubMedData)

        XCTAssertEqual(funders.count, 2)
        XCTAssertEqual(funders[0].name, "National Cancer Institute")
        XCTAssertFalse(funders[0].isIndustry)
    }

    /// Test parsePubMedGrants with nil input.
    func testParsePubMedGrantsNil() {
        let funders = FundingAnalyzer.parsePubMedGrants(nil)
        XCTAssertTrue(funders.isEmpty)
    }

    /// Test parsePubMedGrants filters empty agencies.
    func testParsePubMedGrantsFiltersEmpty() {
        let pubMedData: [[String: String?]] = [
            ["agency": "", "grant_id": "123"],
            ["agency": "Valid Agency", "grant_id": nil],
        ]

        let funders = FundingAnalyzer.parsePubMedGrants(pubMedData)
        XCTAssertEqual(funders.count, 1)
    }

    // MARK: - Summary Tests

    /// Test formatSummary for industry-funded.
    func testFormatSummaryIndustry() {
        let funders = [
            FunderInfo(name: "Pfizer", isIndustry: true, confidence: 1.0),
        ]
        let summary = FundingAnalyzer.formatSummary(funders: funders, sponsorType: .industry)
        XCTAssertTrue(summary.contains("Industry-funded"))
    }

    /// Test formatSummary for mixed funding.
    func testFormatSummaryMixed() {
        let funders = [
            FunderInfo(name: "Pfizer", isIndustry: true, confidence: 1.0),
            FunderInfo(name: "NIH", isIndustry: false, confidence: 0.9),
        ]
        let summary = FundingAnalyzer.formatSummary(funders: funders, sponsorType: .mixed)
        XCTAssertTrue(summary.contains("Mixed funding"))
        XCTAssertTrue(summary.contains("1 industry"))
    }

    /// Test formatSummary for empty funders.
    func testFormatSummaryEmpty() {
        let summary = FundingAnalyzer.formatSummary(funders: [], sponsorType: .unknown)
        XCTAssertTrue(summary.contains("No funding information"))
    }
}
