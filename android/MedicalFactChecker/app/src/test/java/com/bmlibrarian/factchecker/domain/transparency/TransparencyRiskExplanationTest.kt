package com.bmlibrarian.factchecker.domain.transparency

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Port of the Swift `TransparencyRiskExplanationTests`. */
class TransparencyRiskExplanationTest {

    private val cleanCoi = COIAnalysisResult(statement = "The authors declare no competing interests.")

    /** A result built the way the analysis service builds one. */
    private fun build(
        coi: COIAnalysisResult = COIAnalysisResult.NOT_AVAILABLE,
        data: DataAvailabilityResult = DataAvailabilityResult.NOT_STATED,
        industry: Boolean = false,
        funders: List<FunderInfo> = emptyList(),
        registrations: List<TrialRegistration> = emptyList(),
        compliance: ResultsComplianceStatus = ResultsComplianceStatus.UNKNOWN,
        fullTextSearched: Boolean? = true,
        sources: List<String> = listOf(TransparencyConstants.PUBMED_SOURCE_NAME),
    ): TransparencyResult {
        val builder = TransparencyResultBuilder(doi = "10.1000/test", pmid = "123")
        builder.coiAnalysis = coi
        builder.dataAvailability = data
        builder.industryFundingDetected = industry
        builder.industryFundingConfidence = if (industry) 0.9 else 0.0
        builder.funders = funders
        builder.trialRegistrations = registrations
        builder.resultsCompliance = compliance
        builder.fullTextSearched = fullTextSearched
        builder.dataSourcesUsed = sources
        return builder.build()
    }

    private fun registration(resultsPosted: Boolean) = TrialRegistration(
        registry = TransparencyConstants.CLINICAL_TRIALS_REGISTRY_NAME,
        registrationId = "NCT00000001",
        resultsPosted = resultsPosted,
    )

    private fun data(level: DataDisclosureLevel) = DataAvailabilityResult(disclosureLevel = level)

    // ==================== rules agree with the rating ====================

    @Test
    fun `triggers are non-empty exactly when rated high`() {
        for (score in 0..100 step 5) {
            for (industry in listOf(false, true)) {
                for (level in DataDisclosureLevel.entries) {
                    for (coi in listOf(false, true)) {
                        val rating = TransparencyScorer.calculateRiskLevel(score, industry, level, coi)
                        val triggers = TransparencyScorer.highRiskTriggers(score, industry, level, coi)
                        assertEquals(
                            "score $score, industry $industry, $level, coi $coi",
                            rating == TransparencyRiskLevel.HIGH,
                            triggers.isNotEmpty(),
                        )
                    }
                }
            }
        }
    }

    @Test
    fun `all matching triggers are returned`() {
        assertEquals(
            listOf(
                HighRiskTrigger.ScoreBelowThreshold(10, TransparencyConstants.HIGH_RISK_SCORE_THRESHOLD),
                HighRiskTrigger.IndustryFundingWithWithheldData(DataDisclosureLevel.NOT_AVAILABLE),
                HighRiskTrigger.MissingCOIStatement,
            ),
            TransparencyScorer.highRiskTriggers(10, true, DataDisclosureLevel.NOT_AVAILABLE, false),
        )
    }

    @Test
    fun `disabled rules are not returned`() {
        assertEquals(
            emptyList<HighRiskTrigger>(),
            TransparencyScorer.highRiskTriggers(
                80, true, DataDisclosureLevel.RESTRICTED, false,
                industryDataTriggersHighRisk = false, missingCoiTriggersHighRisk = false,
            ),
        )
    }

    // ==================== score components ====================

    @Test
    fun `score components sum to the score`() {
        val cases = listOf(
            build(),
            build(coi = cleanCoi, data = data(DataDisclosureLevel.FULL_OPEN)),
            build(
                coi = COIAnalysisResult(statement = "Consultant to Pfizer.", hasIndustryTies = true),
                data = data(DataDisclosureLevel.NOT_AVAILABLE),
                industry = true,
                registrations = listOf(registration(false)),
                compliance = ResultsComplianceStatus.MISSING,
            ),
            build(
                coi = cleanCoi,
                data = data(DataDisclosureLevel.AVAILABLE_ON_REQUEST),
                registrations = listOf(registration(true)),
                compliance = ResultsComplianceStatus.COMPLIANT,
            ),
        )
        for (result in cases) {
            assertEquals(result.transparencyScore, TransparencyScorer.scoreComponents(result).sumOf { it.points })
        }
    }

