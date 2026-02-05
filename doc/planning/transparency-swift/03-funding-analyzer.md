# Step 03: Funding Analyzer

## Goal

Create pure functions for analyzing funding sources and detecting industry sponsorship.

## File to Create

### `Sources/BioMedLit/Transparency/Analysis/FundingAnalyzer.swift`

```swift
// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2025 Dr Horst Herb
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Pure functions for analyzing study funding sources.
///
/// All functions are stateless and can be safely called from any context.
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

    // MARK: - Funder Classification

    /// Classify a single funder as industry or non-industry.
    ///
    /// Uses a multi-layer approach:
    /// 1. Check known industry funder DOIs (highest confidence)
    /// 2. Check government/academic name patterns
    /// 3. Check corporate name indicators
    ///
    /// - Parameters:
    ///   - name: Funder name
    ///   - doi: CrossRef Funder Registry DOI (optional)
    /// - Returns: Tuple of (isIndustry, confidence 0.0-1.0)
    public static func classifyFunder(name: String, doi: String? = nil) -> (isIndustry: Bool, confidence: Double) {
        // Layer 1: Check known industry funder DOIs (highest confidence)
        if let doi = doi, KnownIndustryFunders.isIndustryFunder(doi) {
            return (true, 1.0)
        }

        let nameLower = name.lowercased()

        // Layer 2: Check government/academic patterns first
        // These take precedence even if corporate suffixes are present
        if RegexHelper.anyMatch(patterns: IndustryPatterns.governmentPatterns, in: nameLower) {
            return (false, 0.85)
        }

        if RegexHelper.anyMatch(patterns: IndustryPatterns.academicPatterns, in: nameLower) {
            return (false, 0.80)
        }

        // Layer 3: Check corporate indicators
        if RegexHelper.anyMatch(patterns: IndustryPatterns.corporateSuffixes, in: nameLower) {
            return (true, 0.75)
        }

        // Layer 4: Check broader industry keywords
        if RegexHelper.anyMatch(patterns: Array(IndustryPatterns.industryKeywords.prefix(6)), in: nameLower) {
            return (true, 0.70)
        }

        // Unknown - low confidence
        return (false, 0.30)
    }

    /// Create a FunderInfo from raw funder data.
    ///
    /// - Parameters:
    ///   - name: Funder name
    ///   - doi: CrossRef Funder Registry DOI (optional)
    ///   - awardNumbers: Grant/award numbers
    /// - Returns: FunderInfo with industry classification
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
    /// - Parameter funders: List of analyzed funders
    /// - Returns: Overall sponsor type classification
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
    /// - Parameter funders: List of analyzed funders
    /// - Returns: Tuple of (detected, maxConfidence)
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
    /// - Parameter crossRefFunders: Array of funder dictionaries from CrossRef API
    /// - Returns: List of FunderInfo objects
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
    /// - Parameter grants: Array of grant dictionaries from PubMed
    /// - Returns: List of FunderInfo objects
    public static func parsePubMedGrants(_ grants: [[String: String?]]?) -> [FunderInfo] {
        guard let grants = grants else { return [] }

        return grants.compactMap { grant -> FunderInfo? in
            guard let agency = grant["agency"] as? String, !agency.isEmpty else { return nil }

            let grantId = grant["grant_id"] as? String
            let awardNumbers = grantId.map { [$0] } ?? []

            return createFunderInfo(name: agency, awardNumbers: awardNumbers)
        }
    }

    // MARK: - Funder Deduplication

    /// Merge funders from multiple sources, removing duplicates.
    ///
    /// Funders are considered duplicates if their names match (case-insensitive).
    /// When duplicates are found, the one with higher confidence is kept.
    ///
    /// - Parameter funderLists: Variable number of funder arrays
    /// - Returns: Deduplicated list of funders
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
    /// - Parameters:
    ///   - currentType: Current sponsor type
    ///   - trialSponsorClass: Sponsor class from ClinicalTrials.gov (e.g., "INDUSTRY", "NIH")
    /// - Returns: Updated sponsor type
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
}
```

## Testing

