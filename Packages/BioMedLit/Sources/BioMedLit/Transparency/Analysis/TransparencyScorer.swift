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
/// Scoring breakdown (kept identical to the canonical Python reference,
/// `calculate_transparency_score`):
/// - Base score: 50 points
/// - Data availability: +20 (open), +5 (request), -5 (restricted), -15 (unavailable), -5 (not stated)
/// - COI disclosure: +5 (has statement), an extra -5 if the statement discloses
///   industry ties, -5 (missing)
/// - Trial registration: +10 (has registration), +5 (results compliant), -10 (results missing)
/// - Penalties: -15 (outcome switching), -10 (industry ties + restricted/unavailable data)
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
        let score = scoreComponents(
            dataAvailability: dataAvailability,
            coiAnalysis: coiAnalysis,
            trialRegistrations: trialRegistrations,
            resultsCompliance: resultsCompliance,
            industryFundingDetected: industryFundingDetected,
            outcomeSwitchingDetected: outcomeSwitchingDetected
        ).reduce(0) { $0 + $1.points }

        // Clamp to valid range
        return max(
            TransparencyConstants.minTransparencyScore,
            min(TransparencyConstants.maxTransparencyScore, score)
        )
    }

    /// The additions and penalties a transparency score is the sum of.
    ///
    /// ``calculateScore(dataAvailability:coiAnalysis:trialRegistrations:resultsCompliance:industryFundingDetected:outcomeSwitchingDetected:)``
    /// is the clamped sum of these, so a report explaining a low score lists
    /// the very terms that produced it. Terms worth zero points are omitted;
    /// the base score is always first.
    ///
    /// - Parameters: As for `calculateScore`.
    /// - Returns: Each term that moved the score, in the order it is applied.
    public static func scoreComponents(
        dataAvailability: DataAvailabilityResult,
        coiAnalysis: COIAnalysisResult,
        trialRegistrations: [TrialRegistration],
        resultsCompliance: ResultsComplianceStatus,
        industryFundingDetected: Bool,
        outcomeSwitchingDetected: Bool
    ) -> [ScoreComponent] {
        let base = ScoreComponent(
            label: "Starting score",
            points: TransparencyConstants.baseTransparencyScore
        )
        var components: [ScoreComponent] = []

        let level = dataAvailability.disclosureLevel
        components.append(ScoreComponent(
            label: "Data availability: \(level.displayName.lowercased())",
            points: dataAvailabilityPoints(for: level)
        ))

        // Stated as the separate terms `coiDisclosurePoints` adds up, so a
        // statement disclosing industry ties reads as credit and penalty
        // rather than as a net zero that looks like nothing was found.
        if coiAnalysis.hasStatement {
            components.append(ScoreComponent(
                label: "Conflict of interest statement present",
                points: TransparencyConstants.coiStatementPoints
            ))
            if coiAnalysis.hasIndustryTies {
                components.append(ScoreComponent(
                    label: "Conflict of interest statement discloses industry ties",
                    points: TransparencyConstants.coiIndustryTiesPenalty
                ))
            }
        } else {
            components.append(ScoreComponent(
                label: "No conflict of interest statement found",
                points: coiDisclosurePoints(hasStatement: false)
            ))
        }

        if !trialRegistrations.isEmpty {
            components.append(ScoreComponent(
                label: "Trial registered",
                points: TransparencyConstants.trialRegistrationPoints
            ))
            switch resultsCompliance {
            case .compliant:
                components.append(ScoreComponent(
                    label: "Trial results posted on time",
                    points: TransparencyConstants.compliantResultsPoints
                ))
            case .missing:
                components.append(ScoreComponent(
                    label: "Trial results not posted",
                    points: TransparencyConstants.missingResultsPenalty
                ))
            case .late, .notRequired, .unknown:
                break
            }
        }

        if outcomeSwitchingDetected {
            components.append(ScoreComponent(
                label: "Outcome switching detected",
                points: TransparencyConstants.outcomeSwitchingPenalty
            ))
        }

        // Industry ties (funding or disclosed COI) combined with
        // restricted/unavailable data is especially concerning.
        let hasIndustryTies = industryFundingDetected || coiAnalysis.hasIndustryTies
        let restrictedOrUnavailable: [DataDisclosureLevel] = [.notAvailable, .restricted]
        if hasIndustryTies && restrictedOrUnavailable.contains(level) {
            components.append(ScoreComponent(
                label: "Industry ties with restricted or unavailable data",
                points: TransparencyConstants.industryNoDataPenalty
            ))
        }

        return [base] + components.filter { $0.points != 0 }
    }

    /// The score terms of a stored result, as ``scoreComponents(dataAvailability:coiAnalysis:trialRegistrations:resultsCompliance:industryFundingDetected:outcomeSwitchingDetected:)``
    /// computes them from its recorded findings.
    ///
    /// - Parameter result: A stored transparency result.
    /// - Returns: Each term that moved the score.
    public static func scoreComponents(for result: TransparencyResult) -> [ScoreComponent] {
        scoreComponents(
            dataAvailability: result.dataAvailability,
            coiAnalysis: result.coiAnalysis,
            trialRegistrations: result.trialRegistrations,
            resultsCompliance: result.resultsCompliance,
            industryFundingDetected: result.industryFundingDetected,
            outcomeSwitchingDetected: result.outcomeSwitchingDetected
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
            return TransparencyConstants.restrictedDataPenalty
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
    /// Credits having a COI statement (disclosure is valued), but applies an
    /// additional penalty when the statement discloses industry ties, since
    /// the underlying situation carries bias risk regardless of disclosure
    /// quality. A missing statement is penalized. Mirrors the Python reference.
    ///
    /// - Parameters:
    ///   - hasStatement: True if a non-empty COI statement was found.
    ///   - hasIndustryTies: True if the statement discloses industry ties.
    /// - Returns: Points to add (positive) or subtract (negative) from score.
    public static func coiDisclosurePoints(
        hasStatement: Bool,
        hasIndustryTies: Bool = false
    ) -> Int {
        guard hasStatement else {
            return TransparencyConstants.missingCoiPenalty
        }
        var points = TransparencyConstants.coiStatementPoints
        if hasIndustryTies {
            points += TransparencyConstants.coiIndustryTiesPenalty
        }
        return points
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
        let triggers = highRiskTriggers(
            score: score,
            industryFunding: industryFunding,
            dataAvailability: dataAvailability,
            coiDisclosed: coiDisclosed,
            scoreThreshold: scoreThreshold,
            industryDataTriggersHighRisk: industryDataTriggersHighRisk,
            missingCoiTriggersHighRisk: missingCoiTriggersHighRisk
        )
        if !triggers.isEmpty {
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

    /// Every rule that, on its own, rates a study high risk.
    ///
    /// ``calculateRiskLevel(score:industryFunding:dataAvailability:coiDisclosed:scoreThreshold:industryDataTriggersHighRisk:missingCoiTriggersHighRisk:)``
    /// rates a study high exactly when this is non-empty, so a report that
    /// explains a high rating names the rules that produced it rather than a
    /// second reading of them that could drift. All matching rules are
    /// returned, not only the first, because a reader weighing the rating
    /// needs to know whether removing one concern would change it.
    ///
    /// - Parameters: As for `calculateRiskLevel`.
    /// - Returns: The high-risk rules that apply, in the order they are checked.
    public static func highRiskTriggers(
        score: Int,
        industryFunding: Bool,
        dataAvailability: DataDisclosureLevel,
        coiDisclosed: Bool,
        scoreThreshold: Int = TransparencyConstants.highRiskScoreThreshold,
        industryDataTriggersHighRisk: Bool = true,
        missingCoiTriggersHighRisk: Bool = true
    ) -> [HighRiskTrigger] {
        var triggers: [HighRiskTrigger] = []

        if score < scoreThreshold {
            triggers.append(.scoreBelowThreshold(score: score, threshold: scoreThreshold))
        }

        if industryDataTriggersHighRisk && industryFunding {
            let restrictedLevels: [DataDisclosureLevel] = [.restricted, .notAvailable, .notStated]
            if restrictedLevels.contains(dataAvailability) {
                triggers.append(.industryFundingWithWithheldData(dataAvailability))
            }
        }

        if missingCoiTriggersHighRisk && !coiDisclosed {
            triggers.append(.missingCOIStatement)
        }

        return triggers
    }

    /// The high-risk rules that apply to a stored result.
    ///
    /// Evaluated with the same defaults ``TransparencyResultBuilder/build()``
    /// rates with, so for a result this build produced it agrees with
    /// ``TransparencyResult/riskLevel``. A result from another analyzer can
    /// carry a high rating none of these rules explains; callers must say so
    /// rather than present an empty list as the reason.
    ///
    /// - Parameter result: A stored transparency result.
    /// - Returns: The high-risk rules its recorded findings meet.
    public static func highRiskTriggers(for result: TransparencyResult) -> [HighRiskTrigger] {
        highRiskTriggers(
            score: result.transparencyScore,
            industryFunding: result.industryFundingDetected,
            dataAvailability: result.dataAvailability.disclosureLevel,
            coiDisclosed: result.coiAnalysis.hasStatement
        )
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
        let restrictedOrUnavailable: [DataDisclosureLevel] = [.notAvailable, .restricted]

        // Industry funding indicators
        if industryFundingDetected {
            indicators.append(RiskIndicatorStrings.industryFunding)

            if restrictedOrUnavailable.contains(dataAvailability.disclosureLevel) {
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

            // Industry funding routed through an institutional intermediary.
            if let statement = coiAnalysis.statement,
               RegexHelper.anyMatch(
                   patterns: COIPatterns.institutionalIntermediaryPatterns,
                   in: statement.lowercased()
               ) {
                indicators.append(RiskIndicatorStrings.institutionalIntermediary)
            }
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

        // Combined risk: industry ties (funding or disclosed COI) + restricted/unavailable data.
        let hasIndustryTies = industryFundingDetected || coiAnalysis.hasIndustryTies
        if hasIndustryTies && restrictedOrUnavailable.contains(dataAvailability.disclosureLevel) {
            indicators.append(RiskIndicatorStrings.combinedIndustryData)
        }

        // Missing trial registration
        if let warning = TrialComplianceAnalyzer.checkMissingRegistration(
            title: title,
            registrations: trialRegistrations
        ) {
            indicators.append(warning)
        }

        // Deduplicate while preserving order (mirrors the Python reference).
        var seen = Set<String>()
        return indicators.filter { seen.insert($0).inserted }
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
        if let note = TransparencyCertainty(fullTextSearched: result.fullTextSearched).note {
            lines.append(note)
        }
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
