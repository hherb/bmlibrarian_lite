package com.bmlibrarian.factchecker.domain.transparency

/**
 * Pure functions computing transparency scores, risk levels and risk indicators.
 *
 * Ported from the Swift `TransparencyScorer` (BioMedLit), whose arithmetic is
 * identical to the canonical Python `calculate_transparency_score`:
 *  - base 50;
 *  - data availability +20 open, +5 on request, -5 restricted, -15 unavailable, -5 not stated;
 *  - COI +5 with a statement (and a further -5 if it discloses industry ties), -5 without;
 *  - trial +10 registered, +5 results compliant, -10 results missing;
 *  - -15 outcome switching; -10 industry ties with restricted/unavailable data.
 */
object TransparencyScorer {

    /** Levels that count as withheld data for the combined industry penalty and indicators. */
    private val RESTRICTED_OR_UNAVAILABLE: Set<DataDisclosureLevel> =
        setOf(DataDisclosureLevel.NOT_AVAILABLE, DataDisclosureLevel.RESTRICTED)

    /** Levels that, with industry funding, rate a study high risk (no statement counts). */
    private val WITHHELD_FOR_HIGH_RISK: Set<DataDisclosureLevel> = setOf(
        DataDisclosureLevel.RESTRICTED,
        DataDisclosureLevel.NOT_AVAILABLE,
        DataDisclosureLevel.NOT_STATED,
    )

    /** Bullet prefixing each indicator in a tooltip. */
    private const val TOOLTIP_BULLET: String = "  • "

    // ==================== Score ====================

    /**
     * The overall transparency score, clamped to 0-100.
     *
     * The clamped sum of [scoreComponents].
     *
     * @param dataAvailability Data availability analysis.
     * @param coiAnalysis COI analysis.
     * @param trialRegistrations Trial registrations found.
     * @param resultsCompliance Results posting compliance.
     * @param industryFundingDetected Whether industry funding was detected.
     * @param outcomeSwitchingDetected Whether outcome switching was detected.
     * @return The score.
     */
    fun calculateScore(
        dataAvailability: DataAvailabilityResult,
        coiAnalysis: COIAnalysisResult,
        trialRegistrations: List<TrialRegistration>,
        resultsCompliance: ResultsComplianceStatus,
        industryFundingDetected: Boolean,
        outcomeSwitchingDetected: Boolean,
    ): Int {
        val score = scoreComponents(
            dataAvailability = dataAvailability,
            coiAnalysis = coiAnalysis,
            trialRegistrations = trialRegistrations,
            resultsCompliance = resultsCompliance,
            industryFundingDetected = industryFundingDetected,
            outcomeSwitchingDetected = outcomeSwitchingDetected,
        ).sumOf { it.points }
        return score.coerceIn(TransparencyConstants.MIN_TRANSPARENCY_SCORE, TransparencyConstants.MAX_TRANSPARENCY_SCORE)
    }

