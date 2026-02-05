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

/// Unit tests for TrialComplianceAnalyzer pure functions.
final class TrialComplianceAnalyzerTests: XCTestCase {

    // MARK: - Results Compliance Tests

    /// Test that results are compliant when posted.
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

    /// Test that results are missing when past deadline and not posted.
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

    /// Test that results status is unknown when no completion date is available.
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

    /// Test that results status is unknown when deadline hasn't passed.
    func testResultsUnknownBeforeDeadline() {
        // Trial completed recently - deadline hasn't passed
        let recentCompletion = Calendar.current.date(byAdding: .month, value: -3, to: Date())!

        let trial = TrialRegistration(
            registry: "ClinicalTrials.gov",
            registrationId: "NCT01234567",
            resultsPosted: false,
            completionDate: recentCompletion
        )

        let compliance = TrialComplianceAnalyzer.checkResultsCompliance(
            trial: trial,
            publicationDate: Date()
        )

        XCTAssertEqual(compliance, .unknown)
    }

    // MARK: - Trial Detection Tests

    /// Test detection of clinical trial indicators in title.
    func testAppearsToBeClinicalTrialTrue() {
        XCTAssertTrue(TrialComplianceAnalyzer.appearsToBeClinicalTrial(
            title: "A Randomized Controlled Trial of Drug X"
        ))
        XCTAssertTrue(TrialComplianceAnalyzer.appearsToBeClinicalTrial(
            title: "Phase III Study of Treatment Y"
        ))
        XCTAssertTrue(TrialComplianceAnalyzer.appearsToBeClinicalTrial(
            title: "An RCT comparing interventions"
        ))
        XCTAssertTrue(TrialComplianceAnalyzer.appearsToBeClinicalTrial(
            title: "This is a clinical trial"
        ))
    }

    /// Test non-trial studies return false.
    func testAppearsToBeClinicalTrialFalse() {
        XCTAssertFalse(TrialComplianceAnalyzer.appearsToBeClinicalTrial(
            title: "A Systematic Review of Treatment Outcomes"
        ))
        XCTAssertFalse(TrialComplianceAnalyzer.appearsToBeClinicalTrial(
            title: "Meta-Analysis of Drug Effects"
        ))
        XCTAssertFalse(TrialComplianceAnalyzer.appearsToBeClinicalTrial(
            title: nil
        ))
    }

    /// Test case insensitivity of trial detection.
    func testAppearsToBeClinicalTrialCaseInsensitive() {
        XCTAssertTrue(TrialComplianceAnalyzer.appearsToBeClinicalTrial(
            title: "RANDOMIZED CONTROLLED TRIAL"
        ))
        XCTAssertTrue(TrialComplianceAnalyzer.appearsToBeClinicalTrial(
            title: "phase iii study"
        ))
    }

    // MARK: - NCT ID Extraction Tests

    /// Test extracting NCT IDs from text.
    func testExtractNCTIds() {
        let text = "Registered as NCT01234567 and NCT98765432"
        let ids = TrialComplianceAnalyzer.extractNCTIds(from: text)

        XCTAssertEqual(ids.count, 2)
        XCTAssertTrue(ids.contains("NCT01234567"))
        XCTAssertTrue(ids.contains("NCT98765432"))
    }

    /// Test extracting no NCT IDs when none present.
    func testExtractNCTIdsNone() {
        let text = "No trial registration mentioned"
        let ids = TrialComplianceAnalyzer.extractNCTIds(from: text)

        XCTAssertTrue(ids.isEmpty)
    }

    /// Test extracting NCT ID from longer text.
    func testExtractNCTIdsFromLongerText() {
        let text = """
        This study (NCT12345678) was conducted at multiple sites.
        See also companion study NCT87654321.
        """
        let ids = TrialComplianceAnalyzer.extractNCTIds(from: text)

        XCTAssertEqual(ids.count, 2)
    }

    /// Test invalid NCT format is not extracted.
    func testExtractNCTIdsInvalidFormat() {
        let text = "NCT123 and NCT1234567890 are invalid"
        let ids = TrialComplianceAnalyzer.extractNCTIds(from: text)

        XCTAssertTrue(ids.isEmpty)
    }

    // MARK: - Industry Sponsor Tests

    /// Test industry sponsor detection.
    func testIsIndustrySponsorTrue() {
        XCTAssertTrue(TrialComplianceAnalyzer.isIndustrySponsor("INDUSTRY"))
        XCTAssertTrue(TrialComplianceAnalyzer.isIndustrySponsor("industry"))
        XCTAssertTrue(TrialComplianceAnalyzer.isIndustrySponsor("Industry"))
    }