    @Test
    fun `disclosed industry ties show as credit and penalty`() {
        val labels = TransparencyScorer.scoreComponents(
            build(coi = COIAnalysisResult(statement = "Consultant to Pfizer.", hasIndustryTies = true)),
        ).map { it.label }
        assertTrue(labels.contains("Conflict of interest statement present"))
        assertTrue(labels.contains("Conflict of interest statement discloses industry ties"))
    }

    /** The exact terms and labels for one case, so every label is pinned to the Swift string. */
    @Test
    fun `score component labels`() {
        val components = TransparencyScorer.scoreComponents(
            build(
                data = data(DataDisclosureLevel.NOT_AVAILABLE),
                industry = true,
                registrations = listOf(registration(false)),
                compliance = ResultsComplianceStatus.MISSING,
            ),
        )
        assertEquals(
            listOf(
                ScoreComponent("Starting score", 50),
                ScoreComponent("Data availability: not available", -15),
                ScoreComponent("No conflict of interest statement found", -5),
                ScoreComponent("Trial registered", 10),
                ScoreComponent("Trial results not posted", -10),
                ScoreComponent("Industry ties with restricted or unavailable data", -10),
            ),
            components,
        )
    }

    @Test
    fun `signed points`() {
        assertEquals("+5", ScoreComponent("a", 5).signedPoints)
        assertEquals("-10", ScoreComponent("a", -10).signedPoints)
    }

    // ==================== explanation ====================

    @Test
    fun `missing COI with full text names the rule without a text caveat`() {
        val result = build(data = data(DataDisclosureLevel.FULL_OPEN))
        assertEquals(TransparencyRiskLevel.HIGH, result.riskLevel)

        val explanation = TransparencyRiskExplanation.of(result)
        assertEquals(
            listOf(
                "No conflict of interest statement was found in the full text. " +
                    "A missing statement is enough on its own for a high rating.",
            ),
            explanation.reasons,
        )
        assertTrue(explanation.caveats.toString(), explanation.caveats.isEmpty())
        assertEquals(TransparencyCertainty.FULL_TEXT, explanation.certainty)
        assertNull(explanation.certainty.note)
        assertTrue(explanation.scoreBreakdown.isEmpty())
    }

    @Test
    fun `missing COI without full text is flagged as unassessed`() {
        val result = build(fullTextSearched = false)
        assertEquals(TransparencyRiskLevel.HIGH, result.riskLevel)

        val explanation = TransparencyRiskExplanation.of(result)
        assertEquals(TransparencyCertainty.LIMITED_NO_FULL_TEXT, explanation.certainty)
        assertTrue(explanation.reasons[0].contains("was not searched"))
        assertTrue(explanation.caveats.any { it.contains("Treat the rating as unassessed") })
    }

    @Test
    fun `unrecorded full text is reported as unknown`() {
        val explanation = TransparencyRiskExplanation.of(build(fullTextSearched = null))
        assertEquals(TransparencyCertainty.UNRECORDED, explanation.certainty)
        assertEquals(TransparencyConstants.UNRECORDED_CERTAINTY_NOTE, explanation.certainty.note)
        assertTrue(explanation.caveats.any { it.contains("unassessed") })
    }

    @Test
    fun `a registry finding is not caveated as missing text`() {
        val result = build(
            coi = cleanCoi,
            data = data(DataDisclosureLevel.NOT_AVAILABLE),
            industry = true,
            registrations = listOf(registration(false)),
            compliance = ResultsComplianceStatus.MISSING,
            fullTextSearched = false,
        )
        assertEquals(TransparencyRiskLevel.HIGH, result.riskLevel)
        val caveats = TransparencyRiskExplanation.of(result).caveats
        assertFalse(caveats.toString(), caveats.any { it.contains("unassessed") })
    }

    @Test
    fun `a low score carries its breakdown`() {
        // 50 - 15 (no data) + 5 (COI statement) - 15 (outcome switching) = 25.
        val builder = TransparencyResultBuilder(doi = "10.1000/x")
        builder.coiAnalysis = cleanCoi
        builder.dataAvailability = data(DataDisclosureLevel.NOT_AVAILABLE)
        builder.outcomeSwitchingDetected = true
        builder.fullTextSearched = true
        builder.dataSourcesUsed = listOf(TransparencyConstants.CROSSREF_SOURCE_NAME)
        val low = builder.build()
        assertEquals(25, low.transparencyScore)

        val explanation = TransparencyRiskExplanation.of(low)
        assertEquals("Its transparency score of 25/100 is below the high-risk cut-off of 40.", explanation.reasons[0])
        assertEquals(low.transparencyScore, explanation.scoreBreakdown.sumOf { it.points })
    }

