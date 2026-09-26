package com.bmlibrarian.factchecker.domain.transparency

import java.math.BigDecimal
import java.math.RoundingMode

/**
 * How far a transparency rating can be relied on, given what was read.
 *
 * Conflict-of-interest and data-availability statements appear only in an
 * article's full text. A rating made without it rests on metadata alone and
 * counts statements it could not look for as missing, so full-text analysis is
 * the standard every other rating is measured against, and any rating short of
 * it must say so wherever it is shown. Ported from the Swift `TransparencyCertainty`.
 */
enum class TransparencyCertainty {
    /** The full text was analysed. */
    FULL_TEXT,

    /** The rating was made without the full text. */
    LIMITED_NO_FULL_TEXT,

    /** Whether the full text was analysed was not recorded. */
    UNRECORDED,
    ;

    /** Whether the rating falls short of full-text analysis, or may. */
    val isLimited: Boolean
        get() = this != FULL_TEXT

    /**
     * What a reader must be told alongside the rating; null for full text.
     * [TransparencyConstants.LIMITED_CERTAINTY_NOTE] or [TransparencyConstants.UNRECORDED_CERTAINTY_NOTE].
     */
    val note: String?
        get() = when (this) {
            FULL_TEXT -> null
            LIMITED_NO_FULL_TEXT -> TransparencyConstants.LIMITED_CERTAINTY_NOTE
            UNRECORDED -> TransparencyConstants.UNRECORDED_CERTAINTY_NOTE
        }

    companion object {
        /**
         * The certainty a result's record of full-text access implies.
         *
         * @param fullTextSearched [TransparencyResult.fullTextSearched].
         * @return [FULL_TEXT] for true, [LIMITED_NO_FULL_TEXT] for false, [UNRECORDED] for null.
         */
        fun from(fullTextSearched: Boolean?): TransparencyCertainty =
            when (fullTextSearched) {
                true -> FULL_TEXT
                false -> LIMITED_NO_FULL_TEXT
                null -> UNRECORDED
            }
    }
}

/**
 * A rule that, on its own, rates a study high transparency risk.
 *
 * Produced by [TransparencyScorer.highRiskTriggers], which is also what
 * [TransparencyScorer.calculateRiskLevel] rates by, so the rules a report names
 * are the rules that were applied.
 */
sealed class HighRiskTrigger {
    /** The transparency score fell below the high-risk cut-off. */
    data class ScoreBelowThreshold(val score: Int, val threshold: Int) : HighRiskTrigger()

    /** Industry funding was detected and the data are restricted, unavailable or covered by no statement. */
    data class IndustryFundingWithWithheldData(val level: DataDisclosureLevel) : HighRiskTrigger()

    /** No conflict-of-interest statement was found. */
    data object MissingCOIStatement : HighRiskTrigger()
}

/**
 * One addition or penalty in a transparency score.
 *
 * @property label What the term is for, e.g. "Trial results not posted".
 * @property points Points added (positive) or subtracted (negative).
 * @property recordsMissingStatement Whether the term records a statement as missing — no
 *   conflict-of-interest or no data-availability statement — which is looked for only in the
 *   full text, so a report must qualify it when that text was not searched.
 */
data class ScoreComponent(val label: String, val points: Int, val recordsMissingStatement: Boolean = false) {
    /** The points with an explicit sign, e.g. "+5" or "-10". */
    val signedPoints: String
        get() = if (points > 0) "+$points" else "$points"
}

/**
 * Why one study was rated high transparency risk, in words a report can show.
 *
 * A badge saying "High" tells a reader to distrust a study without telling them
 * what to distrust it for, and the rule most often responsible — no
 * conflict-of-interest statement found — is also the one most often met because
 * there was no full text to look in. This states the rules that produced the
 * rating, the score terms when the score was one of them, and every reason the
 * rating may not mean what it appears to. Ported from the Swift type of the same
 * name; every user-facing string is identical.
 *
 * @property score The study's transparency score (0-100).
 * @property reasons Each rule that rated the study high, as a sentence. Empty only when the
 *   stored rating is one no current rule explains; [caveats] then says so.
 * @property scoreBreakdown The score's terms, given only when a low score is among [reasons].
 * @property otherConcerns Concerns recorded that did not by themselves decide the rating.
 * @property caveats Reasons the rating may rest on less than it appears to.
 * @property certainty How far the rating can be relied on. Its [TransparencyCertainty.note]
 *   belongs beside the score, not among the caveats: it qualifies the whole rating.
 * @property isUnassessed Whether the rating is shown as unassessed rather than high; see
 *   [TransparencyRiskExplanation.Companion.isUnassessed].
 */
