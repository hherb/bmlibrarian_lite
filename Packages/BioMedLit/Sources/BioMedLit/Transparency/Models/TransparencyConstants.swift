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

    /// Seconds per day (24 * 60 * 60) for time interval calculations.
    public static let secondsPerDay: TimeInterval = 86_400

    // MARK: - Score Adjustments

    // These values mirror the canonical Python reference
    // (`calculate_transparency_score` in
    // `src/bmlibrarian_lite/study_transparency_analyzer/study_transparency_analyzer.py`)
    // so identical inputs produce identical scores on both platforms.

    /// Points awarded for full open data access.
    public static let fullOpenDataPoints: Int = 20

    /// Points awarded for data available on request.
    public static let onRequestDataPoints: Int = 5

    /// Penalty for data available only with significant restrictions.
    public static let restrictedDataPenalty: Int = -5

    /// Penalty for data explicitly not available.
    public static let noDataPenalty: Int = -15

    /// Penalty for missing data availability statement.
    public static let noStatementPenalty: Int = -5

    /// Points awarded for having a COI statement.
    public static let coiStatementPoints: Int = 5

    /// Additional penalty when a COI statement discloses industry ties.
    ///
    /// Disclosure is credited (`coiStatementPoints`), but the underlying
    /// situation still carries bias risk, so disclosed industry ties reduce
    /// the score. Matches Python's `-5` after the `+5` disclosure credit.
    public static let coiIndustryTiesPenalty: Int = -5

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

    /// Penalty for industry ties combined with restricted/unavailable data.
    ///
    /// Applies when industry funding is detected *or* the COI statement
    /// discloses industry ties, and the data is restricted or not available.
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

    /// Maximum characters for outcome description display before truncating.
    public static let maxOutcomeDescriptionLength: Int = 50

    // MARK: - Registry Names

    /// ClinicalTrials.gov registry display name.
    public static let clinicalTrialsRegistryName = "ClinicalTrials.gov"

    // MARK: - Date Parsing Defaults

    /// Default month value when parsing dates with only year.
    public static let defaultMonth: Int = 1

    /// Default day value when parsing dates without day.
    public static let defaultDay: Int = 1
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

    /// Patterns for industry funding routed through institutional intermediaries.
    ///
    /// Detects the common disclosure pattern where industry money flows to a
    /// university/institution rather than directly to the author, often phrased
    /// as "funding to the University of X (but no personal funding) from [pharma]".
    /// Mirrors Python's `INSTITUTIONAL_INTERMEDIARY_PATTERNS`.
    public static let institutionalIntermediaryPatterns: [String] = [
        #"(?:funding|grants?|support|contracts?)\s+(?:to|paid to)\s+(?:the\s+)?(?:university|institution|hospital)"#,
        #"(?:but\s+)?no personal (?:funding|payment|honorari)"#,
        #"(?:grants?|contracts?|funding)\s+(?:or\s+\w+\s+)?(?:to|paid to)\s+(?:his|her|their)\s+institution"#,
        #"(?:research\s+)?grant\s+support\s+through\b"#,
        #"salary\s+support\s+from\b"#,
    ]
}

// MARK: - Data Repository Patterns

