package com.bmlibrarian.factchecker.domain.transparency

/**
 * Small regex helpers shared by the transparency analyzers.
 *
 * Classification patterns are matched against text that has already been
 * lowercased (the patterns themselves are lowercase), mirroring the Python
 * reference's `re.search(pattern, text_lower)`. No compiled-pattern caching —
 * single-statement labeling is not a hot path (see the Swift #111 follow-up).
 */
object RegexHelper {

    /** True if any [patterns] entry occurs anywhere in [text]. */
    fun anyMatch(patterns: List<String>, text: String): Boolean =
        patterns.any { Regex(it).containsMatchIn(text) }

    /** The full first match of [pattern] in [text], or null. */
    fun firstMatch(pattern: String, text: String): String? =
        Regex(pattern).find(text)?.value

    /**
     * Capture group 1 of the first match of [pattern] in [text], or null.
     * [ignoreCase] mirrors Python's `re.I`, used for accession extraction.
     */
    fun firstGroup(pattern: String, text: String, ignoreCase: Boolean = false): String? {
        val regex = if (ignoreCase) Regex(pattern, RegexOption.IGNORE_CASE) else Regex(pattern)
        return regex.find(text)?.groupValues?.getOrNull(1)
    }
}