    /**
     * The additions and penalties a transparency score is the sum of.
     *
     * [calculateScore] is the clamped sum of these, so a report explaining a low
     * score lists the very terms that produced it. Terms worth zero points are
     * omitted; the base score is always first.
     *
     * @param dataAvailability Data availability analysis.
     * @param coiAnalysis COI analysis.
     * @param trialRegistrations Trial registrations found.
     * @param resultsCompliance Results posting compliance.
     * @param industryFundingDetected Whether industry funding was detected.
     * @param outcomeSwitchingDetected Whether outcome switching was detected.
     * @return Each term that moved the score, in the order it is applied.
     */
    fun scoreComponents(
        dataAvailability: DataAvailabilityResult,
        coiAnalysis: COIAnalysisResult,
        trialRegistrations: List<TrialRegistration>,
        resultsCompliance: ResultsComplianceStatus,
        industryFundingDetected: Boolean,
        outcomeSwitchingDetected: Boolean,
    ): List<ScoreComponent> {
        val base = ScoreComponent(label = "Starting score", points = TransparencyConstants.BASE_TRANSPARENCY_SCORE)
        val components = mutableListOf<ScoreComponent>()

        val level = dataAvailability.disclosureLevel
        components.add(
            ScoreComponent(
                label = "Data availability: ${level.displayName.lowercase()}",
                points = dataAvailabilityPoints(level),
                recordsMissingStatement = level == DataDisclosureLevel.NOT_STATED,
            ),
        )

        // Stated as the separate terms coiDisclosurePoints adds up, so a statement
        // disclosing industry ties reads as credit and penalty rather than as a
        // net zero that looks like nothing was found.
        if (coiAnalysis.hasStatement) {
            components.add(
                ScoreComponent(
                    label = "Conflict of interest statement present",
                    points = TransparencyConstants.COI_STATEMENT_POINTS,
                ),
            )
            if (coiAnalysis.hasIndustryTies) {
                components.add(
                    ScoreComponent(
                        label = "Conflict of interest statement discloses industry ties",
                        points = TransparencyConstants.COI_INDUSTRY_TIES_PENALTY,
                    ),
                )
            }
        } else {
            components.add(
                ScoreComponent(
                    label = "No conflict of interest statement found",
                    points = coiDisclosurePoints(hasStatement = false),
                    recordsMissingStatement = true,
                ),
            )
        }

        if (trialRegistrations.isNotEmpty()) {
            components.add(
                ScoreComponent(label = "Trial registered", points = TransparencyConstants.TRIAL_REGISTRATION_POINTS),
            )
            when (resultsCompliance) {
                ResultsComplianceStatus.COMPLIANT -> components.add(
                    ScoreComponent(
                        label = "Trial results posted on time",
                        points = TransparencyConstants.COMPLIANT_RESULTS_POINTS,
                    ),
                )
                ResultsComplianceStatus.MISSING -> components.add(
                    ScoreComponent(
                        label = "Trial results not posted",
                        points = TransparencyConstants.MISSING_RESULTS_PENALTY,
                    ),
                )
                ResultsComplianceStatus.LATE,
                ResultsComplianceStatus.NOT_REQUIRED,
                ResultsComplianceStatus.UNKNOWN,
                -> Unit
            }
        }

        if (outcomeSwitchingDetected) {
            components.add(
                ScoreComponent(
                    label = "Outcome switching detected",
                    points = TransparencyConstants.OUTCOME_SWITCHING_PENALTY,
                ),
            )
        }

        // Industry ties (funding or disclosed COI) with restricted/unavailable data.
        val hasIndustryTies = industryFundingDetected || coiAnalysis.hasIndustryTies
        if (hasIndustryTies && level in RESTRICTED_OR_UNAVAILABLE) {
            components.add(
                ScoreComponent(
                    label = "Industry ties with restricted or unavailable data",
                    points = TransparencyConstants.INDUSTRY_NO_DATA_PENALTY,
                ),
            )
        }

        return listOf(base) + components.filter { it.points != 0 }
    }

    /**
     * The score terms of a stored result, computed from its recorded findings.
     *
     * @param result A stored transparency result.
     * @return Each term that moved the score.
     */
    fun scoreComponents(result: TransparencyResult): List<ScoreComponent> =
        scoreComponents(
            dataAvailability = result.dataAvailability,
            coiAnalysis = result.coiAnalysis,
            trialRegistrations = result.trialRegistrations,
            resultsCompliance = result.resultsCompliance,
            industryFundingDetected = result.industryFundingDetected,
            outcomeSwitchingDetected = result.outcomeSwitchingDetected,
        )

    /**
     * Points for a data disclosure level.
     *
     * @param level The disclosure level.
     * @return Points added (positive) or subtracted (negative); 0 for unknown.
     */
    fun dataAvailabilityPoints(level: DataDisclosureLevel): Int =
        when (level) {
            DataDisclosureLevel.FULL_OPEN -> TransparencyConstants.FULL_OPEN_DATA_POINTS
            DataDisclosureLevel.AVAILABLE_ON_REQUEST -> TransparencyConstants.ON_REQUEST_DATA_POINTS
            DataDisclosureLevel.RESTRICTED -> TransparencyConstants.RESTRICTED_DATA_PENALTY
            DataDisclosureLevel.NOT_AVAILABLE -> TransparencyConstants.NO_DATA_PENALTY
            DataDisclosureLevel.NOT_STATED -> TransparencyConstants.NO_STATEMENT_PENALTY
            DataDisclosureLevel.UNKNOWN -> 0
        }

