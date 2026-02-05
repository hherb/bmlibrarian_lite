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

/// Pure functions for analyzing study funding sources.
///
/// All functions are stateless and can be safely called from any context.
/// This module provides classification of funders as industry or non-industry,
/// determination of overall sponsor types, and parsing of funder data from
/// various sources (CrossRef, PubMed).
///
/// Usage:
/// ```swift
/// let classification = FundingAnalyzer.classifyFunder(name: "Pfizer Inc.", doi: "10.13039/100004319")
/// // Returns: (isIndustry: true, confidence: 1.0)
///
/// let sponsorType = FundingAnalyzer.determineSponsorType(from: funders)
/// // Returns: .industry, .government, .academic, .mixed, or .unknown
/// ```
public enum FundingAnalyzer {

    // MARK: - Confidence Thresholds

    /// Confidence level for known industry funder DOI matches.
    private static let knownFunderConfidence: Double = 1.0

    /// Confidence level for government pattern matches.
    private static let governmentPatternConfidence: Double = 0.85

    /// Confidence level for academic pattern matches.
    private static let academicPatternConfidence: Double = 0.80

    /// Confidence level for corporate suffix matches.
    private static let corporateSuffixConfidence: Double = 0.75

    /// Confidence level for industry keyword matches.
    private static let industryKeywordConfidence: Double = 0.70

    /// Default confidence level when classification is uncertain.
    private static let unknownConfidence: Double = 0.30

    /// Number of primary industry keywords to check before falling back to broader patterns.
    private static let primaryIndustryKeywordCount: Int = 6

    // MARK: - Funder Classification

    /// Classify a single funder as industry or non-industry.
    ///
    /// Uses a multi-layer approach to determine if a funder is an industry entity:
    /// 1. Check known industry funder DOIs (highest confidence)
    /// 2. Check government/academic name patterns (takes precedence over corporate indicators)
    /// 3. Check corporate name indicators (legal entity suffixes)
    /// 4. Check broader industry keywords
    ///
    /// - Parameters:
    ///   - name: Funder name (required).
    ///   - doi: CrossRef Funder Registry DOI (optional, e.g., "10.13039/100004319").
    /// - Returns: Tuple of (isIndustry, confidence 0.0-1.0) where confidence indicates
    ///   reliability of the classification.
    public static func classifyFunder(name: String, doi: String? = nil) -> (isIndustry: Bool, confidence: Double) {
        // Layer 1: Check known industry funder DOIs (highest confidence)
        if let doi = doi, KnownIndustryFunders.isIndustryFunder(doi) {
            return (true, knownFunderConfidence)
        }

        let nameLower = name.lowercased()

        // Layer 2: Check government/academic patterns first
        // These take precedence even if corporate suffixes are present
        if RegexHelper.anyMatch(patterns: IndustryPatterns.governmentPatterns, in: nameLower) {
            return (false, governmentPatternConfidence)
        }

        if RegexHelper.anyMatch(patterns: IndustryPatterns.academicPatterns, in: nameLower) {
            return (false, academicPatternConfidence)
        }

        // Layer 3: Check corporate indicators
        if RegexHelper.anyMatch(patterns: IndustryPatterns.corporateSuffixes, in: nameLower) {
            return (true, corporateSuffixConfidence)
        }

        // Layer 4: Check broader industry keywords (first few are more specific)
        let primaryPatterns = Array(IndustryPatterns.industryKeywords.prefix(primaryIndustryKeywordCount))
        if RegexHelper.anyMatch(patterns: primaryPatterns, in: nameLower) {
            return (true, industryKeywordConfidence)
        }

        // Unknown - low confidence
        return (false, unknownConfidence)
    }

    /// Create a FunderInfo from raw funder data.
    ///
    /// Combines the funder classification with the provided metadata to create
    /// a complete FunderInfo object suitable for use in transparency analysis.
    ///
    /// - Parameters:
    ///   - name: Funder name (required).
    ///   - doi: CrossRef Funder Registry DOI (optional).
    ///   - awardNumbers: Grant/award numbers associated with this funder.
    /// - Returns: FunderInfo with industry classification populated.
    public static func createFunderInfo(
        name: String,
        doi: String? = nil,
        awardNumbers: [String] = []
    ) -> FunderInfo {
        let (isIndustry, confidence) = classifyFunder(name: name, doi: doi)
        return FunderInfo(
            name: name,
            funderDOI: doi,
            awardNumbers: awardNumbers,
            isIndustry: isIndustry,
            confidence: confidence
        )
    }

