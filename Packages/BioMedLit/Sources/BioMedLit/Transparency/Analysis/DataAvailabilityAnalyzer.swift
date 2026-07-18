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
    ///
    /// Key: case-insensitive regex pattern to search for, Value: human-readable
    /// name. Patterns are matched by `detectRepositoryName(in:)` via
    /// `RegexHelper.anyMatch`. The short tokens (geo/ena/sra/pdb) are
    /// word-anchored (`\bgeo\b` etc.) so an unrelated word cannot mislabel the
    /// repository (e.g. "geographic" resolving to "GEO" ahead of "GenBank").
    /// This mirrors the anchoring already applied to the classification patterns
    /// in `DataRepositoryPatterns.fullOpenPatterns` (issues #106/#107).
    private static let repositoryMappings: [(pattern: String, name: String)] = [
        ("zenodo", "Zenodo"),
        ("figshare", "Figshare"),
        ("dryad", "Dryad"),
        ("osf", "Open Science Framework"),
        ("github", "GitHub"),
        ("gitlab", "GitLab"),
        ("dataverse", "Dataverse"),
        ("gene expression omnibus", "Gene Expression Omnibus"),
        (#"\bgeo\b"#, "GEO"),
        ("arrayexpress", "ArrayExpress"),
        ("genbank", "GenBank"),
        (#"\bsra\b"#, "Sequence Read Archive"),
        ("vivli", "Vivli"),
        ("yoda", "YODA Project"),
        ("mendeley data", "Mendeley Data"),
        ("protein data bank", "Protein Data Bank"),
        (#"\bpdb\b"#, "PDB"),
        ("european nucleotide archive", "European Nucleotide Archive"),
        (#"\bena\b"#, "ENA"),
        ("clinicalstudydatarequest", "ClinicalStudyDataRequest.com"),
    ]

    // MARK: - Main Analysis

    /// Analyze a data availability statement.
    ///
    /// Uses the same priority-ordered tiers as the canonical Python reference
    /// (`analyze_data_availability`), so the same statement classifies
    /// identically on both platforms:
    /// 1. **Full open** — data in a public repository, *unless* the statement
    ///    also refuses access (a repository name alone does not prove open
    ///    access), in which case tier 2 takes precedence.
    /// 2. **Not available** — statements that read like a sharing policy but
    ///    amount to a refusal (locked to a collaboration, sponsor
    ///    confidentiality, "will not be released", proprietary, cannot be
    ///    shared, not publicly available).
    /// 3. **Restricted** — on-request/approval-gated access.
    /// 4. **Unknown** — a statement exists but no pattern matches.
    /// 5. **Not stated** — no statement found (empty/nil input).
    ///
    /// A repository mention combined with a *soft* restriction (e.g. "raw data
    /// available from the corresponding author upon request") is genuinely
    /// ambiguous and is deterministically kept as `.fullOpen`; optional
    /// LLM-assisted disambiguation of that case is tracked in issue #109.
    ///
    /// - Parameter statement: The data availability statement text.
    /// - Returns: DataAvailabilityResult with classification, repository info, and restrictions.
    public static func analyze(statement: String?) -> DataAvailabilityResult {
        guard let statement = statement, !statement.isEmpty else {
            return .notStated
        }

        let statementLower = statement.lowercased()

        // A repository *name* appearing in a statement does not by itself prove
        // open access: a statement may name a repository while denying access
        // ("genomic data could not be deposited in GEO for privacy reasons; the
        // data are not publicly available"). A refusal/unavailability signal
        // anywhere in the statement therefore takes precedence over a
        // co-occurring repository mention. Mirrors the Python reference
        // (``analyze_data_availability``).
        //
        // Invariant: every list joined here must also be reachable from Step 2
        // or Step 3. A pattern added here alone suppresses Step 1 without
        // supplying a replacement tier, so the statement silently lands in
        // `.unknown` instead of `.fullOpen` — a regression no existing test
        // would catch. `negatedOpennessPatterns` satisfies this by also being
        // appended to `restrictedPatterns` (issue #117).
        let hasUnavailabilitySignal = RegexHelper.anyMatch(
            patterns: DataRepositoryPatterns.effectivelyUnavailablePatterns
                + DataRepositoryPatterns.strongRefusalPatterns
                + DataRepositoryPatterns.negatedOpennessPatterns,
            in: statementLower
        )

        // --- Step 1: Full open access (highest priority, unless contradicted) ---
        if !hasUnavailabilitySignal,
           let fullOpenResult = checkFullOpenAccess(statement: statement, lowercased: statementLower) {
            return fullOpenResult
        }

        // --- Step 2: Effectively unavailable (refusals dressed as policy) ---
        let effectivelyUnavailableSignals = orderedRestrictionLabels(
            for: DataRepositoryPatterns.effectivelyUnavailablePatterns,
            in: statementLower
        )
        let strongRefusalFound = RegexHelper.anyMatch(
            patterns: DataRepositoryPatterns.strongRefusalPatterns,
            in: statementLower
        )

        if !effectivelyUnavailableSignals.isEmpty || strongRefusalFound {
            var restrictions = effectivelyUnavailableSignals
            for label in extractRestrictions(from: statementLower)
            where !restrictions.contains(label) {
                restrictions.append(label)
            }
            return DataAvailabilityResult(
                statement: statement,
                disclosureLevel: .notAvailable,
                restrictions: restrictions
            )
        }

        // --- Step 3: Restricted/on-request access ---
        let restrictions = extractRestrictions(from: statementLower)
        if !restrictions.isEmpty {
            return DataAvailabilityResult(
                statement: statement,
                disclosureLevel: .restricted,
                restrictions: restrictions
            )
        }

        // --- Step 4: Statement exists but unclear classification ---
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
    /// Scans for known repository name patterns (case-insensitive regex) and
    /// returns the human-readable name of the first match found. Short tokens
    /// are word-anchored in `repositoryMappings`, so an unrelated word cannot
    /// mislabel the repository.
    ///
    /// - Parameter text: Text to search (typically already lowercased).
    /// - Returns: Repository name if detected, nil otherwise.
    public static func detectRepositoryName(in text: String) -> String? {
        for (pattern, name) in repositoryMappings
        where RegexHelper.anyMatch(patterns: [pattern], in: text) {
            return name
        }
        return nil
    }

    /// Extract restriction descriptions from text.
    ///
    /// Identifies mentions of access restrictions such as IRB approval,
    /// data sharing agreements, confidentiality requirements, etc. Labels are
    /// produced in `restrictedPatterns` order with order-preserving dedup,
    /// mirroring the Python reference.
    ///
    /// - Parameter text: Lowercased statement text.
    /// - Returns: List of detected restrictions as human-readable descriptions.
    public static func extractRestrictions(from text: String) -> [String] {
        orderedRestrictionLabels(for: DataRepositoryPatterns.restrictedPatterns, in: text)
    }

    /// Resolve human-readable restriction labels for the patterns that match.
    ///
    /// Iterates the patterns in order and appends each pattern's mapped label
    /// (see `DataRepositoryPatterns.restrictionLabel(for:)`), skipping labels
    /// already present so the result is order-preserving and deduplicated.
    ///
    /// - Parameters:
    ///   - patterns: Restriction/refusal patterns to test, in priority order.
    ///   - text: Lowercased statement text.
    /// - Returns: Ordered, deduplicated restriction labels for matched patterns.
    private static func orderedRestrictionLabels(
        for patterns: [String],
        in text: String
    ) -> [String] {
        var labels: [String] = []
        for pattern in patterns
        where RegexHelper.anyMatch(patterns: [pattern], in: text) {
            let label = DataRepositoryPatterns.restrictionLabel(for: pattern)
            if !labels.contains(label) {
                labels.append(label)
            }
        }
        return labels
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