data class TransparencyRiskExplanation(
    val score: Int,
    val reasons: List<String>,
    val scoreBreakdown: List<ScoreComponent>,
    val otherConcerns: List<String>,
    val caveats: List<String>,
    val certainty: TransparencyCertainty,
    val isUnassessed: Boolean,
) {
    /** The explanation as indented plain-text lines, for exported reports. */
    val plainTextLines: List<String>
        get() {
            val lines = mutableListOf("  Transparency score: $score/${TransparencyConstants.MAX_TRANSPARENCY_SCORE}")
            certainty.note?.let { lines.add("  $it") }
            if (reasons.isNotEmpty()) {
                lines.add("  ${HighRiskTransparencySection.REASONS_LABEL}:")
                reasons.forEach { lines.add("  - $it") }
            }
            if (scoreBreakdown.isNotEmpty()) {
                lines.add("  ${HighRiskTransparencySection.SCORE_BREAKDOWN_LABEL}:")
                scoreBreakdown.forEach { lines.add("  - ${it.label}: ${it.signedPoints}") }
            }
            if (otherConcerns.isNotEmpty()) {
                lines.add("  ${HighRiskTransparencySection.OTHER_CONCERNS_LABEL}:")
                otherConcerns.forEach { lines.add("  - $it") }
            }
            if (caveats.isNotEmpty()) {
                lines.add("  ${HighRiskTransparencySection.CAVEATS_LABEL}:")
                caveats.forEach { lines.add("  - $it") }
            }
            return lines
        }

    companion object {
        /** Caveat for a stored high rating no current rule explains. */
        internal const val UNEXPLAINED_RATING_CAVEAT: String =
            "None of the current high-risk rules matches this study's recorded findings, " +
                "so the rating probably comes from an earlier version of the analysis. " +
                "Re-analyse the study before relying on it."

        /** Caveat when every reason could have been met only for want of the full text. */
        internal const val UNASSESSED_CAVEAT: String =
            "Every reason for a high rating depends on statements that appear only in the " +
                "full text, which was not searched, so the study is shown as unassessed " +
                "rather than as evidence of poor transparency."

        /**
         * Whether a high rating rests only on statements in full text known not to have been
         * searched.
         *
         * Such a rating records what could not be looked for, not what the study lacks, so
         * every surface shows it as unassessed rather than high. Display only: the stored
         * rating and the scoring rules are unchanged, so the platforms stay in step. A high
         * rating any of whose reasons stands without the text — unposted trial results, say —
         * is still high. So is one whose record of full-text access is missing
         * ([TransparencyCertainty.UNRECORDED]): the text may have been searched, and saying it
         * was not would be as unfounded as the rating; its certainty note asks for re-analysis.
         *
         * @param result A stored transparency result.
         * @param certainty What is known of its full-text access; defaults to the result's record.
         * @return true when the rating is to be shown as unassessed.
         */
        fun isUnassessed(result: TransparencyResult, certainty: TransparencyCertainty? = null): Boolean {
            val resolved = certainty ?: TransparencyCertainty.from(result.fullTextSearched)
            if (result.riskLevel != TransparencyRiskLevel.HIGH ||
                resolved != TransparencyCertainty.LIMITED_NO_FULL_TEXT
            ) {
                return false
            }
            val triggers = TransparencyScorer.highRiskTriggers(result)
            return triggers.isNotEmpty() && triggers.all { dependsOnFullText(it, result) }
        }

        /** Caveat for a result produced by an older analyzer. */
        internal const val STALE_CAVEAT: String =
            "This analysis was produced by an older version of the analyser; " +
                "re-analysing may change the rating."

        /**
         * Caveat when no CrossRef record was retrieved. Funders come from CrossRef alone
         * ([TransparencyAnalysisService] merges CrossRef funders only; PubMed grants are not used
         * here, unlike Python), so a PubMed record does not stand in for it; worded so as not to
         * claim which it was.
         */
        internal const val NO_CROSSREF_CAVEAT: String =
            "No CrossRef record was retrieved for this study (none exists, it has no DOI, " +
                "or CrossRef could not be reached), so its funders were not checked."

        /** Suffix for a score term recording a statement missing from text that was not searched. */
        private const val UNSEARCHED_SUFFIX: String = " (full text not searched)"

        /** Suffix for such a term when whether the text was searched was not recorded. */
        private const val POSSIBLY_UNSEARCHED_SUFFIX: String = " (full text may not have been searched)"

        /**
         * Explain a stored result's high rating.
         *
         * @param result A transparency result, normally one rated high.
         * @param certainty What is known of the rating's full-text access. Defaults to the
         *   result's own record; a caller holding better evidence for a result that predates
         *   the record may pass it.
         * @return The explanation.
         */
        fun of(result: TransparencyResult, certainty: TransparencyCertainty? = null): TransparencyRiskExplanation {
            val resolvedCertainty = certainty ?: TransparencyCertainty.from(result.fullTextSearched)
            val triggers = TransparencyScorer.highRiskTriggers(result)

            val scoredLow = triggers.any { it is HighRiskTrigger.ScoreBelowThreshold }
            val unassessed = isUnassessed(result, resolvedCertainty)
            val caveats = mutableListOf<String>()
            if (triggers.isEmpty() && result.riskLevel == TransparencyRiskLevel.HIGH) {
                caveats.add(UNEXPLAINED_RATING_CAVEAT)
            } else if (unassessed) {
                caveats.add(UNASSESSED_CAVEAT)
            }
            if (result.isStale) caveats.add(STALE_CAVEAT)
            if (result.isProvisional) caveats.add(TransparencyConstants.PROVISIONAL_RESULT_CAVEAT)
            if (TransparencyConstants.CROSSREF_SOURCE_NAME !in result.dataSourcesUsed) {
                caveats.add(NO_CROSSREF_CAVEAT)
            }
            if (result.errors.isNotEmpty()) {
                caveats.add("The analysis reported errors: ${result.errors.joinToString("; ")}.")
            }

            return TransparencyRiskExplanation(
                score = result.transparencyScore,
                reasons = triggers.map { sentence(it, result, resolvedCertainty) },
                scoreBreakdown = if (scoredLow) {
                    qualified(TransparencyScorer.scoreComponents(result), resolvedCertainty)
                } else {
                    emptyList()
                },
                otherConcerns = concerns(result, triggers),
                caveats = caveats,
                certainty = resolvedCertainty,
                isUnassessed = unassessed,
            )
        }

        /** A rule as a sentence about this study. */
        private fun sentence(
            trigger: HighRiskTrigger,
            result: TransparencyResult,
            certainty: TransparencyCertainty,
        ): String =
            when (trigger) {
                is HighRiskTrigger.ScoreBelowThreshold ->
                    "Its transparency score of ${trigger.score}/${TransparencyConstants.MAX_TRANSPARENCY_SCORE} " +
                        "is below the high-risk cut-off of ${trigger.threshold}."

                is HighRiskTrigger.IndustryFundingWithWithheldData -> {
                    val percent = roundHalfAwayFromZero(
                        result.industryFundingConfidence * TransparencyConstants.PERCENT_SCALE,
                    )
                    val funders = result.funders.filter { it.isIndustry }.map { it.name }
                    val funderText = if (funders.isEmpty()) "" else " (${funders.joinToString(", ")})"
                    "Industry funding was detected$funderText, with $percent% confidence, " +
                        "and ${dataPhrase(trigger.level, certainty)}."
                }

                HighRiskTrigger.MissingCOIStatement -> {
                    val found = when (certainty) {
                        TransparencyCertainty.FULL_TEXT ->
                            "No conflict of interest statement was found in the full text."
                        TransparencyCertainty.LIMITED_NO_FULL_TEXT ->
                            "No conflict of interest statement was found; the full text, where one " +
                                "would appear, was not searched."
                        TransparencyCertainty.UNRECORDED ->
                            "No conflict of interest statement was found; whether the full text, " +
                                "where one would appear, was searched was not recorded."
                    }
                    "$found A missing statement is enough on its own for a high rating."
                }
            }

        /** What a data disclosure level says about the study's data. */
        private fun dataPhrase(level: DataDisclosureLevel, certainty: TransparencyCertainty): String =
            when (level) {
                DataDisclosureLevel.RESTRICTED -> "its data are available only with restrictions"
                DataDisclosureLevel.NOT_AVAILABLE -> "its data are not available"
                DataDisclosureLevel.NOT_STATED -> when (certainty) {
                    TransparencyCertainty.FULL_TEXT ->
                        "no data availability statement was found in the full text"
                    TransparencyCertainty.LIMITED_NO_FULL_TEXT ->
                        "no data availability statement was found (the full text, where it would " +
                            "appear, was not searched)"
                    TransparencyCertainty.UNRECORDED ->
                        "no data availability statement was found (whether the full text, where " +
                            "it would appear, was searched was not recorded)"
                }
                DataDisclosureLevel.FULL_OPEN,
                DataDisclosureLevel.AVAILABLE_ON_REQUEST,
                DataDisclosureLevel.UNKNOWN,
                -> "its data availability is ${level.displayName.lowercase()}"
            }

        /**
         * Whether a rule could have been met only because the full text was missing.
         *
         * Statements are looked for only in the full text, so without it the
         * analysis records "no COI statement" and "no data statement" whatever the
         * article says. A low score counts when those two penalties alone carry it
         * below the cut-off.
         */
        private fun dependsOnFullText(trigger: HighRiskTrigger, result: TransparencyResult): Boolean =
            when (trigger) {
                HighRiskTrigger.MissingCOIStatement -> true
                is HighRiskTrigger.IndustryFundingWithWithheldData -> trigger.level == DataDisclosureLevel.NOT_STATED
                is HighRiskTrigger.ScoreBelowThreshold -> {
                    var unsearchedPenalties = 0
                    if (!result.coiAnalysis.hasStatement) {
                        unsearchedPenalties += TransparencyConstants.MISSING_COI_PENALTY
                    }
                    if (result.dataAvailability.disclosureLevel == DataDisclosureLevel.NOT_STATED) {
                        unsearchedPenalties += TransparencyConstants.NO_STATEMENT_PENALTY
                    }
                    trigger.score - unsearchedPenalties >= trigger.threshold
                }
            }

        /**
         * Score terms, with those recording a statement as missing qualified when the full
         * text, the only place it is looked for, was not searched — or may not have been.
         */
        private fun qualified(components: List<ScoreComponent>, certainty: TransparencyCertainty): List<ScoreComponent> {
            val suffix = when (certainty) {
                TransparencyCertainty.FULL_TEXT -> return components
                TransparencyCertainty.LIMITED_NO_FULL_TEXT -> UNSEARCHED_SUFFIX
                TransparencyCertainty.UNRECORDED -> POSSIBLY_UNSEARCHED_SUFFIX
            }
            return components.map {
                if (it.recordsMissingStatement) it.copy(label = it.label + suffix) else it
            }
        }

        /** The result's recorded concerns, less those a stated reason already says. */
        private fun concerns(result: TransparencyResult, triggers: List<HighRiskTrigger>): List<String> {
            val seen = mutableSetOf<String>()
            for (trigger in triggers) {
                when (trigger) {
                    HighRiskTrigger.MissingCOIStatement -> {
                        seen.add(RiskIndicatorStrings.MISSING_COI_STATEMENT)
                        // The service's discrepancy warning says the same, without the
                        // reason's qualification about unsearched text.
                        seen.add(RiskIndicatorStrings.FUNDING_WITHOUT_COI_STATEMENT)
                    }
                    is HighRiskTrigger.IndustryFundingWithWithheldData -> {
                        seen.add(RiskIndicatorStrings.INDUSTRY_FUNDING)
                        seen.add(RiskIndicatorStrings.INDUSTRY_RESTRICTED_DATA)
                    }
                    is HighRiskTrigger.ScoreBelowThreshold -> Unit
                }
            }
            // The no-CrossRef caveat already says the funders were not checked.
            if (TransparencyConstants.CROSSREF_SOURCE_NAME !in result.dataSourcesUsed) {
                seen.add(TransparencyConstants.CROSSREF_UNREACHABLE_WARNING)
            }
            return (result.riskIndicators + result.warnings + result.outcomeSwitchingDetails)
                .filter { seen.add(it) }
        }

        /** Round as Swift's `Double.rounded()` does: to nearest, ties away from zero. */
        private fun roundHalfAwayFromZero(value: Double): Int =
            BigDecimal(value).setScale(0, RoundingMode.HALF_UP).toInt()
    }
}

