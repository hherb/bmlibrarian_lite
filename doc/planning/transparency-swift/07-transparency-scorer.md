# Step 07: Transparency Scorer

## Goal

Create pure functions for calculating transparency scores and risk levels.

## File to Create

### `Sources/BioMedLit/Transparency/Analysis/TransparencyScorer.swift`

```swift
// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2025 Dr Horst Herb
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Pure functions for calculating transparency scores and risk levels.
///
/// All functions are stateless and can be safely called from any context.
///
/// Usage:
/// ```swift
/// let score = TransparencyScorer.calculateScore(...)
/// let riskLevel = TransparencyScorer.calculateRiskLevel(score: score, ...)
/// ```
public enum TransparencyScorer {

    // MARK: - Score Calculation

    /// Calculate overall transparency score (0-100).
    ///
    /// Scoring breakdown:
    /// - Data availability: +20 (open), +10 (request), 0 (restricted), -10 (unavailable), -5 (not stated)
    /// - COI disclosure: +10 (has statement), -5 (missing)
    /// - Trial registration: +10 (has registration), +5 (results compliant), -10 (results missing)
    /// - Penalties: -15 (outcome switching), -10 (industry + no data sharing)
    ///
    /// - Returns: Score from 0 to 100
    public static func calculateScore(
        dataAvailability: DataAvailabilityResult,
        coiAnalysis: COIAnalysisResult,
        trialRegistrations: [TrialRegistration],
        resultsCompliance: ResultsComplianceStatus,
        industryFundingDetected: Bool,
        outcomeSwitchingDetected: Bool
    ) -> Int {
        var score = TransparencyConstants.baseTransparencyScore

        // Data availability points
        score += dataAvailabilityPoints(for: dataAvailability.disclosureLevel)

        // COI disclosure points
        score += coiDisclosurePoints(hasStatement: coiAnalysis.statement != nil)

        // Trial registration points
        score += trialRegistrationPoints(
            registrations: trialRegistrations,
            compliance: resultsCompliance
        )

        // Outcome switching penalty
        if outcomeSwitchingDetected {
            score += TransparencyConstants.outcomeSwitchingPenalty
        }

        // Industry funding + restricted data penalty
        if industryFundingDetected &&
           dataAvailability.disclosureLevel == .notAvailable {
            score += TransparencyConstants.industryNoDataPenalty
        }

        // Clamp to valid range
        return max(0, min(100, score))
    }

    /// Calculate points for data availability level.
    public static func dataAvailabilityPoints(for level: DataDisclosureLevel) -> Int {
        switch level {
        case .fullOpen:
            return TransparencyConstants.fullOpenDataPoints
        case .availableOnRequest:
            return TransparencyConstants.onRequestDataPoints
        case .restricted:
            return 0
        case .notAvailable:
            return TransparencyConstants.noDataPenalty
        case .notStated:
            return TransparencyConstants.noStatementPenalty
        case .unknown:
            return 0
        }
    }

    /// Calculate points for COI disclosure.
    public static func coiDisclosurePoints(hasStatement: Bool) -> Int {
        hasStatement ?
            TransparencyConstants.coiStatementPoints :
            TransparencyConstants.missingCoiPenalty
    }

    /// Calculate points for trial registration.
    public static func trialRegistrationPoints(
        registrations: [TrialRegistration],
        compliance: ResultsComplianceStatus
    ) -> Int {
        guard !registrations.isEmpty else { return 0 }

        var points = TransparencyConstants.trialRegistrationPoints

        switch compliance {
        case .compliant:
            points += TransparencyConstants.compliantResultsPoints
        case .missing:
            points += TransparencyConstants.missingResultsPenalty
        case .late, .notRequired, .unknown:
            break
        }

        return points
    }

    // MARK: - Risk Level Calculation

