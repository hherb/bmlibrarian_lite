package com.bmlibrarian.factchecker.domain.transparency

import java.time.Instant
import java.time.ZoneId
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Port of the Swift `TrialComplianceAnalyzerTests`. */
class TrialComplianceAnalyzerTest {

    private fun trial(resultsPosted: Boolean = false, completionDate: Instant? = null) = TrialRegistration(
        registry = "ClinicalTrials.gov",
        registrationId = "NCT01234567",
        resultsPosted = resultsPosted,
        completionDate = completionDate,
    )

    private fun monthsAgo(months: Long): Instant =
        Instant.now().atZone(ZoneId.systemDefault()).minusMonths(months).toInstant()

    // ==================== results compliance ====================

    @Test
    fun `posted results are compliant`() = assertEquals(
        ResultsComplianceStatus.COMPLIANT,
        TrialComplianceAnalyzer.checkResultsCompliance(trial(resultsPosted = true), Instant.now()),
    )

    @Test
    fun `results missing past the deadline`() = assertEquals(
        ResultsComplianceStatus.MISSING,
        TrialComplianceAnalyzer.checkResultsCompliance(trial(completionDate = monthsAgo(24)), Instant.now()),
    )

    @Test
    fun `unknown without a completion date`() = assertEquals(
        ResultsComplianceStatus.UNKNOWN,
        TrialComplianceAnalyzer.checkResultsCompliance(trial(), Instant.now()),
    )

    @Test
    fun `unknown before the deadline`() = assertEquals(
        ResultsComplianceStatus.UNKNOWN,
        TrialComplianceAnalyzer.checkResultsCompliance(trial(completionDate = monthsAgo(3)), Instant.now()),
    )

    /** The deadline is completion + 365 days, strictly after. */
    @Test
    fun `the deadline boundary`() {
        val completion = Instant.parse("2023-03-01T00:00:00Z")
        val deadline = completion.atZone(ZoneId.systemDefault()).plusDays(365).toInstant()
        val t = trial(completionDate = completion)
        assertEquals(ResultsComplianceStatus.UNKNOWN, TrialComplianceAnalyzer.checkResultsCompliance(t, null, deadline))
        assertEquals(
            ResultsComplianceStatus.MISSING,
            TrialComplianceAnalyzer.checkResultsCompliance(t, null, deadline.plusSeconds(1)),
        )
    }

    // ==================== trial detection ====================

    @Test
    fun `titles that look like trials`() {
        assertTrue(TrialComplianceAnalyzer.appearsToBeClinicalTrial("A Randomized Controlled Trial of Drug X"))
        assertTrue(TrialComplianceAnalyzer.appearsToBeClinicalTrial("Phase III Study of Treatment Y"))
        assertTrue(TrialComplianceAnalyzer.appearsToBeClinicalTrial("An RCT comparing interventions"))
        assertTrue(TrialComplianceAnalyzer.appearsToBeClinicalTrial("This is a clinical trial"))
    }

    @Test
    fun `titles that do not`() {
        assertFalse(TrialComplianceAnalyzer.appearsToBeClinicalTrial("A Systematic Review of Treatment Outcomes"))
        assertFalse(TrialComplianceAnalyzer.appearsToBeClinicalTrial("Meta-Analysis of Drug Effects"))
        assertFalse(TrialComplianceAnalyzer.appearsToBeClinicalTrial(null))
    }

    @Test
    fun `trial detection is case-insensitive`() {
        assertTrue(TrialComplianceAnalyzer.appearsToBeClinicalTrial("RANDOMIZED CONTROLLED TRIAL"))
        assertTrue(TrialComplianceAnalyzer.appearsToBeClinicalTrial("phase iii study"))
    }

    // ==================== NCT IDs ====================

    @Test
    fun `extract NCT ids`() {
        assertEquals(
            listOf("NCT01234567", "NCT98765432"),
            TrialComplianceAnalyzer.extractNCTIds("Registered as NCT01234567 and NCT98765432"),
        )
    }

    @Test
    fun `no NCT ids`() = assertTrue(TrialComplianceAnalyzer.extractNCTIds("No trial registration mentioned").isEmpty())

    @Test
    fun `NCT ids across lines`() {
        val text = "This study (NCT12345678) was conducted at multiple sites.\nSee also companion study NCT87654321."
        assertEquals(2, TrialComplianceAnalyzer.extractNCTIds(text).size)
    }

    @Test
    fun `invalid NCT formats are not extracted`() {
        assertTrue(TrialComplianceAnalyzer.extractNCTIds("NCT123 and NCT1234567890 are invalid").isEmpty())
        assertTrue(TrialComplianceAnalyzer.extractNCTIds("SOMENCT12345678").isEmpty())
    }