/// Patterns for data availability analysis.
///
/// These patterns identify data repositories, access restrictions, and
/// extract repository URLs and accession numbers from data availability
/// statements. The pattern lists and restriction labels are ported verbatim
/// from the canonical Python reference (`DATA_REPOSITORIES` and the
/// `_restriction_labels` map in
/// `src/bmlibrarian_lite/study_transparency_analyzer/study_transparency_analyzer.py`)
/// so a given statement classifies identically on both platforms.
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
        #"\bgeo\b"#,
        "arrayexpress",
        "protein data bank",
        #"\bpdb\b"#,
        "genbank",
        #"\bsra\b"#,
        "european nucleotide archive",
        #"\bena\b"#,
        "clinicalstudydatarequest",
        "vivli",
        "yoda",
    ]

    /// Restricted/on-request access indicators.
    ///
    /// A statement matching any of these (and none of the stronger refusal
    /// signals) classifies as `.restricted`. The order is significant: it
    /// determines the order of the human-readable restriction labels.
    public static let restrictedPatterns: [String] = [
        #"upon (?:reasonable )?request"#,
        #"available from (?:the )?(?:corresponding )?author"#,
        #"contact (?:the )?(?:corresponding )?author"#,
        "data sharing agreement",
        "institutional review board",
        "irb approval",
        "ethics committee",
        #"confidential(?:ity)?"#,
        "proprietary",
        "cannot be shared",
        #"not (?:publicly )?available"#,
        #"(?:would|will|shall) not be (?:released|shared|disclosed|provided)"#,
        "not be released to others",
        #"requests?\s+(?:for\s+)?(?:such\s+)?data\s+should\s+be\s+made\s+(?:directly\s+)?to"#,
        #"on the understanding that\b.*\bnot\b"#,
        #"used only for the purpose of\b"#,
        #"agreements?\s+(?:with\s+)?(?:the\s+)?sponsors?\s+prevent"#,
        #"confidentiality\s+agreements?\s+(?:with\s+)?sponsors?"#,
        #"data\s+custodians?\b"#,
    ]

    /// Strong-refusal indicators that escalate a statement to `.notAvailable`.
    ///
    /// These are sharing statements that amount to a refusal (proprietary,
    /// cannot be shared, sponsor confidentiality, etc.). A subset of
    /// `restrictedPatterns`, mirroring Python's `strong_refusal_patterns`.
    public static let strongRefusalPatterns: [String] = [
        "cannot be shared",
        #"not (?:publicly )?available"#,
        "proprietary",
        #"(?:would|will|shall) not be (?:released|shared|disclosed|provided)"#,
        "not be released to others",
        #"agreements?\s+(?:with\s+)?(?:the\s+)?sponsors?\s+prevent"#,
        #"confidentiality\s+agreements?\s+(?:with\s+)?sponsors?"#,
    ]

    /// Patterns indicating an effectively unavailable dataset.
    ///
    /// The sharing statement reads like a policy but access is systematically
    /// denied (locked to a named collaboration, sponsor-gated, custodian-held).
    /// Mirrors Python's `DATA_REPOSITORIES['effectively_unavailable']`.
    public static let effectivelyUnavailablePatterns: [String] = [
        #"(?:provided|available)\s+to\s+the\s+\w+\s+(?:collaboration|consortium|group)\s+on\s+the\s+understanding"#,
        #"not be released.*(?:data custodians?|directly to)"#,
        #"(?:confidentiality|agreement)\s+(?:with\s+)?(?:the\s+)?(?:sponsor|industri|pharma|trial\s+(?:owner|sponsor))"#,
    ]

    /// Human-readable labels for restriction/refusal patterns.
    ///
    /// Keyed by the exact pattern string, mirroring Python's
    /// `_restriction_labels`. Patterns absent from this map fall back to the
    /// pattern text itself (see `restrictionLabel(for:)`).
    public static let restrictionLabels: [String: String] = [
        "cannot be shared": "Data cannot be shared",
        #"not (?:publicly )?available"#: "Data not publicly available",
        "proprietary": "Data described as proprietary",
        #"(?:would|will|shall) not be (?:released|shared|disclosed|provided)"#:
            "Data will not be released",
        "not be released to others": "Data will not be released to others",
        #"agreements?\s+(?:with\s+)?(?:the\s+)?sponsors?\s+prevent"#:
            "Sponsor agreements prevent disclosure",
        #"confidentiality\s+agreements?\s+(?:with\s+)?sponsors?"#:
            "Confidentiality agreements with sponsors",
        #"upon (?:reasonable )?request"#: "Available upon request",
        #"available from (?:the )?(?:corresponding )?author"#: "Available from author",
        #"contact (?:the )?(?:corresponding )?author"#: "Contact corresponding author",
        "data sharing agreement": "Requires data sharing agreement",
        "institutional review board": "Requires IRB approval",
        "irb approval": "Requires IRB approval",
        "ethics committee": "Requires ethics committee approval",
        #"confidential(?:ity)?"#: "Confidentiality restrictions",
        #"requests?\s+(?:for\s+)?(?:such\s+)?data\s+should\s+be\s+made\s+(?:directly\s+)?to"#:
            "Data requests redirected to third party",
        #"on the understanding that\b.*\bnot\b"#:
            "Data provided under restrictive understanding",
        #"used only for the purpose of\b"#: "Data restricted to specific purpose",
        #"data\s+custodians?\b"#: "Data held by custodians (not authors)",
        #"(?:provided|available)\s+to\s+the\s+\w+\s+(?:collaboration|consortium|group)\s+on\s+the\s+understanding"#:
            "Data restricted to named collaboration",
        #"not be released.*(?:data custodians?|directly to)"#:
            "Data will not be released; requests redirected",
        #"(?:confidentiality|agreement)\s+(?:with\s+)?(?:the\s+)?(?:sponsor|industri|pharma|trial\s+(?:owner|sponsor))"#:
            "Sponsor confidentiality agreement restricts access",
    ]

    /// Resolve the human-readable label for a restriction pattern.
    ///
    /// - Parameter pattern: The restriction/refusal regex pattern.
    /// - Returns: The mapped label, or the pattern text itself if unmapped.
    public static func restrictionLabel(for pattern: String) -> String {
        restrictionLabels[pattern] ?? pattern
    }

    /// Pattern for extracting URLs from text.
    public static let urlPattern = #"https?://[^\s<>\"']+"#

    /// Pattern for extracting accession numbers (e.g., "accession: GSE12345").
    /// Uses case-insensitive character class since extraction functions lowercase input.
    public static let accessionPattern = #"(?:accession|identifier)[:\s]+([a-zA-Z0-9]+)"#
}

