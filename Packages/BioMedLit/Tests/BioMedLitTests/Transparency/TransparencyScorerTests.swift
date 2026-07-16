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

/// Unit tests for TransparencyScorer pure functions.
final class TransparencyScorerTests: XCTestCase {

    // MARK: - Score Calculation Tests

    /// Test base case score calculation with minimal data.
    func testCalculateScoreBaseCase() {
        let score = TransparencyScorer.calculateScore(
            dataAvailability: DataAvailabilityResult.notStated,
            coiAnalysis: COIAnalysisResult.notAvailable,
            trialRegistrations: [],
            resultsCompliance: .unknown,
            industryFundingDetected: false,
            outcomeSwitchingDetected: false
        )

        // Base (50) + data (-5) + COI (-5) = 40
        XCTAssertEqual(score, 40)
    }

    /// Test good transparency score calculation.
    func testCalculateScoreGoodTransparency() {
        let score = TransparencyScorer.calculateScore(
            dataAvailability: DataAvailabilityResult(disclosureLevel: .fullOpen),
            coiAnalysis: COIAnalysisResult(statement: "No conflicts", hasIndustryTies: false),
            trialRegistrations: [TrialRegistration(registry: "CT.gov", registrationId: "NCT123", resultsPosted: true)],
            resultsCompliance: .compliant,
            industryFundingDetected: false,
            outcomeSwitchingDetected: false
        )

        // Base (50) + data (20) + COI (10) + trial (10) + results (5) = 95
        XCTAssertEqual(score, 95)
    }

    /// Test poor transparency score calculation.
    func testCalculateScorePoorTransparency() {
        let score = TransparencyScorer.calculateScore(
            dataAvailability: DataAvailabilityResult(disclosureLevel: .notAvailable),
            coiAnalysis: COIAnalysisResult.notAvailable,
            trialRegistrations: [],
            resultsCompliance: .missing,
            industryFundingDetected: true,
            outcomeSwitchingDetected: true
        )

        // Base (50) + data (-10) + COI (-5) + outcome (-15) + industry+nodata (-10) = 10
        XCTAssertEqual(score, 10)
    }

    /// Test score is clamped to valid range.
    func testCalculateScoreClampedToZero() {
        // Extreme penalties should not go below 0
        let score = TransparencyScorer.calculateScore(
            dataAvailability: DataAvailabilityResult(disclosureLevel: .notAvailable),
            coiAnalysis: COIAnalysisResult.notAvailable,
            trialRegistrations: [TrialRegistration(registry: "CT.gov", registrationId: "NCT123")],
            resultsCompliance: .missing,
            industryFundingDetected: true,
            outcomeSwitchingDetected: true
        )

        XCTAssertGreaterThanOrEqual(score, 0)
        XCTAssertLessThanOrEqual(score, 100)
    }

    /// Test data availability on request points.
    func testCalculateScoreOnRequestData() {
        let score = TransparencyScorer.calculateScore(
            dataAvailability: DataAvailabilityResult(disclosureLevel: .availableOnRequest),
            coiAnalysis: COIAnalysisResult(statement: "None", hasIndustryTies: false),
            trialRegistrations: [],
            resultsCompliance: .unknown,
            industryFundingDetected: false,
            outcomeSwitchingDetected: false
        )

        // Base (50) + data (10) + COI (10) = 70
        XCTAssertEqual(score, 70)
    }

    // MARK: - Data Availability Points Tests

    /// Test data availability points for each level.
    func testDataAvailabilityPoints() {
        XCTAssertEqual(
            TransparencyScorer.dataAvailabilityPoints(for: .fullOpen),
            TransparencyConstants.fullOpenDataPoints
        )
        XCTAssertEqual(
            TransparencyScorer.dataAvailabilityPoints(for: .availableOnRequest),
            TransparencyConstants.onRequestDataPoints
        )
        XCTAssertEqual(
            TransparencyScorer.dataAvailabilityPoints(for: .restricted),
            0
        )
        XCTAssertEqual(
            TransparencyScorer.dataAvailabilityPoints(for: .notAvailable),
            TransparencyConstants.noDataPenalty
        )
        XCTAssertEqual(
            TransparencyScorer.dataAvailabilityPoints(for: .notStated),
            TransparencyConstants.noStatementPenalty
        )
        XCTAssertEqual(
            TransparencyScorer.dataAvailabilityPoints(for: .unknown),
            0
        )
    }

