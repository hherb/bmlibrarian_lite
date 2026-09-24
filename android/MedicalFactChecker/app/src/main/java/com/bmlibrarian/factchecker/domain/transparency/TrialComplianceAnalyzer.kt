package com.bmlibrarian.factchecker.domain.transparency

import java.time.Instant
import java.time.ZoneId

/**
 * The outcome of comparing registered with reported trial outcomes.
 *
 * @property detected True if a registered outcome appears to be missing from the report.
 * @property details Human-readable descriptions of each discrepancy.
 */
data class OutcomeSwitchingResult(val detected: Boolean, val details: List<String>)

/**
 * Pure functions analysing clinical-trial registration and compliance.
 *
 * Ported from the Swift `TrialComplianceAnalyzer` (BioMedLit): FDAAA results
 * compliance, trial detection from titles, NCT ID extraction and a simple
 * outcome-switching check.
 */
object TrialComplianceAnalyzer {

    /** Word-overlap ratio above which a reported outcome counts as matching a registered one. */
    private const val OUTCOME_WORD_OVERLAP_THRESHOLD: Double = 0.5

    /** The sponsor class ClinicalTrials.gov reports for an industry sponsor. */
    private const val INDUSTRY_SPONSOR_CLASS: String = "INDUSTRY"

    /** Appended to an outcome description shortened for display. */
    private const val ELLIPSIS: String = "..."

    /**
     * Whether a trial's results posting complies with FDAAA 2007 (results within
     * 12 months of completion).
     *
     * Posted results are compliant. Unposted results are missing once the
     * deadline — completion plus [TransparencyConstants.RESULTS_COMPLIANCE_DEADLINE_DAYS]
     * calendar days in the device's time zone, as Swift's `Calendar.current`
     * computes it — has passed, and unknown before that or without a completion date.
     *
     * @param trial The trial registration.
     * @param publicationDate The article's publication date (unused, reserved for late detection, as in Swift).
     * @param now The current time; a parameter only so tests can fix it.
     * @return The compliance status.
     */
    @Suppress("UNUSED_PARAMETER")
    fun checkResultsCompliance(
        trial: TrialRegistration,
        publicationDate: Instant?,
        now: Instant = Instant.now(),
    ): ResultsComplianceStatus {
        if (trial.resultsPosted) return ResultsComplianceStatus.COMPLIANT

        val completionDate = trial.completionDate ?: return ResultsComplianceStatus.UNKNOWN
        val deadline = completionDate.atZone(ZoneId.systemDefault())
            .plusDays(TransparencyConstants.RESULTS_COMPLIANCE_DEADLINE_DAYS.toLong())
            .toInstant()

        return if (now.isAfter(deadline)) ResultsComplianceStatus.MISSING else ResultsComplianceStatus.UNKNOWN
    }

    /**
     * Whether a title suggests a clinical trial ("randomized", "RCT", "phase II", "trial", ...).
     *
     * @param title The study title, or null.
     * @return True if any [ClinicalTrialPatterns.trialKeywords] occurs in the lowercased title.
     */
    fun appearsToBeClinicalTrial(title: String?): Boolean {
        if (title == null) return false
        val titleLower = title.lowercase()
        return ClinicalTrialPatterns.trialKeywords.any { titleLower.contains(it) }
    }

    /**
     * Extract ClinicalTrials.gov NCT IDs (NCT + 8 digits) from text.
     *
     * @param text Text to search.
     * @return The IDs as they appear in [text], in order.
     */
    fun extractNCTIds(text: String): List<String> =
        TransparencyRegex.findAll(ClinicalTrialPatterns.NCT_ID_PATTERN, text)

    /**
     * Whether a ClinicalTrials.gov sponsor class denotes industry.
     *
     * @param sponsorClass The sponsor class (e.g. "INDUSTRY", "NIH", "OTHER"), or null.
     * @return True for "INDUSTRY", in any case.
     */
    fun isIndustrySponsor(sponsorClass: String?): Boolean =
        sponsorClass?.uppercase() == INDUSTRY_SPONSOR_CLASS

