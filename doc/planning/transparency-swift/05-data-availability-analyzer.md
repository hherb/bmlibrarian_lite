# Step 05: Data Availability Analyzer

## Goal

Create pure functions for analyzing data availability statements.

## File to Create

### `Sources/BioMedLit/Transparency/Analysis/DataAvailabilityAnalyzer.swift`

```swift
// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2025 Dr Horst Herb
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Pure functions for analyzing data availability statements.
///
/// All functions are stateless and can be safely called from any context.
///
/// Usage:
/// ```swift
/// let result = DataAvailabilityAnalyzer.analyze(statement: dataText)
/// // Returns: DataAvailabilityResult with disclosure level
/// ```
public enum DataAvailabilityAnalyzer {

    // MARK: - Main Analysis

    /// Analyze a data availability statement.
    ///
    /// Classification hierarchy:
    /// 1. Full open - data in public repository
    /// 2. Available on request - can be obtained from authors
    /// 3. Restricted - significant restrictions apply
    /// 4. Not available - explicitly unavailable
    /// 5. Not stated - no statement found
    ///
    /// - Parameter statement: The data availability statement text
    /// - Returns: DataAvailabilityResult with classification
    public static func analyze(statement: String?) -> DataAvailabilityResult {
        guard let statement = statement, !statement.isEmpty else {
            return .notStated
        }

        let statementLower = statement.lowercased()

        // Check for full open access (highest priority)
        if let fullOpenResult = checkFullOpenAccess(statement: statement, lowercased: statementLower) {
            return fullOpenResult
        }

        // Check for explicit unavailability
        if containsUnavailabilityIndicators(statementLower) {
            return DataAvailabilityResult(
                statement: statement,
                disclosureLevel: .notAvailable,
                restrictions: extractRestrictions(from: statementLower)
            )
        }

        // Check for restricted/request-only access
        if containsRestrictedAccessIndicators(statementLower) {
            return DataAvailabilityResult(
                statement: statement,
                disclosureLevel: .availableOnRequest,
                restrictions: extractRestrictions(from: statementLower)
            )
        }

        // Statement exists but unclear classification
        return DataAvailabilityResult(
            statement: statement,
            disclosureLevel: .unknown
        )
    }

    // MARK: - Detection Functions

    /// Check for full open access indicators and extract repository info.
    ///
    /// - Parameters:
    ///   - statement: Original statement text
    ///   - lowercased: Lowercased version for pattern matching
    /// - Returns: DataAvailabilityResult if open access detected, nil otherwise
    public static func checkFullOpenAccess(
        statement: String,
        lowercased: String
    ) -> DataAvailabilityResult? {
        // Check each repository pattern
        for pattern in DataRepositoryPatterns.fullOpenPatterns {
            if lowercased.contains(pattern) ||
               RegexHelper.anyMatch(patterns: [pattern], in: lowercased) {

                // Try to extract URL
                let url = extractURL(from: statement)

                // Try to extract accession number
                let accession = extractAccessionNumber(from: statement)

                // Determine repository name
                let repoName = detectRepositoryName(in: lowercased)

                return DataAvailabilityResult(
                    statement: statement,
                    disclosureLevel: .fullOpen,
                    repositoryName: repoName,
                    repositoryURL: url,
                    accessionNumber: accession
                )
            }
        }

        return nil
    }

    /// Check if statement contains unavailability indicators.
    ///
    /// - Parameter text: Lowercased statement text
    /// - Returns: True if data is explicitly unavailable
    public static func containsUnavailabilityIndicators(_ text: String) -> Bool {
        RegexHelper.anyMatch(patterns: DataRepositoryPatterns.unavailablePatterns, in: text)
    }

    /// Check if statement contains restricted access indicators.
    ///
    /// - Parameter text: Lowercased statement text
    /// - Returns: True if restricted access is indicated
    public static func containsRestrictedAccessIndicators(_ text: String) -> Bool {
        RegexHelper.anyMatch(patterns: DataRepositoryPatterns.restrictedPatterns, in: text)
    }

    // MARK: - Extraction Functions

    /// Extract URL from text.
    ///
    /// - Parameter text: Text to search
    /// - Returns: First URL found, or nil
    public static func extractURL(from text: String) -> URL? {
        guard let regex = RegexHelper.regex(DataRepositoryPatterns.urlPattern) else {
            return nil
        }

        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let matchRange = Range(match.range, in: text) else {
            return nil
        }

        let urlString = String(text[matchRange])
        return URL(string: urlString)
    }

