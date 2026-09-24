package com.bmlibrarian.factchecker.domain.transparency

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Pins *which* corpus names the classifier gets right and wrong, not just how many.
 *
 * Port of the Swift `FunderCorpusCompositionTests`, with the same three name
 * sets. The precision/recall floors cannot see a swap (one recognised funder
 * traded for another) and tolerate losing a true positive outright; pinning the
 * names is what makes Android, Swift and Python one parity check rather than
 * three independent claims — none can drift without failing its own copy.
 */
class FunderCorpusCompositionTest {

    @Test
    fun `true positive composition is unchanged`() {
        assertEquals(EXPECTED_TRUE_POSITIVES, FunderCorpus.classify().truePositives)
    }

    @Test
    fun `false positive composition is unchanged`() {
        assertEquals(EXPECTED_FALSE_POSITIVES, FunderCorpus.classify().falsePositives)
    }

    @Test
    fun `false negative composition is unchanged`() {
        assertEquals(EXPECTED_FALSE_NEGATIVES, FunderCorpus.classify().falseNegatives)
    }

    /** Every figure is a fraction of these counts, and the corpus is shared byte-for-byte with bmlib. */
    @Test
    fun `the labelled corpus is unchanged`() {
        val entries = FunderCorpus.entries
        assertEquals(417, entries.size)
        assertEquals(30, entries.count { it.label == "industry" })
        assertEquals(382, entries.count { it.label == "not_industry" })
        assertEquals(5, entries.count { it.label == "ambiguous" })
    }

    private companion object {
        /** The ten industry funders recognised — each by a legal suffix or company-form stem. */
        val EXPECTED_TRUE_POSITIVES = setOf(
            "Astex Pharmaceuticals, Inc.",
            "Cardinal Health, LLC",
            "Chia Tai Tianqing Pharmaceutical Group Co., Ltd.",
            "Chugai Pharmaceutical Co., Ltd",
            "Dr. Reddy's Laboratories, Hyderabad, India",
            "Geneos Therapeutics",
            "ImmVira Co., Limited",
            "NanOlogy, LLC",
            "Natera, Inc",
            "Treatment Technologies and Insights, Incorporated",
        )

        /** The one false positive, and the whole reason precision is 0.909 rather than 1.0. */
        val EXPECTED_FALSE_POSITIVES = setOf(
            "National Inheritance Studio of Veteran Pharmaceutical Workers of Zhong Lingyun",
        )

        /** The twenty industry funders missed — mostly bare brand names. A record of known cost. */
        val EXPECTED_FALSE_NEGATIVES = setOf(
            "AbbVie",
            "Arima Genomics",
            "AstraZeneca.",
            "Bristol Myers Squibb",
            "Diaceutics",
            "Guardant Health",
            "Invitae Corporation",
            "Janssen Scientific Affairs",
            "La Roche Posay",
            "Lockheed Martin",
            "Merck & Co.; Merck Sharp & Dohme",
            "NVIDIA",
            "Personalis",
            "Pfizer",
            "Pfizer and Jazz",
            "Roche",
            "Roche Sweden AB",
            "Tempus Labs",
            "TerumoBCT",
            "Teva",
        )
    }
}