    // MARK: - COI Disclosure Points Tests

    /// Test COI disclosure points.
    func testCoiDisclosurePoints() {
        XCTAssertEqual(
            TransparencyScorer.coiDisclosurePoints(hasStatement: true),
            TransparencyConstants.coiStatementPoints
        )
        XCTAssertEqual(
            TransparencyScorer.coiDisclosurePoints(hasStatement: false),
            TransparencyConstants.missingCoiPenalty
        )
    }

    // MARK: - Trial Registration Points Tests

    /// Test trial registration points.
    func testTrialRegistrationPointsEmpty() {
        let points = TransparencyScorer.trialRegistrationPoints(
            registrations: [],
            compliance: .unknown
        )
        XCTAssertEqual(points, 0)
    }

    /// Test trial registration points with compliant results.
    func testTrialRegistrationPointsCompliant() {
        let points = TransparencyScorer.trialRegistrationPoints(
            registrations: [TrialRegistration(registry: "CT.gov", registrationId: "NCT123")],
            compliance: .compliant
        )
        let expected = TransparencyConstants.trialRegistrationPoints + TransparencyConstants.compliantResultsPoints
        XCTAssertEqual(points, expected)
    }

    /// Test trial registration points with missing results.
    func testTrialRegistrationPointsMissingResults() {
        let points = TransparencyScorer.trialRegistrationPoints(
            registrations: [TrialRegistration(registry: "CT.gov", registrationId: "NCT123")],
            compliance: .missing
        )
        let expected = TransparencyConstants.trialRegistrationPoints + TransparencyConstants.missingResultsPenalty
        XCTAssertEqual(points, expected)
    }

    // MARK: - Risk Level Tests

    /// Test low risk level calculation.
    func testCalculateRiskLevelLow() {
        let level = TransparencyScorer.calculateRiskLevel(
            score: 80,
            industryFunding: false,
            dataAvailability: .fullOpen,
            coiDisclosed: true
        )
        XCTAssertEqual(level, .low)
    }

    /// Test medium risk level by score.
    func testCalculateRiskLevelMediumByScore() {
        let level = TransparencyScorer.calculateRiskLevel(
            score: 55,
            industryFunding: false,
            dataAvailability: .fullOpen,
            coiDisclosed: true
        )
        XCTAssertEqual(level, .medium)
    }

    /// Test medium risk level by industry funding.
    func testCalculateRiskLevelMediumByIndustry() {
        let level = TransparencyScorer.calculateRiskLevel(
            score: 80,
            industryFunding: true,
            dataAvailability: .fullOpen,
            coiDisclosed: true
        )
        XCTAssertEqual(level, .medium)
    }

    /// Test high risk level by score.
    func testCalculateRiskLevelHighByScore() {
        let level = TransparencyScorer.calculateRiskLevel(
            score: 30,
            industryFunding: false,
            dataAvailability: .fullOpen,
            coiDisclosed: true
        )
        XCTAssertEqual(level, .high)
    }

    /// Test high risk level by industry funding with restricted data.
    func testCalculateRiskLevelHighByIndustryData() {
        let level = TransparencyScorer.calculateRiskLevel(
            score: 60,
            industryFunding: true,
            dataAvailability: .notAvailable,
            coiDisclosed: true
        )
        XCTAssertEqual(level, .high)
    }

    /// Test high risk level by missing COI.
    func testCalculateRiskLevelHighByMissingCOI() {
        let level = TransparencyScorer.calculateRiskLevel(
            score: 60,
            industryFunding: false,
            dataAvailability: .fullOpen,
            coiDisclosed: false
        )
        XCTAssertEqual(level, .high)
    }

    /// Test custom threshold for risk level.
    func testCalculateRiskLevelCustomThreshold() {
        let level = TransparencyScorer.calculateRiskLevel(
            score: 50,
            industryFunding: false,
            dataAvailability: .fullOpen,
            coiDisclosed: true,
            scoreThreshold: 30
        )
        // 50 is above threshold of 30, but below 70, so medium
        XCTAssertEqual(level, .medium)
    }

    /// Test disabling industry data trigger.
    func testCalculateRiskLevelIndustryDataDisabled() {
        let level = TransparencyScorer.calculateRiskLevel(
            score: 60,
            industryFunding: true,
            dataAvailability: .notAvailable,
            coiDisclosed: true,
            industryDataTriggersHighRisk: false
        )
        // Would be high, but trigger is disabled, so medium (due to industry)
        XCTAssertEqual(level, .medium)
    }