    @Test
    fun `industry reason names the industry funders`() {
        val pfizer = FunderInfo(name = "Pfizer Inc.", isIndustry = true, confidence = 0.9)
        val nih = FunderInfo(name = "NIH", isIndustry = false, confidence = 0.9)
        val explanation = TransparencyRiskExplanation.of(
            build(coi = cleanCoi, data = data(DataDisclosureLevel.RESTRICTED), industry = true, funders = listOf(pfizer, nih)),
        )
        val reason = explanation.reasons.single { it.contains("Industry funding") }
        assertEquals(
            "Industry funding was detected (Pfizer Inc.), with 90% confidence, " +
                "and its data are available only with restrictions.",
            reason,
        )
        assertFalse(
            "a concern the reason already states is not repeated",
            explanation.otherConcerns.contains(RiskIndicatorStrings.INDUSTRY_FUNDING),
        )
    }

    /** Swift's `rounded()` rounds exact halves away from zero (12.5 -> 13), where half-even would give 12. */
    @Test
    fun `industry confidence percentage rounds like Swift`() {
        fun percentFor(confidence: Double): String {
            val result = build(coi = cleanCoi, data = data(DataDisclosureLevel.NOT_STATED), industry = true)
                .copy(industryFundingConfidence = confidence)
            return TransparencyRiskExplanation.of(result).reasons.single { it.contains("Industry funding") }
        }
        assertTrue(percentFor(0.125).contains("with 13% confidence"))
        assertTrue(percentFor(0.375).contains("with 38% confidence"))
        assertTrue(percentFor(0.3).contains("with 30% confidence"))
    }

    @Test
    fun `no-statement data phrase depends on certainty`() {
        val withText = TransparencyRiskExplanation.of(
            build(coi = cleanCoi, data = data(DataDisclosureLevel.NOT_STATED), industry = true),
        ).reasons.single { it.contains("Industry funding") }
        assertTrue(withText.endsWith("and no data availability statement was found in the full text."))
        val withoutText = TransparencyRiskExplanation.of(
            build(coi = cleanCoi, data = data(DataDisclosureLevel.NOT_STATED), industry = true, fullTextSearched = false),
        ).reasons.single { it.contains("Industry funding") }
        assertTrue(
            withoutText.endsWith(
                "and no data availability statement was found (the full text, where it would appear, was not searched).",
            ),
        )
    }

    @Test
    fun `an unexplained high rating is caveated`() {
        val result = TransparencyResult(
            coiAnalysis = cleanCoi,
            dataAvailability = data(DataDisclosureLevel.FULL_OPEN),
            transparencyScore = 90,
            riskLevel = TransparencyRiskLevel.HIGH,
            dataSourcesUsed = listOf(TransparencyConstants.PUBMED_SOURCE_NAME),
            fullTextSearched = true,
        )
        val explanation = TransparencyRiskExplanation.of(result)
        assertTrue(explanation.reasons.isEmpty())
        assertTrue(explanation.caveats.any { it.startsWith("None of the current high-risk rules") })
    }

    @Test
    fun `provenance caveats`() {
        val result = TransparencyResult(
            transparencyScore = 40,
            riskLevel = TransparencyRiskLevel.HIGH,
            dataSourcesUsed = emptyList(),
            errors = listOf("timeout"),
            analyzerVersion = null,
            fullTextSearched = true,
        )
        val caveats = TransparencyRiskExplanation.of(result).caveats
        assertTrue(caveats.any { it.contains("older version of the analyser") })
        assertTrue(caveats.contains("Neither PubMed nor CrossRef returned a record for this study, so its funders could not be checked."))
        assertTrue(caveats.contains("The analysis reported errors: timeout."))
    }

    // ==================== section ====================

    @Test
    fun `the section is absent without high-risk studies`() = assertNull(HighRiskTransparencySection.plainText(emptyList()))

    @Test
    fun `introduction`() {
        assertNull(HighRiskTransparencySection.introduction(0))
        assertEquals(
            "1 study was rated high transparency risk. Each rule listed below is enough on its own for that " +
                "rating; the caveats say where a rating rests on less than it appears to.",
            HighRiskTransparencySection.introduction(1),
        )
    }

