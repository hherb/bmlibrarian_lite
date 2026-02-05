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

/// Unit tests for COIAnalyzer pure functions.
final class COIAnalyzerTests: XCTestCase {

    // MARK: - Main Analysis Tests

    /// Test analyzing nil statement returns notAvailable.
    func testAnalyzeNilStatement() {
        let result = COIAnalyzer.analyze(statement: nil)
        XCTAssertNil(result.statement)
        XCTAssertFalse(result.hasIndustryTies)
        XCTAssertEqual(result.confidence, 0.0)
    }

    /// Test analyzing empty statement returns notAvailable.
    func testAnalyzeEmptyStatement() {
        let result = COIAnalyzer.analyze(statement: "")
        XCTAssertNil(result.statement)
    }

    /// Test analyzing "no conflict" statement.
    func testAnalyzeNoConflictStatement() {
        let statement = "The authors declare no conflict of interest."
        let result = COIAnalyzer.analyze(statement: statement)

        XCTAssertEqual(result.statement, statement)
        XCTAssertFalse(result.hasIndustryTies)
        XCTAssertEqual(result.confidence, 0.9)
    }

    /// Test analyzing "nothing to disclose" statement.
    func testAnalyzeNothingToDisclose() {
        let statement = "Nothing to disclose."
        let result = COIAnalyzer.analyze(statement: statement)

        XCTAssertFalse(result.hasIndustryTies)
        XCTAssertEqual(result.confidence, 0.9)
    }

    /// Test analyzing "no competing interests" statement.
    func testAnalyzeNoCompetingInterests() {
        let statement = "The authors declare no competing interests."
        let result = COIAnalyzer.analyze(statement: statement)

        XCTAssertFalse(result.hasIndustryTies)
        XCTAssertEqual(result.confidence, 0.9)
    }

    /// Test analyzing "none declared" statement.
    func testAnalyzeNoneDeclared() {
        let statement = "Conflicts of interest: None declared."
        let result = COIAnalyzer.analyze(statement: statement)

        XCTAssertFalse(result.hasIndustryTies)
        XCTAssertEqual(result.confidence, 0.9)
    }

    /// Test analyzing statement with industry ties.
    func testAnalyzeIndustryTies() {
        let statement = "Author X received grants from Pfizer Inc. and serves as a consultant for Novartis."
        let result = COIAnalyzer.analyze(statement: statement)

        XCTAssertTrue(result.hasIndustryTies)
        XCTAssertGreaterThan(result.confidence, 0.5)
    }

    /// Test analyzing statement with honoraria.
    func testAnalyzeWithHonoraria() {
        let statement = "Author received honoraria from pharmaceutical companies."
        let result = COIAnalyzer.analyze(statement: statement)

        XCTAssertTrue(result.hasIndustryTies)
    }

    /// Test analyzing employee disclosure.
    func testAnalyzeEmployeeOf() {
        let statement = "Dr. Smith is an employee of Bristol-Myers Squibb."
        let result = COIAnalyzer.analyze(statement: statement)

        XCTAssertTrue(result.hasIndustryTies)
        XCTAssertFalse(result.disclosedRelationships.isEmpty)
    }

    /// Test analyzing stock/shareholder disclosure.
    func testAnalyzeStockOwnership() {
        let statement = "The author owns stock in Gilead Sciences and Moderna."
        let result = COIAnalyzer.analyze(statement: statement)

        XCTAssertTrue(result.hasIndustryTies)
    }

    /// Test analyzing advisory board disclosure.
    func testAnalyzeAdvisoryBoard() {
        let statement = "Dr. Jones serves on the advisory board for AstraZeneca."
        let result = COIAnalyzer.analyze(statement: statement)

        XCTAssertTrue(result.hasIndustryTies)
    }

    /// Test analyzing speaker bureau disclosure.
    func testAnalyzeSpeakerBureau() {
        let statement = "Author has received speaker fees from several pharmaceutical companies."
        let result = COIAnalyzer.analyze(statement: statement)

        XCTAssertTrue(result.hasIndustryTies)
    }

    // MARK: - No Conflict Detection Tests

    /// Test containsNoConflictDeclaration with various patterns.
    func testContainsNoConflictDeclaration() {
        XCTAssertTrue(COIAnalyzer.containsNoConflictDeclaration("no conflict of interest"))
        XCTAssertTrue(COIAnalyzer.containsNoConflictDeclaration("nothing to disclose"))
        XCTAssertTrue(COIAnalyzer.containsNoConflictDeclaration("no competing interests"))
        XCTAssertTrue(COIAnalyzer.containsNoConflictDeclaration("none declared"))
        XCTAssertTrue(COIAnalyzer.containsNoConflictDeclaration("no financial interest"))
        XCTAssertTrue(COIAnalyzer.containsNoConflictDeclaration("no potential conflict"))
        XCTAssertFalse(COIAnalyzer.containsNoConflictDeclaration("received grants from pfizer"))
    }

