package com.bmlibrarian.factchecker.domain.transparency

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Port of the Swift `TransparencyConstantsTests` for everything this port owns.
 * (The data-availability pattern tests are covered by `DataRepositoryPatternsTest`
 * and the parity contract; they are not duplicated here.)
 */
class TransparencyConstantsTest {

    // ==================== constants ====================

    @Test
    fun `API URLs are https`() {
        assertTrue(TransparencyConstants.CROSSREF_BASE_URL.startsWith("https://"))
        assertTrue(TransparencyConstants.CLINICAL_TRIALS_BASE_URL.startsWith("https://"))
        assertTrue(TransparencyConstants.OPENALEX_BASE_URL.startsWith("https://"))
    }

    @Test
    fun `rate limits are positive`() {
        assertTrue(TransparencyConstants.CROSSREF_RATE_LIMIT > 0)
        assertTrue(TransparencyConstants.CLINICAL_TRIALS_RATE_LIMIT > 0)
        assertTrue(TransparencyConstants.MINIMUM_REQUEST_INTERVAL_MS > 0)
    }

    @Test
    fun `thresholds are ordered`() {
        assertTrue(TransparencyConstants.HIGH_RISK_SCORE_THRESHOLD < TransparencyConstants.MEDIUM_RISK_SCORE_THRESHOLD)
        assertTrue(TransparencyConstants.GOOD_TRANSPARENCY_THRESHOLD > TransparencyConstants.AVERAGE_TRANSPARENCY_THRESHOLD)
        assertTrue(
            TransparencyConstants.AVERAGE_TRANSPARENCY_THRESHOLD > TransparencyConstants.BELOW_AVERAGE_TRANSPARENCY_THRESHOLD,
        )
    }

    @Test
    fun `score range`() {
        assertEquals(0, TransparencyConstants.MIN_TRANSPARENCY_SCORE)
        assertEquals(100, TransparencyConstants.MAX_TRANSPARENCY_SCORE)
        assertTrue(TransparencyConstants.BASE_TRANSPARENCY_SCORE in 0..100)
    }

    /** The scoring values must equal Python's and Swift's, or the platforms score the same study differently. */
    @Test
    fun `score adjustments match the reference`() {
        assertEquals(
            listOf(50, 40, 70, 20, 5, -5, -15, -5, 5, -5, -5, 10, 5, -10, -15, -10, 76, 51, 26),
            listOf(
                TransparencyConstants.BASE_TRANSPARENCY_SCORE,
                TransparencyConstants.HIGH_RISK_SCORE_THRESHOLD,
                TransparencyConstants.MEDIUM_RISK_SCORE_THRESHOLD,
                TransparencyConstants.FULL_OPEN_DATA_POINTS,
                TransparencyConstants.ON_REQUEST_DATA_POINTS,
                TransparencyConstants.RESTRICTED_DATA_PENALTY,
                TransparencyConstants.NO_DATA_PENALTY,
                TransparencyConstants.NO_STATEMENT_PENALTY,
                TransparencyConstants.COI_STATEMENT_POINTS,
                TransparencyConstants.COI_INDUSTRY_TIES_PENALTY,
                TransparencyConstants.MISSING_COI_PENALTY,
                TransparencyConstants.TRIAL_REGISTRATION_POINTS,
                TransparencyConstants.COMPLIANT_RESULTS_POINTS,
                TransparencyConstants.MISSING_RESULTS_PENALTY,
                TransparencyConstants.OUTCOME_SWITCHING_PENALTY,
                TransparencyConstants.INDUSTRY_NO_DATA_PENALTY,
                TransparencyConstants.GOOD_TRANSPARENCY_THRESHOLD,
                TransparencyConstants.AVERAGE_TRANSPARENCY_THRESHOLD,
                TransparencyConstants.BELOW_AVERAGE_TRANSPARENCY_THRESHOLD,
            ),
        )
    }