    // MARK: - Sponsor Type Determination

    /// Determine overall sponsor type from list of funders.
    ///
    /// Analyzes the collection of funders to determine the primary sponsor type:
    /// - `.industry` if only industry funders are present
    /// - `.mixed` if both industry and non-industry funders are present
    /// - `.government` if only government funders are present (no industry)
    /// - `.academic` if only academic funders are present (no industry, no government)
    /// - `.nonprofit` if non-industry funders don't match government/academic patterns
    /// - `.unknown` if no funders are provided
    ///
    /// - Parameter funders: List of analyzed funders.
    /// - Returns: Overall sponsor type classification.
    public static func determineSponsorType(from funders: [FunderInfo]) -> SponsorType {
        guard !funders.isEmpty else {
            return .unknown
        }

        let industryFunders = funders.filter { $0.isIndustry }
        let nonIndustryFunders = funders.filter { !$0.isIndustry }

        // Pure industry funding
        if !industryFunders.isEmpty && nonIndustryFunders.isEmpty {
            return .industry
        }

        // Mixed funding
        if !industryFunders.isEmpty && !nonIndustryFunders.isEmpty {
            return .mixed
        }

        // No industry funding - check if government or academic
        let hasGovernment = nonIndustryFunders.contains { funder in
            RegexHelper.anyMatch(
                patterns: IndustryPatterns.governmentPatterns,
                in: funder.name.lowercased()
            )
        }

        if hasGovernment {
            return .government
        }

        let hasAcademic = nonIndustryFunders.contains { funder in
            RegexHelper.anyMatch(
                patterns: IndustryPatterns.academicPatterns,
                in: funder.name.lowercased()
            )
        }

        return hasAcademic ? .academic : .nonprofit
    }

    /// Determine industry funding status from funders.
    ///
    /// Returns whether any industry funding was detected and the maximum
    /// confidence level among industry funders.
    ///
    /// - Parameter funders: List of analyzed funders.
    /// - Returns: Tuple of (detected, maxConfidence) where detected is true
    ///   if any industry funder was found.
    public static func industryFundingStatus(from funders: [FunderInfo]) -> (detected: Bool, confidence: Double) {
        let industryFunders = funders.filter { $0.isIndustry }

        guard !industryFunders.isEmpty else {
            return (false, 0.0)
        }

        let maxConfidence = industryFunders.map(\.confidence).max() ?? 0.0
        return (true, maxConfidence)
    }

    // MARK: - CrossRef Data Parsing

    /// Parse funders from CrossRef work response.
    ///
    /// Extracts funder information from the CrossRef API "funder" array,
    /// creating classified FunderInfo objects for each entry.
    ///
    /// Expected dictionary structure:
    /// ```json
    /// {
    ///   "name": "Pfizer Inc.",
    ///   "DOI": "10.13039/100004319",
    ///   "award": ["R01-123456"]
    /// }
    /// ```
    ///
    /// - Parameter crossRefFunders: Array of funder dictionaries from CrossRef API.
    /// - Returns: List of FunderInfo objects with classifications.
    public static func parseCrossRefFunders(_ crossRefFunders: [[String: Any]]?) -> [FunderInfo] {
        guard let crossRefFunders = crossRefFunders else { return [] }

        return crossRefFunders.compactMap { funderDict -> FunderInfo? in
            guard let name = funderDict["name"] as? String else { return nil }

            let doi = funderDict["DOI"] as? String
            let awards = funderDict["award"] as? [String] ?? []

            return createFunderInfo(name: name, doi: doi, awardNumbers: awards)
        }
    }

