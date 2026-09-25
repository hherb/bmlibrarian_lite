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

    /** Every figure is a fraction of these counts. Re-audited for #394, so it now differs from bmlib's copy. */
    @Test
    fun `the labelled corpus is unchanged`() {
        val entries = FunderCorpus.entries
        assertEquals(417, entries.size)
        assertEquals(35, entries.count { it.label == "industry" })
        assertEquals(372, entries.count { it.label == "not_industry" })
        assertEquals(10, entries.count { it.label == "ambiguous" })
    }

    private companion object {
        /** The industry funders recognised: ten by a legal suffix or company-form stem, thirteen by brand (#394). */
        val EXPECTED_TRUE_POSITIVES = setOf(
            "AbbVie",
            "Amgen",
            "Astex Pharmaceuticals, Inc.",
            "AstraZeneca",
            "AstraZeneca.",
            "Bristol Myers Squibb",
            "Cardinal Health, LLC",
            "Chia Tai Tianqing Pharmaceutical Group Co., Ltd.",
            "Chugai Pharmaceutical Co., Ltd",
            "Dr. Reddy's Laboratories, Hyderabad, India",
            "Geneos Therapeutics",
            "ImmVira Co., Limited",
            "Janssen Scientific Affairs",
            "La Roche Posay",
            "Merck & Co.; Merck Sharp & Dohme",
            "NanOlogy, LLC",
            "Natera, Inc",
            "Pfizer",
            "Pfizer and Jazz",
            "Roche",
            "Roche Sweden AB",
            "Teva",
            "Treatment Technologies and Insights, Incorporated",
        )

        /** The one false positive, and the whole reason precision is 0.958 rather than 1.0. */
        val EXPECTED_FALSE_POSITIVES = setOf(
            "National Inheritance Studio of Veteran Pharmaceutical Workers of Zhong Lingyun",
        )

        /** The industry funders missed — none a drug or device maker the brand list names. A record of known cost. */
        val EXPECTED_FALSE_NEGATIVES = setOf(
            "Arima Genomics",
            "Diaceutics",
            "Guardant Health",
            "Invitae Corporation",
            "Lockheed Martin",
            "Lån & Spar",
            "NVIDIA",
            "Personalis",
            "PetroChina Major Science and Technology Project",
            "Siemens Healthineers",
            "Tempus Labs",
            "TerumoBCT",
        )
    }
}