    @Test
    fun `reader-facing notes and source names`() {
        assertEquals("Limited certainty because of lack of full text access", TransparencyConstants.LIMITED_CERTAINTY_NOTE)
        assertEquals(
            "Certainty unknown: this analysis did not record whether the full text was accessed. " +
                "Re-analyse for a rating of known certainty.",
            TransparencyConstants.UNRECORDED_CERTAINTY_NOTE,
        )
        assertEquals("· limited", TransparencyConstants.LIMITED_CERTAINTY_BADGE_SUFFIX)
        assertEquals("PubMed", TransparencyConstants.PUBMED_SOURCE_NAME)
        assertEquals("CrossRef", TransparencyConstants.CROSSREF_SOURCE_NAME)
        assertEquals("ClinicalTrials.gov", TransparencyConstants.CLINICAL_TRIALS_REGISTRY_NAME)
    }

    // ==================== known industry funders ====================

    @Test
    fun `known industry funder lookup`() {
        assertTrue(KnownIndustryFunders.isIndustryFunder("10.13039/100004319"))
        assertFalse(KnownIndustryFunders.isIndustryFunder("10.13039/unknown"))
        assertFalse(KnownIndustryFunders.isIndustryFunder(null))
    }

    @Test
    fun `known industry funder names`() {
        assertEquals("Pfizer", KnownIndustryFunders.companyName("10.13039/100004319"))
        assertEquals("AstraZeneca", KnownIndustryFunders.companyName("10.13039/100004325"))
        assertEquals("Merck", KnownIndustryFunders.companyName("10.13039/100004334"))
        assertNull(KnownIndustryFunders.companyName("unknown"))
    }

    @Test
    fun `known funder DOIs are registry DOIs`() {
        assertEquals(26, KnownIndustryFunders.funderDOIs.size)
        for (doi in KnownIndustryFunders.funderDOIs.keys) assertTrue(doi, doi.startsWith("10.13039/"))
    }

    // ==================== industry patterns ====================

    @Test
    fun `industry keywords match`() {
        val patterns = IndustryPatterns.industryKeywords
        for (text in listOf(
            "Funded by Pfizer Inc.", "Pharmaceutical company support", "Biotechnology firm", "Employee of Novartis",
            "Shareholder in AstraZeneca", "Consultant for Merck", "Advisory board member", "Speaker's bureau fee",
            "Received honoraria",
        )) {
            assertTrue(text, TransparencyRegex.anyMatch(patterns, text))
        }
    }

    @Test
    fun `government patterns match`() {
        val patterns = IndustryPatterns.governmentPatterns
        for (text in listOf(
            "Funded by NIH grant", "National Institutes of Health", "NIAID support", "National Science Foundation",
            "CDC funding", "Veterans Affairs", "PCORI grant", "Wellcome Trust",
        )) {
            assertTrue(text, TransparencyRegex.anyMatch(patterns, text))
        }
        assertFalse(TransparencyRegex.anyMatch(patterns, "Pfizer Inc."))
    }

    @Test
    fun `academic patterns match`() {
        for (text in listOf("Harvard University", "Stanford Medical School", "Johns Hopkins Hospital", "Medical Center grant")) {
            assertTrue(text, TransparencyRegex.anyMatch(IndustryPatterns.academicPatterns, text))
        }
    }

    @Test
    fun `funder name words match as whole words`() {
        val patterns = IndustryPatterns.funderNameWords
        for (text in listOf(
            "Pfizer Inc", "Genentech Inc.", "Novartis Corp", "AstraZeneca Ltd", "Boehringer Ingelheim GmbH",
            "Flatiron Health LLC",
        )) {
            assertTrue(text, TransparencyRegex.anyMatch(patterns, text))
        }
        assertFalse(TransparencyRegex.anyMatch(patterns, "Lincoln Medical Center"))
        assertFalse(TransparencyRegex.anyMatch(patterns, "Department of Biotechnology"))
        assertFalse(TransparencyRegex.anyMatch(patterns, "Research Corporation for Science Advancement"))
    }