    /** Matched case-insensitively, returned in the text's own case. */
    @Test
    fun `NCT ids keep their original case`() {
        assertEquals(listOf("nct01234567"), TrialComplianceAnalyzer.extractNCTIds("see nct01234567"))
    }

    // ==================== industry sponsor ====================

    @Test
    fun `industry sponsor`() {
        assertTrue(TrialComplianceAnalyzer.isIndustrySponsor("INDUSTRY"))
        assertTrue(TrialComplianceAnalyzer.isIndustrySponsor("industry"))
        assertTrue(TrialComplianceAnalyzer.isIndustrySponsor("Industry"))
    }

    @Test
    fun `non-industry sponsor`() {
        assertFalse(TrialComplianceAnalyzer.isIndustrySponsor("NIH"))
        assertFalse(TrialComplianceAnalyzer.isIndustrySponsor("OTHER"))
        assertFalse(TrialComplianceAnalyzer.isIndustrySponsor(null))
        assertFalse(TrialComplianceAnalyzer.isIndustrySponsor("U_S__FED"))
    }

    // ==================== outcome switching ====================

    @Test
    fun `no registered outcomes`() = assertEquals(
        OutcomeSwitchingResult(false, emptyList()),
        TrialComplianceAnalyzer.checkOutcomeSwitching(emptyList(), listOf("primary endpoint")),
    )

    @Test
    fun `no reported outcomes`() = assertEquals(
        OutcomeSwitchingResult(false, listOf("Unable to compare - no reported outcomes extracted")),
        TrialComplianceAnalyzer.checkOutcomeSwitching(listOf("mortality rate"), emptyList()),
    )

    @Test
    fun `matching outcomes`() = assertFalse(
        TrialComplianceAnalyzer.checkOutcomeSwitching(
            listOf("overall survival rate"),
            listOf("overall survival rate at 5 years"),
        ).detected,
    )

    @Test
    fun `mismatched outcomes`() {
        val (detected, details) = TrialComplianceAnalyzer.checkOutcomeSwitching(
            listOf("progression free survival"),
            listOf("quality of life score"),
        )
        assertTrue(detected)
        assertEquals(listOf("Registered outcome may not be reported: progression free survival"), details)
    }

    @Test
    fun `long outcomes are shortened for display`() {
        val outcome = "a".repeat(60)
        val details = TrialComplianceAnalyzer.checkOutcomeSwitching(listOf(outcome), listOf("unrelated")).details
        assertEquals(listOf("Registered outcome may not be reported: ${"a".repeat(50)}..."), details)
    }

    // ==================== summary ====================

    @Test fun `summary without registration`() = assertEquals(
        "No trial registration found",
        TrialComplianceAnalyzer.formatSummary(emptyList(), ResultsComplianceStatus.UNKNOWN),
    )

    @Test
    fun `summary with results`() {
        val registrations = listOf(TrialRegistration(registry = "ClinicalTrials.gov", registrationId = "NCT123", resultsPosted = true))
        assertEquals(
            "1 trial registration found; 1 with results posted; Results compliant",
            TrialComplianceAnalyzer.formatSummary(registrations, ResultsComplianceStatus.COMPLIANT),
        )
    }

    @Test
    fun `summary missing results`() {
        val registrations = listOf(TrialRegistration(registry = "ClinicalTrials.gov", registrationId = "NCT123"))
        assertTrue(
            TrialComplianceAnalyzer.formatSummary(registrations, ResultsComplianceStatus.MISSING).contains("Results missing"),
        )
    }

    @Test
    fun `summary multiple registrations`() {
        val registrations = listOf(
            TrialRegistration(registry = "CT.gov", registrationId = "NCT1"),
            TrialRegistration(registry = "ISRCTN", registrationId = "ISRCTN123"),
        )
        assertEquals(
            "2 trial registrations found",
            TrialComplianceAnalyzer.formatSummary(registrations, ResultsComplianceStatus.UNKNOWN),
        )
    }

    // ==================== missing registration ====================

    @Test fun `missing registration detected`() = assertEquals(
        "Clinical trial without detected registration",
        TrialComplianceAnalyzer.checkMissingRegistration("Randomized Controlled Trial of X", emptyList()),
    )

    @Test fun `not a trial`() = assertNull(TrialComplianceAnalyzer.checkMissingRegistration("Systematic Review", emptyList()))

    @Test fun `has registration`() = assertNull(
        TrialComplianceAnalyzer.checkMissingRegistration(
            "Randomized Trial",
            listOf(TrialRegistration(registry = "CT.gov", registrationId = "NCT123")),
        ),
    )

    @Test fun `null title`() = assertNull(TrialComplianceAnalyzer.checkMissingRegistration(null, emptyList()))
}