    // MARK: - Risk Indicators Tests

    /// Test industry funding risk indicators.
    func testIdentifyRiskIndicatorsIndustry() {
        let indicators = TransparencyScorer.identifyRiskIndicators(
            industryFundingDetected: true,
            dataAvailability: DataAvailabilityResult(disclosureLevel: .notAvailable),
            resultsCompliance: .unknown,
            coiAnalysis: COIAnalysisResult.notAvailable,
            trialRegistrations: [],
            outcomeSwitchingDetected: false,
            title: nil
        )

        XCTAssertTrue(indicators.contains("Industry funding detected"))
        XCTAssertTrue(indicators.contains("Industry-funded with restricted data access"))
    }

    /// Test missing results risk indicator.
    func testIdentifyRiskIndicatorsMissingResults() {
        let indicators = TransparencyScorer.identifyRiskIndicators(
            industryFundingDetected: false,
            dataAvailability: DataAvailabilityResult.notStated,
            resultsCompliance: .missing,
            coiAnalysis: COIAnalysisResult.notAvailable,
            trialRegistrations: [],
            outcomeSwitchingDetected: false,
            title: nil
        )

        XCTAssertTrue(indicators.contains { $0.contains("Trial results not posted") })
    }

    /// Test industry ties risk indicator.
    func testIdentifyRiskIndicatorsIndustryTies() {
        let coiWithTies = COIAnalysisResult(
            statement: "Grants from Pfizer",
            hasIndustryTies: true
        )
        let indicators = TransparencyScorer.identifyRiskIndicators(
            industryFundingDetected: false,
            dataAvailability: DataAvailabilityResult(disclosureLevel: .fullOpen),
            resultsCompliance: .unknown,
            coiAnalysis: coiWithTies,
            trialRegistrations: [],
            outcomeSwitchingDetected: false,
            title: nil
        )

        XCTAssertTrue(indicators.contains("Authors have disclosed industry financial ties"))
    }

    /// Test missing COI risk indicator.
    func testIdentifyRiskIndicatorsMissingCOI() {
        let indicators = TransparencyScorer.identifyRiskIndicators(
            industryFundingDetected: false,
            dataAvailability: DataAvailabilityResult(disclosureLevel: .fullOpen),
            resultsCompliance: .unknown,
            coiAnalysis: COIAnalysisResult.notAvailable,
            trialRegistrations: [],
            outcomeSwitchingDetected: false,
            title: nil
        )

        XCTAssertTrue(indicators.contains("No conflict of interest statement found"))
    }

    /// Test missing registration risk indicator.
    func testIdentifyRiskIndicatorsMissingRegistration() {
        let indicators = TransparencyScorer.identifyRiskIndicators(
            industryFundingDetected: false,
            dataAvailability: DataAvailabilityResult(disclosureLevel: .fullOpen),
            resultsCompliance: .unknown,
            coiAnalysis: COIAnalysisResult(statement: "None"),
            trialRegistrations: [],
            outcomeSwitchingDetected: false,
            title: "Randomized Controlled Trial"
        )

        XCTAssertTrue(indicators.contains { $0.contains("without detected registration") })
    }

    /// Test outcome switching risk indicator.
    func testIdentifyRiskIndicatorsOutcomeSwitching() {
        let indicators = TransparencyScorer.identifyRiskIndicators(
            industryFundingDetected: false,
            dataAvailability: DataAvailabilityResult(disclosureLevel: .fullOpen),
            resultsCompliance: .unknown,
            coiAnalysis: COIAnalysisResult(statement: "None"),
            trialRegistrations: [],
            outcomeSwitchingDetected: true,
            title: nil
        )

        XCTAssertTrue(indicators.contains("Outcome switching detected"))
    }

    /// Test standalone data availability risk indicators (without industry funding).
    func testIdentifyRiskIndicatorsDataAvailability() {
        let unavailable = TransparencyScorer.identifyRiskIndicators(
            industryFundingDetected: false,
            dataAvailability: DataAvailabilityResult(disclosureLevel: .notAvailable),
            resultsCompliance: .unknown,
            coiAnalysis: COIAnalysisResult(statement: "None"),
            trialRegistrations: [],
            outcomeSwitchingDetected: false,
            title: nil
        )
        XCTAssertTrue(
            unavailable.contains("Data effectively unavailable despite sharing statement")
        )

        let restricted = TransparencyScorer.identifyRiskIndicators(
            industryFundingDetected: false,
            dataAvailability: DataAvailabilityResult(disclosureLevel: .restricted),
            resultsCompliance: .unknown,
            coiAnalysis: COIAnalysisResult(statement: "None"),
            trialRegistrations: [],
            outcomeSwitchingDetected: false,
            title: nil
        )
        XCTAssertTrue(restricted.contains("Data access restricted"))
    }

