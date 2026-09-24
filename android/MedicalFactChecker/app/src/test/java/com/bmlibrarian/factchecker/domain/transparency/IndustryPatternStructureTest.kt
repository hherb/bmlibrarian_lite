package com.bmlibrarian.factchecker.domain.transparency

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Structural checks on the industry pattern lists (port of the Swift
 * `IndustryPatternStructureTests`).
 *
 * A pattern that matches nothing moves no corpus metric, so these catch the
 * dead entries the corpus cannot: an invalid regex (skipped for good by
 * [TransparencyRegex.regex]), a `\b` pattern in the substring list, or an
 * uppercase stem that can never meet a lowercased name.
 */
class IndustryPatternStructureTest {

    @Test
    fun `every stem is lowercased`() {
        for (stem in IndustryPatterns.funderNameStems) {
            assertEquals("'$stem' can never match: names are lowercased first", stem.lowercase(), stem)
        }
    }

    @Test
    fun `no stem is a regex source`() {
        for (stem in IndustryPatterns.funderNameStems) {
            assertFalse("'$stem' is a regex source in the substring list", stem.contains("\\"))
        }
    }

    @Test
    fun `no stem is empty`() {
        for (stem in IndustryPatterns.funderNameStems) assertFalse("an empty stem matches every name", stem.isEmpty())
    }

    @Test
    fun `every funder name word compiles`() {
        for (pattern in IndustryPatterns.funderNameWords) {
            assertNotNull("'$pattern' is not a valid regex", TransparencyRegex.regex(pattern))
        }
    }

    @Test
    fun `every industry keyword compiles`() {
        for (pattern in IndustryPatterns.industryKeywords) {
            assertNotNull("'$pattern' is not a valid regex", TransparencyRegex.regex(pattern))
        }
    }

    /** Android compiles through the (?U) helper; every sponsor and COI pattern must survive it too. */
    @Test
    fun `every sponsor, COI and trial pattern compiles`() {
        val patterns = IndustryPatterns.nonIndustryPatterns + COIPatterns.noConflictPatterns +
            COIPatterns.relationshipPatterns + COIPatterns.institutionalIntermediaryPatterns +
            FullTextSections.coiPatterns + FullTextSections.dataAvailabilityPatterns +
            ClinicalTrialPatterns.NCT_ID_PATTERN
        for (pattern in patterns) assertNotNull("'$pattern' is not a valid regex", TransparencyRegex.regex(pattern))
    }

    @Test
    fun `every funder name word is word anchored`() {
        for (pattern in IndustryPatterns.funderNameWords) {
            assertTrue(
                "'$pattern' is unanchored in the whole-word list",
                pattern.startsWith("\\b") && pattern.endsWith("\\b"),
            )
        }
    }

    @Test
    fun `COI prose phrases stay out of the funder lists`() {
        val funderPatterns = IndustryPatterns.funderNameWords.toSet()
        for (phrase in IndustryPatterns.industryKeywords.filter { it.contains(" ") }) {
            assertFalse("'$phrase' is a COI prose phrase", phrase in funderPatterns)
        }
    }
}