```swift
import XCTest
@testable import BioMedLit

final class FundingAnalyzerTests: XCTestCase {

    // MARK: - Funder Classification Tests

    func testClassifyKnownIndustryFunderByDOI() {
        let (isIndustry, confidence) = FundingAnalyzer.classifyFunder(
            name: "Pfizer",
            doi: "10.13039/100004319"
        )
        XCTAssertTrue(isIndustry)
        XCTAssertEqual(confidence, 1.0)
    }

    func testClassifyGovernmentFunder() {
        let (isIndustry, confidence) = FundingAnalyzer.classifyFunder(
            name: "National Institutes of Health"
        )
        XCTAssertFalse(isIndustry)
        XCTAssertGreaterThan(confidence, 0.8)
    }

    func testClassifyAcademicFunder() {
        let (isIndustry, confidence) = FundingAnalyzer.classifyFunder(
            name: "Harvard University"
        )
        XCTAssertFalse(isIndustry)
        XCTAssertGreaterThan(confidence, 0.7)
    }

    func testClassifyCorporateBySuffix() {
        let (isIndustry, confidence) = FundingAnalyzer.classifyFunder(
            name: "Unknown Biotech Inc."
        )
        XCTAssertTrue(isIndustry)
        XCTAssertGreaterThan(confidence, 0.6)
    }

    func testClassifyUnknownFunder() {
        let (isIndustry, confidence) = FundingAnalyzer.classifyFunder(
            name: "Some Foundation"
        )
        XCTAssertFalse(isIndustry)
        XCTAssertLessThan(confidence, 0.5)
    }

    // MARK: - Sponsor Type Tests

    func testDetermineSponsorTypeIndustryOnly() {
        let funders = [
            FunderInfo(name: "Pfizer", isIndustry: true, confidence: 1.0),
            FunderInfo(name: "Novartis", isIndustry: true, confidence: 1.0),
        ]
        XCTAssertEqual(FundingAnalyzer.determineSponsorType(from: funders), .industry)
    }

    func testDetermineSponsorTypeMixed() {
        let funders = [
            FunderInfo(name: "Pfizer", isIndustry: true, confidence: 1.0),
            FunderInfo(name: "NIH", isIndustry: false, confidence: 0.9),
        ]
        XCTAssertEqual(FundingAnalyzer.determineSponsorType(from: funders), .mixed)
    }

    func testDetermineSponsorTypeGovernment() {
        let funders = [
            FunderInfo(name: "National Institutes of Health", isIndustry: false, confidence: 0.9),
        ]
        XCTAssertEqual(FundingAnalyzer.determineSponsorType(from: funders), .government)
    }

    func testDetermineSponsorTypeEmpty() {
        XCTAssertEqual(FundingAnalyzer.determineSponsorType(from: []), .unknown)
    }

    // MARK: - Industry Funding Status Tests

    func testIndustryFundingStatusDetected() {
        let funders = [
            FunderInfo(name: "NIH", isIndustry: false, confidence: 0.9),
            FunderInfo(name: "Pfizer", isIndustry: true, confidence: 1.0),
        ]
        let (detected, confidence) = FundingAnalyzer.industryFundingStatus(from: funders)
        XCTAssertTrue(detected)
        XCTAssertEqual(confidence, 1.0)
    }

    func testIndustryFundingStatusNotDetected() {
        let funders = [
            FunderInfo(name: "NIH", isIndustry: false, confidence: 0.9),
        ]
        let (detected, confidence) = FundingAnalyzer.industryFundingStatus(from: funders)
        XCTAssertFalse(detected)
        XCTAssertEqual(confidence, 0.0)
    }

    // MARK: - Merge Tests

    func testMergeFundersRemovesDuplicates() {
        let list1 = [FunderInfo(name: "Pfizer", isIndustry: true, confidence: 0.7)]
        let list2 = [FunderInfo(name: "pfizer", isIndustry: true, confidence: 1.0)]

        let merged = FundingAnalyzer.mergeFunders(list1, list2)

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.confidence, 1.0) // Kept higher confidence
    }

    // MARK: - Trial Sponsor Update Tests

    func testUpdateSponsorTypeFromIndustryTrial() {
        let updated = FundingAnalyzer.updateSponsorType(.government, withTrialSponsorClass: "INDUSTRY")
        XCTAssertEqual(updated, .mixed)
    }

    func testUpdateSponsorTypeNoChange() {
        let updated = FundingAnalyzer.updateSponsorType(.industry, withTrialSponsorClass: "INDUSTRY")
        XCTAssertEqual(updated, .industry)
    }
}
```

## Dependencies

- `TransparencyModels.swift` (Step 01)
- `TransparencyConstants.swift` (Step 02)

## Notes

- All functions are pure (no side effects)
- `enum` namespace prevents instantiation
- Functions handle nil inputs gracefully
- Confidence scores indicate reliability of classification
