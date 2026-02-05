# Step 06: Trial Compliance Analyzer

## Goal

Create pure functions for analyzing clinical trial registration and results compliance.

## File to Create

### `Sources/BioMedLit/Transparency/Analysis/TrialComplianceAnalyzer.swift`

```swift
// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2025 Dr Horst Herb
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Pure functions for analyzing clinical trial compliance.
///
/// All functions are stateless and can be safely called from any context.
///
/// Usage:
/// ```swift
/// let compliance = TrialComplianceAnalyzer.checkResultsCompliance(
///     trial: trialReg,
///     publicationDate: pubDate
/// )
/// ```
public enum TrialComplianceAnalyzer {

    // MARK: - Results Compliance

    /// Check if trial results posting is compliant with regulations.
    ///
    /// Based on FDAAA 2007 which requires results within 12 months of completion
    /// for applicable clinical trials.
    ///
    /// - Parameters:
    ///   - trial: Trial registration information
    ///   - publicationDate: Publication date of the article
    /// - Returns: Compliance status
    public static func checkResultsCompliance(
        trial: TrialRegistration,
        publicationDate: Date?
    ) -> ResultsComplianceStatus {
        // Results are posted - generally compliant
        if trial.resultsPosted {
            // Could add late detection with results posting date if available
            return .compliant
        }

        // No results posted - check if they should be
        guard let completionDate = trial.completionDate else {
            return .unknown
        }

        // Calculate deadline (12 months from completion)
        let deadline = Calendar.current.date(
            byAdding: .day,
            value: TransparencyConstants.resultsComplianceDeadlineDays,
            to: completionDate
        ) ?? completionDate

        // Check if past deadline
        if Date() > deadline {
            return .missing
        }

        return .unknown
    }

    // MARK: - Trial Detection

    /// Check if a study title suggests it's a clinical trial.
    ///
    /// - Parameter title: Study title
    /// - Returns: True if clinical trial indicators found
    public static func appearsToBeClinicialTrial(title: String?) -> Bool {
        guard let title = title else { return false }

        let titleLower = title.lowercased()
        return ClinicalTrialPatterns.trialKeywords.contains { keyword in
            titleLower.contains(keyword)
        }
    }

    /// Extract NCT IDs from text.
    ///
    /// - Parameter text: Text to search
    /// - Returns: Array of NCT IDs found
    public static func extractNCTIds(from text: String) -> [String] {
        guard let regex = RegexHelper.regex(ClinicalTrialPatterns.nctIdPattern) else {
            return []
        }

        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)