    /// Calculate risk level from transparency metrics.
    ///
    /// High Risk: score < 40 OR (industry + restricted data) OR missing COI
    /// Medium Risk: score 40-70 OR industry with disclosure
    /// Low Risk: score > 70, transparent
    ///
    /// - Parameters:
    ///   - score: Transparency score (0-100)
    ///   - industryFunding: Whether industry funding detected
    ///   - dataAvailability: Data disclosure level
    ///   - coiDisclosed: Whether COI statement exists
    ///   - settings: Optional custom thresholds (uses defaults if nil)
    /// - Returns: Risk level classification
    public static func calculateRiskLevel(
        score: Int,
        industryFunding: Bool,
        dataAvailability: DataDisclosureLevel,
        coiDisclosed: Bool,
        scoreThreshold: Int = TransparencyConstants.highRiskScoreThreshold,
        industryDataTriggersHighRisk: Bool = true,
        missingCoiTriggersHighRisk: Bool = true
    ) -> TransparencyRiskLevel {
        // High risk: low score
        if score < scoreThreshold {
            return .high
        }

        // High risk: industry funding with restricted/unavailable data
        if industryDataTriggersHighRisk && industryFunding {
            let restrictedLevels: [DataDisclosureLevel] = [.restricted, .notAvailable, .notStated]
            if restrictedLevels.contains(dataAvailability) {
                return .high
            }
        }

        // High risk: missing COI disclosure
        if missingCoiTriggersHighRisk && !coiDisclosed {
            return .high
        }

        // Medium risk: score in middle range
        if score <= TransparencyConstants.mediumRiskScoreThreshold {
            return .medium
        }

        // Medium risk: any industry funding (even with disclosure)
        if industryFunding {
            return .medium
        }

        return .low
    }

    // MARK: - Risk Indicators

    /// Identify risk of bias indicators.
    ///
    /// - Returns: List of human-readable risk indicator strings
    public static func identifyRiskIndicators(
        industryFundingDetected: Bool,
        dataAvailability: DataAvailabilityResult,
        resultsCompliance: ResultsComplianceStatus,
        coiAnalysis: COIAnalysisResult,
        trialRegistrations: [TrialRegistration],
        title: String?
    ) -> [String] {
        var indicators: [String] = []

        // Industry funding indicators
        if industryFundingDetected {
            indicators.append("Industry funding detected")

            let restrictedLevels: [DataDisclosureLevel] = [.notAvailable, .restricted]
            if restrictedLevels.contains(dataAvailability.disclosureLevel) {
                indicators.append("Industry-funded with restricted data access")
            }
        }

        // Trial results compliance
        if resultsCompliance == .missing {
            indicators.append("Trial results not posted to ClinicalTrials.gov")
        }

        // COI concerns
        if coiAnalysis.hasIndustryTies {
            indicators.append("Authors have industry financial ties")
        }
        if coiAnalysis.statement == nil {
            indicators.append("No conflict of interest statement found")
        }

        // Missing trial registration
        if let warning = TrialComplianceAnalyzer.checkMissingRegistration(
            title: title,
            registrations: trialRegistrations
        ) {
            indicators.append(warning)
        }

        return indicators
    }

    // MARK: - Tooltip Formatting

