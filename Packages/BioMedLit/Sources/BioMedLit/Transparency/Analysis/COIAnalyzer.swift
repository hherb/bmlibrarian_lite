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

/// Pure functions for analyzing conflict of interest statements.
///
/// All functions are stateless and can be safely called from any context.
/// This module detects industry ties, extracts disclosed relationships,
/// and validates consistency between funding and COI disclosures.
///
/// Usage:
/// ```swift
/// let result = COIAnalyzer.analyze(statement: coiText)
/// // Returns: COIAnalysisResult with industry ties detection
///
/// let warning = COIAnalyzer.checkFundingCOIDiscrepancy(
///     coiResult: result,
///     industryFundingDetected: true
/// )
/// // Returns warning message if discrepancy found
/// ```
public enum COIAnalyzer {

    // MARK: - Confidence Thresholds

    /// Confidence when explicit "no conflicts" declaration is found.
    private static let noConflictConfidence: Double = 0.9

    /// Base confidence when industry ties are detected.
    private static let industryTiesBaseConfidence: Double = 0.5

    /// Confidence increment per industry keyword match (capped).
    private static let industryMatchConfidenceIncrement: Double = 0.1

    /// Maximum confidence for industry ties detection.
    private static let maxIndustryConfidence: Double = 0.95

    /// Confidence when statement exists but classification is uncertain.
    private static let uncertainConfidence: Double = 0.5

    // MARK: - Main Analysis

    /// Analyze a conflict of interest statement for industry ties.
    ///
    /// Performs multi-stage analysis:
    /// 1. Checks for explicit "no conflicts" declarations
    /// 2. Counts industry-related keywords
    /// 3. Extracts specific disclosed relationships
    ///
    /// - Parameter statement: The COI statement text (nil if not available).
    /// - Returns: COIAnalysisResult with analysis details including industry ties
    ///   detection, confidence score, and extracted relationships.
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
                confidence: noConflictConfidence
            )
        }

        // Check for industry-related keywords
        let industryMatchCount = countIndustryMatches(in: statementLower)
        let hasIndustryTies = industryMatchCount > 0

        // Calculate confidence based on match strength
        let confidence: Double
        if hasIndustryTies {
            confidence = min(
                industryTiesBaseConfidence + Double(industryMatchCount) * industryMatchConfidenceIncrement,
                maxIndustryConfidence
            )
        } else {
            confidence = uncertainConfidence // Uncertain - no clear indication either way
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
    /// Uses predefined patterns to identify common ways authors declare
    /// they have no conflicts of interest.
    ///
    /// - Parameter text: Lowercased statement text.
    /// - Returns: True if no-conflict declaration found.
    public static func containsNoConflictDeclaration(_ text: String) -> Bool {
        RegexHelper.anyMatch(patterns: COIPatterns.noConflictPatterns, in: text)
    }

    /// Count industry-related keyword matches in text.
    ///
    /// Counts occurrences of industry indicators like pharmaceutical company
    /// names, corporate suffixes, and relationship terms (consultant, grants, etc.).
    ///
    /// - Parameter text: Lowercased text to analyze.
    /// - Returns: Number of industry keyword matches.
    public static func countIndustryMatches(in text: String) -> Int {
        RegexHelper.countMatches(patterns: IndustryPatterns.industryKeywords, in: text)
    }

    /// Extract disclosed relationships from COI statement.
    ///
    /// Uses patterns to identify and extract specific relationship mentions
    /// such as "received grants from [company]" or "consultant for [company]".
    ///
    /// - Parameter text: Lowercased statement text.
    /// - Returns: Array of extracted relationship descriptions, deduplicated.
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
    /// Returns a warning if industry funding is detected but the COI statement
    /// doesn't mention industry ties, which could indicate incomplete disclosure.
    ///
    /// - Parameters:
    ///   - coiResult: COI analysis result.
    ///   - industryFundingDetected: Whether industry funding was detected from
    ///     funding analysis.
    /// - Returns: Warning message if discrepancy found, nil otherwise.
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

    /// Check if COI statement indicates potential concerns.
    ///
    /// Returns true if the statement mentions multiple industry relationships
    /// or significant financial ties that warrant closer scrutiny.
    ///
    /// - Parameter result: COI analysis result.
    /// - Returns: True if significant industry ties are disclosed.
    public static func hasSignificantIndustryTies(_ result: COIAnalysisResult) -> Bool {
        // Significant if multiple relationships disclosed or high confidence
        result.hasIndustryTies && (result.disclosedRelationships.count > 1 || result.confidence >= 0.8)
    }

    // MARK: - Summary

    /// Generate a human-readable summary of COI analysis.
    ///
    /// - Parameter result: COI analysis result.
    /// - Returns: Summary string for display in UI.
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

    /// Format a detailed description of disclosed relationships.
    ///
    /// - Parameter relationships: List of relationship descriptions.
    /// - Returns: Formatted string listing all relationships.
    public static func formatRelationships(_ relationships: [String]) -> String {
        guard !relationships.isEmpty else {
            return "None disclosed"
        }

        if relationships.count == 1 {
            return relationships[0].capitalized
        }

        return relationships.map { $0.capitalized }.joined(separator: "; ")
    }
}