        return matches.compactMap { match in
            guard let matchRange = Range(match.range, in: text) else { return nil }
            return String(text[matchRange])
        }
    }

    // MARK: - Industry Sponsor Detection

    /// Check if trial is industry-sponsored based on sponsor class.
    ///
    /// - Parameter sponsorClass: Sponsor class from ClinicalTrials.gov
    /// - Returns: True if industry-sponsored
    public static func isIndustrySponsor(_ sponsorClass: String?) -> Bool {
        sponsorClass?.uppercased() == "INDUSTRY"
    }

    // MARK: - Outcome Analysis

    /// Check for potential outcome switching.
    ///
    /// Compares registered outcomes with reported outcomes.
    /// Note: This is a simplified check - full analysis requires NLP.
    ///
    /// - Parameters:
    ///   - registered: Registered primary outcomes
    ///   - reported: Reported outcomes (from publication)
    /// - Returns: Tuple of (detected, details)
    public static func checkOutcomeSwitching(
        registered: [String],
        reported: [String]
    ) -> (detected: Bool, details: [String]) {
        // Skip if no registered outcomes
        guard !registered.isEmpty else {
            return (false, [])
        }

        // Skip if no reported outcomes to compare
        guard !reported.isEmpty else {
            return (false, ["Unable to compare - no reported outcomes extracted"])
        }

        var details: [String] = []

        // Simplified check: look for major mismatches
        // A proper implementation would use NLP/fuzzy matching

        let registeredLower = Set(registered.map { $0.lowercased() })
        let reportedLower = Set(reported.map { $0.lowercased() })

        // Check if any registered outcomes are completely absent
        for outcome in registeredLower {
            let found = reportedLower.contains { reported in
                // Simple word overlap check
                let outcomeWords = Set(outcome.components(separatedBy: .whitespaces))
                let reportedWords = Set(reported.components(separatedBy: .whitespaces))
                let overlap = outcomeWords.intersection(reportedWords)
                return Double(overlap.count) / Double(outcomeWords.count) > 0.5
            }

            if !found {
                details.append("Registered outcome may not be reported: \(outcome.prefix(50))...")
            }
        }

        return (!details.isEmpty, details)
    }

    // MARK: - Summary

    /// Generate human-readable compliance summary.
    ///
    /// - Parameters:
    ///   - registrations: Trial registrations
    ///   - compliance: Results compliance status
    /// - Returns: Summary string
    public static func formatSummary(
        registrations: [TrialRegistration],
        compliance: ResultsComplianceStatus
    ) -> String {
        guard !registrations.isEmpty else {
            return "No trial registration found"
        }

        let regCount = registrations.count
        let resultsPosted = registrations.filter(\.resultsPosted).count

        var parts: [String] = []
        parts.append("\(regCount) trial registration\(regCount == 1 ? "" : "s") found")

        if resultsPosted > 0 {
            parts.append("\(resultsPosted) with results posted")
        }

        switch compliance {
        case .compliant:
            parts.append("Results compliant")
        case .late:
            parts.append("Results posted late")
        case .missing:
            parts.append("Results missing")
        case .notRequired, .unknown:
            break
        }

        return parts.joined(separator: "; ")
    }

    // MARK: - Missing Registration Warning

    /// Generate warning if study appears to be a clinical trial without registration.
    ///
    /// - Parameters:
    ///   - title: Study title
    ///   - registrations: Found trial registrations
    /// - Returns: Warning message if applicable, nil otherwise
    public static func checkMissingRegistration(
        title: String?,
        registrations: [TrialRegistration]
    ) -> String? {
        guard registrations.isEmpty,
              appearsToBeClinicialTrial(title: title) else {
            return nil
        }

        return "Clinical trial without detected registration"
    }
}
```

## Testing

```swift
import XCTest
@testable import BioMedLit

final class TrialComplianceAnalyzerTests: XCTestCase {

    // MARK: - Results Compliance Tests

    func testResultsCompliantWhenPosted() {
        let trial = TrialRegistration(
            registry: "ClinicalTrials.gov",
            registrationId: "NCT01234567",
            resultsPosted: true
        )

        let compliance = TrialComplianceAnalyzer.checkResultsCompliance(
            trial: trial,
            publicationDate: Date()
        )

        XCTAssertEqual(compliance, .compliant)
    }

    func testResultsMissingPastDeadline() {
        // Trial completed 2 years ago, no results
        let twoYearsAgo = Calendar.current.date(byAdding: .year, value: -2, to: Date())!

        let trial = TrialRegistration(
            registry: "ClinicalTrials.gov",
            registrationId: "NCT01234567",
            resultsPosted: false,
            completionDate: twoYearsAgo
        )

        let compliance = TrialComplianceAnalyzer.checkResultsCompliance(
            trial: trial,
            publicationDate: Date()
        )

        XCTAssertEqual(compliance, .missing)
    }

    func testResultsUnknownNoCompletionDate() {
        let trial = TrialRegistration(
            registry: "ClinicalTrials.gov",
            registrationId: "NCT01234567",
            resultsPosted: false,
            completionDate: nil
        )

        let compliance = TrialComplianceAnalyzer.checkResultsCompliance(
            trial: trial,
            publicationDate: Date()
        )

        XCTAssertEqual(compliance, .unknown)
    }

    // MARK: - Trial Detection Tests