    /// Format a detailed tooltip for the transparency result.
    ///
    /// - Parameter result: Transparency analysis result
    /// - Returns: Formatted tooltip string
    public static func formatTooltip(for result: TransparencyResult) -> String {
        var lines: [String] = []

        lines.append("Transparency Score: \(result.transparencyScore)/100")
        lines.append("Risk Level: \(result.riskLevel.fullLabel)")
        lines.append("")

        // Funding section
        if result.industryFundingDetected {
            let pct = Int(result.industryFundingConfidence * 100)
            lines.append("Industry Funding: Detected (\(pct)% confidence)")
        } else {
            lines.append("Industry Funding: Not detected")
        }

        // Data availability
        lines.append("Data Availability: \(result.dataAvailability.disclosureLevel.displayName)")

        // COI disclosure
        let coiStatus = result.coiAnalysis.statement != nil ?
            (result.coiAnalysis.hasIndustryTies ? "Disclosed" : "No conflicts") :
            "Not Disclosed"
        lines.append("Conflicts of Interest: \(coiStatus)")

        // Trial registration
        if !result.trialRegistrations.isEmpty {
            let resultsStatus = result.trialRegistrations.first?.resultsPosted == true ?
                "Results Compliant" : "Results Not Posted"
            lines.append("Trial Registration: Registered (\(resultsStatus))")
        }

        // Risk indicators
        if !result.riskIndicators.isEmpty {
            let maxIndicators = TransparencyConstants.maxRiskIndicatorsInTooltip
            lines.append("")
            lines.append("Risk Indicators:")
            for indicator in result.riskIndicators.prefix(maxIndicators) {
                lines.append("  • \(indicator)")
            }
            if result.riskIndicators.count > maxIndicators {
                lines.append("  ... and \(result.riskIndicators.count - maxIndicators) more")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Score Category

    /// Get score category description.
    ///
    /// - Parameter score: Transparency score (0-100)
    /// - Returns: Category description
    public static func scoreCategory(_ score: Int) -> String {
        switch score {
        case TransparencyConstants.goodTransparencyThreshold...100:
            return "Good transparency"
        case TransparencyConstants.averageTransparencyThreshold..<TransparencyConstants.goodTransparencyThreshold:
            return "Average transparency"
        case TransparencyConstants.belowAverageTransparencyThreshold..<TransparencyConstants.averageTransparencyThreshold:
            return "Below average transparency"
        default:
            return "Poor transparency"
        }
    }
}
```

## Testing

```swift
import XCTest
@testable import BioMedLit

final class TransparencyScorerTests: XCTestCase {

    // MARK: - Score Calculation Tests

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
    }

    // MARK: - Risk Level Tests

    func testCalculateRiskLevelLow() {
        let level = TransparencyScorer.calculateRiskLevel(
            score: 80,
            industryFunding: false,
            dataAvailability: .fullOpen,
            coiDisclosed: true
        )
        XCTAssertEqual(level, .low)
    }

    func testCalculateRiskLevelMediumByScore() {
        let level = TransparencyScorer.calculateRiskLevel(
            score: 55,
            industryFunding: false,
            dataAvailability: .fullOpen,
            coiDisclosed: true
        )
        XCTAssertEqual(level, .medium)
    }

    func testCalculateRiskLevelMediumByIndustry() {
        let level = TransparencyScorer.calculateRiskLevel(
            score: 80,
            industryFunding: true,
            dataAvailability: .fullOpen,
            coiDisclosed: true
        )
        XCTAssertEqual(level, .medium)
    }

    func testCalculateRiskLevelHighByScore() {
        let level = TransparencyScorer.calculateRiskLevel(
            score: 30,
            industryFunding: false,
            dataAvailability: .fullOpen,
            coiDisclosed: true
        )
        XCTAssertEqual(level, .high)
    }

    func testCalculateRiskLevelHighByIndustryData() {
        let level = TransparencyScorer.calculateRiskLevel(
            score: 60,
            industryFunding: true,
            dataAvailability: .notAvailable,
            coiDisclosed: true
        )
        XCTAssertEqual(level, .high)
    }

    func testCalculateRiskLevelHighByMissingCOI() {
        let level = TransparencyScorer.calculateRiskLevel(
            score: 60,
            industryFunding: false,
            dataAvailability: .fullOpen,
            coiDisclosed: false
        )
        XCTAssertEqual(level, .high)
    }

    // MARK: - Risk Indicators Tests

    func testIdentifyRiskIndicatorsIndustry() {
        let indicators = TransparencyScorer.identifyRiskIndicators(
            industryFundingDetected: true,
            dataAvailability: DataAvailabilityResult(disclosureLevel: .notAvailable),
            resultsCompliance: .unknown,
            coiAnalysis: COIAnalysisResult.notAvailable,
            trialRegistrations: [],
            title: nil
        )

        XCTAssertTrue(indicators.contains("Industry funding detected"))
        XCTAssertTrue(indicators.contains("Industry-funded with restricted data access"))
    }

    func testIdentifyRiskIndicatorsMissingResults() {
        let indicators = TransparencyScorer.identifyRiskIndicators(
            industryFundingDetected: false,
            dataAvailability: DataAvailabilityResult.notStated,
            resultsCompliance: .missing,
            coiAnalysis: COIAnalysisResult.notAvailable,
            trialRegistrations: [],
            title: nil
        )

        XCTAssertTrue(indicators.contains { $0.contains("Trial results not posted") })
    }

    // MARK: - Tooltip Tests

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
    }

    // MARK: - Score Category Tests

    func testScoreCategory() {
        XCTAssertEqual(TransparencyScorer.scoreCategory(90), "Good transparency")
        XCTAssertEqual(TransparencyScorer.scoreCategory(60), "Average transparency")
        XCTAssertEqual(TransparencyScorer.scoreCategory(40), "Below average transparency")
        XCTAssertEqual(TransparencyScorer.scoreCategory(20), "Poor transparency")
    }
}
```

## Dependencies

- `TransparencyModels.swift` (Step 01)
- `TransparencyConstants.swift` (Step 02)
- `TrialComplianceAnalyzer.swift` (Step 06)

## Notes

- Pure functions with no side effects
- Scoring constants are configurable via TransparencyConstants
- Risk level calculation allows custom thresholds
- Tooltip formatting for direct use in SwiftUI `.help()` modifier