    /// Test case insensitivity of no-conflict detection.
    func testContainsNoConflictDeclarationCaseInsensitive() {
        XCTAssertTrue(COIAnalyzer.containsNoConflictDeclaration("NO CONFLICT OF INTEREST"))
        XCTAssertTrue(COIAnalyzer.containsNoConflictDeclaration("Nothing To Disclose"))
        XCTAssertTrue(COIAnalyzer.containsNoConflictDeclaration("NONE DECLARED"))
    }

    // MARK: - Industry Match Counting Tests

    /// Test counting single industry match.
    func testCountIndustryMatchesSingle() {
        let count = COIAnalyzer.countIndustryMatches(in: "works for pfizer inc.")
        XCTAssertGreaterThanOrEqual(count, 1)
    }

    /// Test counting multiple industry matches.
    func testCountIndustryMatchesMultiple() {
        let count = COIAnalyzer.countIndustryMatches(in: "consultant for pharma corp. and biotech ltd.")
        XCTAssertGreaterThanOrEqual(count, 2)
    }

    /// Test counting zero industry matches.
    func testCountIndustryMatchesNone() {
        let count = COIAnalyzer.countIndustryMatches(in: "funded by nih and university grant")
        XCTAssertEqual(count, 0)
    }

    /// Test counting matches with employee relationship.
    func testCountIndustryMatchesEmployee() {
        let count = COIAnalyzer.countIndustryMatches(in: "is an employee of merck")
        XCTAssertGreaterThanOrEqual(count, 1)
    }

    // MARK: - Relationship Extraction Tests

    /// Test extracting grants relationships.
    func testExtractRelationshipsGrants() {
        let relationships = COIAnalyzer.extractRelationships(
            from: "received grants from pfizer and novartis"
        )
        XCTAssertFalse(relationships.isEmpty)
    }

    /// Test extracting consultant relationship.
    func testExtractRelationshipsConsultant() {
        let relationships = COIAnalyzer.extractRelationships(
            from: "serves as consultant for medtronic"
        )
        XCTAssertFalse(relationships.isEmpty)
    }

    /// Test extracting employee relationship.
    func testExtractRelationshipsEmployee() {
        let relationships = COIAnalyzer.extractRelationships(
            from: "employee of astrazeneca"
        )
        XCTAssertFalse(relationships.isEmpty)
    }

    /// Test extracting stock ownership relationship.
    func testExtractRelationshipsStock() {
        let relationships = COIAnalyzer.extractRelationships(
            from: "owns stock in moderna and johnson & johnson"
        )
        XCTAssertFalse(relationships.isEmpty)
    }

    /// Test extracting advisory board relationship.
    func testExtractRelationshipsAdvisoryBoard() {
        let relationships = COIAnalyzer.extractRelationships(
            from: "serves on the advisory board for genentech"
        )
        XCTAssertFalse(relationships.isEmpty)
    }

    /// Test extracting multiple relationships.
    func testExtractRelationshipsMultiple() {
        let text = "received grants from pfizer, consultant for novartis, and employee of roche"
        let relationships = COIAnalyzer.extractRelationships(from: text)
        XCTAssertGreaterThanOrEqual(relationships.count, 2)
    }

    /// Test deduplication of extracted relationships.
    func testExtractRelationshipsDeduplication() {
        let text = "received grants from pfizer. also received grants from pfizer for another project"
        let relationships = COIAnalyzer.extractRelationships(from: text)
        // Should deduplicate based on extracted company names
        XCTAssertGreaterThanOrEqual(relationships.count, 1)
    }

    // MARK: - Discrepancy Check Tests

