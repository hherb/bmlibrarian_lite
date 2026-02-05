# Step 04: COI Analyzer

## Goal

Create pure functions for analyzing conflict of interest statements.

## File to Create

### `Sources/BioMedLit/Transparency/Analysis/COIAnalyzer.swift`

```swift
// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2025 Dr Horst Herb
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Pure functions for analyzing conflict of interest statements.
///
/// All functions are stateless and can be safely called from any context.
///
/// Usage:
/// ```swift
/// let result = COIAnalyzer.analyze(statement: coiText)
/// // Returns: COIAnalysisResult with industry ties detection
/// ```
public enum COIAnalyzer {

    // MARK: - Main Analysis

    /// Analyze a conflict of interest statement for industry ties.
    ///
    /// - Parameter statement: The COI statement text (nil if not available)
    /// - Returns: COIAnalysisResult with analysis details
    public static func analyze(statement: String?) -> COIAnalysisResult {
        guard let statement = statement, !statement.isEmpty else {
            return .notAvailable
        }

        let statementLower = statement.lowercased()

        // Check for explicit "no conflicts" declarations
        if containsNoConflictDeclaration(statementLower) {
            return COIAnalysisResult(
                statement: statement,
                hasIndustryTies: false,
                disclosedRelationships: [],
                confidence: 0.9
            )
        }

        // Check for industry-related keywords
        let industryMatchCount = countIndustryMatches(in: statementLower)
        let hasIndustryTies = industryMatchCount > 0

        // Calculate confidence based on match strength
        let confidence: Double
        if hasIndustryTies {
            confidence = min(0.5 + Double(industryMatchCount) * 0.1, 0.95)
        } else {
            confidence = 0.5 // Uncertain - no clear indication either way
        }

        // Extract disclosed relationships
        let relationships = extractRelationships(from: statementLower)

        return COIAnalysisResult(
            statement: statement,
            hasIndustryTies: hasIndustryTies,
            disclosedRelationships: relationships,
            confidence: confidence
        )
    }

    // MARK: - Detection Functions

    /// Check if statement contains an explicit "no conflicts" declaration.
    ///
    /// - Parameter text: Lowercased statement text
    /// - Returns: True if no-conflict declaration found
    public static func containsNoConflictDeclaration(_ text: String) -> Bool {
        RegexHelper.anyMatch(patterns: COIPatterns.noConflictPatterns, in: text)
    }

    /// Count industry-related keyword matches in text.
    ///
    /// - Parameter text: Lowercased text to analyze
    /// - Returns: Number of industry keyword matches
    public static func countIndustryMatches(in text: String) -> Int {
        RegexHelper.countMatches(patterns: IndustryPatterns.industryKeywords, in: text)
    }

    /// Extract disclosed relationships from COI statement.
    ///
    /// - Parameter text: Lowercased statement text
    /// - Returns: Array of extracted relationship descriptions
    public static func extractRelationships(from text: String) -> [String] {
        var relationships: [String] = []

        for pattern in COIPatterns.relationshipPatterns {
            let matches = RegexHelper.extractAll(pattern: pattern, from: text)
            relationships.append(contentsOf: matches)
        }

        // Clean up and deduplicate
        return Array(Set(relationships.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }))
    }

    // MARK: - Validation

    /// Check for discrepancy between funding and COI disclosure.
    ///
    /// Returns a warning if industry funding is detected but COI statement
    /// doesn't mention industry ties.
    ///
    /// - Parameters:
    ///   - coiResult: COI analysis result
    ///   - industryFundingDetected: Whether industry funding was detected
    /// - Returns: Warning message if discrepancy found, nil otherwise
    public static func checkFundingCOIDiscrepancy(
        coiResult: COIAnalysisResult,
        industryFundingDetected: Bool
    ) -> String? {
        guard industryFundingDetected else { return nil }

        // If we have a COI statement but it doesn't mention industry ties
        if coiResult.statement != nil && !coiResult.hasIndustryTies {
            return "Industry funding detected but COI statement does not mention industry ties"
        }

        // If no COI statement at all
        if coiResult.statement == nil {
            return "Industry funding detected but no COI statement found"
        }

        return nil
    }

    // MARK: - Summary

    /// Generate a human-readable summary of COI analysis.
    ///
    /// - Parameter result: COI analysis result
    /// - Returns: Summary string for display
    public static func formatSummary(_ result: COIAnalysisResult) -> String {
        guard result.statement != nil else {
            return "No conflict of interest statement found"
        }

        if result.hasIndustryTies {
            let relationshipCount = result.disclosedRelationships.count
            if relationshipCount > 0 {
                return "Industry ties disclosed (\(relationshipCount) relationship\(relationshipCount == 1 ? "" : "s"))"
            }
            return "Industry ties indicated"
        } else {
            return "No conflicts declared"
        }
    }
}
```

## Testing

```swift
import XCTest
@testable import BioMedLit