// MARK: - Risk Indicator Strings

/// Canonical risk-of-bias indicator strings shown in the UI.
///
/// These must stay byte-identical to the Python reference implementation
/// (`RISK_INDICATOR_*` constants in
/// `src/bmlibrarian_lite/study_transparency_analyzer/study_transparency_analyzer.py`);
/// cross-platform tests pin the literals.
public enum RiskIndicatorStrings {

    /// Industry funding was detected.
    public static let industryFunding = "Industry funding detected"

    /// Industry funding combined with restricted/unavailable data.
    public static let industryRestrictedData =
        "Industry-funded with restricted data access"

    /// Trial results were due but not posted to ClinicalTrials.gov.
    public static let resultsNotPosted =
        "Trial results not posted to ClinicalTrials.gov"

    /// Authors disclosed industry financial ties in the COI statement.
    public static let industryTiesDisclosed =
        "Authors have disclosed industry financial ties"

    /// Industry funding was routed through an institutional intermediary.
    public static let institutionalIntermediary =
        "Industry funding routed through institutional intermediaries"

    /// No conflict of interest statement was found.
    public static let missingCoiStatement =
        "No conflict of interest statement found"

    /// A sharing statement exists but the data is effectively unavailable.
    public static let dataEffectivelyUnavailable =
        "Data effectively unavailable despite sharing statement"

    /// Data access is restricted (e.g. request/approval required).
    public static let dataAccessRestricted = "Data access restricted"

    /// Reported outcomes deviate from registered outcomes.
    public static let outcomeSwitching = "Outcome switching detected"

    /// Industry ties combined with restricted or unavailable data.
    public static let combinedIndustryData =
        "Industry ties combined with restricted/unavailable data"

    /// The study appears to be a clinical trial but no registration was found.
    public static let missingTrialRegistration =
        "Clinical trial without detected registration"
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
    /// Matches format: NCT followed by exactly 8 digits (e.g., NCT01234567).
    /// Lookarounds reject IDs embedded in longer tokens, such as
    /// `NCT1234567890` (too many digits) or `SOMENCT12345678`.
    public static let nctIdPattern = #"(?<![A-Za-z0-9])NCT\d{8}(?!\d)"#

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
