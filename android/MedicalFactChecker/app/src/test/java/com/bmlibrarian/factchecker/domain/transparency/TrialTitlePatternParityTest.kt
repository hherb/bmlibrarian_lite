package com.bmlibrarian.factchecker.domain.transparency

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

/**
 * Binds Android to the trial-title contract, `trial_title_patterns.json` (#385), as
 * `TransparencyParityTests` binds Swift and `tests/test_trial_registration_gate.py` binds
 * Python.
 *
 * Whether a title reads as a trial's decides one risk indicator, "Clinical trial without
 * detected registration". A substring test read "atrial fibrillation" and "myocardial
 * infarction" as trials on all three platforms, so the fragments are asserted
 * string-for-string and every case is run through [TrialComplianceAnalyzer.appearsToBeClinicalTrial].
 */
class TrialTitlePatternParityTest {

    @Serializable
    private data class Case(val title: String, @SerialName("is_trial") val isTrial: Boolean)

    @Serializable
    private data class Manifest(val patterns: List<String>, val cases: List<Case>)

    private val manifest: Manifest =
        ParityFixtures.json.decodeFromString(Manifest.serializer(), ParityFixtures.read("trial_title_patterns.json"))

    @Test
    fun `trial title patterns match the shared contract`() {
        ParityFixtures.assertPatternsMatch(ClinicalTrialPatterns.trialTitlePatterns, manifest.patterns, "patterns")
    }

    @Test
    fun `every case classifies as the contract says`() {
        assertFalse("trial-title fixture is empty", manifest.cases.isEmpty())
        for (case in manifest.cases) {
            assertEquals("title: ${case.title}", case.isTrial, TrialComplianceAnalyzer.appearsToBeClinicalTrial(case.title))
        }
    }
}