    /**
     * Check for potential outcome switching by word overlap.
     *
     * A registered outcome counts as reported when more than half of its words
     * appear in some reported outcome. A simplified check; semantic matching
     * would need NLP.
     *
     * @param registered Registered outcomes.
     * @param reported Outcomes extracted from the publication.
     * @return Whether switching was detected, with one detail per unmatched registered outcome.
     */
    fun checkOutcomeSwitching(registered: List<String>, reported: List<String>): OutcomeSwitchingResult {
        if (registered.isEmpty()) return OutcomeSwitchingResult(detected = false, details = emptyList())
        if (reported.isEmpty()) {
            return OutcomeSwitchingResult(
                detected = false,
                details = listOf("Unable to compare - no reported outcomes extracted"),
            )
        }

        val registeredLower = registered.map { it.lowercase() }.toCollection(LinkedHashSet())
        val reportedLower = reported.map { it.lowercase() }.toCollection(LinkedHashSet())
        val details = mutableListOf<String>()

        for (outcome in registeredLower) {
            val outcomeWords = words(outcome)
            val found = reportedLower.any { candidate ->
                if (outcomeWords.isEmpty()) return@any false
                val overlap = outcomeWords.intersect(words(candidate))
                overlap.size.toDouble() / outcomeWords.size > OUTCOME_WORD_OVERLAP_THRESHOLD
            }
            if (!found) {
                val maxLength = TransparencyConstants.MAX_OUTCOME_DESCRIPTION_LENGTH
                val suffix = if (outcome.length > maxLength) ELLIPSIS else ""
                details.add("Registered outcome may not be reported: ${outcome.take(maxLength)}$suffix")
            }
        }

        return OutcomeSwitchingResult(detected = details.isNotEmpty(), details = details)
    }

    /**
     * The distinct words of [text], split on spaces and tabs as Swift's
     * `CharacterSet.whitespaces` does (line breaks are not separators).
     */
    private fun words(text: String): Set<String> =
        text.splitWhere { it == '\t' || Character.getType(it) == Character.SPACE_SEPARATOR.toInt() }
            .filter { it.isNotEmpty() }
            .toSet()

    /** Split on every character matching [isSeparator]. */
    private inline fun String.splitWhere(isSeparator: (Char) -> Boolean): List<String> {
        val parts = mutableListOf<String>()
        val current = StringBuilder()
        for (character in this) {
            if (isSeparator(character)) {
                parts.add(current.toString())
                current.clear()
            } else {
                current.append(character)
            }
        }
        parts.add(current.toString())
        return parts
    }

    /**
     * A one-line summary of trial registration and results compliance.
     *
     * @param registrations Registrations found for the study.
     * @param compliance Results compliance status.
     * @return The summary.
     */
    fun formatSummary(registrations: List<TrialRegistration>, compliance: ResultsComplianceStatus): String {
        if (registrations.isEmpty()) return "No trial registration found"

        val regCount = registrations.size
        val resultsPosted = registrations.count { it.resultsPosted }
        val parts = mutableListOf("$regCount trial registration${if (regCount == 1) "" else "s"} found")

        if (resultsPosted > 0) parts.add("$resultsPosted with results posted")

        when (compliance) {
            ResultsComplianceStatus.COMPLIANT -> parts.add("Results compliant")
            ResultsComplianceStatus.LATE -> parts.add("Results posted late")
            ResultsComplianceStatus.MISSING -> parts.add("Results missing")
            ResultsComplianceStatus.NOT_REQUIRED, ResultsComplianceStatus.UNKNOWN -> Unit
        }

        return parts.joinToString("; ")
    }

    /**
     * A warning when a study looks like a clinical trial but no registration was found.
     *
     * Only a registry's answer can say a registration is missing: with no trial ID to look
     * up, or no answer, the list is empty for a reason that is not the study's, so nothing is
     * said (mirrors Python's `trial_registration_assessed` gate).
     *
     * @param title The study title.
     * @param registrations Registrations found (empty if none).
     * @param registrationAssessed Whether ClinicalTrials.gov answered for every trial the
     *   article cites.
     * @return [RiskIndicatorStrings.MISSING_TRIAL_REGISTRATION], or null.
     */
    fun checkMissingRegistration(
        title: String?,
        registrations: List<TrialRegistration>,
        registrationAssessed: Boolean,
    ): String? {
        if (!registrationAssessed || registrations.isNotEmpty() || !appearsToBeClinicalTrial(title)) return null
        return RiskIndicatorStrings.MISSING_TRIAL_REGISTRATION
    }

    /**
     * Warning for a trial whose registry lookup failed (network, server or HTTP error): its
     * registration was not checked, not found missing.
     *
     * @param nctId The trial's NCT ID.
     * @return The warning, worded as the Python reference words it.
     */
    fun registryUnreachableWarning(nctId: String): String =
        "Could not reach ClinicalTrials.gov for trial $nctId, so its registration could " +
            "not be checked. Absence of a registration is not evidence the study is unregistered."

    /**
     * Warning for a trial ClinicalTrials.gov answered it holds no record of.
     *
     * @param nctId The trial's NCT ID.
     * @return The warning — a finding about the study, not about the lookup.
     */
    fun registryHasNoRecordWarning(nctId: String): String =
        "ClinicalTrials.gov holds no record of trial $nctId, which the article cites as its registration."

    /**
     * Warning for a registry record that arrived but could not be read.
     *
     * @param nctId The trial's NCT ID.
     * @return The warning; an unread record is not an absent one.
     */
    fun unreadableRegistryRecordWarning(nctId: String): String =
        "ClinicalTrials.gov returned a record for trial $nctId that could not be read, so its " +
            "registration could not be checked."
}