    // MARK: - Tooltip Tests

    /// Test tooltip formatting.
    func testFormatTooltip() {
        let result = TransparencyResult(
            title: "Test Study",
            transparencyScore: 65,
            riskLevel: .medium,
            riskIndicators: ["Industry funding detected"]
        )

        let tooltip = TransparencyScorer.formatTooltip(for: result)

        XCTAssertTrue(tooltip.contains("65/100"))
        XCTAssertTrue(tooltip.contains("Medium Risk"))
        XCTAssertTrue(tooltip.contains("Risk Indicators:"))
    }

    /// Test tooltip with industry funding.
    func testFormatTooltipWithIndustryFunding() {
        let result = TransparencyResult(
            title: "Test Study",
            industryFundingDetected: true,
            industryFundingConfidence: 0.85,
            transparencyScore: 50,
            riskLevel: .medium
        )

        let tooltip = TransparencyScorer.formatTooltip(for: result)

        XCTAssertTrue(tooltip.contains("Industry Funding: Detected"))
        XCTAssertTrue(tooltip.contains("85% confidence"))
    }

    /// Test tooltip with trial registration.
    func testFormatTooltipWithTrialRegistration() {
        let result = TransparencyResult(
            title: "Test Study",
            trialRegistrations: [
                TrialRegistration(registry: "CT.gov", registrationId: "NCT123", resultsPosted: true)
            ],
            transparencyScore: 70,
            riskLevel: .low
        )

        let tooltip = TransparencyScorer.formatTooltip(for: result)

        XCTAssertTrue(tooltip.contains("Trial Registration: Registered"))
        XCTAssertTrue(tooltip.contains("Results Compliant"))
    }

    // MARK: - Score Category Tests

    /// Test score category determination.
    func testScoreCategory() {
        XCTAssertEqual(TransparencyScorer.scoreCategory(90), "Good transparency")
        XCTAssertEqual(TransparencyScorer.scoreCategory(76), "Good transparency")
        XCTAssertEqual(TransparencyScorer.scoreCategory(75), "Average transparency")
        XCTAssertEqual(TransparencyScorer.scoreCategory(60), "Average transparency")
        XCTAssertEqual(TransparencyScorer.scoreCategory(51), "Average transparency")
        XCTAssertEqual(TransparencyScorer.scoreCategory(50), "Below average transparency")
        XCTAssertEqual(TransparencyScorer.scoreCategory(40), "Below average transparency")
        XCTAssertEqual(TransparencyScorer.scoreCategory(26), "Below average transparency")
        XCTAssertEqual(TransparencyScorer.scoreCategory(25), "Poor transparency")
        XCTAssertEqual(TransparencyScorer.scoreCategory(10), "Poor transparency")
        XCTAssertEqual(TransparencyScorer.scoreCategory(0), "Poor transparency")
    }

    // MARK: - Builder Integration Tests

    /// Test TransparencyResultBuilder uses TransparencyScorer.
    func testBuilderUsesScorer() {
        var builder = TransparencyResultBuilder(pmid: "12345678")
        builder.dataAvailability = DataAvailabilityResult(disclosureLevel: .fullOpen)
        builder.coiAnalysis = COIAnalysisResult(statement: "No conflicts")
        builder.industryFundingDetected = false

        let result = builder.build()

        // Base (50) + data (20) + COI (10) = 80
        XCTAssertEqual(result.transparencyScore, 80)
        XCTAssertEqual(result.riskLevel, .low)
    }

    /// Test builder with industry funding affects risk level.
    func testBuilderWithIndustryFunding() {
        var builder = TransparencyResultBuilder(pmid: "12345678")
        builder.dataAvailability = DataAvailabilityResult(disclosureLevel: .notAvailable)
        builder.coiAnalysis = COIAnalysisResult(statement: "No conflicts")
        builder.industryFundingDetected = true

        let result = builder.build()

        // Should be high risk due to industry + restricted data
        XCTAssertEqual(result.riskLevel, .high)
    }
}
