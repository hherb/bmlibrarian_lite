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

import Foundation

/// Pure functions for calculating transparency scores and risk levels.
///
/// All functions are stateless and can be safely called from any context.
/// This module provides the core scoring logic for transparency analysis,
/// calculating scores based on data availability, COI disclosure, trial
/// registration, and other factors.
///
/// Scoring breakdown:
/// - Base score: 50 points
/// - Data availability: +20 (open), +10 (request), 0 (restricted), -10 (unavailable), -5 (not stated)
/// - COI disclosure: +10 (has statement), -5 (missing)
/// - Trial registration: +10 (has registration), +5 (results compliant), -10 (results missing)
/// - Penalties: -15 (outcome switching), -10 (industry + no data sharing)
///
/// Usage:
/// ```swift
/// let score = TransparencyScorer.calculateScore(...)
/// let riskLevel = TransparencyScorer.calculateRiskLevel(score: score, ...)
/// let tooltip = TransparencyScorer.formatTooltip(for: result)
/// ```
public enum TransparencyScorer {

    // MARK: - Score Calculation

    /// Calculate overall transparency score (0-100).
    ///
    /// Combines multiple transparency factors into a single score using
    /// weighted point additions and penalties defined in TransparencyConstants.
    ///
    /// - Parameters:
    ///   - dataAvailability: Data availability analysis result.
    ///   - coiAnalysis: Conflict of interest analysis result.
    ///   - trialRegistrations: List of trial registrations found.
    ///   - resultsCompliance: Results posting compliance status.
    ///   - industryFundingDetected: Whether industry funding was detected.
    ///   - outcomeSwitchingDetected: Whether outcome switching was detected.
    /// - Returns: Score from 0 to 100 (clamped to this range).
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
        score += coiDisclosurePoints(hasStatement: coiAnalysis.hasStatement)

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
        return max(
            TransparencyConstants.minTransparencyScore,
            min(TransparencyConstants.maxTransparencyScore, score)
        )
    }

    /// Calculate points for data availability level.
    ///
    /// Maps data disclosure levels to their corresponding point values.
    ///
    /// - Parameter level: The data disclosure level.
    /// - Returns: Points to add (positive) or subtract (negative) from score.
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
    ///
    /// Awards points for having a COI statement, penalizes for missing.
    ///
    /// - Parameter hasStatement: True if a COI statement was found.
    /// - Returns: Points to add (positive) or subtract (negative) from score.
    public static func coiDisclosurePoints(hasStatement: Bool) -> Int {
        hasStatement ?
            TransparencyConstants.coiStatementPoints :
            TransparencyConstants.missingCoiPenalty
    }

    /// Calculate points for trial registration.
    ///
    /// Awards points for having trial registration and additional points
    /// for compliant results posting, with penalties for missing results.
    ///
    /// - Parameters:
    ///   - registrations: List of trial registrations found.
    ///   - compliance: Results posting compliance status.
    /// - Returns: Points to add (positive) or subtract (negative) from score.
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
    /// Determines risk level based on score thresholds and specific risk factors:
    /// - High Risk: score < threshold OR (industry + restricted data) OR missing COI
    /// - Medium Risk: score in middle range OR industry with disclosure
    /// - Low Risk: score > threshold and no risk factors
    ///
    /// - Parameters:
    ///   - score: Transparency score (0-100).
    ///   - industryFunding: Whether industry funding was detected.
    ///   - dataAvailability: Data disclosure level.
    ///   - coiDisclosed: Whether a COI statement exists.
    ///   - scoreThreshold: Score below which is considered high risk
    ///     (defaults to TransparencyConstants.highRiskScoreThreshold).
    ///   - industryDataTriggersHighRisk: Whether industry funding with restricted
    ///     data should trigger high risk (defaults to true).
    ///   - missingCoiTriggersHighRisk: Whether missing COI should trigger
    ///     high risk (defaults to true).
    /// - Returns: Risk level classification.
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
    /// Examines all transparency factors and generates a list of human-readable
    /// risk indicator strings for display in the UI.
    ///
    /// Indicator strings are kept aligned with the Python reference
    /// implementation in
    /// `src/bmlibrarian_lite/study_transparency_analyzer/`.
    ///
    /// - Parameters:
    ///   - industryFundingDetected: Whether industry funding was detected.
    ///   - dataAvailability: Data availability analysis result.
    ///   - resultsCompliance: Results posting compliance status.
    ///   - coiAnalysis: COI analysis result.
    ///   - trialRegistrations: List of trial registrations found.
    ///   - outcomeSwitchingDetected: Whether outcome switching was detected.
    ///   - title: Study title (for missing registration check).
    /// - Returns: List of human-readable risk indicator strings.
    public static func identifyRiskIndicators(
        industryFundingDetected: Bool,
        dataAvailability: DataAvailabilityResult,
        resultsCompliance: ResultsComplianceStatus,
        coiAnalysis: COIAnalysisResult,
        trialRegistrations: [TrialRegistration],
        outcomeSwitchingDetected: Bool,
        title: String?
    ) -> [String] {
        var indicators: [String] = []

        // Industry funding indicators
        if industryFundingDetected {
            indicators.append(RiskIndicatorStrings.industryFunding)

            let restrictedLevels: [DataDisclosureLevel] = [.notAvailable, .restricted]
            if restrictedLevels.contains(dataAvailability.disclosureLevel) {
                indicators.append(RiskIndicatorStrings.industryRestrictedData)
            }
        }

        // Trial results compliance
        if resultsCompliance == .missing {
            indicators.append(RiskIndicatorStrings.resultsNotPosted)
        }

        // COI concerns
        if coiAnalysis.hasIndustryTies {
            indicators.append(RiskIndicatorStrings.industryTiesDisclosed)
        }
        if !coiAnalysis.hasStatement {
            indicators.append(RiskIndicatorStrings.missingCoiStatement)
        }

        // Data availability concerns (independent of funding source)
        switch dataAvailability.disclosureLevel {
        case .notAvailable:
            indicators.append(RiskIndicatorStrings.dataEffectivelyUnavailable)
        case .restricted:
            indicators.append(RiskIndicatorStrings.dataAccessRestricted)
        default:
            break
        }

        // Outcome switching
        if outcomeSwitchingDetected {
            indicators.append(RiskIndicatorStrings.outcomeSwitching)
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
    /// Generates a multi-line tooltip string suitable for display in SwiftUI's
    /// `.help()` modifier or similar tooltip contexts.
    ///
    /// - Parameter result: Transparency analysis result.
    /// - Returns: Formatted tooltip string with line breaks.
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
        let coiStatus: String
        if result.coiAnalysis.hasStatement {
            coiStatus = result.coiAnalysis.hasIndustryTies ? "Disclosed" : "No conflicts"
        } else {
            coiStatus = "Not Disclosed"
        }
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
                lines.append("  \u{2022} \(indicator)")
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
    /// Maps a transparency score to a human-readable category description
    /// for display in the UI.
    ///
    /// - Parameter score: Transparency score (0-100).
    /// - Returns: Category description string.
    public static func scoreCategory(_ score: Int) -> String {
        switch score {
        case TransparencyConstants.goodTransparencyThreshold...TransparencyConstants.maxTransparencyScore:
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
