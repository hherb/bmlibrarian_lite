package com.bmlibrarian.factchecker.domain.transparency

/**
 * Constants for study-transparency analysis.
 *
 * Ported from the Swift `TransparencyConstants` (BioMedLit), whose scoring
 * values mirror the canonical Python reference (`calculate_transparency_score`
 * in `study_transparency_analyzer.py`) so identical inputs produce identical
 * scores on every platform. The data-availability patterns are not here: they
 * live in [DataRepositoryPatterns].
 */
object TransparencyConstants {

    // ==================== Analyzer version ====================

    /**
     * Version of the transparency analyzer that produced a stored result.
     *
     * Stamped onto every [TransparencyResult] at build time, so a result computed
     * under an earlier version can be recognised as stale ([TransparencyResult.isStale])
     * and offered for re-analysis instead of being shown beside a current one as
     * if the two numbers were comparable.
     *
     * **Bump this whenever a change moves stored scores**, only ever upward, and
     * in step with Swift's `TransparencyConstants.analyzerVersion`: results sync
     * between devices, and staleness compares with `<` so a result stamped by a
     * newer build is not mistaken for an older one. History (see Swift for the
     * full record): 1 — original scoring (stored results carry no version);
     * 2 — Europe PMC allow-list, JATS fixes and recalibrated funder patterns;
     * 3 — PDF text reaches the analyzer, abstract-only deposits no longer do;
     * 4 — results record whether the full text was searched, and a missing trial
     * registration is reported only when ClinicalTrials.gov answered;
     * 5 — back-matter headings kept by the Swift JATS parser, "… Statement"
     * headings accepted by the extractors, PubMed DOIs read by Swift;
     * 6 — funders named by brand classified as industry, their foundations not (#394).
     * 7 — a title reads as a trial's only by whole word, so "atrial fibrillation" no longer
     *     raises the missing-registration indicator; a result a source could not be read for
     *     records it ([TransparencyResult.sourcesUnreachable]) and is re-analysed (#385).
     */
    const val ANALYZER_VERSION: Int = 7

    // ==================== API URLs ====================

    /** CrossRef API base URL for funder and DOI metadata lookups. */
    const val CROSSREF_BASE_URL: String = "https://api.crossref.org"

    /** ClinicalTrials.gov API v2 base URL for trial registration data. */
    const val CLINICAL_TRIALS_BASE_URL: String = "https://clinicaltrials.gov/api/v2"

    /** OpenAlex API base URL for open access metadata. */
    const val OPENALEX_BASE_URL: String = "https://api.openalex.org"

    // ==================== Rate limits ====================

    /** CrossRef polite rate limit (requests per second). */
    const val CROSSREF_RATE_LIMIT: Double = 10.0

    /** ClinicalTrials.gov rate limit (requests per second). */
    const val CLINICAL_TRIALS_RATE_LIMIT: Double = 5.0

    /** Minimum interval between two requests to the same service, in milliseconds (Swift: 0.2 s). */
    const val MINIMUM_REQUEST_INTERVAL_MS: Long = 200L

    // ==================== Scoring thresholds ====================

    /** Base transparency score before adjustments. */
    const val BASE_TRANSPARENCY_SCORE: Int = 50

    /** Score threshold for high risk classification (score < this = high risk). */
    const val HIGH_RISK_SCORE_THRESHOLD: Int = 40

    /** Score threshold for medium risk classification (score <= this = medium risk). */
    const val MEDIUM_RISK_SCORE_THRESHOLD: Int = 70

    /** FDAAA compliance deadline in days (12 months after primary completion). */
    const val RESULTS_COMPLIANCE_DEADLINE_DAYS: Int = 365

    /** Seconds per day (24 * 60 * 60) for time interval calculations. */
    const val SECONDS_PER_DAY: Long = 86_400L

    // ==================== Score adjustments ====================

    /** Points awarded for full open data access. */
    const val FULL_OPEN_DATA_POINTS: Int = 20

    /** Points awarded for data available on request. */
    const val ON_REQUEST_DATA_POINTS: Int = 5

    /** Penalty for data available only with significant restrictions. */
    const val RESTRICTED_DATA_PENALTY: Int = -5

    /** Penalty for data explicitly not available. */
    const val NO_DATA_PENALTY: Int = -15

    /** Penalty for a missing data availability statement. */
    const val NO_STATEMENT_PENALTY: Int = -5

    /** Points awarded for having a COI statement. */
    const val COI_STATEMENT_POINTS: Int = 5

    /**
     * Additional penalty when a COI statement discloses industry ties.
     *
     * Disclosure is credited ([COI_STATEMENT_POINTS]), but the underlying
     * situation still carries bias risk. Matches Python's `-5` after the `+5`.
     */
    const val COI_INDUSTRY_TIES_PENALTY: Int = -5

    /** Penalty for a missing COI statement. */
    const val MISSING_COI_PENALTY: Int = -5

    /** Points awarded for trial registration. */
    const val TRIAL_REGISTRATION_POINTS: Int = 10

