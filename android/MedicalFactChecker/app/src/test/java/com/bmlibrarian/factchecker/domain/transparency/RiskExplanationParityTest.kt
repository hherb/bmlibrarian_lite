package com.bmlibrarian.factchecker.domain.transparency

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

/**
 * Binds Android to the risk-explanation contract, `risk_explanation_strings.json` (#386), as
 * `TransparencyParityTests` binds Swift and `tests/test_risk_explanation_contract.py` binds
 * Python. Strings are asserted string-for-string; each case is scored, rated and explained by
 * Kotlin's own code.
 */
class RiskExplanationParityTest {

    @Serializable
    private data class Strings(
        @SerialName("limited_certainty_note") val limitedCertaintyNote: String,
        @SerialName("limited_certainty_badge_suffix") val limitedCertaintyBadgeSuffix: String,
        @SerialName("provisional_result_caveat") val provisionalResultCaveat: String,
        @SerialName("unexplained_rating_caveat") val unexplainedRatingCaveat: String,
        @SerialName("section_heading") val sectionHeading: String,
        @SerialName("reasons_label") val reasonsLabel: String,
        @SerialName("score_breakdown_label") val scoreBreakdownLabel: String,
        @SerialName("other_concerns_label") val otherConcernsLabel: String,
        @SerialName("caveats_label") val caveatsLabel: String,
    )

    @Serializable
    private data class Introduction(val count: Int, val text: String)

    @Serializable
    private data class AppOnly(
        @SerialName("unrecorded_certainty_note") val unrecordedCertaintyNote: String,
        @SerialName("unassessed_label") val unassessedLabel: String,
        @SerialName("unassessed_note") val unassessedNote: String,
    )

    @Serializable
    private data class Findings(
        @SerialName("data_availability") val dataAvailability: String,
        val coi: String,
        @SerialName("industry_funding") val industryFunding: Boolean,
        @SerialName("industry_confidence") val industryConfidence: Double,
        @SerialName("trial_registered") val trialRegistered: Boolean,
        val results: String,
        @SerialName("outcome_switching") val outcomeSwitching: Boolean,
        @SerialName("sources_unreachable") val sourcesUnreachable: Boolean,
    )

    @Serializable
    private data class Expected(
        val score: Int,
        @SerialName("risk_level") val riskLevel: String,
        val reasons: List<String>,
        @SerialName("score_breakdown") val scoreBreakdown: List<String>,
        val caveats: List<String>,
    )

    @Serializable
    private data class Case(
        val name: String,
        val findings: Findings,
        @SerialName("stored_risk_level") val storedRiskLevel: String? = null,
        val expected: Expected,
    )

    @Serializable
    private data class Contract(
        val strings: Strings,
        @SerialName("introduction_examples") val introductionExamples: List<Introduction>,
        @SerialName("swift_kotlin_only") val swiftKotlinOnly: AppOnly,
        val cases: List<Case>,
    )

    private val contract: Contract =
        ParityFixtures.json.decodeFromString(Contract.serializer(), ParityFixtures.read("risk_explanation_strings.json"))

    @Test
    fun `strings match the shared contract`() {
        val s = contract.strings
        assertEquals(s.limitedCertaintyNote, TransparencyConstants.LIMITED_CERTAINTY_NOTE)
        assertEquals(s.limitedCertaintyBadgeSuffix, TransparencyConstants.LIMITED_CERTAINTY_BADGE_SUFFIX)
        assertEquals(s.provisionalResultCaveat, TransparencyConstants.PROVISIONAL_RESULT_CAVEAT)
        assertEquals(s.unexplainedRatingCaveat, TransparencyRiskExplanation.UNEXPLAINED_RATING_CAVEAT)
        assertEquals(s.sectionHeading, HighRiskTransparencySection.HEADING)
        assertEquals(s.reasonsLabel, HighRiskTransparencySection.REASONS_LABEL)
        assertEquals(s.scoreBreakdownLabel, HighRiskTransparencySection.SCORE_BREAKDOWN_LABEL)
        assertEquals(s.otherConcernsLabel, HighRiskTransparencySection.OTHER_CONCERNS_LABEL)
        assertEquals(s.caveatsLabel, HighRiskTransparencySection.CAVEATS_LABEL)
        for (example in contract.introductionExamples) {
            assertEquals(example.text, HighRiskTransparencySection.introduction(example.count))
        }
        // Strings the desktop has no equivalent for: Python charges no missing statement it did
        // not read, so it has neither an "Unassessed" display nor an unrecorded-certainty note.
        assertEquals(contract.swiftKotlinOnly.unrecordedCertaintyNote, TransparencyConstants.UNRECORDED_CERTAINTY_NOTE)
        assertEquals(contract.swiftKotlinOnly.unassessedLabel, TransparencyConstants.UNASSESSED_LABEL)
        assertEquals(contract.swiftKotlinOnly.unassessedNote, TransparencyConstants.UNASSESSED_NOTE)
    }

