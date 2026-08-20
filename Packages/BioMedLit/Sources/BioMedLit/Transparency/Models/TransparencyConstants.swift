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

    // MARK: - Analyzer Version

    /// Version of the transparency analyzer that produced a stored result.
    ///
    /// Stamped onto every ``TransparencyResult`` at build time, so a result
    /// computed under an earlier version can be recognised as stale and offered
    /// for re-analysis instead of being shown beside a current one as if the two
    /// numbers were comparable.
    ///
    /// **Bump this whenever a change moves stored scores**, and only ever upward:
    /// ``TransparencyResult/isStale`` compares with `<` so that a newer result
    /// arriving by CloudKit sync is not mistaken for an older one. History:
    /// - `1` — the original scoring model (implicit; stored results from this era
    ///   carry no version at all and decode as `nil`).
    /// - `2` — Europe PMC free-PDF availability allow-list (bmlib #79); JATS
    ///   caption routing, unsectioned-`<body>` prose (bmlib #30) and unsectioned
    ///   `<back>` prose, which is where acknowledgements and competing-interest
    ///   statements live; `<sub-article>` peer-review correspondence excluded
    ///   from the body; `<contrib-group>` author reading; `<table-wrap-foot>`
    ///   footnotes captured instead of dropped; and the funder patterns
    ///   recalibrated against the shared labelled corpus (bmlib #36). Each
    ///   changes which evidence reaches the scorer.
    public static let analyzerVersion = 2


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

    /// Keywords indicating industry affiliation in **COI prose**.
    ///
    /// Matched against a paper's conflict-of-interest / disclosure statement in
    /// the full text — running text, not an org name. Deliberately kept separate
    /// from ``funderNameStems`` / ``funderNameWords``: the generic corporate
    /// suffixes match far too freely in running text, while the disclosure
    /// phrases below never occur in a funder name.
    ///
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

    // MARK: - Funder Name Matching
    //
    // Matched against structured funder names — CrossRef `funder[].name` and
    // PubMed `<Grant><Agency>` — both short org-name strings.
    //
    // THE TWO LISTS ARE DIFFERENT KINDS OF THING, AND MERGING THEM IS A BUG.
    // A stem has to match *inside* a longer word ("pharmaceutic" reaching
    // "Pharmaceuticals"); a whole word must not ("inc" as a substring matches
    // "Lincoln", "Vincent" and "province").
    //
    // Membership of both lists was decided by measuring against 816 unique real
    // names sampled from CrossRef (431) and PubMed (402) — the two sources
    // overlap — 417 of them hand-labelled: the shared
    // corpus at `doc/cross_platform/transparency_parity/funder_names.json`
    // (bmlib issue #36). The counts below are from that corpus.

    /// Substring stems for funder names — matched *inside* a longer word.
    ///
    /// Every one scored at least one true positive, and each is narrower than
    /// what it replaced:
    /// - `pharmaceutic` — 3 TP / 1 FP. Replaces `\bpharma(?:ceutical)?\b`, which
    ///   could not match the standard company-name plural "X Pharmaceuticals"
    ///   because the word boundary lands before the "s"; as a bare substring
    ///   "pharma" instead scored 3 TP / 5 FP by reaching "Pharmacy",
    ///   "Pharmacology" and "Pharmacogenetics", all academic. The one false
    ///   positive it does keep — "National Inheritance Studio of Veteran
    ///   Pharmaceutical Workers of Zhong Lingyun" — is the entire reason overall
    ///   precision is 0.909 rather than 1.0, so it is worth knowing about rather
    ///   than filed under "no false positives".
    /// - `therapeutics` — 1 TP / 0 FP.
    /// - `laboratories` — 1 TP / 0 FP. The plural only: "Key Laboratory"
    ///   (singular) is a Chinese state-lab form, twice in the labelled corpus and
    ///   common in the unlabelled remainder, and it must keep missing them.
    public static let funderNameStems: [String] = [
        "pharmaceutic",
        "therapeutics",
        "laboratories",
    ]

    /// Whole-word terms for funder names — matched with word boundaries.
    ///
    /// No trailing `\.?` is needed: `\b` already sits between the last letter and
    /// a following ".", so "Inc" and "Inc." both match.
    ///
    /// The first two are the safe residue of stems the corpus disqualified — see
    /// ``funderNameStems`` for "pharma", and for "biotech": as a substring it
    /// scored 0 TP / 4 FP, reaching only "Department of Biotechnology" (an Indian
    /// ministry) and "Biotechnology and Biological Sciences Research Council" (a
    /// UK research council). "Biotechnology" names a field, not a company type;
    /// as a bare word it is a company name ("Acme Biotech"), so that form is kept.
    ///
    /// The rest are legally reserved incorporation suffixes — a public body cannot
    /// use one. Deliberately absent, each for a measured or stated reason:
    /// - `co` — 4 TP / 0 FP on the corpus, and excluded anyway: it collides with
    ///   the English prefix ("project co-sponsored by…"), a form the corpus does
    ///   not happen to contain. A judgement call against four measured true
    ///   positives, not a measured false positive.
    /// - `corporation` — 1 TP / 1 FP; US non-profits use it ("Research
    ///   Corporation for Science Advancement").
    /// - `pty` — 0 TP; no corpus evidence, so nothing earned.
    /// - `ag`, `bv`, `nv`, `sa` — same, and two-letter tokens besides.
    /// - `ab` — 1 TP / 0 FP; passes the count but excluded because it collides
    ///   with province and country codes, and these strings carry locations, so
    ///   "University of Calgary, AB" would be a false positive the corpus cannot
    ///   see. Costs one true positive, "Roche Sweden AB".
    /// - `labs` — same call: "Los Alamos National Labs" is not industry. Costs
    ///   "Tempus Labs".
    ///
    /// Ties go to precision here, because `industryFundingDetected` feeds a
    /// HIGH-risk rule and HIGH downgrades a paper's quality tier.
    ///
    /// **One deliberate deviation from bmlib's list:** `plc` is kept here and
    /// excluded there. bmlib excludes it as "0 TP — no corpus evidence", but
    /// `corp` and `gmbh` also score 0 TP / 0 FP on the same corpus and bmlib keeps
    /// both on the reserved-suffix argument. (`pharma` and `biotech` also score
    /// 0/0 there, but bmlib keeps those as the safe residue of disqualified stems,
    /// which is a different argument and not a parallel for this one.) `plc` is
    /// a legally reserved UK public-limited-company suffix in exactly that
    /// position, it scores 0 TP / 0 FP (so precision and recall are unchanged),
    /// and it is the form UK-listed pharma funders report under.
    public static let funderNameWords: [String] = [
        #"\bpharma\b"#,
        #"\bbiotech\b"#,
        #"\bincorporated\b"#,
        #"\binc\b"#,
        #"\bcorp\b"#,
        #"\blimited\b"#,
        #"\bltd\b"#,
        #"\bgmbh\b"#,
        #"\bllc\b"#,
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
        // Open-availability affirmations (issue #113): genuinely-open statements
        // that name no repository but explicitly affirm open access. Deliberately
        // narrow — bare "available" is not matched. Mirrors Python's
        // DATA_REPOSITORIES['full_open'].
        // The negative lookbehind guards against a negated affirmation ("not
        // openly accessible") falsely matching FULL_OPEN (issue #113 review).
        #"(?<!not )openly (?:available|shared|accessible)"#,
        #"(?<!not )freely (?:available|shared|accessible)"#,
        #"(?<!not )available (?:in|within|as|via|through) (?:the )?supplement"#,
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
        #"cannot be (?:\w+ )?shared"#,
        #"not (?:publicly )?available"#,
        #"(?:would|will|shall) not be (?:\w+ )?(?:released|shared|disclosed|provided)"#,
        "not be released to others",
        #"requests?\s+(?:for\s+)?(?:such\s+)?data\s+should\s+be\s+made\s+(?:directly\s+)?to"#,
        #"on the understanding that\b.*\bnot\b"#,
        #"used only for the purpose of\b"#,
        #"agreements?\s+(?:with\s+)?(?:the\s+)?sponsors?\s+prevent"#,
        #"confidentiality\s+agreements?\s+(?:with\s+)?sponsors?"#,
        #"data\s+custodians?\b"#,
        // Privacy/legal data-restriction detection (issue #104): GDPR/HIPAA/
        // privacy/patient-consent statements classify as `.restricted`. Word-
        // anchored per #106/#107. Mirrors Python's DATA_REPOSITORIES['restricted'].
        #"\bgdpr\b"#,
        #"\bhipaa\b"#,
        #"\bprivacy\b"#,
        #"\bpatient consent\b"#,
        // Negated open-availability affirmations (issue #117). Listed here so a
        // bare negated affirmation ("data were never openly shared") carries an
        // explicit restriction label and classifies `.restricted`, matching the
        // already-pinned adjacent form ("not openly accessible without IRB
        // approval"). See `negatedOpennessPatterns` for the rationale.
    ] + negatedOpennessPatterns

    /// Negated open-availability affirmations (issue #117).
    ///
    /// The `(?<!not )` lookbehind carried by `fullOpenPatterns` is fixed-width,
    /// so it only suppresses an *immediately* negated affirmation. Every
    /// detached negator escaped it and produced a false `.fullOpen` — the
    /// dangerous over-stating-openness direction:
    ///
    ///   "data are not currently openly available"  (intervening word)
    ///   "data were never openly shared"            (alternate negator)
    ///   "data are not  openly available"           (doubled whitespace)
    ///   "the data could not be openly shared"      (modal outside the
    ///                                               strong-refusal alternation)
    ///
    /// Python's `re` forbids variable-length lookbehind, and these patterns must
    /// stay byte-identical across Python/Swift/Android, so widening the
    /// lookbehind is not available. The guard is therefore expressed as a
    /// *forward* match: a negator, then at most two intervening words, then the
    /// affirmation.
    ///
    /// The window is bounded rather than open-ended, and the
    /// `(?!and\b|but\b|or\b)` barrier terminates the negation scope at a
    /// coordinating conjunction. Both keep the check from reaching into an
    /// affirmation the negator does not govern ("data were not embargoed **and**
    /// were openly shared" stays `.fullOpen`), which would under-report
    /// genuinely open data.
    ///
    /// Issue #125 widened the negator alternation with `no`, `neither` and
    /// `nor` ("data are no longer openly available", "by no means openly
    /// available", "posted nor openly available" all escaped the #117
    /// alternation and reported `.fullOpen`). The worked false-positive shapes
    /// stay open: "no restrictions apply and data are openly available"
    /// (window + barrier), "no embargo; data are openly available" (`\w+`
    /// cannot cross punctuation), "no limits on these openly available
    /// records" (window bound).
    ///
    /// The last two patterns cover the two-token "neither … nor" form, which a
    /// single-token alternation cannot express ("neither the raw nor the
    /// processed data are openly available"). Their windows are wider than the
    /// single-token `{0,2}` because each must span a conjunct noun phrase —
    /// `{0,3}` words to "nor", `{0,4}` from "nor" to the affirmation — and
    /// both negators are unambiguous, so the widening does not reopen the
    /// far-negator hole.
    ///
    /// Byte-identical to Python's `NEGATED_OPENNESS_PATTERNS` and the Android
    /// equivalent.
    public static let negatedOpennessPatterns: [String] = [
        #"\b(?:not|no|never|cannot|neither|nor)\b(?:\s+(?!and\b|but\b|or\b)\w+){0,2}\s+(?:openly|freely) (?:available|shared|accessible)"#,
        #"\b(?:not|no|never|cannot|neither|nor)\b(?:\s+(?!and\b|but\b|or\b)\w+){0,2}\s+available (?:in|within|as|via|through) (?:the )?supplement"#,
        #"\bneither\b(?:\s+(?!and\b|but\b|or\b)\w+){0,3}\s+nor\b(?:\s+(?!and\b|but\b|or\b)\w+){0,4}\s+(?:openly|freely) (?:available|shared|accessible)"#,
        #"\bneither\b(?:\s+(?!and\b|but\b|or\b)\w+){0,3}\s+nor\b(?:\s+(?!and\b|but\b|or\b)\w+){0,4}\s+available (?:in|within|as|via|through) (?:the )?supplement"#,
    ]

    /// Strong-refusal indicators that escalate a statement to `.notAvailable`.
    ///
    /// These are sharing statements that amount to a refusal (proprietary,
    /// cannot be shared, sponsor confidentiality, etc.). A subset of
    /// `restrictedPatterns`, mirroring Python's `strong_refusal_patterns`.
    ///
    /// The `(?:\w+ )?` in the refusal patterns tolerates one intervening adverb
    /// so a negated open affirmation ("will not be openly shared", "cannot be
    /// openly shared") sets the up-front unavailability signal and skips the
    /// full-open step (issue #113 review). Detached negators that escape this
    /// tolerance are handled by `negatedOpennessPatterns` (issue #117).
    public static let strongRefusalPatterns: [String] = [
        #"cannot be (?:\w+ )?shared"#,
        #"not (?:publicly )?available"#,
        "proprietary",
        #"(?:would|will|shall) not be (?:\w+ )?(?:released|shared|disclosed|provided)"#,
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
        #"cannot be (?:\w+ )?shared"#: "Data cannot be shared",
        #"not (?:publicly )?available"#: "Data not publicly available",
        "proprietary": "Data described as proprietary",
        #"(?:would|will|shall) not be (?:\w+ )?(?:released|shared|disclosed|provided)"#:
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
        #"\bgdpr\b"#: "GDPR restrictions",
        #"\bhipaa\b"#: "HIPAA restrictions",
        #"\bprivacy\b"#: "Privacy restrictions",
        #"\bpatient consent\b"#: "Patient consent required",
        negatedOpennessPatterns[0]: "Data not openly available",
        negatedOpennessPatterns[1]: "Data not openly available",
        negatedOpennessPatterns[2]: "Data not openly available",
        negatedOpennessPatterns[3]: "Data not openly available",
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
