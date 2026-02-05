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

final class TransparencyConstantsTests: XCTestCase {

    // MARK: - TransparencyConstants Tests

    func testAPIURLsAreValid() {
        XCTAssertTrue(TransparencyConstants.crossRefBaseURL.starts(with: "https://"))
        XCTAssertTrue(TransparencyConstants.clinicalTrialsBaseURL.starts(with: "https://"))
        XCTAssertTrue(TransparencyConstants.openAlexBaseURL.starts(with: "https://"))
    }

    func testRateLimitsArePositive() {
        XCTAssertGreaterThan(TransparencyConstants.crossRefRateLimit, 0)
        XCTAssertGreaterThan(TransparencyConstants.clinicalTrialsRateLimit, 0)
        XCTAssertGreaterThan(TransparencyConstants.minimumRequestInterval, 0)
    }

    func testScoreThresholdsAreOrdered() {
        // High risk threshold < medium risk threshold
        XCTAssertLessThan(
            TransparencyConstants.highRiskScoreThreshold,
            TransparencyConstants.mediumRiskScoreThreshold
        )

        // Category thresholds are in descending order
        XCTAssertGreaterThan(
            TransparencyConstants.goodTransparencyThreshold,
            TransparencyConstants.averageTransparencyThreshold
        )
        XCTAssertGreaterThan(
            TransparencyConstants.averageTransparencyThreshold,
            TransparencyConstants.belowAverageTransparencyThreshold
        )
    }

    func testBaseScoreIsReasonable() {
        // Base score should be within valid range
        XCTAssertGreaterThanOrEqual(
            TransparencyConstants.baseTransparencyScore,
            TransparencyConstants.minTransparencyScore
        )
        XCTAssertLessThanOrEqual(
            TransparencyConstants.baseTransparencyScore,
            TransparencyConstants.maxTransparencyScore
        )
    }

    func testScoreRangeIsValid() {
        XCTAssertEqual(TransparencyConstants.minTransparencyScore, 0)
        XCTAssertEqual(TransparencyConstants.maxTransparencyScore, 100)
        XCTAssertLessThan(
            TransparencyConstants.minTransparencyScore,
            TransparencyConstants.maxTransparencyScore
        )
    }

    // MARK: - KnownIndustryFunders Tests

    func testKnownIndustryFunderLookup() {
        XCTAssertTrue(KnownIndustryFunders.isIndustryFunder("10.13039/100004319"))
        XCTAssertFalse(KnownIndustryFunders.isIndustryFunder("10.13039/unknown"))
        XCTAssertFalse(KnownIndustryFunders.isIndustryFunder(nil))
    }

    func testKnownIndustryFunderName() {
        XCTAssertEqual(KnownIndustryFunders.companyName(for: "10.13039/100004319"), "Pfizer")
        XCTAssertEqual(KnownIndustryFunders.companyName(for: "10.13039/100004325"), "AstraZeneca")
        XCTAssertEqual(KnownIndustryFunders.companyName(for: "10.13039/100004334"), "Merck")
        XCTAssertNil(KnownIndustryFunders.companyName(for: "unknown"))
    }

    func testKnownIndustryFunderRegistryNotEmpty() {
        XCTAssertGreaterThan(KnownIndustryFunders.funderDOIs.count, 0)
    }

    func testKnownIndustryFunderDOIsAreValid() {
        for (doi, _) in KnownIndustryFunders.funderDOIs {
            XCTAssertTrue(doi.starts(with: "10.13039/"), "Invalid funder DOI format: \(doi)")
        }
    }

    // MARK: - IndustryPatterns Tests

    func testIndustryKeywordsMatch() {
        let patterns = IndustryPatterns.industryKeywords

        XCTAssertTrue(RegexHelper.anyMatch(patterns: patterns, in: "Funded by Pfizer Inc."))
        XCTAssertTrue(RegexHelper.anyMatch(patterns: patterns, in: "Pharmaceutical company support"))
        XCTAssertTrue(RegexHelper.anyMatch(patterns: patterns, in: "Biotechnology firm"))
        XCTAssertTrue(RegexHelper.anyMatch(patterns: patterns, in: "Employee of Novartis"))
        XCTAssertTrue(RegexHelper.anyMatch(patterns: patterns, in: "Shareholder in AstraZeneca"))
        XCTAssertTrue(RegexHelper.anyMatch(patterns: patterns, in: "Consultant for Merck"))
        XCTAssertTrue(RegexHelper.anyMatch(patterns: patterns, in: "Advisory board member"))
        XCTAssertTrue(RegexHelper.anyMatch(patterns: patterns, in: "Speaker's bureau fee"))
        XCTAssertTrue(RegexHelper.anyMatch(patterns: patterns, in: "Received honoraria"))
    }

