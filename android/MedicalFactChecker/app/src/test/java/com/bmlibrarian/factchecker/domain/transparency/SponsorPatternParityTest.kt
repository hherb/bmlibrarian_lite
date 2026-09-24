package com.bmlibrarian.factchecker.domain.transparency

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Binds Android to the sponsor-pattern contract, `sponsor_patterns.json` (#147,
 * #152), as `TransparencyParityTests` binds Swift and
 * `TestSponsorPatternManifestParity` binds Python.
 *
 * The two halves are asserted string-for-string and order-sensitively: the
 * government half is tested first in [FundingAnalyzer.determineSponsorType], and
 * the concatenation is what [FundingAnalyzer.classifyFunder] treats as "not
 * industry", so adding, dropping or moving one pattern either re-tiers sponsors
 * or moves the industry boundary that feeds a HIGH-risk rule. The confidence
 * ladder is asserted behaviourally, by classifying each layer's probe.
 */
class SponsorPatternParityTest {

    @Serializable
    private data class ConfidenceProbe(
        val layer: String,
        val name: String,
        val doi: String? = null,
        @SerialName("is_industry") val isIndustry: Boolean,
    )

    @Serializable
    private data class SponsorManifest(
        val patterns: Map<String, List<String>>,
        val confidences: Map<String, Double>,
        @SerialName("confidence_probes") val confidenceProbes: List<ConfidenceProbe>,
        @SerialName("pattern_probes") val patternProbes: List<String>,
    )

    private companion object {
        val manifest: SponsorManifest by lazy {
            ParityFixtures.json.decodeFromString(SponsorManifest.serializer(), ParityFixtures.read("sponsor_patterns.json"))
        }

        fun half(name: String): List<String> =
            requireNotNull(manifest.patterns[name]) { "shared sponsor contract has no '$name' half" }

        const val CONFIDENCE_TOLERANCE = 1e-9
    }

    // ==================== pattern strings ====================

    @Test
    fun `government patterns match the shared contract`() {
        ParityFixtures.assertPatternsMatch(IndustryPatterns.governmentPatterns, half("government"), "government")
    }

    @Test
    fun `academic patterns match the shared contract`() {
        ParityFixtures.assertPatternsMatch(IndustryPatterns.academicPatterns, half("academic"), "academic")
    }

    @Test
    fun `non-industry patterns are the contract halves in order`() {
        ParityFixtures.assertPatternsMatch(
            IndustryPatterns.nonIndustryPatterns,
            half("government") + half("academic"),
            "government + academic",
        )
    }

    @Test
    fun `the contract sponsor halves are disjoint`() {
        val overlap = half("government").toSet().intersect(half("academic").toSet())
        assertTrue("a pattern appears in both sponsor halves: $overlap", overlap.isEmpty())
    }

    /** An emptied half would pass a list comparison against an emptied Kotlin list. */
    @Test
    fun `neither sponsor half is empty`() {
        assertFalse(half("government").isEmpty())
        assertFalse(half("academic").isEmpty())
        assertFalse(IndustryPatterns.governmentPatterns.isEmpty())
        assertFalse(IndustryPatterns.academicPatterns.isEmpty())
    }

    // ==================== probes ====================

    /** A typo transcribed faithfully into every platform agrees with itself; a probe catches it. */
    @Test
    fun `every contract sponsor pattern is exercised by a probe`() {
        val probes = manifest.patternProbes.map { it.lowercase() }
        for ((tier, patterns) in manifest.patterns) {
            for (pattern in patterns) {
                assertTrue(
                    "'$tier' pattern $pattern is matched by no probe name in the contract",
                    probes.any { RegexHelper.matches(pattern, it) },
                )
            }
        }
    }

    @Test
    fun `every sponsor pattern probe is non-industry`() {
        for (name in manifest.patternProbes) {
            assertFalse("'$name' classified as industry", FundingAnalyzer.classifyFunder(name).isIndustry)
        }
    }

    // ==================== confidence ladder ====================

    @Test
    fun `every probe reports the contract confidence`() {
        for (probe in manifest.confidenceProbes) {
            val expected = requireNotNull(manifest.confidences[probe.layer]) {
                "contract has no confidence for layer '${probe.layer}'"
            }
            val (isIndustry, confidence) = FundingAnalyzer.classifyFunder(probe.name, probe.doi)
            assertEquals("'${probe.name}' (${probe.layer}) isIndustry", probe.isIndustry, isIndustry)
            assertEquals(
                "'${probe.name}' reported $confidence, contract says $expected for layer '${probe.layer}'",
                expected,
                confidence,
                CONFIDENCE_TOLERANCE,
            )
        }
    }

    @Test
    fun `every contract layer has a probe`() {
        assertEquals(manifest.confidences.keys, manifest.confidenceProbes.map { it.layer }.toSet())
    }

    @Test
    fun `the confidence ladder is strictly descending`() {
        val ladder = listOf("known_industry_doi", "government_pattern", "academic_pattern", "industry_name", "unknown")
        val values = ladder.map { requireNotNull(manifest.confidences[it]) { "contract has no layer '$it'" } }
        assertEquals(values.sortedDescending(), values)
        assertEquals("two layers share a confidence", values.size, values.toSet().size)
    }
}
