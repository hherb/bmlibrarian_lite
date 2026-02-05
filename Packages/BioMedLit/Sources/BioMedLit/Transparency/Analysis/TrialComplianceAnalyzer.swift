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

/// Pure functions for analyzing clinical trial compliance.
///
/// All functions are stateless and can be safely called from any context.
/// This module provides functionality for checking trial results posting compliance
/// based on FDAAA 2007 regulations, detecting clinical trials from study titles,
/// extracting NCT IDs from text, and analyzing outcome switching.
///
/// Usage:
/// ```swift
/// let compliance = TrialComplianceAnalyzer.checkResultsCompliance(
///     trial: trialReg,
///     publicationDate: pubDate
/// )
///
/// let nctIds = TrialComplianceAnalyzer.extractNCTIds(from: articleText)
/// ```
public enum TrialComplianceAnalyzer {

    // MARK: - Outcome Word Overlap Threshold

    /// Minimum word overlap ratio for matching registered outcomes to reported outcomes.
    /// A ratio above this threshold indicates the outcome is likely reported.
    private static let outcomeWordOverlapThreshold: Double = 0.5

    // MARK: - Results Compliance

    /// Check if trial results posting is compliant with regulations.
    ///
    /// Based on FDAAA 2007 which requires results within 12 months of completion
    /// for applicable clinical trials.
    ///
    /// - Parameters:
    ///   - trial: Trial registration information.
    ///   - publicationDate: Publication date of the article (optional, unused in current
    ///     implementation but reserved for future late detection logic).
    /// - Returns: Compliance status indicating whether results are compliant, missing,
    ///   or unknown.
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
    /// Examines the title for common clinical trial indicators such as "randomized",
    /// "RCT", "phase II", "trial", etc.
    ///
    /// - Parameter title: Study title to analyze.
    /// - Returns: True if clinical trial indicators found, false otherwise.
    public static func appearsToBeClinicalTrial(title: String?) -> Bool {
        guard let title = title else { return false }

        let titleLower = title.lowercased()
        return ClinicalTrialPatterns.trialKeywords.contains { keyword in
            titleLower.contains(keyword)
        }
    }

    /// Extract NCT IDs from text.
    ///
    /// Searches for ClinicalTrials.gov registration identifiers in the format
    /// NCT followed by 8 digits (e.g., NCT01234567).
    ///
    /// - Parameter text: Text to search for NCT IDs.
    /// - Returns: Array of NCT IDs found, preserving original case.
    public static func extractNCTIds(from text: String) -> [String] {
        return RegexHelper.findAll(
            pattern: ClinicalTrialPatterns.nctIdPattern,
            in: text
        )
    }

    // MARK: - Industry Sponsor Detection

    /// Check if trial is industry-sponsored based on sponsor class.
    ///
    /// Uses the sponsor class field from ClinicalTrials.gov to determine
    /// if the trial is primarily sponsored by industry.
    ///
    /// - Parameter sponsorClass: Sponsor class from ClinicalTrials.gov
    ///   (e.g., "INDUSTRY", "NIH", "OTHER").
    /// - Returns: True if the sponsor class indicates industry sponsorship.
    public static func isIndustrySponsor(_ sponsorClass: String?) -> Bool {
        sponsorClass?.uppercased() == "INDUSTRY"
    }

    // MARK: - Outcome Analysis

    /// Check for potential outcome switching.
    ///
    /// Compares registered outcomes with reported outcomes using word overlap
    /// analysis to detect potential discrepancies between what was registered
    /// and what was reported.
    ///
    /// Note: This is a simplified check using word overlap. Full analysis
    /// would require NLP techniques for semantic similarity matching.
    ///
    /// - Parameters:
    ///   - registered: Registered primary outcomes from trial registry.
    ///   - reported: Reported outcomes extracted from publication.
    /// - Returns: Tuple of (detected, details) where detected is true if
    ///   potential outcome switching was found, and details contains
    ///   human-readable descriptions of discrepancies.
    public static func checkOutcomeSwitching(
        registered: [String],
        reported: [String]
    ) -> (detected: Bool, details: [String]) {
        // Skip if no registered outcomes to compare against
        guard !registered.isEmpty else {
            return (false, [])
        }

        // Skip if no reported outcomes to compare
        guard !reported.isEmpty else {
            return (false, ["Unable to compare - no reported outcomes extracted"])
        }

        var details: [String] = []

        // Simplified check: look for major mismatches using word overlap
        // A proper implementation would use NLP/fuzzy matching
        let registeredLower = Set(registered.map { $0.lowercased() })
        let reportedLower = Set(reported.map { $0.lowercased() })

        // Check if any registered outcomes are completely absent from reported
        for outcome in registeredLower {
            let found = reportedLower.contains { reported in
                // Simple word overlap check
                let outcomeWords = Set(outcome.components(separatedBy: .whitespaces)
                    .filter { !$0.isEmpty })
                let reportedWords = Set(reported.components(separatedBy: .whitespaces)
                    .filter { !$0.isEmpty })

                guard !outcomeWords.isEmpty else { return false }

                let overlap = outcomeWords.intersection(reportedWords)
                return Double(overlap.count) / Double(outcomeWords.count) > outcomeWordOverlapThreshold
            }

            if !found {
                // Truncate long outcome descriptions for display
                let truncatedOutcome = outcome.prefix(50)
                let suffix = outcome.count > 50 ? "..." : ""
                details.append("Registered outcome may not be reported: \(truncatedOutcome)\(suffix)")
            }
        }

        return (!details.isEmpty, details)
    }

    // MARK: - Summary

    /// Generate human-readable compliance summary.
    ///
    /// Creates a summary string describing the trial registration status
    /// and results compliance for display in the UI.
    ///
    /// - Parameters:
    ///   - registrations: Trial registrations found for the study.
    ///   - compliance: Results compliance status.
    /// - Returns: Summary string suitable for UI display.
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
    /// Checks if the study title suggests it's a clinical trial but no
    /// registration was found, which may indicate a transparency concern.
    ///
    /// - Parameters:
    ///   - title: Study title.
    ///   - registrations: Found trial registrations (empty if none found).
    /// - Returns: Warning message if applicable, nil otherwise.
    public static func checkMissingRegistration(
        title: String?,
        registrations: [TrialRegistration]
    ) -> String? {
        guard registrations.isEmpty,
              appearsToBeClinicalTrial(title: title) else {
            return nil
        }

        return "Clinical trial without detected registration"
    }
}