    /// Extract accession number from text.
    ///
    /// - Parameter text: Text to search
    /// - Returns: Accession number if found, nil otherwise
    public static func extractAccessionNumber(from text: String) -> String? {
        RegexHelper.extractFirst(pattern: DataRepositoryPatterns.accessionPattern, from: text)
    }

    /// Detect repository name from text.
    ///
    /// - Parameter text: Lowercased text to search
    /// - Returns: Repository name if detected, nil otherwise
    public static func detectRepositoryName(in text: String) -> String? {
        // Repository name mappings
        let repoMappings: [(pattern: String, name: String)] = [
            ("zenodo", "Zenodo"),
            ("figshare", "Figshare"),
            ("dryad", "Dryad"),
            ("osf", "Open Science Framework"),
            ("github", "GitHub"),
            ("gitlab", "GitLab"),
            ("dataverse", "Dataverse"),
            ("gene expression omnibus", "Gene Expression Omnibus"),
            ("geo", "GEO"),
            ("arrayexpress", "ArrayExpress"),
            ("genbank", "GenBank"),
            ("sra", "Sequence Read Archive"),
            ("vivli", "Vivli"),
            ("yoda", "YODA Project"),
        ]

        for (pattern, name) in repoMappings {
            if text.contains(pattern) {
                return name
            }
        }

        return nil
    }

    /// Extract restriction descriptions from text.
    ///
    /// - Parameter text: Lowercased statement text
    /// - Returns: List of detected restrictions
    public static func extractRestrictions(from text: String) -> [String] {
        var restrictions: [String] = []

        let restrictionMappings: [(pattern: String, description: String)] = [
            ("upon reasonable request", "Available upon reasonable request"),
            ("upon request", "Available upon request"),
            ("data sharing agreement", "Requires data sharing agreement"),
            ("institutional review board", "IRB approval required"),
            ("irb approval", "IRB approval required"),
            ("ethics committee", "Ethics committee approval required"),
            ("confidential", "Confidentiality restrictions"),
            ("proprietary", "Proprietary data"),
        ]

        for (pattern, description) in restrictionMappings {
            if text.contains(pattern) || RegexHelper.anyMatch(patterns: [pattern], in: text) {
                restrictions.append(description)
            }
        }

        return restrictions
    }

    // MARK: - Summary

    /// Generate a human-readable summary of data availability.
    ///
    /// - Parameter result: Data availability analysis result
    /// - Returns: Summary string for display
    public static func formatSummary(_ result: DataAvailabilityResult) -> String {
        switch result.disclosureLevel {
        case .fullOpen:
            if let repo = result.repositoryName {
                return "Data available in \(repo)"
            }
            return "Data publicly available"

        case .availableOnRequest:
            return "Data available upon request"

        case .restricted:
            if !result.restrictions.isEmpty {
                return "Data access restricted: \(result.restrictions.first!)"
            }
            return "Data access restricted"

        case .notAvailable:
            return "Data not available"

        case .notStated:
            return "No data availability statement"

        case .unknown:
            return "Data availability unclear"
        }
    }
}
```

## Testing

```swift
import XCTest
@testable import BioMedLit

final class DataAvailabilityAnalyzerTests: XCTestCase {

    // MARK: - Main Analysis Tests

    func testAnalyzeNilStatement() {
        let result = DataAvailabilityAnalyzer.analyze(statement: nil)
        XCTAssertEqual(result.disclosureLevel, .notStated)
    }

    func testAnalyzeEmptyStatement() {
        let result = DataAvailabilityAnalyzer.analyze(statement: "")
        XCTAssertEqual(result.disclosureLevel, .notStated)
    }

    func testAnalyzeZenodoRepository() {
        let statement = "Data available at https://zenodo.org/record/12345"
        let result = DataAvailabilityAnalyzer.analyze(statement: statement)

        XCTAssertEqual(result.disclosureLevel, .fullOpen)
        XCTAssertEqual(result.repositoryName, "Zenodo")
        XCTAssertNotNil(result.repositoryURL)
    }