    func testAppearsToBeClinicialTrialTrue() {
        XCTAssertTrue(TrialComplianceAnalyzer.appearsToBeClinicialTrial(
            title: "A Randomized Controlled Trial of Drug X"
        ))
        XCTAssertTrue(TrialComplianceAnalyzer.appearsToBeClinicialTrial(
            title: "Phase III Study of Treatment Y"
        ))
        XCTAssertTrue(TrialComplianceAnalyzer.appearsToBeClinicialTrial(
            title: "An RCT comparing interventions"
        ))
    }

    func testAppearsToBeClinicialTrialFalse() {
        XCTAssertFalse(TrialComplianceAnalyzer.appearsToBeClinicialTrial(
            title: "A Systematic Review of Treatment Outcomes"
        ))
        XCTAssertFalse(TrialComplianceAnalyzer.appearsToBeClinicialTrial(
            title: nil
        ))
    }

    // MARK: - NCT ID Extraction Tests

    func testExtractNCTIds() {
        let text = "Registered as NCT01234567 and NCT98765432"
        let ids = TrialComplianceAnalyzer.extractNCTIds(from: text)

        XCTAssertEqual(ids.count, 2)
        XCTAssertTrue(ids.contains("NCT01234567"))
        XCTAssertTrue(ids.contains("NCT98765432"))
    }

    func testExtractNCTIdsNone() {
        let text = "No trial registration mentioned"
        let ids = TrialComplianceAnalyzer.extractNCTIds(from: text)

        XCTAssertTrue(ids.isEmpty)
    }

    // MARK: - Industry Sponsor Tests

    func testIsIndustrySponsorTrue() {
        XCTAssertTrue(TrialComplianceAnalyzer.isIndustrySponsor("INDUSTRY"))
        XCTAssertTrue(TrialComplianceAnalyzer.isIndustrySponsor("industry"))
        XCTAssertTrue(TrialComplianceAnalyzer.isIndustrySponsor("Industry"))
    }

    func testIsIndustrySponsorFalse() {
        XCTAssertFalse(TrialComplianceAnalyzer.isIndustrySponsor("NIH"))
        XCTAssertFalse(TrialComplianceAnalyzer.isIndustrySponsor("OTHER"))
        XCTAssertFalse(TrialComplianceAnalyzer.isIndustrySponsor(nil))
    }

    // MARK: - Missing Registration Tests

    func testCheckMissingRegistrationDetected() {
        let warning = TrialComplianceAnalyzer.checkMissingRegistration(
            title: "Randomized Controlled Trial of X",
            registrations: []
        )

        XCTAssertNotNil(warning)
        XCTAssertTrue(warning!.contains("without detected registration"))
    }

    func testCheckMissingRegistrationNotApplicable() {
        // Not a trial
        XCTAssertNil(TrialComplianceAnalyzer.checkMissingRegistration(
            title: "Systematic Review",
            registrations: []
        ))

        // Has registration
        XCTAssertNil(TrialComplianceAnalyzer.checkMissingRegistration(
            title: "Randomized Trial",
            registrations: [
                TrialRegistration(registry: "CT.gov", registrationId: "NCT123")
            ]
        ))
    }

    // MARK: - Summary Tests

    func testFormatSummaryNoRegistration() {
        let summary = TrialComplianceAnalyzer.formatSummary(
            registrations: [],
            compliance: .unknown
        )
        XCTAssertTrue(summary.contains("No trial registration"))
    }

    func testFormatSummaryWithResults() {
        let registrations = [
            TrialRegistration(
                registry: "ClinicalTrials.gov",
                registrationId: "NCT123",
                resultsPosted: true
            )
        ]
        let summary = TrialComplianceAnalyzer.formatSummary(
            registrations: registrations,
            compliance: .compliant
        )

        XCTAssertTrue(summary.contains("1 trial registration"))
        XCTAssertTrue(summary.contains("results posted"))
    }
}
```

## Dependencies

- `TransparencyModels.swift` (Step 01)
- `TransparencyConstants.swift` (Step 02)

## Notes

- Pure functions with no side effects
- FDAAA 2007 compliance rules simplified
- Outcome switching detection is basic (NLP would improve)
- NCT ID extraction uses regex pattern matching
