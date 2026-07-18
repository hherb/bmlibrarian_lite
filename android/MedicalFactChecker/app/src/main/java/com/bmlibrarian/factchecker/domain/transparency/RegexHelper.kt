package com.bmlibrarian.factchecker.domain.transparency

/**
 * Small regex helpers shared by the transparency analyzers.
 *
 * Classification patterns are matched against text that has already been
 * lowercased (the patterns themselves are lowercase), mirroring the Python
 * reference's `re.search(pattern, text_lower)`.
 *
 * **Unicode parity:** every pattern is compiled with the `(?U)`
 * (`UNICODE_CHARACTER_CLASS`) flag so `\w`, `\s`, `\b` and `\d` match the same
 * code points as the canonical Python `re` engine (whose `str` patterns are
 * Unicode-aware) and the Swift ICU `NSRegularExpression`. Kotlin/Java regex
 * otherwise defaults these classes to ASCII only, which would silently diverge
 * from the other two platforms on non-ASCII input — e.g. an accented
 * intervening word in a `(?:\w+ )?` group would be skipped on Python/Swift but
 * not on Android. The `(?U)` prefix keeps the byte-identical pattern strings
 * themselves unchanged.
 *
 * No compiled-pattern caching — single-statement labeling is not a hot path
 * (see the Swift #111 follow-up).
 */
object RegexHelper {

    /** Inline flag enabling Unicode-aware `\w`/`\s`/`\b`/`\d` (see class KDoc). */
    private const val UNICODE_FLAG = "(?U)"

    /** Compile [pattern] with Unicode character classes, optionally case-insensitive. */
    private fun compile(pattern: String, ignoreCase: Boolean = false): Regex =
        if (ignoreCase) {
            Regex(UNICODE_FLAG + pattern, RegexOption.IGNORE_CASE)
        } else {
            Regex(UNICODE_FLAG + pattern)
        }

    /** True if [pattern] occurs anywhere in [text]. */
    fun matches(pattern: String, text: String): Boolean =
        compile(pattern).containsMatchIn(text)

    /** True if any [patterns] entry occurs anywhere in [text]. */
    fun anyMatch(patterns: List<String>, text: String): Boolean =
        patterns.any { matches(it, text) }

    /** The full first match of [pattern] in [text], or null. */
    fun firstMatch(pattern: String, text: String): String? =
        compile(pattern).find(text)?.value

    /**
     * Capture group 1 of the first match of [pattern] in [text], or null.
     * [ignoreCase] mirrors Python's `re.I`, used for accession extraction.
     */
    fun firstGroup(pattern: String, text: String, ignoreCase: Boolean = false): String? =
        compile(pattern, ignoreCase).find(text)?.groupValues?.getOrNull(1)
}
