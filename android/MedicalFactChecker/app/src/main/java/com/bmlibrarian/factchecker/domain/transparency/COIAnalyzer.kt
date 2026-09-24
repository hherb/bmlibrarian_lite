package com.bmlibrarian.factchecker.domain.transparency

import kotlin.math.min

/**
 * Pure functions analysing conflict-of-interest statements.
 *
 * Ported from the Swift `COIAnalyzer` (BioMedLit): detects industry ties,
 * extracts disclosed relationships, and checks consistency between funding
 * and COI disclosure.
 */
object COIAnalyzer {

    /** Confidence when an explicit "no conflicts" declaration is found. */
    private const val NO_CONFLICT_CONFIDENCE: Double = 0.9

    /** Base confidence when industry ties are detected. */
    private const val INDUSTRY_TIES_BASE_CONFIDENCE: Double = 0.5

    /** Confidence added per industry keyword match. */
    private const val INDUSTRY_MATCH_CONFIDENCE_INCREMENT: Double = 0.1

    /** Maximum confidence of an industry-ties detection. */
    private const val MAX_INDUSTRY_CONFIDENCE: Double = 0.95

    /** Confidence when a statement exists but says nothing either way. */
    private const val UNCERTAIN_CONFIDENCE: Double = 0.5

    /** Confidence at or above which disclosed ties count as significant. */
    private const val SIGNIFICANT_TIES_CONFIDENCE: Double = 0.8

    /** More disclosed relationships than this count as significant ties. */
    private const val SIGNIFICANT_RELATIONSHIP_COUNT: Int = 1

    /**
     * Analyse a COI statement for industry ties.
     *
     * An explicit "no conflicts" declaration wins outright; otherwise industry
     * keywords are counted (confidence 0.5 + 0.1 per match, capped at 0.95) and
     * disclosed relationships extracted.
     *
     * @param statement The COI statement, or null when none was found.
     * @return The analysis; [COIAnalysisResult.NOT_AVAILABLE] for a null or empty statement.
     */
    fun analyze(statement: String?): COIAnalysisResult {
        if (statement.isNullOrEmpty()) return COIAnalysisResult.NOT_AVAILABLE

        val statementLower = statement.lowercase()

        if (containsNoConflictDeclaration(statementLower)) {
            return COIAnalysisResult(
                statement = statement,
                hasIndustryTies = false,
                disclosedRelationships = emptyList(),
                confidence = NO_CONFLICT_CONFIDENCE,
            )
        }

        val industryMatchCount = countIndustryMatches(statementLower)
        val hasIndustryTies = industryMatchCount > 0
        val confidence = if (hasIndustryTies) {
            min(
                INDUSTRY_TIES_BASE_CONFIDENCE + industryMatchCount * INDUSTRY_MATCH_CONFIDENCE_INCREMENT,
                MAX_INDUSTRY_CONFIDENCE,
            )
        } else {
            UNCERTAIN_CONFIDENCE
        }

        return COIAnalysisResult(
            statement = statement,
            hasIndustryTies = hasIndustryTies,
            disclosedRelationships = extractRelationships(statementLower),
            confidence = confidence,
        )
    }

    /**
     * Whether a statement explicitly declares no conflicts.
     *
     * @param text Statement text (matched case-insensitively).
     * @return True if a no-conflict pattern matches.
     */
    fun containsNoConflictDeclaration(text: String): Boolean =
        TransparencyRegex.anyMatch(COIPatterns.noConflictPatterns, text)

    /**
     * Count industry keyword matches (company forms and relationship terms).
     *
     * @param text Text to analyse.
     * @return The number of matches across [IndustryPatterns.industryKeywords].
     */
    fun countIndustryMatches(text: String): Int =
        TransparencyRegex.countMatches(IndustryPatterns.industryKeywords, text)

    /**
     * Extract disclosed relationships ("received grants from [company]" and similar).
     *
     * Swift deduplicates through a `Set` and so returns them in no defined
     * order; here duplicates are dropped keeping first-seen order.
     *
     * @param text Statement text.
     * @return The trimmed, lowercased relationship captures, without duplicates.
     */
    fun extractRelationships(text: String): List<String> =
        COIPatterns.relationshipPatterns
            .flatMap { TransparencyRegex.extractAll(it, text) }
            .map { it.trim() }
            .distinct()

    /**
     * A warning when industry funding was detected but the COI statement does not reflect it.
     *
     * @param coiResult The COI analysis.
     * @param industryFundingDetected Whether the funding analysis found industry funding.
     * @return The warning, or null when there is no discrepancy.
     */
    fun checkFundingCOIDiscrepancy(coiResult: COIAnalysisResult, industryFundingDetected: Boolean): String? {
        if (!industryFundingDetected) return null
        if (coiResult.statement != null && !coiResult.hasIndustryTies) {
            return "Industry funding detected but COI statement does not mention industry ties"
        }
        if (coiResult.statement == null) {
            return "Industry funding detected but no COI statement found"
        }
        return null
    }

    /**
     * Whether disclosed industry ties warrant closer scrutiny: more than one
     * relationship, or a confidence of at least 0.8.
     *
     * @param result The COI analysis.
     * @return True for significant ties.
     */
    fun hasSignificantIndustryTies(result: COIAnalysisResult): Boolean =
        result.hasIndustryTies &&
            (result.disclosedRelationships.size > SIGNIFICANT_RELATIONSHIP_COUNT ||
                result.confidence >= SIGNIFICANT_TIES_CONFIDENCE)

    /**
     * A one-line summary of a COI analysis for display.
     *
     * @param result The COI analysis.
     * @return The summary.
     */
    fun formatSummary(result: COIAnalysisResult): String {
        if (result.statement == null) return "No conflict of interest statement found"
        if (!result.hasIndustryTies) return "No conflicts declared"
        val relationshipCount = result.disclosedRelationships.size
        if (relationshipCount > 0) {
            val suffix = if (relationshipCount == 1) "" else "s"
            return "Industry ties disclosed ($relationshipCount relationship$suffix)"
        }
        return "Industry ties indicated"
    }

    /**
     * Disclosed relationships as display text, each capitalised, joined with "; ".
     *
     * @param relationships Relationship descriptions.
     * @return The formatted list, or "None disclosed" when empty.
     */
    fun formatRelationships(relationships: List<String>): String {
        if (relationships.isEmpty()) return "None disclosed"
        return relationships.joinToString("; ") { capitalized(it) }
    }

    /**
     * Capitalise every word the way Foundation's `String.capitalized` does:
     * the first character of each whitespace-delimited word upper-cased, every
     * other character lower-cased.
     */
    internal fun capitalized(text: String): String {
        val builder = StringBuilder(text.length)
        var atWordStart = true
        for (character in text) {
            builder.append(if (atWordStart) character.uppercaseChar() else character.lowercaseChar())
            atWordStart = character.isWhitespace()
        }
        return builder.toString()
    }
}