    @Test
    fun `funder name stems match inside longer words`() {
        fun matches(name: String) = IndustryPatterns.funderNameStems.any { name.lowercase().contains(it) }
        assertTrue(matches("Vertex Pharmaceuticals Incorporated"))
        assertTrue(matches("Moderna Therapeutics"))
        assertTrue(matches("Abbott Laboratories"))
        assertFalse(matches("Key Laboratory of Molecular Biology"))
        assertFalse(matches("School of Pharmacy"))
        assertFalse(matches("Institute of Pharmacology"))
    }

    // ==================== COI patterns ====================

    @Test
    fun `no conflict patterns match`() {
        val patterns = COIPatterns.noConflictPatterns
        for (text in listOf(
            "The authors declare no conflict of interest", "Nothing to disclose",
            "The authors have no competing interests", "No financial interest to declare", "None declared",
        )) {
            assertTrue(text, TransparencyRegex.anyMatch(patterns, text))
        }
        assertFalse(TransparencyRegex.anyMatch(patterns, "Author received grants from Pfizer"))
    }

    @Test
    fun `relationship patterns extract`() {
        fun extract(text: String) = COIPatterns.relationshipPatterns.flatMap { TransparencyRegex.extractAll(it, text) }
        assertTrue(extract("Author received grants from Pfizer and Novartis.").any { it.contains("pfizer") })
        assertFalse(extract("Author is a consultant for AstraZeneca.").isEmpty())
        assertFalse(extract("Author is an employee of Merck.").isEmpty())
    }

    // ==================== clinical trial patterns ====================

    @Test
    fun `trial keywords`() {
        for (keyword in listOf("trial", "randomized", "rct", "phase iii")) {
            assertTrue(keyword, keyword in ClinicalTrialPatterns.trialKeywords)
        }
    }

    @Test
    fun `NCT pattern extraction`() {
        assertEquals(
            listOf("NCT01234567"),
            TransparencyRegex.findAll(
                ClinicalTrialPatterns.NCT_ID_PATTERN,
                "This trial was registered at ClinicalTrials.gov (NCT01234567).",
            ),
        )
        assertTrue(
            TransparencyRegex.findAll(ClinicalTrialPatterns.NCT_ID_PATTERN, "An observational study without registration.")
                .isEmpty(),
        )
    }

    @Test
    fun `registry names`() {
        assertTrue("ClinicalTrials.gov" in ClinicalTrialPatterns.registryNames)
        assertTrue("ISRCTN" in ClinicalTrialPatterns.registryNames)
        assertTrue("EudraCT" in ClinicalTrialPatterns.registryNames)
    }

    // ==================== risk indicator strings (byte-identical to Python/Swift) ====================

    @Test
    fun `risk indicator strings`() {
        assertEquals("Industry funding detected", RiskIndicatorStrings.INDUSTRY_FUNDING)
        assertEquals("Industry-funded with restricted data access", RiskIndicatorStrings.INDUSTRY_RESTRICTED_DATA)
        assertEquals("Trial results not posted to ClinicalTrials.gov", RiskIndicatorStrings.RESULTS_NOT_POSTED)
        assertEquals("Authors have disclosed industry financial ties", RiskIndicatorStrings.INDUSTRY_TIES_DISCLOSED)
        assertEquals(
            "Industry funding routed through institutional intermediaries",
            RiskIndicatorStrings.INSTITUTIONAL_INTERMEDIARY,
        )
        assertEquals("No conflict of interest statement found", RiskIndicatorStrings.MISSING_COI_STATEMENT)
        assertEquals(
            "Data effectively unavailable despite sharing statement",
            RiskIndicatorStrings.DATA_EFFECTIVELY_UNAVAILABLE,
        )
        assertEquals("Data access restricted", RiskIndicatorStrings.DATA_ACCESS_RESTRICTED)
        assertEquals("Outcome switching detected", RiskIndicatorStrings.OUTCOME_SWITCHING)
        assertEquals("Industry ties combined with restricted/unavailable data", RiskIndicatorStrings.COMBINED_INDUSTRY_DATA)
        assertEquals("Clinical trial without detected registration", RiskIndicatorStrings.MISSING_TRIAL_REGISTRATION)
    }

