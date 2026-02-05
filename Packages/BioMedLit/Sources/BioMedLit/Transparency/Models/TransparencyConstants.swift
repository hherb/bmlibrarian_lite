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

/// Constants for transparency analysis.
///
/// Contains API URLs, rate limits, scoring thresholds, and UI configuration
/// values used throughout the transparency analysis module.
public enum TransparencyConstants {

    // MARK: - API URLs

    /// CrossRef API base URL for funder and DOI metadata lookups.
    public static let crossRefBaseURL = "https://api.crossref.org"

    /// ClinicalTrials.gov API v2 base URL for trial registration data.
    public static let clinicalTrialsBaseURL = "https://clinicaltrials.gov/api/v2"

    /// OpenAlex API base URL for open access metadata.
    public static let openAlexBaseURL = "https://api.openalex.org"

    // MARK: - Rate Limits

    /// CrossRef polite rate limit (requests per second).
    /// CrossRef allows higher rates for polite users who provide email in User-Agent.
    public static let crossRefRateLimit: Double = 10.0

    /// ClinicalTrials.gov rate limit (requests per second).
    public static let clinicalTrialsRateLimit: Double = 5.0

    /// Minimum interval between requests in seconds.
    public static let minimumRequestInterval: TimeInterval = 0.2

    // MARK: - Scoring Thresholds

    /// Base transparency score before adjustments.
    public static let baseTransparencyScore: Int = 50

    /// Score threshold for high risk classification (score < this = high risk).
    public static let highRiskScoreThreshold: Int = 40

    /// Score threshold for medium risk classification (score < this = medium risk).
    public static let mediumRiskScoreThreshold: Int = 70

    /// FDAAA compliance deadline in days (12 months after primary completion).
    public static let resultsComplianceDeadlineDays: Int = 365

    // MARK: - Score Adjustments

    /// Points awarded for full open data access.
    public static let fullOpenDataPoints: Int = 20

    /// Points awarded for data available on request.
    public static let onRequestDataPoints: Int = 10

    /// Penalty for data explicitly not available.
    public static let noDataPenalty: Int = -10

    /// Penalty for missing data availability statement.
    public static let noStatementPenalty: Int = -5

    /// Points awarded for having a COI statement.
    public static let coiStatementPoints: Int = 10

    /// Penalty for missing COI statement.
    public static let missingCoiPenalty: Int = -5

    /// Points awarded for trial registration.
    public static let trialRegistrationPoints: Int = 10

    /// Points awarded for compliant results posting.
    public static let compliantResultsPoints: Int = 5

    /// Penalty for missing trial results.
    public static let missingResultsPenalty: Int = -10

    /// Penalty for detected outcome switching.
    public static let outcomeSwitchingPenalty: Int = -15

    /// Penalty for industry funding with no data sharing.
    public static let industryNoDataPenalty: Int = -10

    // MARK: - Score Category Thresholds

    /// Score threshold for "good transparency" category (score >= this).
    public static let goodTransparencyThreshold: Int = 76

    /// Score threshold for "average transparency" category (score >= this).
    public static let averageTransparencyThreshold: Int = 51

    /// Score threshold for "below average transparency" category (score >= this).
    public static let belowAverageTransparencyThreshold: Int = 26

    // MARK: - Score Range

    /// Minimum valid transparency score.
    public static let minTransparencyScore: Int = 0

    /// Maximum valid transparency score.
    public static let maxTransparencyScore: Int = 100

    // MARK: - UI Limits

    /// Maximum risk indicators to show in tooltip before truncating.
    public static let maxRiskIndicatorsInTooltip: Int = 5
}

// MARK: - Known Industry Funders

/// Known industry funder DOIs from CrossRef Funder Registry.
///
/// This registry maps CrossRef Funder Registry DOIs to company names for
/// major pharmaceutical, biotechnology, and medical device companies.
public enum KnownIndustryFunders {

    /// CrossRef Funder Registry DOIs for major pharmaceutical companies.
    /// Key: Funder DOI, Value: Company name.
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
    ///
    /// - Parameter doi: The CrossRef Funder Registry DOI to check.
    /// - Returns: True if the DOI matches a known industry funder.
    public static func isIndustryFunder(_ doi: String?) -> Bool {
        guard let doi = doi else { return false }
        return funderDOIs[doi] != nil
    }

    /// Get company name for a funder DOI.
    ///
    /// - Parameter doi: The CrossRef Funder Registry DOI.
    /// - Returns: The company name if found, nil otherwise.
    public static func companyName(for doi: String) -> String? {
        funderDOIs[doi]
    }
}

// MARK: - Pattern Matching

/// Regex patterns for industry detection in text.
///
/// These patterns are used to identify industry affiliations in funding
/// statements, author affiliations, and conflict of interest declarations.
public enum IndustryPatterns {

    /// Keywords indicating industry affiliation in text.
    /// All patterns are case-insensitive raw strings for regex matching.
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

    /// Corporate name suffixes for identifying company names.
    /// Subset of industryKeywords focused on legal entity suffixes.
    public static let corporateSuffixes: [String] = [
        #"\binc\.?\b"#,
        #"\bcorp(?:oration)?\.?\b"#,
        #"\bltd\.?\b"#,
        #"\bgmbh\b"#,
        #"\bplc\b"#,
    ]