    /**
     * Points for COI disclosure: credit for a statement, less a penalty when it
     * discloses industry ties; a penalty for no statement.
     *
     * @param hasStatement True if a non-empty COI statement was found.
     * @param hasIndustryTies True if the statement discloses industry ties.
     * @return Points added or subtracted.
     */
    fun coiDisclosurePoints(hasStatement: Boolean, hasIndustryTies: Boolean = false): Int {
        if (!hasStatement) return TransparencyConstants.MISSING_COI_PENALTY
        var points = TransparencyConstants.COI_STATEMENT_POINTS
        if (hasIndustryTies) points += TransparencyConstants.COI_INDUSTRY_TIES_PENALTY
        return points
    }

    /**
     * Points for trial registration and results compliance.
     *
     * @param registrations Trial registrations found.
     * @param compliance Results compliance status.
     * @return Points added or subtracted; 0 without a registration.
     */
    fun trialRegistrationPoints(registrations: List<TrialRegistration>, compliance: ResultsComplianceStatus): Int {
        if (registrations.isEmpty()) return 0
        var points = TransparencyConstants.TRIAL_REGISTRATION_POINTS
        when (compliance) {
            ResultsComplianceStatus.COMPLIANT -> points += TransparencyConstants.COMPLIANT_RESULTS_POINTS
            ResultsComplianceStatus.MISSING -> points += TransparencyConstants.MISSING_RESULTS_PENALTY
            ResultsComplianceStatus.LATE, ResultsComplianceStatus.NOT_REQUIRED, ResultsComplianceStatus.UNKNOWN -> Unit
        }
        return points
    }

    // ==================== Risk level ====================

    /**
     * The risk level of a set of transparency findings.
     *
     * High exactly when [highRiskTriggers] is non-empty; otherwise medium for a
     * score at or below [TransparencyConstants.MEDIUM_RISK_SCORE_THRESHOLD] or any
     * industry funding; otherwise low.
     *
     * @param score Transparency score.
     * @param industryFunding Whether industry funding was detected.
     * @param dataAvailability Data disclosure level.
     * @param coiDisclosed Whether a COI statement exists.
     * @param scoreThreshold Score below which the study is high risk.
     * @param industryDataTriggersHighRisk Whether industry funding with withheld data rates high.
     * @param missingCoiTriggersHighRisk Whether a missing COI statement rates high.
     * @return The risk level.
     */
    fun calculateRiskLevel(
        score: Int,
        industryFunding: Boolean,
        dataAvailability: DataDisclosureLevel,
        coiDisclosed: Boolean,
        scoreThreshold: Int = TransparencyConstants.HIGH_RISK_SCORE_THRESHOLD,
        industryDataTriggersHighRisk: Boolean = true,
        missingCoiTriggersHighRisk: Boolean = true,
    ): TransparencyRiskLevel {
        val triggers = highRiskTriggers(
            score = score,
            industryFunding = industryFunding,
            dataAvailability = dataAvailability,
            coiDisclosed = coiDisclosed,
            scoreThreshold = scoreThreshold,
            industryDataTriggersHighRisk = industryDataTriggersHighRisk,
            missingCoiTriggersHighRisk = missingCoiTriggersHighRisk,
        )
        if (triggers.isNotEmpty()) return TransparencyRiskLevel.HIGH
        if (score <= TransparencyConstants.MEDIUM_RISK_SCORE_THRESHOLD) return TransparencyRiskLevel.MEDIUM
        if (industryFunding) return TransparencyRiskLevel.MEDIUM
        return TransparencyRiskLevel.LOW
    }