    /** Points awarded for compliant results posting. */
    const val COMPLIANT_RESULTS_POINTS: Int = 5

    /** Penalty for missing trial results. */
    const val MISSING_RESULTS_PENALTY: Int = -10

    /** Penalty for detected outcome switching. */
    const val OUTCOME_SWITCHING_PENALTY: Int = -15

    /**
     * Penalty for industry ties combined with restricted/unavailable data.
     *
     * Applies when industry funding is detected *or* the COI statement discloses
     * industry ties, and the data is restricted or not available.
     */
    const val INDUSTRY_NO_DATA_PENALTY: Int = -10

    // ==================== Score category thresholds ====================

    /** Score threshold for the "good transparency" category (score >= this). */
    const val GOOD_TRANSPARENCY_THRESHOLD: Int = 76

    /** Score threshold for the "average transparency" category (score >= this). */
    const val AVERAGE_TRANSPARENCY_THRESHOLD: Int = 51

    /** Score threshold for the "below average transparency" category (score >= this). */
    const val BELOW_AVERAGE_TRANSPARENCY_THRESHOLD: Int = 26

    // ==================== Score range ====================

    /** Minimum valid transparency score. */
    const val MIN_TRANSPARENCY_SCORE: Int = 0

    /** Maximum valid transparency score. */
    const val MAX_TRANSPARENCY_SCORE: Int = 100

    /** Multiplier turning a 0.0-1.0 confidence into a percentage. */
    const val PERCENT_SCALE: Double = 100.0

    // ==================== UI limits ====================

    /** Maximum risk indicators to show in a tooltip before summarising the rest. */
    const val MAX_RISK_INDICATORS_IN_TOOLTIP: Int = 5

    /** Maximum characters of an outcome description quoted in an outcome-switching detail. */
    const val MAX_OUTCOME_DESCRIPTION_LENGTH: Int = 50

    // ==================== Registry names ====================

    /** ClinicalTrials.gov registry display name; also the data-source name it is recorded under. */
    const val CLINICAL_TRIALS_REGISTRY_NAME: String = "ClinicalTrials.gov"

    // ==================== Certainty notes ====================

    /** Shown with every rating made without the article's full text. */
    const val LIMITED_CERTAINTY_NOTE: String =
        "Limited certainty because of lack of full text access"

    /** Shown with a rating that did not record whether the full text was read. */
    const val UNRECORDED_CERTAINTY_NOTE: String =
        "Certainty unknown: this analysis did not record whether the full text was " +
            "accessed. Re-analyse for a rating of known certainty."

    /** Suffix a compact risk badge carries when its rating's certainty is limited. */
    const val LIMITED_CERTAINTY_BADGE_SUFFIX: String = "· limited"

    /** Shown in place of "High" for a rating whose every reason rests on unsearched full text. */
    const val UNASSESSED_LABEL: String = "Unassessed"

    /** Shown with a single rating displayed as unassessed. */
    const val UNASSESSED_NOTE: String =
        "Shown as unassessed rather than high risk: every reason for a high rating depends " +
            "on statements that appear only in the full text, which was not available to search."

    // ==================== Metadata sources ====================

    /** Name recorded in `dataSourcesUsed` when PubMed returned the article. */
    const val PUBMED_SOURCE_NAME: String = "PubMed"

    /** Name recorded in `dataSourcesUsed` when CrossRef returned the work. */
    const val CROSSREF_SOURCE_NAME: String = "CrossRef"

    /**
     * Warning recorded when CrossRef, the only source of funders, could not be reached or
     * its answer could not be read: "industry funding: not detected" then means not looked for.
     */
    const val CROSSREF_UNREACHABLE_WARNING: String =
        "CrossRef could not be reached, so this study's funders were not checked; " +
            "industry funding may be present though none is reported."

    /**
     * Warning recorded when the article's PubMed metadata could not be read. The title — the
     * only place NCT IDs are read from — is then missing, and when no DOI was given so is the
     * DOI CrossRef, the only source of funders, is asked by. Swift's `pubMedUnreachableWarning`.
     * Android reads that metadata from the stored document (`storedMetadataLookup`), which
     * never fails, so in the app this fires only for a lookup that asks a network.
     */
    const val PUBMED_UNREACHABLE_WARNING: String =
        "PubMed could not be reached, so this study's record was not read; its DOI, " +
            "and with it the funders CrossRef holds, may be missing from this analysis."

    /**
     * Caveat on a result a source could not be read for ([TransparencyResult.isProvisional]).
     * Swift's `provisionalResultCaveat`.
     */
    const val PROVISIONAL_RESULT_CAVEAT: String =
        "A source this analysis needed could not be read, so the rating is provisional: " +
            "it rests on less than the full record. Re-analyse the study before relying on it."

    // ==================== Date parsing defaults ====================

    /** Default month value when parsing dates with only a year. */
    const val DEFAULT_MONTH: Int = 1

    /** Default day value when parsing dates without a day. */
    const val DEFAULT_DAY: Int = 1
}
