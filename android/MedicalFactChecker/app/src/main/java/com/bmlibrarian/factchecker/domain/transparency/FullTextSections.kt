package com.bmlibrarian.factchecker.domain.transparency

/**
 * Finds the conflict-of-interest and data-availability statements in an
 * article's full text.
 *
 * Ported from the private helpers of the Swift `TransparencyAnalysisService`.
 * Each pattern captures from a section heading to the next blank line (or the
 * end of the text); the first pattern whose capture is non-blank wins. As in
 * Swift, matching runs on the **lowercased** text, so the statement returned —
 * and stored in the result — is lowercased.
 *
 * A heading these patterns do not recognise yields null, which the analysis
 * then records as "no statement": an unrecognised statement reads as an absent one.
 */
object FullTextSections {

    /**
     * An optional trailing word of a statement's heading, as the canonical Python extractor
     * allows (#359 there): "Data Availability Statement" and "Conflict of Interest Statement"
     * are the commonest spellings, and without it the heading's last word was captured as the
     * statement itself. Same pattern as Swift's `TransparencyAnalysisService.headingQualifier`.
     */
    const val HEADING_QUALIFIER: String = """(?:\s+(?:statements?|disclosures?|declarations?|section))?"""

    /** Data-availability section headings, in the order they are tried. */
    val dataAvailabilityPatterns: List<String> = listOf(
        """(?i)data\s+availability""" + HEADING_QUALIFIER + """[:\s]+([^§]+?)(?=\n\n|\z)""",
        """(?i)availability\s+of\s+data""" + HEADING_QUALIFIER + """[:\s]+([^§]+?)(?=\n\n|\z)""",
        """(?i)data\s+sharing""" + HEADING_QUALIFIER + """[:\s]+([^§]+?)(?=\n\n|\z)""",
        """(?i)data\s+access""" + HEADING_QUALIFIER + """[:\s]+([^§]+?)(?=\n\n|\z)""",
    )

    /** Conflict-of-interest section headings, in the order they are tried. */
    val coiPatterns: List<String> = listOf(
        """(?i)conflict(?:s)?\s+of\s+interest""" + HEADING_QUALIFIER + """[:\s]+([^§]+?)(?=\n\n|\z)""",
        """(?i)competing\s+interest(?:s)?""" + HEADING_QUALIFIER + """[:\s]+([^§]+?)(?=\n\n|\z)""",
        """(?i)disclosure(?:s)?""" + HEADING_QUALIFIER + """[:\s]+([^§]+?)(?=\n\n|\z)""",
        """(?i)financial\s+disclosure(?:s)?""" + HEADING_QUALIFIER + """[:\s]+([^§]+?)(?=\n\n|\z)""",
    )

    /**
     * The data-availability statement of a full text.
     *
     * @param fullText The article's full text.
     * @return The lowercased, trimmed statement, or null if no heading matched.
     */
    fun extractDataAvailability(fullText: String): String? = firstSection(dataAvailabilityPatterns, fullText)

    /**
     * The conflict-of-interest statement of a full text.
     *
     * @param fullText The article's full text.
     * @return The lowercased, trimmed statement, or null if no heading matched.
     */
    fun extractCoi(fullText: String): String? = firstSection(coiPatterns, fullText)

    /** The first non-blank trimmed capture of [patterns], tried in order. */
    private fun firstSection(patterns: List<String>, fullText: String): String? {
        for (pattern in patterns) {
            val trimmed = TransparencyRegex.extractFirst(pattern, fullText)?.trim()
            if (!trimmed.isNullOrEmpty()) return trimmed
        }
        return null
    }
}