    /**
     * Every rule that, on its own, rates a study high risk.
     *
     * [calculateRiskLevel] rates high exactly when this is non-empty, so a report
     * explaining a high rating names the rules that produced it. All matching
     * rules are returned, not only the first.
     *
     * @param score Transparency score.
     * @param industryFunding Whether industry funding was detected.
     * @param dataAvailability Data disclosure level.
     * @param coiDisclosed Whether a COI statement exists.
     * @param scoreThreshold Score below which the study is high risk.
     * @param industryDataTriggersHighRisk Whether industry funding with withheld data rates high.
     * @param missingCoiTriggersHighRisk Whether a missing COI statement rates high.
     * @return The high-risk rules that apply, in the order they are checked.
     */
    fun highRiskTriggers(
        score: Int,
        industryFunding: Boolean,
        dataAvailability: DataDisclosureLevel,
        coiDisclosed: Boolean,
        scoreThreshold: Int = TransparencyConstants.HIGH_RISK_SCORE_THRESHOLD,
        industryDataTriggersHighRisk: Boolean = true,
        missingCoiTriggersHighRisk: Boolean = true,
    ): List<HighRiskTrigger> {
        val triggers = mutableListOf<HighRiskTrigger>()
        if (score < scoreThreshold) {
            triggers.add(HighRiskTrigger.ScoreBelowThreshold(score = score, threshold = scoreThreshold))
        }
        if (industryDataTriggersHighRisk && industryFunding && dataAvailability in WITHHELD_FOR_HIGH_RISK) {
            triggers.add(HighRiskTrigger.IndustryFundingWithWithheldData(dataAvailability))
        }
        if (missingCoiTriggersHighRisk && !coiDisclosed) {
            triggers.add(HighRiskTrigger.MissingCOIStatement)
        }
        return triggers
    }

    /**
     * The high-risk rules a stored result's findings meet, with the defaults
     * [TransparencyResultBuilder.build] rates with.
     *
     * A result from another analyzer can carry a high rating none of these rules
     * explains; callers must say so rather than present an empty list as the reason.
     *
     * @param result A stored transparency result.
     * @return The high-risk rules that apply.
     */
    fun highRiskTriggers(result: TransparencyResult): List<HighRiskTrigger> =
        highRiskTriggers(
            score = result.transparencyScore,
            industryFunding = result.industryFundingDetected,
            dataAvailability = result.dataAvailability.disclosureLevel,
            coiDisclosed = result.coiAnalysis.hasStatement,
        )

    // ==================== Risk indicators ====================

    /**
     * The human-readable risk-of-bias indicators of a set of findings.
     *
     * Aligned with the Python reference; duplicates are dropped keeping order.
     *
     * @param industryFundingDetected Whether industry funding was detected.
     * @param dataAvailability Data availability analysis.
     * @param resultsCompliance Results posting compliance.
     * @param coiAnalysis COI analysis.
     * @param trialRegistrations Trial registrations found.
     * @param outcomeSwitchingDetected Whether outcome switching was detected.
     * @param title Study title (for the missing-registration check).
     * @param trialRegistrationAssessed Whether ClinicalTrials.gov answered for every trial the
     *   article cites; without that answer a missing registration is not reported.
     * @return The indicators, drawn from [RiskIndicatorStrings].
     */
    fun identifyRiskIndicators(
        industryFundingDetected: Boolean,
        dataAvailability: DataAvailabilityResult,
        resultsCompliance: ResultsComplianceStatus,
        coiAnalysis: COIAnalysisResult,
        trialRegistrations: List<TrialRegistration>,
        outcomeSwitchingDetected: Boolean,
        title: String?,
        trialRegistrationAssessed: Boolean = false,
    ): List<String> {
        val indicators = mutableListOf<String>()
        val level = dataAvailability.disclosureLevel

        if (industryFundingDetected) {
            indicators.add(RiskIndicatorStrings.INDUSTRY_FUNDING)
            if (level in RESTRICTED_OR_UNAVAILABLE) indicators.add(RiskIndicatorStrings.INDUSTRY_RESTRICTED_DATA)
        }

        if (resultsCompliance == ResultsComplianceStatus.MISSING) {
            indicators.add(RiskIndicatorStrings.RESULTS_NOT_POSTED)
        }

        if (coiAnalysis.hasIndustryTies) {
            indicators.add(RiskIndicatorStrings.INDUSTRY_TIES_DISCLOSED)
            val statement = coiAnalysis.statement
            if (statement != null &&
                TransparencyRegex.anyMatch(COIPatterns.institutionalIntermediaryPatterns, statement.lowercase())
            ) {
                indicators.add(RiskIndicatorStrings.INSTITUTIONAL_INTERMEDIARY)
            }
        }
        if (!coiAnalysis.hasStatement) {
            indicators.add(RiskIndicatorStrings.MISSING_COI_STATEMENT)
        }

        when (level) {
            DataDisclosureLevel.NOT_AVAILABLE -> indicators.add(RiskIndicatorStrings.DATA_EFFECTIVELY_UNAVAILABLE)
            DataDisclosureLevel.RESTRICTED -> indicators.add(RiskIndicatorStrings.DATA_ACCESS_RESTRICTED)
            else -> Unit
        }

        if (outcomeSwitchingDetected) indicators.add(RiskIndicatorStrings.OUTCOME_SWITCHING)

        val hasIndustryTies = industryFundingDetected || coiAnalysis.hasIndustryTies
        if (hasIndustryTies && level in RESTRICTED_OR_UNAVAILABLE) {
            indicators.add(RiskIndicatorStrings.COMBINED_INDUSTRY_DATA)
        }

        TrialComplianceAnalyzer.checkMissingRegistration(title, trialRegistrations, trialRegistrationAssessed)
            ?.let { indicators.add(it) }

        return indicators.distinct()
    }

