package com.bmlibrarian.factchecker.domain.transparency

import java.util.regex.PatternSyntaxException

/**
 * Pattern matching with the semantics of Swift's `RegexHelper` (BioMedLit),
 * used by the funder, COI and trial analyzers.
 *
 * Differs from [RegexHelper] (which the data-availability classifier uses) in
 * the ways Swift's helper does, so those analyzers classify identically on both
 * platforms:
 *  - every pattern is matched **case-insensitively**;
 *  - [anyMatch], [countMatches], [extractFirst] and [extractAll] lowercase the
 *    text first, so captured groups come back lowercased; [findAll] alone keeps
 *    the text's original case (for identifiers such as NCT IDs);
 *  - an invalid pattern is skipped (Swift's `try?` returns nil), never thrown.
 *
 * Patterns are compiled through [RegexHelper.compile], so the `(?U)` flag that
 * gives `\w`, `\b`, `\s` and `\d` the same Unicode reach as Python and ICU is
 * the one the data-availability classifier uses, not a second copy of it.
 */
object TransparencyRegex {

    /**
     * Compile a case-insensitive regex.
     *
     * @param pattern The regex source.
     * @return The compiled regex, or null when the pattern is invalid.
     */
    fun regex(pattern: String): Regex? =
        try {
            RegexHelper.compile(pattern, ignoreCase = true)
        } catch (e: PatternSyntaxException) {
            null
        }

    /**
     * Whether any pattern matches the lowercased text.
     *
     * @param patterns Regex sources to try, in order.
     * @param text Text to search.
     * @return True if at least one valid pattern matches.
     */
    fun anyMatch(patterns: List<String>, text: String): Boolean {
        val lowercased = text.lowercase()
        return patterns.any { pattern -> regex(pattern)?.containsMatchIn(lowercased) == true }
    }

    /**
     * Total number of matches of all patterns in the lowercased text.
     *
     * @param patterns Regex sources to count.
     * @param text Text to search.
     * @return The sum of each valid pattern's non-overlapping match count.
     */
    fun countMatches(patterns: List<String>, text: String): Int {
        val lowercased = text.lowercase()
        return patterns.sumOf { pattern -> regex(pattern)?.findAll(lowercased)?.count() ?: 0 }
    }

    /**
     * Capture group 1 of the first match in the lowercased text.
     *
     * @param pattern Regex source with at least one capture group.
     * @param text Text to search.
     * @return The lowercased capture, or null if nothing matched or group 1 did not participate.
     */
    fun extractFirst(pattern: String, text: String): String? {
        val lowercased = text.lowercase()
        return regex(pattern)?.find(lowercased)?.groups?.get(1)?.value
    }

    /**
     * Capture group 1 of every match in the lowercased text.
     *
     * @param pattern Regex source with at least one capture group.
     * @param text Text to search.
     * @return Every participating group-1 capture, lowercased, in match order.
     */
    fun extractAll(pattern: String, text: String): List<String> {
        val lowercased = text.lowercase()
        val compiled = regex(pattern) ?: return emptyList()
        return compiled.findAll(lowercased).mapNotNull { it.groups[1]?.value }.toList()
    }

    /**
     * Every full match of a pattern, keeping the text's original case.
     *
     * @param pattern Regex source (matched case-insensitively).
     * @param text Text to search.
     * @return Each matched substring as it appears in [text], in order.
     */
    fun findAll(pattern: String, text: String): List<String> {
        val compiled = regex(pattern) ?: return emptyList()
        return compiled.findAll(text).map { it.value }.toList()
    }
}