    func testGovernmentPatternsMatch() {
        let patterns = IndustryPatterns.governmentPatterns

        XCTAssertTrue(RegexHelper.anyMatch(patterns: patterns, in: "Funded by NIH grant"))
        XCTAssertTrue(RegexHelper.anyMatch(patterns: patterns, in: "National Institutes of Health"))
        XCTAssertTrue(RegexHelper.anyMatch(patterns: patterns, in: "NIAID support"))
        XCTAssertTrue(RegexHelper.anyMatch(patterns: patterns, in: "National Science Foundation"))
        XCTAssertTrue(RegexHelper.anyMatch(patterns: patterns, in: "CDC funding"))
        XCTAssertTrue(RegexHelper.anyMatch(patterns: patterns, in: "Veterans Affairs"))
        XCTAssertTrue(RegexHelper.anyMatch(patterns: patterns, in: "PCORI grant"))
        XCTAssertTrue(RegexHelper.anyMatch(patterns: patterns, in: "Wellcome Trust"))

        // Should not match industry
        XCTAssertFalse(RegexHelper.anyMatch(patterns: patterns, in: "Pfizer Inc."))
    }

    func testAcademicPatternsMatch() {
        let patterns = IndustryPatterns.academicPatterns

        XCTAssertTrue(RegexHelper.anyMatch(patterns: patterns, in: "Harvard University"))
        XCTAssertTrue(RegexHelper.anyMatch(patterns: patterns, in: "Stanford Medical School"))
        XCTAssertTrue(RegexHelper.anyMatch(patterns: patterns, in: "Johns Hopkins Hospital"))
        XCTAssertTrue(RegexHelper.anyMatch(patterns: patterns, in: "Medical Center grant"))
    }

    func testCorporateSuffixesMatch() {
        let patterns = IndustryPatterns.corporateSuffixes

        XCTAssertTrue(RegexHelper.anyMatch(patterns: patterns, in: "Pfizer Inc"))
        XCTAssertTrue(RegexHelper.anyMatch(patterns: patterns, in: "Novartis Corp"))
        XCTAssertTrue(RegexHelper.anyMatch(patterns: patterns, in: "AstraZeneca Ltd"))
        XCTAssertTrue(RegexHelper.anyMatch(patterns: patterns, in: "Boehringer Ingelheim GmbH"))
        XCTAssertTrue(RegexHelper.anyMatch(patterns: patterns, in: "GlaxoSmithKline PLC"))
    }

    // MARK: - COIPatterns Tests

    func testNoConflictPatternsMatch() {
        let patterns = COIPatterns.noConflictPatterns

        XCTAssertTrue(RegexHelper.anyMatch(
            patterns: patterns,
            in: "The authors declare no conflict of interest"
        ))
        XCTAssertTrue(RegexHelper.anyMatch(
            patterns: patterns,
            in: "Nothing to disclose"
        ))
        XCTAssertTrue(RegexHelper.anyMatch(
            patterns: patterns,
            in: "The authors have no competing interests"
        ))
        XCTAssertTrue(RegexHelper.anyMatch(
            patterns: patterns,
            in: "No financial interest to declare"
        ))
        XCTAssertTrue(RegexHelper.anyMatch(
            patterns: patterns,
            in: "None declared"
        ))

        // Should not match disclosure statements
        XCTAssertFalse(RegexHelper.anyMatch(
            patterns: patterns,
            in: "Author received grants from Pfizer"
        ))
    }