    // ==================== Tooltip ====================

    /**
     * A multi-line tooltip describing a result.
     *
     * Carries the certainty note ([TransparencyCertainty.note]) beside the rating
     * whenever the rating was made without the full text, or may have been.
     *
     * @param result The result.
     * @return Lines joined with "\n".
     */
    fun formatTooltip(result: TransparencyResult): String {
        val lines = mutableListOf<String>()

        lines.add("Transparency Score: ${result.transparencyScore}/${TransparencyConstants.MAX_TRANSPARENCY_SCORE}")
        lines.add("Risk Level: ${result.riskLevel.fullLabel}")
        TransparencyCertainty.from(result.fullTextSearched).note?.let { lines.add(it) }
        lines.add("")

        if (result.industryFundingDetected) {
            val pct = (result.industryFundingConfidence * TransparencyConstants.PERCENT_SCALE).toInt()
            lines.add("Industry Funding: Detected ($pct% confidence)")
        } else {
            lines.add("Industry Funding: Not detected")
        }

        lines.add("Data Availability: ${result.dataAvailability.disclosureLevel.displayName}")

        val coiStatus = when {
            !result.coiAnalysis.hasStatement -> "Not Disclosed"
            result.coiAnalysis.hasIndustryTies -> "Disclosed"
            else -> "No conflicts"
        }
        lines.add("Conflicts of Interest: $coiStatus")

        if (result.trialRegistrations.isNotEmpty()) {
            val resultsStatus =
                if (result.trialRegistrations.first().resultsPosted) "Results Compliant" else "Results Not Posted"
            lines.add("Trial Registration: Registered ($resultsStatus)")
        }

        if (result.riskIndicators.isNotEmpty()) {
            val maxIndicators = TransparencyConstants.MAX_RISK_INDICATORS_IN_TOOLTIP
            lines.add("")
            lines.add("Risk Indicators:")
            result.riskIndicators.take(maxIndicators).forEach { lines.add("$TOOLTIP_BULLET$it") }
            if (result.riskIndicators.size > maxIndicators) {
                lines.add("  ... and ${result.riskIndicators.size - maxIndicators} more")
            }
        }

        return lines.joinToString("\n")
    }

    // ==================== Score category ====================

    /**
     * The category description of a score.
     *
     * @param score Transparency score.
     * @return "Good transparency" (76-100), "Average transparency" (51-75),
     *   "Below average transparency" (26-50) or "Poor transparency" (anything else).
     */
    fun scoreCategory(score: Int): String =
        when (score) {
            in TransparencyConstants.GOOD_TRANSPARENCY_THRESHOLD..TransparencyConstants.MAX_TRANSPARENCY_SCORE ->
                "Good transparency"
            in TransparencyConstants.AVERAGE_TRANSPARENCY_THRESHOLD until
                TransparencyConstants.GOOD_TRANSPARENCY_THRESHOLD -> "Average transparency"
            in TransparencyConstants.BELOW_AVERAGE_TRANSPARENCY_THRESHOLD until
                TransparencyConstants.AVERAGE_TRANSPARENCY_THRESHOLD -> "Below average transparency"
            else -> "Poor transparency"
        }
}