    /// Test discrepancy when industry funding but no industry ties in COI.
    func testCheckFundingCOIDiscrepancyDetected() {
        let coiResult = COIAnalysisResult(
            statement: "No conflicts declared",
            hasIndustryTies: false,
            confidence: 0.9
        )
        let warning = COIAnalyzer.checkFundingCOIDiscrepancy(
            coiResult: coiResult,
            industryFundingDetected: true
        )
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning!.contains("Industry funding detected"))
    }

    /// Test no discrepancy when no industry funding.
    func testCheckFundingCOIDiscrepancyNoFunding() {
        let coiResult = COIAnalysisResult(
            statement: "No conflicts declared",
            hasIndustryTies: false,
            confidence: 0.9
        )
        let warning = COIAnalyzer.checkFundingCOIDiscrepancy(
            coiResult: coiResult,
            industryFundingDetected: false
        )
        XCTAssertNil(warning)
    }

    /// Test no discrepancy when proper disclosure.
    func testCheckFundingCOIDiscrepancyProperDisclosure() {
        let coiResult = COIAnalysisResult(
            statement: "Received grants from Pfizer",
            hasIndustryTies: true,
            confidence: 0.8
        )
        let warning = COIAnalyzer.checkFundingCOIDiscrepancy(
            coiResult: coiResult,
            industryFundingDetected: true
        )
        XCTAssertNil(warning)
    }

    /// Test discrepancy when no COI statement at all.
    func testCheckFundingCOIDiscrepancyMissingStatement() {
        let warning = COIAnalyzer.checkFundingCOIDiscrepancy(
            coiResult: .notAvailable,
            industryFundingDetected: true
        )
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning!.contains("no COI statement found"))
    }

    // MARK: - Significant Industry Ties Tests

    /// Test hasSignificantIndustryTies with multiple relationships.
    func testHasSignificantIndustryTiesMultiple() {
        let result = COIAnalysisResult(
            statement: "Grants from Pfizer and Novartis",
            hasIndustryTies: true,
            disclosedRelationships: ["pfizer", "novartis"],
            confidence: 0.7
        )
        XCTAssertTrue(COIAnalyzer.hasSignificantIndustryTies(result))
    }

    /// Test hasSignificantIndustryTies with high confidence.
    func testHasSignificantIndustryTiesHighConfidence() {
        let result = COIAnalysisResult(
            statement: "Employee of Merck",
            hasIndustryTies: true,
            disclosedRelationships: ["merck"],
            confidence: 0.85
        )
        XCTAssertTrue(COIAnalyzer.hasSignificantIndustryTies(result))
    }

    /// Test hasSignificantIndustryTies with no ties.
    func testHasSignificantIndustryTiesNoTies() {
        let result = COIAnalysisResult(
            statement: "No conflicts declared",
            hasIndustryTies: false,
            confidence: 0.9
        )
        XCTAssertFalse(COIAnalyzer.hasSignificantIndustryTies(result))
    }

    // MARK: - Summary Tests

    /// Test formatSummary for no COI statement.
    func testFormatSummaryNoCOI() {
        let summary = COIAnalyzer.formatSummary(.notAvailable)
        XCTAssertTrue(summary.contains("No conflict of interest statement"))
    }

    /// Test formatSummary for no conflicts declared.
    func testFormatSummaryNoConflicts() {
        let result = COIAnalysisResult(
            statement: "None declared",
            hasIndustryTies: false,
            confidence: 0.9
        )
        let summary = COIAnalyzer.formatSummary(result)
        XCTAssertTrue(summary.contains("No conflicts declared"))
    }

    /// Test formatSummary with relationships.
    func testFormatSummaryWithRelationships() {
        let result = COIAnalysisResult(
            statement: "Received grants from Pfizer",
            hasIndustryTies: true,
            disclosedRelationships: ["pfizer"],
            confidence: 0.8
        )
        let summary = COIAnalyzer.formatSummary(result)
        XCTAssertTrue(summary.contains("Industry ties disclosed"))
        XCTAssertTrue(summary.contains("1 relationship"))
    }

    /// Test formatSummary with multiple relationships.
    func testFormatSummaryWithMultipleRelationships() {
        let result = COIAnalysisResult(
            statement: "Grants from Pfizer and Novartis",
            hasIndustryTies: true,
            disclosedRelationships: ["pfizer", "novartis"],
            confidence: 0.8
        )
        let summary = COIAnalyzer.formatSummary(result)
        XCTAssertTrue(summary.contains("2 relationships"))
    }

    /// Test formatSummary with industry ties but no extracted relationships.
    func testFormatSummaryIndustryTiesNoRelationships() {
        let result = COIAnalysisResult(
            statement: "Has pharmaceutical ties",
            hasIndustryTies: true,
            disclosedRelationships: [],
            confidence: 0.6
        )
        let summary = COIAnalyzer.formatSummary(result)
        XCTAssertTrue(summary.contains("Industry ties indicated"))
    }

    // MARK: - Format Relationships Tests

    /// Test formatRelationships with empty list.
    func testFormatRelationshipsEmpty() {
        let formatted = COIAnalyzer.formatRelationships([])
        XCTAssertEqual(formatted, "None disclosed")
    }

    /// Test formatRelationships with single relationship.
    func testFormatRelationshipsSingle() {
        let formatted = COIAnalyzer.formatRelationships(["pfizer"])
        XCTAssertEqual(formatted, "Pfizer")
    }

    /// Test formatRelationships with multiple relationships.
    func testFormatRelationshipsMultiple() {
        let formatted = COIAnalyzer.formatRelationships(["pfizer", "novartis"])
        XCTAssertTrue(formatted.contains("Pfizer"))
        XCTAssertTrue(formatted.contains("Novartis"))
        XCTAssertTrue(formatted.contains("; "))
    }
}
