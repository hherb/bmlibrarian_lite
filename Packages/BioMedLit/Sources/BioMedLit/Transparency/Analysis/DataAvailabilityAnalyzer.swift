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

/// Pure functions for analyzing data availability statements.
///
/// All functions are stateless and can be safely called from any context.
/// This module classifies data disclosure levels, extracts repository information,
/// and identifies access restrictions mentioned in data availability statements.
///
/// Usage:
/// ```swift
/// let result = DataAvailabilityAnalyzer.analyze(statement: dataText)
/// // Returns: DataAvailabilityResult with disclosure level
///
/// let summary = DataAvailabilityAnalyzer.formatSummary(result)
/// // Returns: "Data available in Zenodo"
/// ```
public enum DataAvailabilityAnalyzer {

    // MARK: - Repository Mappings

    /// Repository name mappings for detection.
    /// Key: pattern to search for (lowercase), Value: human-readable name.
    private static let repositoryMappings: [(pattern: String, name: String)] = [
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
        ("mendeley data", "Mendeley Data"),
        ("protein data bank", "Protein Data Bank"),
        ("pdb", "PDB"),
        ("european nucleotide archive", "European Nucleotide Archive"),
        ("ena", "ENA"),
        ("clinicalstudydatarequest", "ClinicalStudyDataRequest.com"),
    ]

    /// Restriction pattern mappings.
    /// Key: pattern to search for (lowercase), Value: human-readable description.
    private static let restrictionMappings: [(pattern: String, description: String)] = [
        ("upon reasonable request", "Available upon reasonable request"),
        ("upon request", "Available upon request"),
        ("data sharing agreement", "Requires data sharing agreement"),
        ("institutional review board", "IRB approval required"),
        ("irb approval", "IRB approval required"),
        ("ethics committee", "Ethics committee approval required"),
        ("confidential", "Confidentiality restrictions"),
        ("proprietary", "Proprietary data"),
        ("privacy", "Privacy restrictions"),
        ("patient consent", "Patient consent required"),
        ("gdpr", "GDPR restrictions"),
        ("hipaa", "HIPAA restrictions"),
    ]

    // MARK: - Main Analysis

    /// Analyze a data availability statement.
    ///
    /// Classification hierarchy (checked in order):
    /// 1. Full open - data in public repository
    /// 2. Not available - explicitly unavailable
    /// 3. Available on request - can be obtained from authors
    /// 4. Unknown - statement exists but classification unclear
    /// 5. Not stated - no statement found
    ///
    /// - Parameter statement: The data availability statement text.
    /// - Returns: DataAvailabilityResult with classification, repository info, and restrictions.
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
    /// Scans the statement for known public repository names and attempts
    /// to extract URLs and accession numbers when present.
    ///
    /// - Parameters:
    ///   - statement: Original statement text (for URL/accession extraction).
    ///   - lowercased: Lowercased version for pattern matching.
    /// - Returns: DataAvailabilityResult if open access detected, nil otherwise.
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
    /// - Parameter text: Lowercased statement text.
    /// - Returns: True if data is explicitly unavailable.
    public static func containsUnavailabilityIndicators(_ text: String) -> Bool {
        RegexHelper.anyMatch(patterns: DataRepositoryPatterns.unavailablePatterns, in: text)
    }

    /// Check if statement contains restricted access indicators.
    ///
    /// - Parameter text: Lowercased statement text.
    /// - Returns: True if restricted access is indicated.
    public static func containsRestrictedAccessIndicators(_ text: String) -> Bool {
        RegexHelper.anyMatch(patterns: DataRepositoryPatterns.restrictedPatterns, in: text)
    }

    // MARK: - Extraction Functions

    /// Extract URL from text.
    ///
    /// Searches for HTTP/HTTPS URLs in the text and returns the first match.
    ///
    /// - Parameter text: Text to search.
    /// - Returns: First URL found, or nil if none present.
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
    /// Searches for patterns like "accession: GSE12345" or "identifier: SRR12345678"
    /// and extracts the identifier.
    ///
    /// - Parameter text: Text to search.
    /// - Returns: Accession number if found, nil otherwise.
    public static func extractAccessionNumber(from text: String) -> String? {
        RegexHelper.extractFirst(pattern: DataRepositoryPatterns.accessionPattern, from: text)
    }

    /// Detect repository name from text.
    ///
    /// Scans for known repository name patterns and returns the human-readable
    /// name of the first match found.
    ///
    /// - Parameter text: Lowercased text to search.
    /// - Returns: Repository name if detected, nil otherwise.
    public static func detectRepositoryName(in text: String) -> String? {
        for (pattern, name) in repositoryMappings {
            if text.contains(pattern) {
                return name
            }
        }
        return nil
    }

    /// Extract restriction descriptions from text.
    ///
    /// Identifies mentions of access restrictions such as IRB approval,
    /// data sharing agreements, confidentiality requirements, etc.
    ///
    /// - Parameter text: Lowercased statement text.
    /// - Returns: List of detected restrictions as human-readable descriptions.
    public static func extractRestrictions(from text: String) -> [String] {
        var restrictions: [String] = []

        for (pattern, description) in restrictionMappings {
            if text.contains(pattern) || RegexHelper.anyMatch(patterns: [pattern], in: text) {
                restrictions.append(description)
            }
        }

        // Deduplicate (some patterns may produce the same description)
        return Array(Set(restrictions))
    }

    // MARK: - Validation

    /// Check if data availability is adequate for a clinical trial.
    ///
    /// Clinical trials generally require higher transparency standards.
    /// Returns a warning if data is not openly available.
    ///
    /// - Parameters:
    ///   - result: Data availability analysis result.
    ///   - isClinicalTrial: Whether the article describes a clinical trial.
    /// - Returns: Warning message if data availability is inadequate, nil otherwise.
    public static func checkClinicalTrialDataAvailability(
        result: DataAvailabilityResult,
        isClinicalTrial: Bool
    ) -> String? {
        guard isClinicalTrial else { return nil }

        switch result.disclosureLevel {
        case .notAvailable:
            return "Clinical trial data is not available"
        case .notStated:
            return "Clinical trial has no data availability statement"
        case .availableOnRequest:
            return "Clinical trial data only available on request (not openly accessible)"
        case .restricted:
            return "Clinical trial data has access restrictions"
        case .fullOpen, .unknown:
            return nil
        }
    }

    // MARK: - Summary

    /// Generate a human-readable summary of data availability.
    ///
    /// - Parameter result: Data availability analysis result.
    /// - Returns: Summary string for display in UI.
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
            if let firstRestriction = result.restrictions.first {
                return "Data access restricted: \(firstRestriction)"
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

    /// Format detailed data availability information.
    ///
    /// Includes repository name, URL, accession number, and restrictions
    /// when available.
    ///
    /// - Parameter result: Data availability analysis result.
    /// - Returns: Multi-line detailed description.
    public static func formatDetailedInfo(_ result: DataAvailabilityResult) -> String {
        var lines: [String] = []

        lines.append("Status: \(result.disclosureLevel.displayName)")

        if let repo = result.repositoryName {
            lines.append("Repository: \(repo)")
        }

        if let url = result.repositoryURL {
            lines.append("URL: \(url.absoluteString)")
        }

        if let accession = result.accessionNumber {
            lines.append("Accession: \(accession)")
        }

        if !result.restrictions.isEmpty {
            lines.append("Restrictions: \(result.restrictions.joined(separator: ", "))")
        }

        return lines.joined(separator: "\n")
    }
}