final class COIAnalyzerTests: XCTestCase {

    // MARK: - Main Analysis Tests

    func testAnalyzeNilStatement() {
        let result = COIAnalyzer.analyze(statement: nil)
        XCTAssertNil(result.statement)
        XCTAssertFalse(result.hasIndustryTies)
        XCTAssertEqual(result.confidence, 0.0)
    }

    func testAnalyzeEmptyStatement() {
        let result = COIAnalyzer.analyze(statement: "")
        XCTAssertNil(result.statement)
    }

    func testAnalyzeNoConflictStatement() {
        let statement = "The authors declare no conflict of interest."
        let result = COIAnalyzer.analyze(statement: statement)

        XCTAssertEqual(result.statement, statement)
        XCTAssertFalse(result.hasIndustryTies)
        XCTAssertEqual(result.confidence, 0.9)
    }

    func testAnalyzeNothingToDisclose() {
        let statement = "Nothing to disclose."
        let result = COIAnalyzer.analyze(statement: statement)

        XCTAssertFalse(result.hasIndustryTies)
        XCTAssertEqual(result.confidence, 0.9)
    }

    func testAnalyzeIndustryTies() {
        let statement = "Author X received grants from Pfizer Inc. and serves as a consultant for Novartis."
        let result = COIAnalyzer.analyze(statement: statement)

        XCTAssertTrue(result.hasIndustryTies)
        XCTAssertGreaterThan(result.confidence, 0.5)
    }

    func testAnalyzeWithHonoraria() {
        let statement = "Author received honoraria from pharmaceutical companies."
        let result = COIAnalyzer.analyze(statement: statement)

        XCTAssertTrue(result.hasIndustryTies)
    }

    func testAnalyzeEmployeeOf() {
        let statement = "Dr. Smith is an employee of Bristol-Myers Squibb."
        let result = COIAnalyzer.analyze(statement: statement)

        XCTAssertTrue(result.hasIndustryTies)
        XCTAssertFalse(result.disclosedRelationships.isEmpty)
    }

    // MARK: - No Conflict Detection Tests

    func testContainsNoConflictDeclaration() {
        XCTAssertTrue(COIAnalyzer.containsNoConflictDeclaration("no conflict of interest"))
        XCTAssertTrue(COIAnalyzer.containsNoConflictDeclaration("nothing to disclose"))
        XCTAssertTrue(COIAnalyzer.containsNoConflictDeclaration("no competing interests"))
        XCTAssertTrue(COIAnalyzer.containsNoConflictDeclaration("none declared"))
        XCTAssertFalse(COIAnalyzer.containsNoConflictDeclaration("received grants from pfizer"))
    }

    // MARK: - Industry Match Counting Tests

    func testCountIndustryMatchesSingle() {
        let count = COIAnalyzer.countIndustryMatches(in: "works for pfizer inc.")
        XCTAssertGreaterThanOrEqual(count, 1)
    }

    func testCountIndustryMatchesMultiple() {
        let count = COIAnalyzer.countIndustryMatches(in: "consultant for pharma corp. and biotech ltd.")
        XCTAssertGreaterThanOrEqual(count, 2)
    }

    func testCountIndustryMatchesNone() {
        let count = COIAnalyzer.countIndustryMatches(in: "funded by nih")
        XCTAssertEqual(count, 0)
    }

    // MARK: - Relationship Extraction Tests

    func testExtractRelationshipsGrants() {
        let relationships = COIAnalyzer.extractRelationships(
            from: "received grants from pfizer and novartis"
        )
        XCTAssertFalse(relationships.isEmpty)
    }

    func testExtractRelationshipsConsultant() {
        let relationships = COIAnalyzer.extractRelationships(
            from: "serves as consultant for medtronic"
        )
        XCTAssertFalse(relationships.isEmpty)
    }

    func testExtractRelationshipsEmployee() {
        let relationships = COIAnalyzer.extractRelationships(
            from: "employee of astrazeneca"
        )
        XCTAssertFalse(relationships.isEmpty)
    }

    // MARK: - Discrepancy Check Tests

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

    // MARK: - Summary Tests

    func testFormatSummaryNoCOI() {
        let summary = COIAnalyzer.formatSummary(.notAvailable)
        XCTAssertTrue(summary.contains("No conflict of interest statement"))
    }

    func testFormatSummaryNoConflicts() {
        let result = COIAnalysisResult(
            statement: "None declared",
            hasIndustryTies: false,
            confidence: 0.9
        )
        let summary = COIAnalyzer.formatSummary(result)
        XCTAssertTrue(summary.contains("No conflicts declared"))
    }

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
}
```

## Dependencies

- `TransparencyModels.swift` (Step 01)
- `TransparencyConstants.swift` (Step 02)

## Notes

- Pure functions with no side effects
- Handles nil/empty input gracefully
- Returns confidence scores to indicate reliability
- Extracts specific relationship mentions for detailed reporting
