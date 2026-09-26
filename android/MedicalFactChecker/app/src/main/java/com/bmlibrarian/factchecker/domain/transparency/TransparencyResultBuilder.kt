package com.bmlibrarian.factchecker.domain.transparency

import java.time.Instant

/**
 * Collects a [TransparencyResult]'s fields while an analysis runs, then builds
 * the immutable result with its score, risk level and risk indicators.
 *
 * Ported from the Swift `TransparencyResultBuilder`. Example:
 * ```
 * val builder = TransparencyResultBuilder(pmid = "12345678")
 * builder.title = "Study Title"
 * builder.industryFundingDetected = true
 * builder.dataAvailability = DataAvailabilityResult(disclosureLevel = DataDisclosureLevel.FULL_OPEN)
 * val result = builder.build()
 * ```
 *
 * @param doi Digital Object Identifier.
 * @param pmid PubMed identifier.
 */
class TransparencyResultBuilder(
    /** Digital Object Identifier. */
    var doi: String? = null,
    /** PubMed identifier. */
    var pmid: String? = null,
) {
    /** PubMed Central identifier. */
    var pmcid: String? = null

    /** Article title. */
    var title: String? = null

    /** Journal name. */
    var journal: String? = null

    /** Publication date. */
    var publicationDate: Instant? = null

    /** Author names. */
    var authors: List<String> = emptyList()

    /** Primary sponsor type classification. */
    var sponsorType: SponsorType = SponsorType.UNKNOWN

    /** Identified funders. */
    var funders: List<FunderInfo> = emptyList()

    /** Whether industry funding was detected. */
    var industryFundingDetected: Boolean = false

    /** Confidence (0.0-1.0) of the industry-funding detection. */
    var industryFundingConfidence: Double = 0.0

    /** Clinical trial registrations found. */
    var trialRegistrations: List<TrialRegistration> = emptyList()

    /** Results posting compliance status. */
    var resultsCompliance: ResultsComplianceStatus = ResultsComplianceStatus.UNKNOWN

    /** Conflict-of-interest analysis. */
    var coiAnalysis: COIAnalysisResult = COIAnalysisResult.NOT_AVAILABLE

    /** Data availability analysis. */
    var dataAvailability: DataAvailabilityResult = DataAvailabilityResult.NOT_STATED

    /** Whether outcome switching was detected. */
    var outcomeSwitchingDetected: Boolean = false

    /** Details of detected outcome discrepancies. */
    var outcomeSwitchingDetails: List<String> = emptyList()

    /** Data sources that returned a record. */
    var dataSourcesUsed: List<String> = emptyList()

    /** Non-fatal warnings encountered during analysis. */
    var warnings: List<String> = emptyList()

    /** Errors encountered during analysis. */
    var errors: List<String> = emptyList()

    /** Whether the article's full text was given to the analysis; null when not recorded. */
    var fullTextSearched: Boolean? = null

    /**
     * Whether ClinicalTrials.gov answered for every trial the article cites, so an empty
     * [trialRegistrations] is the registry's answer. False when no trial ID was found to look
     * up or a lookup failed.
     */
    var trialRegistrationAssessed: Boolean = false

    /**
     * Whether a source the analysis needed could not be read, which makes the result
     * provisional ([TransparencyResult.sourcesUnreachable]).
     */
    var sourcesUnreachable: Boolean = false

    /**
     * Build the result, computing its score, risk level and risk indicators with
     * [TransparencyScorer] from the fields populated so far. Stamped with the
     * current [TransparencyConstants.ANALYZER_VERSION].
     *
     * @return The immutable result.
     */
    fun build(): TransparencyResult {
        val score = TransparencyScorer.calculateScore(
            dataAvailability = dataAvailability,
            coiAnalysis = coiAnalysis,
            trialRegistrations = trialRegistrations,
            resultsCompliance = resultsCompliance,
            industryFundingDetected = industryFundingDetected,
            outcomeSwitchingDetected = outcomeSwitchingDetected,
        )
        val riskLevel = TransparencyScorer.calculateRiskLevel(
            score = score,
            industryFunding = industryFundingDetected,
            dataAvailability = dataAvailability.disclosureLevel,
            coiDisclosed = coiAnalysis.hasStatement,
        )
        val riskIndicators = TransparencyScorer.identifyRiskIndicators(
            industryFundingDetected = industryFundingDetected,
            dataAvailability = dataAvailability,
            resultsCompliance = resultsCompliance,
            coiAnalysis = coiAnalysis,
            trialRegistrations = trialRegistrations,
            outcomeSwitchingDetected = outcomeSwitchingDetected,
            title = title,
            trialRegistrationAssessed = trialRegistrationAssessed,
        )
        return build(score = score, riskLevel = riskLevel, riskIndicators = riskIndicators)
    }

    /**
     * Build the result with a score, risk level and indicators computed elsewhere.
     *
     * Also stamped with the current analyzer version.
     *
     * @param score Pre-calculated transparency score.
     * @param riskLevel Pre-calculated risk level.
     * @param riskIndicators Pre-calculated risk indicators.
     * @return The immutable result.
     */
    fun build(
        score: Int,
        riskLevel: TransparencyRiskLevel,
        riskIndicators: List<String>,
    ): TransparencyResult =
        TransparencyResult(
            doi = doi,
            pmid = pmid,
            pmcid = pmcid,
            title = title,
            journal = journal,
            publicationDate = publicationDate,
            authors = authors,
            sponsorType = sponsorType,
            funders = funders,
            industryFundingDetected = industryFundingDetected,
            industryFundingConfidence = industryFundingConfidence,
            trialRegistrations = trialRegistrations,
            resultsCompliance = resultsCompliance,
            coiAnalysis = coiAnalysis,
            dataAvailability = dataAvailability,
            outcomeSwitchingDetected = outcomeSwitchingDetected,
            outcomeSwitchingDetails = outcomeSwitchingDetails,
            transparencyScore = score,
            riskLevel = riskLevel,
            riskIndicators = riskIndicators,
            dataSourcesUsed = dataSourcesUsed,
            warnings = warnings,
            errors = errors,
            fullTextSearched = fullTextSearched,
            sourcesUnreachable = sourcesUnreachable,
        )
}