    @Test
    fun `every case is explained as the contract says`() {
        assertFalse("risk-explanation cases are empty", contract.cases.isEmpty())
        for (case in contract.cases) {
            val result = resultFor(case)
            val explanation = TransparencyRiskExplanation.of(result)
            assertEquals(case.name, case.expected.score, result.transparencyScore)
            assertEquals(case.name, case.expected.riskLevel, result.riskLevel.name.lowercase())
            assertEquals(case.name, case.expected.reasons, explanation.reasons)
            assertEquals(
                case.name,
                case.expected.scoreBreakdown,
                explanation.scoreBreakdown.map { "${it.label}: ${it.signedPoints}" },
            )
            assertEquals(case.name, case.expected.caveats, explanation.caveats)
        }
    }

    /** Builds the [TransparencyResult] a platform-neutral fixture case describes. */
    private fun resultFor(case: Case): TransparencyResult {
        val f = case.findings
        val level = when (f.dataAvailability) {
            "full_open" -> DataDisclosureLevel.FULL_OPEN
            "on_request" -> DataDisclosureLevel.AVAILABLE_ON_REQUEST
            "restricted" -> DataDisclosureLevel.RESTRICTED
            "not_available" -> DataDisclosureLevel.NOT_AVAILABLE
            "not_stated" -> DataDisclosureLevel.NOT_STATED
            "unknown" -> DataDisclosureLevel.UNKNOWN
            else -> error("${case.name}: unknown data_availability finding '${f.dataAvailability}'")
        }
        val builder = TransparencyResultBuilder(doi = "10.1000/test", pmid = "123")
        builder.coiAnalysis = when (f.coi) {
            "disclosed" -> COIAnalysisResult(statement = "The authors declare no competing interests.")
            "not_stated" -> COIAnalysisResult.NOT_AVAILABLE
            else -> error("${case.name}: unknown coi finding '${f.coi}'")
        }
        builder.dataAvailability = DataAvailabilityResult(disclosureLevel = level)
        builder.industryFundingDetected = f.industryFunding
        builder.industryFundingConfidence = f.industryConfidence
        if (f.trialRegistered) {
            builder.trialRegistrations = listOf(
                TrialRegistration(
                    registry = TransparencyConstants.CLINICAL_TRIALS_REGISTRY_NAME,
                    registrationId = "NCT00000001",
                    resultsPosted = f.results == "compliant",
                ),
            )
        }
        builder.resultsCompliance = when (f.results) {
            "compliant" -> ResultsComplianceStatus.COMPLIANT
            "late" -> ResultsComplianceStatus.LATE
            "missing" -> ResultsComplianceStatus.MISSING
            "not_required" -> ResultsComplianceStatus.NOT_REQUIRED
            "unknown" -> ResultsComplianceStatus.UNKNOWN
            else -> error("${case.name}: unknown results finding '${f.results}'")
        }
        builder.outcomeSwitchingDetected = f.outcomeSwitching
        builder.sourcesUnreachable = f.sourcesUnreachable
        builder.fullTextSearched = true
        builder.dataSourcesUsed = listOf(TransparencyConstants.PUBMED_SOURCE_NAME, TransparencyConstants.CROSSREF_SOURCE_NAME)
        val built = builder.build()
        val stored = case.storedRiskLevel ?: return built
        return built.copy(riskLevel = TransparencyRiskLevel.valueOf(stored.uppercase()))
    }
}
