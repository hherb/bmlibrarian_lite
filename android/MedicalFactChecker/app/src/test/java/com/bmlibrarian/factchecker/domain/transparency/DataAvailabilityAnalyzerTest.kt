package com.bmlibrarian.factchecker.domain.transparency

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DataAvailabilityAnalyzerTest {

    private fun analyze(statement: String?) = DataAvailabilityAnalyzer.analyze(statement)

    // ==================== classification tiers ====================

    @Test
    fun `empty statement is not stated`() {
        assertEquals(DataDisclosureLevel.NOT_STATED, analyze(null).disclosureLevel)
        assertEquals(DataDisclosureLevel.NOT_STATED, analyze("").disclosureLevel)
    }

    @Test
    fun `public repository is full open`() {
        assertEquals(DataDisclosureLevel.FULL_OPEN, analyze("Data deposited in Zenodo.").disclosureLevel)
    }

    @Test
    fun `on request is restricted not available on request`() {
        val result = analyze("Data available upon reasonable request from the corresponding author.")
        assertEquals(DataDisclosureLevel.RESTRICTED, result.disclosureLevel)
        assertTrue(result.restrictions.isNotEmpty())
    }

    @Test
    fun `ethics committee is restricted`() {
        assertEquals(
            DataDisclosureLevel.RESTRICTED,
            analyze("Data access requires ethics committee approval.").disclosureLevel,
        )
    }

    @Test
    fun `strong refusal is not available`() {
        val result = analyze("Individual patient data will not be released to others.")
        assertEquals(DataDisclosureLevel.NOT_AVAILABLE, result.disclosureLevel)
        assertTrue(result.restrictions.isNotEmpty())
    }

    @Test
    fun `sponsor confidentiality is not available`() {
        assertEquals(
            DataDisclosureLevel.NOT_AVAILABLE,
            analyze("Confidentiality agreements with sponsors prevent data disclosure.").disclosureLevel,
        )
    }

    @Test
    fun `named collaboration lock is not available with ordered restrictions`() {
        val result = analyze(
            "Data are provided to the CORE consortium on the understanding that they are not shared.",
        )
        assertEquals(DataDisclosureLevel.NOT_AVAILABLE, result.disclosureLevel)
        assertEquals(
            listOf(
                "Data restricted to named collaboration",
                "Data provided under restrictive understanding",
            ),
            result.restrictions,
        )
    }

    @Test
    fun `whitespace-only statement is unknown not stated`() {
        // Only empty/null is NOT_STATED; a whitespace-only statement matches no
        // pattern and falls through to UNKNOWN, mirroring Python's `if not text`
        // and Swift's `!statement.isEmpty` guards (review finding #4).
        assertEquals(DataDisclosureLevel.UNKNOWN, analyze("   ").disclosureLevel)
    }

    @Test
    fun `ambiguous statement is unknown`() {
        assertEquals(
            DataDisclosureLevel.UNKNOWN,
            analyze("The study data is maintained by the research team.").disclosureLevel,
        )
    }

    // ==================== #113 open-availability affirmations ====================

    @Test
    fun `open affirmation without repository is full open`() {
        assertEquals(
            DataDisclosureLevel.FULL_OPEN,
            analyze("De-identified data are openly shared; no HIPAA-protected identifiers remain.").disclosureLevel,
        )
        assertEquals(
            DataDisclosureLevel.FULL_OPEN,
            analyze("All data are available in the supplementary materials; patient privacy was protected throughout.").disclosureLevel,
        )
        assertEquals(
            DataDisclosureLevel.FULL_OPEN,
            analyze("The complete dataset is freely available to all researchers.").disclosureLevel,
        )
    }

    @Test
    fun `open affirmation with strong refusal is not available`() {
        assertEquals(
            DataDisclosureLevel.NOT_AVAILABLE,
            analyze("Data are freely available in summary form but the individual-level data cannot be shared.").disclosureLevel,
        )
    }

    @Test
    fun `negated affirmation does not trigger full open`() {
        // Immediate "not " before the affirmation adverb is blocked by (?<!not ),
        // so these fall through to the normal tiers (#113 review).
        val irb = analyze("Raw data are not openly accessible without IRB approval.")
        assertEquals(DataDisclosureLevel.RESTRICTED, irb.disclosureLevel)
        assertEquals(
            listOf("Requires IRB approval", "Data not openly available"),
            irb.restrictions,
        )

        val author = analyze("Data are not freely shared; available from the corresponding author.")
        assertEquals(DataDisclosureLevel.RESTRICTED, author.disclosureLevel)

        val notOpen = analyze("The data are not openly available.")
        assertNotEquals(DataDisclosureLevel.FULL_OPEN, notOpen.disclosureLevel)
    }

    @Test
    fun `non-adjacent negated affirmation is not available`() {
        // One intervening adverb ("will not be openly shared", "cannot be openly
        // shared") is caught by the (?:\w+ )?-broadened strong-refusal patterns
        // → NOT_AVAILABLE (#113 review).
        val willNot = analyze("The data will not be openly shared with third parties.")
        assertEquals(DataDisclosureLevel.NOT_AVAILABLE, willNot.disclosureLevel)
        assertEquals(
            listOf("Data will not be released", "Data not openly available"),
            willNot.restrictions,
        )

        val cannot = analyze("Raw data cannot be openly shared.")
        assertEquals(DataDisclosureLevel.NOT_AVAILABLE, cannot.disclosureLevel)
        assertEquals(
            listOf("Data cannot be shared", "Data not openly available"),
            cannot.restrictions,
        )
    }

    // ==================== #117 detached-negator negation scope ====================

    @Test
    fun `non-adjacent negator does not trigger full open`() {
        // The (?<!not ) lookbehind is fixed-width, so an intervening word, an
        // alternate negator ("never"), doubled whitespace, or a modal outside
        // the strong-refusal (?:would|will|shall) list all escaped it and
        // produced a false FULL_OPEN. negatedOpennessPatterns closes the gap
        // with a forward-matching bounded negation scope (#117).
        val never = analyze("Data were never openly shared.")
        assertEquals(DataDisclosureLevel.RESTRICTED, never.disclosureLevel)
        assertEquals(listOf("Data not openly available"), never.restrictions)

        val intervening = analyze("Data are not currently openly available.")
        assertEquals(DataDisclosureLevel.RESTRICTED, intervening.disclosureLevel)

        val doubledSpace = analyze("Data are not  openly available.")
        assertEquals(DataDisclosureLevel.RESTRICTED, doubledSpace.disclosureLevel)

        val could = analyze("The data could not be openly shared.")
        assertEquals(DataDisclosureLevel.RESTRICTED, could.disclosureLevel)

        val supplement = analyze("Data are not currently available in the supplementary materials.")
        assertEquals(DataDisclosureLevel.RESTRICTED, supplement.disclosureLevel)
    }

    @Test
    fun `negation scope stops at coordinating conjunction`() {
        // The (?!and\b|but\b|or\b) barrier stops the negation scope reaching
        // across a conjunction into an affirmation the negator does not govern;
        // without it the window would under-report genuinely open data (#117).
        //
        // The conjunction must fall *inside* the two-word window for this test
        // to exercise the barrier at all. In "not embargoed and were openly
        // shared" the affirmation sits three words after the negator, so the
        // {0,2} bound already blocks it and the barrier is never consulted —
        // such a sentence passes with the barrier deleted and pins nothing. The
        // first two cases place the conjunction at the second window slot,
        // immediately before the affirmation: they are the assertions that fail
        // if the barrier is removed, and must keep that shape if reworded.
        val immediateAnd = analyze("Data were not embargoed and openly shared.")
        assertEquals(DataDisclosureLevel.FULL_OPEN, immediateAnd.disclosureLevel)

        val immediateOr = analyze("Data are not restricted or openly available.")
        assertEquals(DataDisclosureLevel.FULL_OPEN, immediateOr.disclosureLevel)

        // Broader regression coverage: realistic phrasings that must stay
        // FULL_OPEN. These are held by the window bound rather than the barrier.
        val conjunction = analyze("Data were not embargoed and were openly shared.")
        assertEquals(DataDisclosureLevel.FULL_OPEN, conjunction.disclosureLevel)

        val contrast = analyze("Data are not subject to embargo, but are openly available.")
        assertEquals(DataDisclosureLevel.FULL_OPEN, contrast.disclosureLevel)
    }

    @Test
    fun `negation scope window is bounded`() {
        // At most two intervening words, so an unrelated earlier negation in the
        // same statement leaves a genuine affirmation intact (#117).
        //
        // The statement must contain a token the patterns actually treat as a
        // negator — since #125 that is not, no, never, cannot, neither or nor —
        // for the bound to be under test. The first case keeps a real negator
        // seven unpunctuated words from the affirmation, so it fails if {0,2}
        // is widened; do not reword it in a way that inserts punctuation
        // between the two, because \w+ cannot cross punctuation and the bound
        // would stop being what holds the line.
        val farNegator = analyze(
            "Reuse is not limited by any licence because these datasets " +
                "are openly available.",
        )
        assertEquals(DataDisclosureLevel.FULL_OPEN, farNegator.disclosureLevel)

        // Broader regression coverage: "no" negates within the same bounded
        // window as the other negators (#125), so an affirmation two clauses
        // away survives: the window bound and the semicolon (which \w+ cannot
        // cross) both hold the line here.
        val result = analyze(
            "No identifiable fields were retained during curation; " +
                "the processed dataset is openly available.",
        )
        assertEquals(DataDisclosureLevel.FULL_OPEN, result.disclosureLevel)
    }

    // ==================== #125 "no" / "neither … nor" negators ====================

    @Test
    fun `no and neither-nor negators do not trigger full open`() {
        // The #117 negator alternation was (?:not|never|cannot): "no" was
        // absent and "neither … nor" is a two-token negator a single-token
        // alternation cannot express, so "no longer openly available", "by no
        // means openly available" and "neither the raw nor the processed data
        // are openly available" all still reported FULL_OPEN — the same
        // dangerous over-stating-openness direction #117 closed for detached
        // negators (#125). The alternation now carries no/neither/nor, and two
        // dedicated patterns cover the two-token "neither … nor" form with
        // bounded windows ({0,3} words to "nor", {0,4} to the affirmation).
        // Mirrors Python's test_no_and_neither_nor_negators_do_not_trigger_full_open.
        val noLonger = analyze("Data are no longer openly available.")
        assertEquals(DataDisclosureLevel.RESTRICTED, noLonger.disclosureLevel)
        assertEquals(listOf("Data not openly available"), noLonger.restrictions)

        val freely = analyze("Data are no longer freely available.")
        assertEquals(DataDisclosureLevel.RESTRICTED, freely.disclosureLevel)

        val byNoMeans = analyze("The dataset is by no means openly available.")
        assertEquals(DataDisclosureLevel.RESTRICTED, byNoMeans.disclosureLevel)

        val bareNo = analyze("No data are openly available for this study.")
        assertEquals(DataDisclosureLevel.RESTRICTED, bareNo.disclosureLevel)

        // Single-token "neither" (no "nor" clause): held by the alternation
        // entry, not the two-token patterns.
        val bareNeither = analyze("Neither dataset is openly available.")
        assertEquals(DataDisclosureLevel.RESTRICTED, bareNeither.disclosureLevel)

        val neitherNor = analyze("Neither the raw nor the processed data are openly available.")
        assertEquals(DataDisclosureLevel.RESTRICTED, neitherNor.disclosureLevel)
        assertEquals(listOf("Data not openly available"), neitherNor.restrictions)

        val neitherNorLong = analyze(
            "Neither the raw data nor the processed data are openly available.",
        )
        assertEquals(DataDisclosureLevel.RESTRICTED, neitherNorLong.disclosureLevel)

        val trailingNor = analyze("The data are not publicly posted nor openly available.")
        assertEquals(DataDisclosureLevel.RESTRICTED, trailingNor.disclosureLevel)

        val noSupplement = analyze("Data are no longer available in the supplementary materials.")
        assertEquals(DataDisclosureLevel.RESTRICTED, noSupplement.disclosureLevel)

        val neitherSupplement = analyze("Neither the code nor the data are available in the supplement.")
        assertEquals(DataDisclosureLevel.RESTRICTED, neitherSupplement.disclosureLevel)
    }

    @Test
    fun `no negator does not suppress genuine affirmations`() {
        // False-positive shapes worked through before adding "no" to the
        // alternation (#125); each pins the guard that holds it: the
        // (?!and\b|but\b|or\b) barrier, punctuation (\w+ cannot cross ; or ,),
        // or the window bound ({0,2} single-token, {0,4} after "nor").
        // Mirrors Python's test_no_negator_does_not_suppress_genuine_affirmations.

        // Barrier pin (single-token "no"): "and" occupies the window slot
        // immediately before the affirmation, so this flips to RESTRICTED if
        // (?!and\b|but\b|or\b) is dropped.
        val noBarrier = analyze("Data are subject to no embargo and openly available.")
        assertEquals(DataDisclosureLevel.FULL_OPEN, noBarrier.disclosureLevel)

        // Window pin (broader): the conjunction and affirmation sit outside
        // the two-word window entirely.
        val noRestrictions = analyze("No restrictions apply and data are openly available.")
        assertEquals(DataDisclosureLevel.FULL_OPEN, noRestrictions.disclosureLevel)

        // Punctuation pin: the semicolon stops the \w+ chain.
        val noEmbargo = analyze("There is no embargo; the data are openly available.")
        assertEquals(DataDisclosureLevel.FULL_OPEN, noEmbargo.disclosureLevel)

        // Window pin (single-token "no"): three intervening words.
        val noLimits = analyze("There are no limits on these openly available records.")
        assertEquals(DataDisclosureLevel.FULL_OPEN, noLimits.disclosureLevel)

        // Barrier pin (two-token form): "and" occupies the window slot
        // immediately before the affirmation, so this flips to RESTRICTED if
        // the barrier is dropped from the "neither … nor" patterns.
        val neitherBarrier = analyze(
            "The data are neither embargoed nor restricted and openly available to all.",
        )
        assertEquals(DataDisclosureLevel.FULL_OPEN, neitherBarrier.disclosureLevel)

        // Window pin (two-token form): five unpunctuated words between "nor"
        // and the affirmation, so this flips to RESTRICTED if the {0,4} bound
        // is widened past the phrase length.
        val neitherWindow = analyze(
            "Neither the sponsor nor the funder restricted access to the openly available dataset.",
        )
        assertEquals(DataDisclosureLevel.FULL_OPEN, neitherWindow.disclosureLevel)
    }

    // ==================== privacy/legal restricted-tier (#104) ====================

    @Test
    fun `gdpr restriction is restricted`() {
        val result = analyze("Individual patient data are restricted under GDPR.")
        assertEquals(DataDisclosureLevel.RESTRICTED, result.disclosureLevel)
        assertEquals(listOf("GDPR restrictions"), result.restrictions)
    }

    @Test
    fun `hipaa restriction is restricted`() {
        val result = analyze("Access to the dataset is limited by HIPAA.")
        assertEquals(DataDisclosureLevel.RESTRICTED, result.disclosureLevel)
        assertEquals(listOf("HIPAA restrictions"), result.restrictions)
    }

    @Test
    fun `privacy restriction is restricted`() {
        val result = analyze("Sharing is constrained by participant privacy considerations.")
        assertEquals(DataDisclosureLevel.RESTRICTED, result.disclosureLevel)
        assertEquals(listOf("Privacy restrictions"), result.restrictions)
    }

    @Test
    fun `patient consent restriction is restricted`() {
        val result = analyze("Data access requires patient consent.")
        assertEquals(DataDisclosureLevel.RESTRICTED, result.disclosureLevel)
        assertEquals(listOf("Patient consent required"), result.restrictions)
    }

    @Test
    fun `privacy does not override full open repository`() {
        assertEquals(
            DataDisclosureLevel.FULL_OPEN,
            analyze("Data are deposited in Zenodo; no privacy concerns were identified.").disclosureLevel,
        )
    }

    @Test
    fun `gdpr with strong refusal is not available`() {
        val result = analyze("The data are not publicly available owing to GDPR.")
        assertEquals(DataDisclosureLevel.NOT_AVAILABLE, result.disclosureLevel)
        assertTrue(result.restrictions.contains("Data not publicly available"))
        assertTrue(result.restrictions.contains("GDPR restrictions"))
    }

    // ==================== short-token over-match guards (#106/#108) ====================

    @Test
    fun `geographic word does not trigger full open`() {
        assertEquals(
            DataDisclosureLevel.NOT_AVAILABLE,
            analyze("Geographic data underlying this study are not publicly available.").disclosureLevel,
        )
    }

    @Test
    fun `phenomena word does not trigger full open`() {
        assertEquals(
            DataDisclosureLevel.RESTRICTED,
            analyze("The phenomena studied are described; data available upon request from the corresponding author.").disclosureLevel,
        )
    }

    @Test
    fun `standalone short tokens still full open`() {
        for (token in listOf("GEO", "SRA", "ENA", "PDB")) {
            assertEquals(
                "token $token",
                DataDisclosureLevel.FULL_OPEN,
                analyze("Raw data have been deposited in $token under accession XYZ123.").disclosureLevel,
            )
        }
    }

    @Test
    fun `short tokens embedded in words are not full open`() {
        for (word in listOf("misranked", "compdb")) {
            assertNotEquals(
                "word $word",
                DataDisclosureLevel.FULL_OPEN,
                analyze("The $word results are summarized in the manuscript text.").disclosureLevel,
            )
        }
    }

    // ==================== repository name overridden by refusal (#106/#108) ====================

    @Test
    fun `repository named but access refused is not available`() {
        assertEquals(
            DataDisclosureLevel.NOT_AVAILABLE,
            analyze(
                "Sequencing data could not be deposited in GEO for privacy reasons; the individual patient data cannot be shared.",
            ).disclosureLevel,
        )
    }

    @Test
    fun `repository named but not publicly available is not available`() {
        assertEquals(
            DataDisclosureLevel.NOT_AVAILABLE,
            analyze("Although GenBank was used during analysis, the data are not publicly available.").disclosureLevel,
        )
    }

    @Test
    fun `repository with soft request stays full open`() {
        assertEquals(
            DataDisclosureLevel.FULL_OPEN,
            analyze(
                "Processed data are available in GEO under accession GSE12345. " +
                    "Raw individual-level data are available from the corresponding author upon reasonable request.",
            ).disclosureLevel,
        )
    }

    // ==================== label dedup (#114) ====================

    @Test
    fun `restricted label sharing patterns deduplicated`() {
        val result = analyze("Access to the data requires institutional review board review and IRB approval.")
        assertEquals(DataDisclosureLevel.RESTRICTED, result.disclosureLevel)
        assertEquals(listOf("Requires IRB approval"), result.restrictions)
    }

    // ==================== extraction (repository name / url / accession) ====================

    @Test
    fun `full open detects repository name`() {
        assertEquals("GenBank", analyze("Sequences were deposited in GenBank.").repositoryName)
    }

    @Test
    fun `repository name not overmatched by geographic`() {
        val result = analyze("Geographic sequences were deposited in GenBank.")
        assertEquals(DataDisclosureLevel.FULL_OPEN, result.disclosureLevel)
        assertEquals("GenBank", result.repositoryName)
    }

    @Test
    fun `url and accession extracted for full open`() {
        val result = analyze("Data are in Zenodo at https://zenodo.org/record/42 under accession GSE99.")
        assertEquals("https://zenodo.org/record/42", result.repositoryUrl)
        assertEquals("GSE99", result.accessionNumber)
    }
}