/**
 * A study rated high risk, as a report lists it.
 *
 * @property reference How the report refers to the study, e.g. "Smith et al., 2020".
 * @property citation The study's full citation.
 * @property explanation Why it was rated high.
 */
data class HighRiskTransparencyEntry(
    val reference: String,
    val citation: String,
    val explanation: TransparencyRiskExplanation,
) {
    /**
     * Creates an entry from a result.
     *
     * @param reference How the report refers to the study.
     * @param citation The study's full citation.
     * @param result Its transparency result.
     * @param certainty What is known of the rating's full-text access, when the caller knows
     *   better than the result's own record.
     */
    constructor(
        reference: String,
        citation: String,
        result: TransparencyResult,
        certainty: TransparencyCertainty? = null,
    ) : this(reference, citation, TransparencyRiskExplanation.of(result, certainty))
}

/** The report section discussing every study rated high transparency risk. */
object HighRiskTransparencySection {
    /** The section's heading. */
    const val HEADING: String = "Why Studies Were Rated High Transparency Risk"

    /** Heads the rules that produced a study's rating. */
    const val REASONS_LABEL: String = "Rated high risk because"

    /** Heads the terms of a study's score. */
    const val SCORE_BREAKDOWN_LABEL: String = "How the score was reached"

    /** Heads the concerns that did not by themselves decide the rating. */
    const val OTHER_CONCERNS_LABEL: String = "Other concerns recorded"