    func testRelationshipPatternsExtract() {
        let patterns = COIPatterns.relationshipPatterns

        // Test grants extraction
        let grantsText = "Author received grants from Pfizer and Novartis."
        var relationships: [String] = []
        for pattern in patterns {
            relationships.append(contentsOf: RegexHelper.extractAll(pattern: pattern, from: grantsText))
        }
        XCTAssertFalse(relationships.isEmpty)
        XCTAssertTrue(relationships.contains { $0.contains("pfizer") })

        // Test consultant extraction
        let consultantText = "Author is a consultant for AstraZeneca."
        var consultantRels: [String] = []
        for pattern in patterns {
            consultantRels.append(contentsOf: RegexHelper.extractAll(pattern: pattern, from: consultantText))
        }
        XCTAssertFalse(consultantRels.isEmpty)

        // Test employee extraction
        let employeeText = "Author is an employee of Merck."
        var employeeRels: [String] = []
        for pattern in patterns {
            employeeRels.append(contentsOf: RegexHelper.extractAll(pattern: pattern, from: employeeText))
        }
        XCTAssertFalse(employeeRels.isEmpty)
    }

    // MARK: - DataRepositoryPatterns Tests

    func testFullOpenPatternsMatch() {
        let patterns = DataRepositoryPatterns.fullOpenPatterns

        XCTAssertTrue(RegexHelper.anyMatch(
            patterns: patterns,
            in: "Data available at https://zenodo.org/123"
        ))
        XCTAssertTrue(RegexHelper.anyMatch(
            patterns: patterns,
            in: "Deposited in Gene Expression Omnibus"
        ))
        XCTAssertTrue(RegexHelper.anyMatch(
            patterns: patterns,
            in: "Available on figshare"
        ))
        XCTAssertTrue(RegexHelper.anyMatch(
            patterns: patterns,
            in: "Data deposited in Dryad"
        ))
        XCTAssertTrue(RegexHelper.anyMatch(
            patterns: patterns,
            in: "Code available at GitHub"
        ))
        XCTAssertTrue(RegexHelper.anyMatch(
            patterns: patterns,
            in: "Deposited in GEO"
        ))
        XCTAssertTrue(RegexHelper.anyMatch(
            patterns: patterns,
            in: "Sequences in GenBank"
        ))

        // Should not match restricted access
        XCTAssertFalse(RegexHelper.anyMatch(
            patterns: patterns,
            in: "Available upon request"
        ))
    }

    func testRestrictedPatternsMatch() {
        let patterns = DataRepositoryPatterns.restrictedPatterns

        XCTAssertTrue(RegexHelper.anyMatch(
            patterns: patterns,
            in: "Data available upon reasonable request"
        ))
        XCTAssertTrue(RegexHelper.anyMatch(
            patterns: patterns,
            in: "Available from the corresponding author"
        ))
        XCTAssertTrue(RegexHelper.anyMatch(
            patterns: patterns,
            in: "Contact the author for data"
        ))
        XCTAssertTrue(RegexHelper.anyMatch(
            patterns: patterns,
            in: "Requires data sharing agreement"
        ))
        XCTAssertTrue(RegexHelper.anyMatch(
            patterns: patterns,
            in: "IRB approval required"
        ))
        XCTAssertTrue(RegexHelper.anyMatch(
            patterns: patterns,
            in: "Ethics committee approval needed"
        ))
    }

    func testUnavailablePatternsMatch() {
        let patterns = DataRepositoryPatterns.unavailablePatterns

        XCTAssertTrue(RegexHelper.anyMatch(
            patterns: patterns,
            in: "Data are proprietary"
        ))
        XCTAssertTrue(RegexHelper.anyMatch(
            patterns: patterns,
            in: "Data cannot be shared"
        ))
        XCTAssertTrue(RegexHelper.anyMatch(
            patterns: patterns,
            in: "Data not publicly available"
        ))
        XCTAssertTrue(RegexHelper.anyMatch(
            patterns: patterns,
            in: "Data not available due to privacy"
        ))
    }

    func testURLPatternExtraction() {
        let text = "Data available at https://zenodo.org/record/12345 and https://github.com/user/repo"
        let urls = RegexHelper.findAll(pattern: DataRepositoryPatterns.urlPattern, in: text)

        XCTAssertEqual(urls.count, 2)
        XCTAssertTrue(urls.contains("https://zenodo.org/record/12345"))
        XCTAssertTrue(urls.contains("https://github.com/user/repo"))
    }

    func testAccessionPatternExtraction() {
        let text = "Data deposited with accession: GSE123456"
        let accession = RegexHelper.extractFirst(
            pattern: DataRepositoryPatterns.accessionPattern,
            from: text
        )

        XCTAssertEqual(accession, "gse123456")
    }