    /** The failed-lookup warnings, pinned to the Swift strings. */
    @Test
    fun `failed lookup warnings match Swift`() {
        assertEquals(
            "CrossRef could not be reached, so this study's funders were not checked; " +
                "industry funding may be present though none is reported.",
            TransparencyConstants.CROSSREF_UNREACHABLE_WARNING,
        )
        assertEquals(
            "Could not reach ClinicalTrials.gov for trial NCT01234567, so its registration could " +
                "not be checked. Absence of a registration is not evidence the study is unregistered.",
            TrialComplianceAnalyzer.registryUnreachableWarning("NCT01234567"),
        )
        assertEquals(
            "ClinicalTrials.gov holds no record of trial NCT01234567, which the article cites as its registration.",
            TrialComplianceAnalyzer.registryHasNoRecordWarning("NCT01234567"),
        )
        assertEquals(
            "ClinicalTrials.gov returned a record for trial NCT01234567 that could not be read, so its " +
                "registration could not be checked.",
            TrialComplianceAnalyzer.unreadableRegistryRecordWarning("NCT01234567"),
        )
    }

    // ==================== TransparencyRegex (Swift RegexHelper semantics) ====================

    @Test
    fun `regex creation`() {
        assertNotNull(TransparencyRegex.regex("""\btest\b"""))
        assertNull(TransparencyRegex.regex("[invalid"))
    }

    /** An invalid pattern is skipped, as Swift's `try?` skips it, rather than thrown. */
    @Test
    fun `an invalid pattern is skipped`() {
        assertTrue(TransparencyRegex.anyMatch(listOf("[invalid", "apple"), "apple"))
        assertEquals(1, TransparencyRegex.countMatches(listOf("[invalid", "apple"), "apple"))
    }

    @Test
    fun `any match`() {
        val patterns = listOf("apple", "banana", "cherry")
        assertTrue(TransparencyRegex.anyMatch(patterns, "I like apples"))
        assertTrue(TransparencyRegex.anyMatch(patterns, "BANANA bread"))
        assertFalse(TransparencyRegex.anyMatch(patterns, "orange juice"))
    }

    @Test
    fun `count matches`() =
        assertEquals(2, TransparencyRegex.countMatches(listOf("""\bthe\b"""), "The quick brown fox jumps over the lazy dog."))

    @Test
    fun `extract first`() {
        assertEquals("2.5", TransparencyRegex.extractFirst("""version (\d+\.\d+)""", "Software version 2.5 released"))
        assertNull(TransparencyRegex.extractFirst("""version (\d+\.\d+)""", "No version mentioned"))
    }

    @Test
    fun `extract first lowercases the capture`() =
        assertEquals("gse123456", TransparencyRegex.extractFirst("""accession[:\s]+([a-z0-9]+)""", "Accession: GSE123456"))

    @Test
    fun `extract all`() =
        assertEquals(listOf("1", "22", "333"), TransparencyRegex.extractAll("""(\d+)""", "Numbers: 1, 22, 333"))

    @Test
    fun `find all keeps original case`() {
        val found = TransparencyRegex.findAll("""\b\w+@\w+\.\w+\b""", "Contact: Alice@example.com and bob@test.org")
        assertEquals(listOf("Alice@example.com", "bob@test.org"), found)
    }

    @Test
    fun `matching is case-insensitive`() {
        assertTrue(TransparencyRegex.anyMatch(listOf("PFIZER"), "pfizer"))
        assertTrue(TransparencyRegex.anyMatch(listOf("PFIZER"), "Pfizer"))
        assertTrue(TransparencyRegex.anyMatch(listOf("PFIZER"), "PFIZER"))
    }

    /** Compiled through RegexHelper's (?U): `\w` reaches accented letters as it does in ICU and Python. */
    @Test
    fun `word classes are unicode-aware`() {
        assertEquals(listOf("é"), TransparencyRegex.extractAll("""(\w)""", "é"))
    }
}