    /// Test non-industry sponsor detection.
    func testIsIndustrySponsorFalse() {
        XCTAssertFalse(TrialComplianceAnalyzer.isIndustrySponsor("NIH"))
        XCTAssertFalse(TrialComplianceAnalyzer.isIndustrySponsor("OTHER"))
        XCTAssertFalse(TrialComplianceAnalyzer.isIndustrySponsor(nil))
        XCTAssertFalse(TrialComplianceAnalyzer.isIndustrySponsor("U_S__FED"))
    }

    // MARK: - Outcome Switching Tests

    /// Test no outcome switching when no registered outcomes.
    func testOutcomeSwitchingNoRegistered() {
        let (detected, details) = TrialComplianceAnalyzer.checkOutcomeSwitching(
            registered: [],
            reported: ["primary endpoint"]
        )

        XCTAssertFalse(detected)
        XCTAssertTrue(details.isEmpty)
    }

    /// Test outcome switching when registered but no reported.
    func testOutcomeSwitchingNoReported() {
        let (detected, details) = TrialComplianceAnalyzer.checkOutcomeSwitching(
            registered: ["mortality rate"],
            reported: []
        )

        XCTAssertFalse(detected)
        XCTAssertTrue(details.first?.contains("no reported outcomes") ?? false)
    }

    /// Test no outcome switching when outcomes match.
    func testOutcomeSwitchingMatching() {
        let (detected, _) = TrialComplianceAnalyzer.checkOutcomeSwitching(
            registered: ["overall survival rate"],
            reported: ["overall survival rate at 5 years"]
        )

        XCTAssertFalse(detected)
    }

    /// Test outcome switching detection when outcomes differ.
    func testOutcomeSwitchingMismatch() {
        let (detected, details) = TrialComplianceAnalyzer.checkOutcomeSwitching(
            registered: ["progression free survival"],
            reported: ["quality of life score"]
        )

        XCTAssertTrue(detected)
        XCTAssertFalse(details.isEmpty)
    }

    // MARK: - Summary Tests

    /// Test summary with no registrations.
    func testFormatSummaryNoRegistration() {
        let summary = TrialComplianceAnalyzer.formatSummary(
            registrations: [],
            compliance: .unknown
        )
        XCTAssertTrue(summary.contains("No trial registration"))
    }

    /// Test summary with registration and results posted.
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
        XCTAssertTrue(summary.contains("Results compliant"))
    }

    /// Test summary with missing results.
    func testFormatSummaryMissingResults() {
        let registrations = [
            TrialRegistration(
                registry: "ClinicalTrials.gov",
                registrationId: "NCT123",
                resultsPosted: false
            )
        ]
        let summary = TrialComplianceAnalyzer.formatSummary(
            registrations: registrations,
            compliance: .missing
        )

        XCTAssertTrue(summary.contains("Results missing"))
    }

    /// Test summary with multiple registrations.
    func testFormatSummaryMultipleRegistrations() {
        let registrations = [
            TrialRegistration(registry: "CT.gov", registrationId: "NCT1"),
            TrialRegistration(registry: "ISRCTN", registrationId: "ISRCTN123")
        ]
        let summary = TrialComplianceAnalyzer.formatSummary(
            registrations: registrations,
            compliance: .unknown
        )

        XCTAssertTrue(summary.contains("2 trial registrations"))
    }

    // MARK: - Missing Registration Tests

    /// Test missing registration detected for trial without registration.
    func testCheckMissingRegistrationDetected() {
        let warning = TrialComplianceAnalyzer.checkMissingRegistration(
            title: "Randomized Controlled Trial of X",
            registrations: []
        )

        XCTAssertNotNil(warning)
        XCTAssertTrue(warning!.contains("without detected registration"))
    }

    /// Test no warning when not a clinical trial.
    func testCheckMissingRegistrationNotTrial() {
        let warning = TrialComplianceAnalyzer.checkMissingRegistration(
            title: "Systematic Review",
            registrations: []
        )

        XCTAssertNil(warning)
    }

    /// Test no warning when registration exists.
    func testCheckMissingRegistrationHasRegistration() {
        let warning = TrialComplianceAnalyzer.checkMissingRegistration(
            title: "Randomized Trial",
            registrations: [
                TrialRegistration(registry: "CT.gov", registrationId: "NCT123")
            ]
        )

        XCTAssertNil(warning)
    }

    /// Test no warning for nil title.
    func testCheckMissingRegistrationNilTitle() {
        let warning = TrialComplianceAnalyzer.checkMissingRegistration(
            title: nil,
            registrations: []
        )

        XCTAssertNil(warning)
    }
}