    /// Parse funders from PubMed grant data.
    ///
    /// Extracts funder information from PubMed's grant list format,
    /// creating classified FunderInfo objects for each entry.
    ///
    /// Expected dictionary structure:
    /// ```json
    /// {
    ///   "agency": "National Institutes of Health",
    ///   "grant_id": "R01-CA123456"
    /// }
    /// ```
    ///
    /// - Parameter grants: Array of grant dictionaries from PubMed.
    /// - Returns: List of FunderInfo objects with classifications.
    public static func parsePubMedGrants(_ grants: [[String: String?]]?) -> [FunderInfo] {
        guard let grants = grants else { return [] }

        return grants.compactMap { grant -> FunderInfo? in
            // Unwrap the double optional: grant["agency"] returns String??
            guard let agencyOpt = grant["agency"],
                  let agency = agencyOpt,
                  !agency.isEmpty else {
                return nil
            }

            // Similarly unwrap grant_id (optional value from optional key)
            let grantId: String? = grant["grant_id"].flatMap { $0 }
            let awardNumbers = grantId.map { [$0] } ?? []

            return createFunderInfo(name: agency, awardNumbers: awardNumbers)
        }
    }

    // MARK: - Funder Deduplication

    /// Merge funders from multiple sources, removing duplicates.
    ///
    /// Funders are considered duplicates if their names match (case-insensitive).
    /// When duplicates are found, the one with higher confidence is kept,
    /// ensuring the most reliable classification is retained.
    ///
    /// - Parameter funderLists: Variable number of funder arrays from different sources.
    /// - Returns: Deduplicated list of funders with highest confidence retained.
    public static func mergeFunders(_ funderLists: [FunderInfo]...) -> [FunderInfo] {
        var fundersByName: [String: FunderInfo] = [:]

        for list in funderLists {
            for funder in list {
                let key = funder.name.lowercased()

                if let existing = fundersByName[key] {
                    // Keep the one with higher confidence
                    if funder.confidence > existing.confidence {
                        fundersByName[key] = funder
                    }
                } else {
                    fundersByName[key] = funder
                }
            }
        }

        return Array(fundersByName.values)
    }

    // MARK: - Trial Sponsor Analysis

    /// Update sponsor type based on clinical trial sponsor class.
    ///
    /// Incorporates sponsor information from ClinicalTrials.gov to refine
    /// the sponsor type classification. If the trial indicates industry
    /// sponsorship but the current type doesn't, upgrades to mixed funding.
    ///
    /// - Parameters:
    ///   - currentType: Current sponsor type based on funding analysis.
    ///   - trialSponsorClass: Sponsor class from ClinicalTrials.gov
    ///     (e.g., "INDUSTRY", "NIH", "OTHER").
    /// - Returns: Updated sponsor type that incorporates trial sponsor information.
    public static func updateSponsorType(
        _ currentType: SponsorType,
        withTrialSponsorClass trialSponsorClass: String?
    ) -> SponsorType {
        guard let sponsorClass = trialSponsorClass?.uppercased() else {
            return currentType
        }

        let isTrialIndustry = sponsorClass == "INDUSTRY"

        switch currentType {
        case .unknown:
            return isTrialIndustry ? .industry : currentType
        case .government, .academic, .nonprofit:
            return isTrialIndustry ? .mixed : currentType
        case .industry, .mixed:
            return currentType
        }
    }

    // MARK: - Summary

    /// Generate a human-readable summary of funding analysis.
    ///
    /// - Parameters:
    ///   - funders: List of analyzed funders.
    ///   - sponsorType: Overall sponsor type classification.
    /// - Returns: Summary string suitable for display in UI.
    public static func formatSummary(funders: [FunderInfo], sponsorType: SponsorType) -> String {
        guard !funders.isEmpty else {
            return "No funding information available"
        }

        let industryCount = funders.filter { $0.isIndustry }.count
        let totalCount = funders.count

        switch sponsorType {
        case .industry:
            return "Industry-funded (\(industryCount) funder\(industryCount == 1 ? "" : "s"))"
        case .mixed:
            return "Mixed funding (\(industryCount) industry, \(totalCount - industryCount) non-industry)"
        case .government:
            return "Government-funded (\(totalCount) funder\(totalCount == 1 ? "" : "s"))"
        case .academic:
            return "Academic-funded (\(totalCount) funder\(totalCount == 1 ? "" : "s"))"
        case .nonprofit:
            return "Non-profit funded (\(totalCount) funder\(totalCount == 1 ? "" : "s"))"
        case .unknown:
            return "Funding source unknown"
        }
    }
}