    /** Heads the reasons a rating may rest on less than it appears to. */
    const val CAVEATS_LABEL: String = "Caveats"

    /**
     * The sentence introducing the section.
     *
     * @param count The number of studies rated high.
     * @return The introduction, or null when there are none.
     */
    fun introduction(count: Int): String? {
        if (count <= 0) return null
        val studies = if (count == 1) "1 study was" else "$count studies were"
        return "$studies rated high transparency risk. Each rule listed below is enough " +
            "on its own for that rating; the caveats say where a rating rests on less than " +
            "it appears to."
    }

    /** Heads the rules a high rating would rest on, for a rating shown as unassessed. */
    const val UNASSESSED_REASONS_LABEL: String = "A high rating would rest only on"

    /**
     * The sentence accounting for ratings shown as unassessed.
     *
     * @param count The number of studies shown as unassessed.
     * @return The sentence, or null when there are none.
     */
    fun unassessedSummary(count: Int): String? {
        if (count <= 0) return null
        val studies = if (count == 1) "1 study is" else "$count studies are"
        return "$studies shown as unassessed rather than high risk: every reason for a high " +
            "rating depends on statements that appear only in the full text, which was not " +
            "available to search."
    }

    /**
     * The section as plain text, for copied, shared and exported reports.
     *
     * @param entries The studies rated high, in the order to list them.
     * @param unassessedCount How many studies are shown as unassessed instead.
     * @return The section, or null when there is nothing to say.
     */
    fun plainText(entries: List<HighRiskTransparencyEntry>, unassessedCount: Int = 0): String? {
        val unassessed = unassessedSummary(unassessedCount)
        val introduction = introduction(entries.size)
            ?: return unassessed?.let { "${HEADING.uppercase()}\n\n$it" }
        val lines = mutableListOf(HEADING.uppercase(), "", introduction)
        if (unassessed != null) lines.addAll(listOf("", unassessed))
        for (entry in entries) {
            lines.add("")
            lines.add("${entry.reference}: ${entry.citation}")
            lines.addAll(entry.explanation.plainTextLines)
        }
        return lines.joinToString("\n")
    }
}