    @Test
    fun `the section lists each study with its reasons`() {
        val entry = HighRiskTransparencyEntry(
            reference = "Smith et al., 2020",
            citation = "Smith J et al. (2020). A trial. DOI: 10.1000/test",
            result = build(fullTextSearched = false),
        )
        val text = HighRiskTransparencySection.plainText(listOf(entry, entry))!!
        assertTrue(text.startsWith(HighRiskTransparencySection.HEADING.uppercase()))
        assertTrue(text.contains("2 studies were rated high transparency risk"))
        assertTrue(text.contains("Smith et al., 2020: Smith J et al. (2020). A trial."))
        assertTrue(text.contains("Rated high risk because:"))
        assertTrue(text.contains("Treat the rating as unassessed"))
        assertTrue(text.contains(TransparencyConstants.LIMITED_CERTAINTY_NOTE))
    }

    /** One entry's plain text, line for line, as the Swift export writes it. */
    @Test
    fun `plain text layout`() {
        val entry = HighRiskTransparencyEntry("Doe, 2021", "Doe J (2021). X.", build(fullTextSearched = false))
        assertEquals(
            listOf(
                "WHY STUDIES WERE RATED HIGH TRANSPARENCY RISK",
                "",
                "1 study was rated high transparency risk. Each rule listed below is enough on its own for that " +
                    "rating; the caveats say where a rating rests on less than it appears to.",
                "",
                "Doe, 2021: Doe J (2021). X.",
                "  Transparency score: 40/100",
                "  Limited certainty because of lack of full text access",
                "  Rated high risk because:",
                "  - No conflict of interest statement was found; the full text, where one would appear, " +
                    "was not searched. A missing statement is enough on its own for a high rating.",
                "  Caveats:",
                "  - Every reason for this rating depends on statements that appear only in the full text. " +
                    "Treat the rating as unassessed rather than as evidence of poor transparency.",
            ).joinToString("\n"),
            HighRiskTransparencySection.plainText(listOf(entry)),
        )
    }

    @Test
    fun `limited certainty is stated even when a reason stands without text`() {
        val explanation = TransparencyRiskExplanation.of(
            build(
                coi = cleanCoi,
                data = data(DataDisclosureLevel.NOT_AVAILABLE),
                industry = true,
                registrations = listOf(registration(false)),
                compliance = ResultsComplianceStatus.MISSING,
                fullTextSearched = false,
            ),
        )
        assertTrue(explanation.plainTextLines.contains("  ${TransparencyConstants.LIMITED_CERTAINTY_NOTE}"))
    }

    @Test
    fun `a certainty override replaces an unrecorded one`() {
        val explanation = TransparencyRiskExplanation.of(
            build(fullTextSearched = null),
            TransparencyCertainty.LIMITED_NO_FULL_TEXT,
        )
        assertEquals(TransparencyConstants.LIMITED_CERTAINTY_NOTE, explanation.certainty.note)
    }

    // ==================== certainty ====================

    @Test
    fun `certainty from record`() {
        assertEquals(TransparencyCertainty.FULL_TEXT, TransparencyCertainty.from(true))
        assertEquals(TransparencyCertainty.LIMITED_NO_FULL_TEXT, TransparencyCertainty.from(false))
        assertEquals(TransparencyCertainty.UNRECORDED, TransparencyCertainty.from(null))
        assertFalse(TransparencyCertainty.FULL_TEXT.isLimited)
        assertTrue(TransparencyCertainty.LIMITED_NO_FULL_TEXT.isLimited)
        assertTrue(TransparencyCertainty.UNRECORDED.isLimited)
        assertEquals("Limited certainty because of lack of full text access", TransparencyConstants.LIMITED_CERTAINTY_NOTE)
    }

    @Test
    fun `tooltip carries the certainty note`() {
        assertTrue(
            TransparencyScorer.formatTooltip(build(fullTextSearched = false)).contains(TransparencyConstants.LIMITED_CERTAINTY_NOTE),
        )
        assertFalse(
            TransparencyScorer.formatTooltip(build(fullTextSearched = true)).contains(TransparencyConstants.LIMITED_CERTAINTY_NOTE),
        )
    }

    // ==================== persistence ====================

    @Test
    fun `a result without the full-text field decodes as unknown`() {
        val stored = Json.parseToJsonElement(TransparencyJson.encode(build(fullTextSearched = true))).jsonObject
        val decoded = TransparencyJson.decode(JsonObject(stored - "fullTextSearched").toString())
        assertNull(decoded.fullTextSearched)
    }
}
