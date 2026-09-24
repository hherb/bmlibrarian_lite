package com.bmlibrarian.factchecker.domain.transparency

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Industry-funder name matching, measured against the shared labelled corpus.
 *
 * Port of the Swift `FunderClassificationTests`. `industryFundingDetected` feeds
 * a HIGH-risk rule, so a false positive costs more than a false negative; the
 * corpus floors at the bottom keep that honest on Android as they do on Swift
 * and Python.
 */
class FunderClassificationTest {

    private fun isIndustry(name: String): Boolean = FundingAnalyzer.classifyFunder(name).isIndustry

    // ==================== org suffixes match as words ====================

    @Test fun `inc with a dot`() = assertTrue(isIndustry("Genentech Inc."))

    @Test fun `inc without a dot`() = assertTrue(isIndustry("Pfizer Inc"))

    @Test fun `inc uppercased`() = assertTrue(isIndustry("PFIZER INC"))

    @Test fun `lincoln is not a company`() = assertFalse(isIndustry("Lincoln Medical Center"))

    @Test
    fun `spelled-out suffixes earned inclusion`() {
        assertTrue(isIndustry("Vertex Pharmaceuticals Incorporated"))
        assertTrue(isIndustry("Takeda Limited"))
    }

    @Test fun `LLC earned inclusion`() = assertTrue(isIndustry("Flatiron Health LLC"))

    @Test fun `GmbH`() = assertTrue(isIndustry("Boehringer Ingelheim GmbH"))

    // ==================== stems match inside a longer word; words must not ====================

    @Test fun `pharmaceuticals plural`() = assertTrue(isIndustry("Regeneron Pharmaceuticals"))

    @Test fun `pharmaceutical singular`() = assertTrue(isIndustry("Pharmaceutical Research Institute"))

    @Test fun `bare pharma is still industry`() = assertTrue(isIndustry("Acme Pharma"))

    @Test fun `therapeutics`() = assertTrue(isIndustry("Moderna Therapeutics"))

    @Test fun `plural laboratories is industry`() = assertTrue(isIndustry("Abbott Laboratories"))

    @Test fun `a singular key laboratory is not industry`() =
        assertFalse(isIndustry("Key Laboratory of Molecular Biology"))

    @Test fun `pharmacy is not industry`() = assertFalse(isIndustry("School of Pharmacy"))

    @Test fun `pharmacology is not industry`() = assertFalse(isIndustry("Institute of Pharmacology"))

    // ==================== measured exclusions ====================

    @Test
    fun `biotechnology alone is not industry`() {
        assertFalse(isIndustry("Department of Biotechnology"))
        assertFalse(isIndustry("Biotechnology and Biological Sciences Research Council"))
    }

    @Test fun `bare biotech is still industry`() = assertTrue(isIndustry("Acme Biotech"))

    @Test fun `corporation is not an org token`() =
        assertFalse(isIndustry("Research Corporation for Science Advancement"))

    @Test fun `corp is an org token`() = assertTrue(isIndustry("Amgen Corp"))

    @Test fun `co is not an org token`() = assertFalse(isIndustry("Project co-sponsored by the province"))

    @Test
    fun `PLC is an org token`() {
        assertTrue(isIndustry("Diagnostics PLC"))
        assertTrue(isIndustry("GlaxoSmithKline plc"))
    }

    @Test fun `labs is not an org token`() = assertFalse(isIndustry("Los Alamos National Labs"))

    @Test fun `AB is not an org token`() = assertFalse(isIndustry("University of Calgary, Calgary, AB, Canada"))

    // ==================== public-sector funders ====================

    @Test fun `a government agency`() = assertFalse(isIndustry("Ministry of Science and Technology"))

    @Test fun `a charity`() = assertFalse(isIndustry("Wellcome Trust"))

    @Test fun `an empty name`() = assertFalse(isIndustry(""))

    @Test
    fun `known industry funder DOI still wins`() {
        val (industry, confidence) = FundingAnalyzer.classifyFunder("Pfizer", "10.13039/100004319")
        assertTrue(industry)
        assertEquals(1.0, confidence, 0.0)
    }

    /** The table in `doc/cross_platform/ios_bmlib_alignment.md` §1.4, pinned as Swift pins it. */
    @Test
    fun `agrees with bmlib on the documented table`() {
        val expected = listOf(
            "Department of Biotechnology" to false,
            "Biotechnology and Biological Sciences Research Council" to false,
            "Research Corporation for Science Advancement" to false,
            "Vertex Pharmaceuticals Incorporated" to true,
            "Regeneron Pharmaceuticals" to true,
            "Moderna Therapeutics" to true,
            "Abbott Laboratories" to true,
            "Tempus Labs, LLC" to true,
            "Flatiron Health LLC" to true,
            "Pfizer Inc" to true,
            "Genentech, Inc." to true,
            "Ministry of Science and Technology" to false,
            "Lincoln Medical Center" to false,
            "University of Calgary, Calgary, AB, Canada" to false,
            "Key Laboratory of Molecular Biology" to false,
            "Novo Nordisk A/S" to false,
            "Bristol-Myers Squibb Company" to false,
        )
        for ((name, want) in expected) assertEquals(name, want, isIndustry(name))
    }

    // ==================== the labelled corpus ====================

    private data class Score(val tp: Int, val fp: Int, val fn: Int) {
        val precision: Double get() = tp.toDouble() / (tp + fp)
        val recall: Double get() = tp.toDouble() / (tp + fn)
    }

    private fun scoreCorpus(): Score {
        val composition = FunderCorpus.classify()
        return Score(
            tp = composition.truePositives.size,
            fp = composition.falsePositives.size,
            fn = composition.falseNegatives.size,
        )
    }

    @Test
    fun `the corpus is present and labelled`() {
        val entries = FunderCorpus.entries
        assertTrue(entries.map { it.label }.toSet().all { it in setOf("industry", "not_industry", "ambiguous") })
        assertTrue(entries.count { it.label == "industry" } >= MIN_INDUSTRY_ENTRIES)
        assertTrue(entries.all { it.source in setOf("crossref", "pubmed", "both") })
        assertTrue(entries.filter { it.label == "ambiguous" }.all { !it.reason.isNullOrEmpty() })
    }

    @Test
    fun `precision meets the floor`() {
        val precision = scoreCorpus().precision
        assertTrue("precision fell to $precision", precision >= MIN_PRECISION)
    }

    @Test
    fun `recall meets the floor`() {
        val recall = scoreCorpus().recall
        assertTrue("recall fell to $recall", recall >= MIN_RECALL)
    }

    @Test
    fun `it beats the matcher it replaced`() {
        val score = scoreCorpus()
        assertTrue(score.precision > PREVIOUS_PRECISION)
        assertTrue(score.recall > PREVIOUS_RECALL)
    }

    private companion object {
        /** Floors one notch below the measured 0.909 / 0.333, as on Swift and Python. */
        const val MIN_PRECISION = 0.90
        const val MIN_RECALL = 0.30

        /** What the substring matcher this replaced scored on the same corpus. */
        const val PREVIOUS_PRECISION = 0.455
        const val PREVIOUS_RECALL = 0.167

        const val MIN_INDUSTRY_ENTRIES = 25
    }
}