    /// Known government/public funder patterns.
    /// Used to classify funding as non-industry (government) source.
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
    /// Used to classify funding as non-industry (academic) source.
    public static let academicPatterns: [String] = [
        #"\buniversit(?:y|ies)\b"#,
        #"\bcollege\b"#,
        #"\bhospital\b"#,
        #"\bmedical (?:center|school)\b"#,
        #"\bgovernment\b"#,
        #"\bfederal\b"#,
        #"\bstate\b"#,
    ]

    /// Combined government and academic patterns for non-industry matching.
    public static let nonIndustryPatterns: [String] = governmentPatterns + academicPatterns
}

// MARK: - COI Patterns

/// Regex patterns for conflict of interest analysis.
///
/// These patterns identify COI statements and extract disclosed relationships
/// from article text.
public enum COIPatterns {

    /// Patterns indicating no conflicts declared.
    /// Match these to classify a COI statement as "no conflicts."
    public static let noConflictPatterns: [String] = [
        #"no (?:potential )?conflict"#,
        #"nothing to (?:disclose|declare)"#,
        #"no (?:competing|financial) interest"#,
        #"no relationship"#,
        #"none (?:declared|to declare)"#,
    ]

    /// Patterns for extracting disclosed relationships.
    /// The first capture group contains the entity name(s).
    public static let relationshipPatterns: [String] = [
        #"(?:received|reports?|has|have) (?:grants?|funding|honoraria|fees?|payments?) from ([^.;]+)"#,
        #"(?:consultant|advisory board|speaker) for ([^.;]+)"#,
        #"employee of ([^.;]+)"#,
        #"(?:stock|shares?|equity) in ([^.;]+)"#,
    ]
}

// MARK: - Data Repository Patterns

/// Patterns for data availability analysis.
///
/// These patterns identify data repositories, access restrictions, and
/// extract repository URLs and accession numbers from data availability statements.
public enum DataRepositoryPatterns {

    /// Full open access repository indicators.
    /// Presence of these terms suggests data is openly available.
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
    /// Presence of these terms suggests data requires request or approval.
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
    /// Presence of these terms suggests data is not available.
    public static let unavailablePatterns: [String] = [
        "proprietary",
        "cannot be shared",
        #"not (?:publicly )?available"#,
    ]

    /// Pattern for extracting URLs from text.
    public static let urlPattern = #"https?://[^\s<>\"']+"#

    /// Pattern for extracting accession numbers (e.g., "accession: GSE12345").
    /// Uses case-insensitive character class since extraction functions lowercase input.
    public static let accessionPattern = #"(?:accession|identifier)[:\s]+([a-zA-Z0-9]+)"#
}

// MARK: - Clinical Trial Patterns

/// Patterns for clinical trial detection.
///
/// Used to identify whether an article describes a clinical trial and to
/// extract trial registration identifiers.
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

    /// NCT ID pattern for ClinicalTrials.gov registration numbers.
    /// Matches format: NCT followed by 8 digits (e.g., NCT01234567).
    public static let nctIdPattern = #"NCT\d{8}"#

    /// Registry names that indicate trial registration.
    /// Used to identify which registry a trial is registered with.
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

/// Helper for creating NSRegularExpression instances and performing pattern matching.
///
/// Provides convenience methods for common regex operations used in transparency
/// analysis, including case-insensitive matching and capture group extraction.
public enum RegexHelper {

    /// Create a case-insensitive regex from a pattern string.
    ///
    /// - Parameter pattern: The regex pattern string.
    /// - Returns: An NSRegularExpression instance, or nil if the pattern is invalid.
    public static func regex(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }

    /// Check if any pattern in the array matches the text.
    ///
    /// - Parameters:
    ///   - patterns: Array of regex pattern strings to try.
    ///   - text: The text to search in.
    /// - Returns: True if any pattern matches.
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
    ///
    /// - Parameters:
    ///   - patterns: Array of regex pattern strings to count.
    ///   - text: The text to search in.
    /// - Returns: Total number of matches across all patterns.
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

    /// Extract first capture group from the first pattern match.
    ///
    /// - Parameters:
    ///   - pattern: Regex pattern with at least one capture group.
    ///   - text: The text to search in.
    /// - Returns: The captured string, or nil if no match.
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

    /// Extract all first capture groups from all pattern matches.
    ///
    /// - Parameters:
    ///   - pattern: Regex pattern with at least one capture group.
    ///   - text: The text to search in.
    /// - Returns: Array of captured strings from all matches.
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

    /// Extract all matches of a pattern (full match, no capture groups).
    ///
    /// Unlike `extractFirst` and `extractAll`, this method preserves the original
    /// case of matched text. This is intentional for extracting URLs, NCT IDs,
    /// and other identifiers where case matters.
    ///
    /// - Parameters:
    ///   - pattern: Regex pattern to match (case-insensitive).
    ///   - text: The text to search in.
    /// - Returns: Array of matched strings with original case preserved.
    public static func findAll(pattern: String, in text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)

        guard let regex = regex(pattern) else { return [] }

        return regex.matches(in: text, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: text) else {
                return nil
            }
            return String(text[matchRange])
        }
    }
}
