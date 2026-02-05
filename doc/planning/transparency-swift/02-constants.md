# Step 02: Constants & Pattern Definitions

## Goal

Define constants for industry funder registry, keyword patterns, and data repository indicators.

## File to Create

### `Sources/BioMedLit/Transparency/Models/TransparencyConstants.swift`

```swift
// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2025 Dr Horst Herb
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Constants for transparency analysis.
public enum TransparencyConstants {

    // MARK: - API URLs

    /// CrossRef API base URL.
    public static let crossRefBaseURL = "https://api.crossref.org"

    /// ClinicalTrials.gov API v2 base URL.
    public static let clinicalTrialsBaseURL = "https://clinicaltrials.gov/api/v2"

    /// OpenAlex API base URL.
    public static let openAlexBaseURL = "https://api.openalex.org"

    // MARK: - Rate Limits

    /// CrossRef polite rate limit (requests per second).
    public static let crossRefRateLimit: Double = 10.0

    /// ClinicalTrials.gov rate limit (requests per second).
    public static let clinicalTrialsRateLimit: Double = 5.0

    /// Minimum interval between requests in seconds.
    public static let minimumRequestInterval: TimeInterval = 0.2

    // MARK: - Scoring Thresholds

    /// Base transparency score.
    public static let baseTransparencyScore: Int = 50

    /// Score threshold for high risk classification.
    public static let highRiskScoreThreshold: Int = 40

    /// Score threshold for medium risk classification.
    public static let mediumRiskScoreThreshold: Int = 70

    /// FDAAA compliance deadline in days (12 months).
    public static let resultsComplianceDeadlineDays: Int = 365

    // MARK: - Score Adjustments

    /// Points for full open data access.
    public static let fullOpenDataPoints: Int = 20

    /// Points for data available on request.
    public static let onRequestDataPoints: Int = 10

    /// Penalty for data not available.
    public static let noDataPenalty: Int = -10

    /// Penalty for no data statement.
    public static let noStatementPenalty: Int = -5

    /// Points for having COI statement.
    public static let coiStatementPoints: Int = 10

    /// Penalty for missing COI statement.
    public static let missingCoiPenalty: Int = -5

    /// Points for trial registration.
    public static let trialRegistrationPoints: Int = 10

    /// Points for compliant results posting.
    public static let compliantResultsPoints: Int = 5

    /// Penalty for missing trial results.
    public static let missingResultsPenalty: Int = -10

    /// Penalty for outcome switching.
    public static let outcomeSwitchingPenalty: Int = -15

    /// Penalty for industry funding without data sharing.
    public static let industryNoDataPenalty: Int = -10
}

// MARK: - Known Industry Funders

/// Known industry funder DOIs from CrossRef Funder Registry.
public enum KnownIndustryFunders {

    /// CrossRef Funder Registry DOIs for major pharmaceutical companies.
    /// Key: Funder DOI, Value: Company name
    public static let funderDOIs: [String: String] = [
        "10.13039/100004319": "Pfizer",
        "10.13039/100004325": "AstraZeneca",
        "10.13039/100004326": "Bayer",
        "10.13039/100004328": "GlaxoSmithKline",
        "10.13039/100004330": "Johnson & Johnson",
        "10.13039/100004331": "Eli Lilly",
        "10.13039/100004334": "Merck",
        "10.13039/100004336": "Novartis",
        "10.13039/100004337": "Novo Nordisk",
        "10.13039/100004339": "Roche",
        "10.13039/100004341": "Sanofi",
        "10.13039/100005564": "Gilead Sciences",
        "10.13039/100006483": "AbbVie",
        "10.13039/100006436": "Celgene",
        "10.13039/100006928": "Amgen",
        "10.13039/100007054": "Bristol-Myers Squibb",
        "10.13039/100008272": "Biogen",
        "10.13039/100008897": "Boehringer Ingelheim",
        "10.13039/100009947": "Takeda",
        "10.13039/100010877": "UCB",
        "10.13039/100014476": "Regeneron",
        "10.13039/100004344": "Teva",
        "10.13039/100007723": "Allergan",
        "10.13039/100004374": "Medtronic",
        "10.13039/100004375": "Boston Scientific",
        "10.13039/100007497": "Abbott",
    ]

    /// Check if a funder DOI is a known industry funder.
    public static func isIndustryFunder(_ doi: String?) -> Bool {
        guard let doi = doi else { return false }
        return funderDOIs[doi] != nil
    }

    /// Get company name for a funder DOI.
    public static func companyName(for doi: String) -> String? {
        funderDOIs[doi]
    }
}

// MARK: - Pattern Matching

/// Regex patterns for industry detection.
public enum IndustryPatterns {

    /// Keywords indicating industry affiliation in text.
    public static let industryKeywords: [String] = [
        #"\bpharma(?:ceutical)?\b"#,
        #"\bbiotech(?:nology)?\b"#,
        #"\bmedical device\b"#,
        #"\bdrug compan(?:y|ies)\b"#,
        #"\bmanufacturer\b"#,
        #"\binc\.?\b"#,
        #"\bcorp(?:oration)?\.?\b"#,
        #"\bltd\.?\b"#,
        #"\bgmbh\b"#,
        #"\bplc\b"#,
        #"\bemployee of\b"#,
        #"\bstock(?:holder)?\b"#,
        #"\bshareholder\b"#,
        #"\bconsultant for\b"#,
        #"\badvisory board\b"#,
        #"\bspeaker(?:'s)? (?:bureau|fee)\b"#,
        #"\bhonorari(?:a|um)\b"#,
        #"\bgrant(?:s)? from\b"#,
    ]

    /// Corporate name suffixes (subset of industryKeywords for name matching).
    public static let corporateSuffixes: [String] = [
        #"\binc\.?\b"#,
        #"\bcorp(?:oration)?\.?\b"#,
        #"\bltd\.?\b"#,
        #"\bgmbh\b"#,
        #"\bplc\b"#,
    ]

    /// Known government/academic funder patterns.
    public static let governmentPatterns: [String] = [
        #"\bnih\b"#,
        #"\bnational institutes? of health\b"#,
        #"\bniaid\b"#,
        #"\bnci\b"#,
        #"\bnhlbi\b"#,
        #"\bnimh\b"#,
        #"\bnsf\b"#,
        #"\bnational science foundation\b"#,
        #"\bcdc\b"#,
        #"\bcenters? for disease control\b"#,
        #"\bfda\b"#,
        #"\bfood and drug administration\b"#,
        #"\bva\b"#,
        #"\bveterans? (?:affairs|administration)\b"#,
        #"\bahrq\b"#,
        #"\bpcori\b"#,
        #"\bwellcome\b"#,
        #"\bmedical research council\b"#,
    ]

    /// Academic/institutional patterns.
    public static let academicPatterns: [String] = [
        #"\buniversit(?:y|ies)\b"#,
        #"\bcollege\b"#,
        #"\bhospital\b"#,
        #"\bmedical (?:center|school)\b"#,
        #"\bgovernment\b"#,
        #"\bfederal\b"#,
        #"\bstate\b"#,
    ]

    /// Compile all government and academic patterns for matching.
    public static let nonIndustryPatterns: [String] = governmentPatterns + academicPatterns
}

// MARK: - COI Patterns

/// Regex patterns for conflict of interest analysis.
public enum COIPatterns {

    /// Patterns indicating no conflicts declared.
    public static let noConflictPatterns: [String] = [
        #"no (?:potential )?conflict"#,
        #"nothing to (?:disclose|declare)"#,
        #"no (?:competing|financial) interest"#,
        #"no relationship"#,
        #"none (?:declared|to declare)"#,
    ]

    /// Patterns for extracting disclosed relationships.
    public static let relationshipPatterns: [String] = [
        #"(?:received|reports?|has|have) (?:grants?|funding|honoraria|fees?|payments?) from ([^.;]+)"#,
        #"(?:consultant|advisory board|speaker) for ([^.;]+)"#,
        #"employee of ([^.;]+)"#,
        #"(?:stock|shares?|equity) in ([^.;]+)"#,
    ]
}

// MARK: - Data Repository Patterns

/// Patterns for data availability analysis.
public enum DataRepositoryPatterns {

    /// Full open access repository indicators.
    public static let fullOpenPatterns: [String] = [
        "zenodo",
        "figshare",
        "dryad",
        #"osf\.io"#,
        "open science framework",
        "github",
        "gitlab",
        "dataverse",
        "mendeley data",
        "gene expression omnibus",
        "geo",
        "arrayexpress",
        "protein data bank",
        "pdb",
        "genbank",
        "sra",
        "european nucleotide archive",
        "ena",
        "clinicalstudydatarequest",
        "vivli",
        "yoda",
    ]

    /// Restricted/request-only access indicators.
    public static let restrictedPatterns: [String] = [
        #"upon (?:reasonable )?request"#,
        #"available from (?:the )?(?:corresponding )?author"#,
        #"contact (?:the )?(?:corresponding )?author"#,
        "data sharing agreement",
        "institutional review board",
        "irb approval",
        "ethics committee",
        #"confidential(?:ity)?"#,
    ]

    /// Explicit data unavailability indicators.
    public static let unavailablePatterns: [String] = [
        "proprietary",
        "cannot be shared",
        #"not (?:publicly )?available"#,
    ]

    /// Pattern for extracting URLs from text.
    public static let urlPattern = #"https?://[^\s<>\"']+"#

    /// Pattern for extracting accession numbers.
    public static let accessionPattern = #"(?:accession|identifier)[:\s]+([A-Z0-9]+)"#
}

// MARK: - Clinical Trial Patterns

/// Patterns for clinical trial detection.
public enum ClinicalTrialPatterns {

    /// Keywords suggesting the study is a clinical trial.
    public static let trialKeywords: [String] = [
        "trial",
        "randomized",
        "randomised",
        "rct",
        "phase i",
        "phase ii",
        "phase iii",
        "phase iv",
    ]

    /// NCT ID pattern for ClinicalTrials.gov.
    public static let nctIdPattern = #"NCT\d{8}"#

    /// Registry names that indicate trial registration.
    public static let registryNames: Set<String> = [
        "ClinicalTrials.gov",
        "ISRCTN",
        "EudraCT",
        "ACTRN",
        "ChiCTR",
        "CTRI",
        "DRKS",
        "IRCT",
        "JPRN",
        "NTR",
        "PACTR",
        "REBEC",
        "RPCEC",
        "SLCTR",
        "TCTR",
    ]
}

// MARK: - Regex Helper

/// Helper for creating NSRegularExpression instances.
public enum RegexHelper {

    /// Create a case-insensitive regex from a pattern string.
    public static func regex(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }

    /// Check if any pattern in the array matches the text.
    public static func anyMatch(patterns: [String], in text: String) -> Bool {
        let lowercased = text.lowercased()
        let range = NSRange(lowercased.startIndex..., in: lowercased)

        for pattern in patterns {
            if let regex = regex(pattern),
               regex.firstMatch(in: lowercased, range: range) != nil {
                return true
            }
        }
        return false
    }

    /// Count matches across all patterns in the array.
    public static func countMatches(patterns: [String], in text: String) -> Int {
        let lowercased = text.lowercased()
        let range = NSRange(lowercased.startIndex..., in: lowercased)
        var count = 0

        for pattern in patterns {
            if let regex = regex(pattern) {
                count += regex.numberOfMatches(in: lowercased, range: range)
            }
        }
        return count
    }

    /// Extract first capture group from pattern match.
    public static func extractFirst(pattern: String, from text: String) -> String? {
        let lowercased = text.lowercased()
        let range = NSRange(lowercased.startIndex..., in: lowercased)

        guard let regex = regex(pattern),
              let match = regex.firstMatch(in: lowercased, range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: lowercased) else {
            return nil
        }

        return String(lowercased[captureRange])
    }

    /// Extract all capture groups from pattern matches.
    public static func extractAll(pattern: String, from text: String) -> [String] {
        let lowercased = text.lowercased()
        let range = NSRange(lowercased.startIndex..., in: lowercased)

        guard let regex = regex(pattern) else { return [] }

        return regex.matches(in: lowercased, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let captureRange = Range(match.range(at: 1), in: lowercased) else {
                return nil
            }
            return String(lowercased[captureRange])
        }
    }
}
```