    func testAnalyzeGEORepository() {
        let statement = "Data deposited in Gene Expression Omnibus under accession GSE12345"
        let result = DataAvailabilityAnalyzer.analyze(statement: statement)

        XCTAssertEqual(result.disclosureLevel, .fullOpen)
        XCTAssertEqual(result.repositoryName, "Gene Expression Omnibus")
    }

    func testAnalyzeAvailableOnRequest() {
        let statement = "Data available upon reasonable request from the corresponding author"
        let result = DataAvailabilityAnalyzer.analyze(statement: statement)

        XCTAssertEqual(result.disclosureLevel, .availableOnRequest)
        XCTAssertFalse(result.restrictions.isEmpty)
    }

    func testAnalyzeProprietaryData() {
        let statement = "Data is proprietary and cannot be shared"
        let result = DataAvailabilityAnalyzer.analyze(statement: statement)

        XCTAssertEqual(result.disclosureLevel, .notAvailable)
    }

    func testAnalyzeNotPubliclyAvailable() {
        let statement = "Data is not publicly available due to privacy restrictions"
        let result = DataAvailabilityAnalyzer.analyze(statement: statement)

        XCTAssertEqual(result.disclosureLevel, .notAvailable)
    }

    func testAnalyzeIRBRestriction() {
        let statement = "Data available from authors pending IRB approval"
        let result = DataAvailabilityAnalyzer.analyze(statement: statement)

        XCTAssertEqual(result.disclosureLevel, .availableOnRequest)
        XCTAssertTrue(result.restrictions.contains { $0.contains("IRB") })
    }

    // MARK: - URL Extraction Tests

    func testExtractURL() {
        let text = "Available at https://github.com/user/repo"
        let url = DataAvailabilityAnalyzer.extractURL(from: text)

        XCTAssertNotNil(url)
        XCTAssertEqual(url?.absoluteString, "https://github.com/user/repo")
    }

    func testExtractURLNoURL() {
        let text = "Data available upon request"
        let url = DataAvailabilityAnalyzer.extractURL(from: text)

        XCTAssertNil(url)
    }

    // MARK: - Accession Extraction Tests

    func testExtractAccessionNumber() {
        let text = "Deposited under accession GSE12345"
        let accession = DataAvailabilityAnalyzer.extractAccessionNumber(from: text)

        XCTAssertNotNil(accession)
    }

    func testExtractIdentifier() {
        let text = "Data identifier: SRR12345678"
        let accession = DataAvailabilityAnalyzer.extractAccessionNumber(from: text)

        XCTAssertNotNil(accession)
    }

    // MARK: - Repository Detection Tests

    func testDetectRepositoryZenodo() {
        XCTAssertEqual(
            DataAvailabilityAnalyzer.detectRepositoryName(in: "data in zenodo"),
            "Zenodo"
        )
    }

    func testDetectRepositoryGitHub() {
        XCTAssertEqual(
            DataAvailabilityAnalyzer.detectRepositoryName(in: "code on github"),
            "GitHub"
        )
    }

    func testDetectRepositoryNone() {
        XCTAssertNil(
            DataAvailabilityAnalyzer.detectRepositoryName(in: "available from author")
        )
    }

    // MARK: - Restriction Extraction Tests

    func testExtractRestrictionsMultiple() {
        let text = "available upon request pending irb approval and data sharing agreement"
        let restrictions = DataAvailabilityAnalyzer.extractRestrictions(from: text)

        XCTAssertTrue(restrictions.count >= 2)
    }

    // MARK: - Summary Tests

    func testFormatSummaryFullOpen() {
        let result = DataAvailabilityResult(
            disclosureLevel: .fullOpen,
            repositoryName: "Zenodo"
        )
        let summary = DataAvailabilityAnalyzer.formatSummary(result)
        XCTAssertTrue(summary.contains("Zenodo"))
    }

    func testFormatSummaryNotStated() {
        let summary = DataAvailabilityAnalyzer.formatSummary(.notStated)
        XCTAssertTrue(summary.contains("No data availability"))
    }
}
```

## Dependencies

- `TransparencyModels.swift` (Step 01)
- `TransparencyConstants.swift` (Step 02)

## Notes

- Pure functions with no side effects
- Handles nil/empty input with `.notStated` return
- Extracts URLs and accession numbers when present
- Maps patterns to human-readable repository names