    // MARK: - ClinicalTrialPatterns Tests

    func testTrialKeywordsMatch() {
        let keywords = ClinicalTrialPatterns.trialKeywords

        XCTAssertTrue(keywords.contains("trial"))
        XCTAssertTrue(keywords.contains("randomized"))
        XCTAssertTrue(keywords.contains("rct"))
        XCTAssertTrue(keywords.contains("phase iii"))
    }

    func testNCTIdPatternExtraction() {
        let text = "This trial was registered at ClinicalTrials.gov (NCT01234567)."
        let nctIds = RegexHelper.findAll(
            pattern: ClinicalTrialPatterns.nctIdPattern,
            in: text
        )

        XCTAssertEqual(nctIds.count, 1)
        XCTAssertEqual(nctIds.first, "NCT01234567")
    }

    func testNCTIdPatternNoMatch() {
        let text = "This was an observational study without registration."
        let nctIds = RegexHelper.findAll(
            pattern: ClinicalTrialPatterns.nctIdPattern,
            in: text
        )

        XCTAssertTrue(nctIds.isEmpty)
    }

    func testRegistryNamesNotEmpty() {
        XCTAssertGreaterThan(ClinicalTrialPatterns.registryNames.count, 0)
        XCTAssertTrue(ClinicalTrialPatterns.registryNames.contains("ClinicalTrials.gov"))
        XCTAssertTrue(ClinicalTrialPatterns.registryNames.contains("ISRCTN"))
        XCTAssertTrue(ClinicalTrialPatterns.registryNames.contains("EudraCT"))
    }

    // MARK: - RegexHelper Tests

    func testRegexHelperCreation() {
        XCTAssertNotNil(RegexHelper.regex(#"\btest\b"#))
        XCTAssertNil(RegexHelper.regex("[invalid"))
    }

    func testRegexHelperAnyMatch() {
        let patterns = ["apple", "banana", "cherry"]

        XCTAssertTrue(RegexHelper.anyMatch(patterns: patterns, in: "I like apples"))
        XCTAssertTrue(RegexHelper.anyMatch(patterns: patterns, in: "BANANA bread"))
        XCTAssertFalse(RegexHelper.anyMatch(patterns: patterns, in: "orange juice"))
    }

    func testRegexHelperCountMatches() {
        let patterns = [#"\bthe\b"#]
        let text = "The quick brown fox jumps over the lazy dog."

        let count = RegexHelper.countMatches(patterns: patterns, in: text)
        XCTAssertEqual(count, 2)
    }

    func testRegexHelperExtractFirst() {
        let pattern = #"version (\d+\.\d+)"#
        let text = "Software version 2.5 released"

        let extracted = RegexHelper.extractFirst(pattern: pattern, from: text)
        XCTAssertEqual(extracted, "2.5")
    }

    func testRegexHelperExtractFirstNoMatch() {
        let pattern = #"version (\d+\.\d+)"#
        let text = "No version mentioned"

        let extracted = RegexHelper.extractFirst(pattern: pattern, from: text)
        XCTAssertNil(extracted)
    }

    func testRegexHelperExtractAll() {
        let pattern = #"(\d+)"#
        let text = "Numbers: 1, 22, 333"

        let extracted = RegexHelper.extractAll(pattern: pattern, from: text)
        XCTAssertEqual(extracted.count, 3)
        XCTAssertEqual(extracted, ["1", "22", "333"])
    }

    func testRegexHelperFindAll() {
        let pattern = #"\b\w+@\w+\.\w+\b"#
        let text = "Contact: alice@example.com and bob@test.org"

        let found = RegexHelper.findAll(pattern: pattern, in: text)
        XCTAssertEqual(found.count, 2)
        XCTAssertTrue(found.contains("alice@example.com"))
        XCTAssertTrue(found.contains("bob@test.org"))
    }

    func testRegexHelperCaseInsensitive() {
        let patterns = ["PFIZER"]

        XCTAssertTrue(RegexHelper.anyMatch(patterns: patterns, in: "pfizer"))
        XCTAssertTrue(RegexHelper.anyMatch(patterns: patterns, in: "Pfizer"))
        XCTAssertTrue(RegexHelper.anyMatch(patterns: patterns, in: "PFIZER"))
    }
}