## Testing

```swift
import XCTest
@testable import BioMedLit

final class TransparencyConstantsTests: XCTestCase {

    func testKnownIndustryFunderLookup() {
        XCTAssertTrue(KnownIndustryFunders.isIndustryFunder("10.13039/100004319"))
        XCTAssertFalse(KnownIndustryFunders.isIndustryFunder("10.13039/unknown"))
        XCTAssertFalse(KnownIndustryFunders.isIndustryFunder(nil))
    }

    func testKnownIndustryFunderName() {
        XCTAssertEqual(KnownIndustryFunders.companyName(for: "10.13039/100004319"), "Pfizer")
        XCTAssertNil(KnownIndustryFunders.companyName(for: "unknown"))
    }

    func testRegexHelperAnyMatch() {
        let patterns = IndustryPatterns.industryKeywords
        XCTAssertTrue(RegexHelper.anyMatch(patterns: patterns, in: "Funded by Pfizer Inc."))
        XCTAssertTrue(RegexHelper.anyMatch(patterns: patterns, in: "Pharmaceutical company support"))
        XCTAssertFalse(RegexHelper.anyMatch(patterns: patterns, in: "NIH grant support"))
    }

    func testRegexHelperGovernmentMatch() {
        let patterns = IndustryPatterns.governmentPatterns
        XCTAssertTrue(RegexHelper.anyMatch(patterns: patterns, in: "Funded by NIH grant"))
        XCTAssertTrue(RegexHelper.anyMatch(patterns: patterns, in: "National Institutes of Health"))
        XCTAssertFalse(RegexHelper.anyMatch(patterns: patterns, in: "Pfizer Inc."))
    }

    func testNoConflictPatternMatching() {
        let patterns = COIPatterns.noConflictPatterns
        XCTAssertTrue(RegexHelper.anyMatch(patterns: patterns, in: "The authors declare no conflict of interest"))
        XCTAssertTrue(RegexHelper.anyMatch(patterns: patterns, in: "Nothing to disclose"))
        XCTAssertFalse(RegexHelper.anyMatch(patterns: patterns, in: "Author received grants from Pfizer"))
    }

    func testDataRepositoryDetection() {
        let patterns = DataRepositoryPatterns.fullOpenPatterns
        XCTAssertTrue(RegexHelper.anyMatch(patterns: patterns, in: "Data available at https://zenodo.org/123"))
        XCTAssertTrue(RegexHelper.anyMatch(patterns: patterns, in: "Deposited in Gene Expression Omnibus"))
        XCTAssertFalse(RegexHelper.anyMatch(patterns: patterns, in: "Available upon request"))
    }

    func testRelationshipExtraction() {
        let text = "Author received grants from Pfizer and honoraria from Novartis."
        let patterns = COIPatterns.relationshipPatterns
        var relationships: [String] = []

        for pattern in patterns {
            relationships.append(contentsOf: RegexHelper.extractAll(pattern: pattern, from: text))
        }

        XCTAssertFalse(relationships.isEmpty)
    }
}
```

## Dependencies

None - uses only Foundation.

## Notes

- All patterns are raw strings (`#"..."#`) to avoid escaping backslashes
- `RegexHelper` provides safe, reusable pattern matching functions
- Constants are organized by category (scoring, API, patterns)
- Pattern lists can be extended without code changes
