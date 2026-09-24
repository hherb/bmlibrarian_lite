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
        sources: List<String> = listOf(TransparencyConstants.PUBMED_SOURCE_NAME, TransparencyConstants.CROSSREF_SOURCE_NAME),
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
                ScoreComponent("No conflict of interest statement found", -5, recordsMissingStatement = true),
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
        assertTrue(explanation.caveats.any { it.contains("shown as unassessed") })
    }

    /**
     * Unknown coverage is reported as unknown — not as unsearched text, which may be false —
     * and the rating stays high rather than unassessed.
     */
    @Test
    fun `unrecorded full text is reported as unknown`() {
        val explanation = TransparencyRiskExplanation.of(build(fullTextSearched = null))
        assertEquals(TransparencyCertainty.UNRECORDED, explanation.certainty)
        assertEquals(TransparencyConstants.UNRECORDED_CERTAINTY_NOTE, explanation.certainty.note)
        assertEquals(
            listOf(
                "No conflict of interest statement was found; whether the full text, where one would " +
                    "appear, was searched was not recorded. A missing statement is enough on its own " +
                    "for a high rating.",
            ),
            explanation.reasons,
        )
        assertFalse(explanation.isUnassessed)
        assertFalse(explanation.caveats.any { it.contains("unassessed") })
    }

    @Test
    fun `unrecorded full text qualifies score terms as possibly unsearched`() {
        val builder = TransparencyResultBuilder(doi = "10.1000/x")
        builder.industryFundingDetected = true
        builder.industryFundingConfidence = 0.9
        builder.outcomeSwitchingDetected = true
        builder.fullTextSearched = null
        val explanation = TransparencyRiskExplanation.of(builder.build())
        assertTrue(
            explanation.scoreBreakdown.any {
                it.label == "No conflict of interest statement found (full text may not have been searched)"
            },
        )
        assertTrue(
            explanation.reasons.any {
                it.contains(
                    "no data availability statement was found (whether the full text, where it " +
                        "would appear, was searched was not recorded)",
                )
            },
        )
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
        assertTrue(caveats.any { it.startsWith("No CrossRef record was retrieved") })
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
        assertTrue(text.contains("shown as unassessed"))
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
                "  - Every reason for a high rating depends on statements that appear only in the full text, " +
                    "which was not searched, so the study is shown as unassessed rather than as evidence of " +
                    "poor transparency.",
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

    /** Funders come only from CrossRef; a PubMed record does not stand in for it. */
    @Test
    fun `missing CrossRef is caveated even with PubMed`() {
        val pubmedOnly = TransparencyRiskExplanation.of(build(sources = listOf(TransparencyConstants.PUBMED_SOURCE_NAME)))
        assertTrue(pubmedOnly.caveats.any { it.contains("funders were not checked") })
        val withCrossRef = TransparencyRiskExplanation.of(build(sources = listOf(TransparencyConstants.CROSSREF_SOURCE_NAME)))
        assertFalse(withCrossRef.caveats.any { it.contains("funders were not checked") })
    }

    /**
     * Without full text, the COI warning is not repeated unqualified, and a score term
     * recording a missing statement says it was not searched.
     */
    @Test
    fun `unsearched statements are not repeated as findings`() {
        val builder = TransparencyResultBuilder(doi = "10.1000/x")
        builder.industryFundingDetected = true
        builder.industryFundingConfidence = 0.9
        builder.dataAvailability = DataAvailabilityResult(disclosureLevel = DataDisclosureLevel.NOT_AVAILABLE)
        builder.outcomeSwitchingDetected = true
        builder.fullTextSearched = false
        builder.warnings = listOf(RiskIndicatorStrings.FUNDING_WITHOUT_COI_STATEMENT)
        val result = builder.build()
        assertTrue(result.transparencyScore < TransparencyConstants.HIGH_RISK_SCORE_THRESHOLD)

        val explanation = TransparencyRiskExplanation.of(result)
        assertFalse(RiskIndicatorStrings.FUNDING_WITHOUT_COI_STATEMENT in explanation.otherConcerns)
        assertTrue(
            explanation.scoreBreakdown.any {
                it.label == "No conflict of interest statement found (full text not searched)"
            },
        )
    }

    // ==================== Unassessed ====================

    @Test
    fun `a text-only high rating is unassessed`() {
        val result = build(fullTextSearched = false)
        assertEquals(TransparencyRiskLevel.HIGH, result.riskLevel)
        assertTrue(TransparencyRiskExplanation.isUnassessed(result))
        assertTrue(TransparencyRiskExplanation.of(result).isUnassessed)
        assertFalse(
            "unrecorded coverage may have included the text, so the rating stays high",
            TransparencyRiskExplanation.isUnassessed(build(fullTextSearched = null)),
        )
    }

    @Test
    fun `industry funding with unstated data and no text is unassessed`() {
        val result = build(coi = cleanCoi, industry = true, fullTextSearched = false)
        assertEquals(
            listOf(HighRiskTrigger.IndustryFundingWithWithheldData(DataDisclosureLevel.NOT_STATED)),
            TransparencyScorer.highRiskTriggers(result),
        )
        assertTrue(TransparencyRiskExplanation.isUnassessed(result))
    }

    @Test
    fun `industry funding with restricted data and no text stays high`() {
        val result = build(coi = cleanCoi, data = data(DataDisclosureLevel.RESTRICTED), industry = true, fullTextSearched = false)
        assertEquals(
            listOf(HighRiskTrigger.IndustryFundingWithWithheldData(DataDisclosureLevel.RESTRICTED)),
            TransparencyScorer.highRiskTriggers(result),
        )
        assertFalse(TransparencyRiskExplanation.isUnassessed(result))
    }

    /** A stored result rated high at a given score, with no COI or data statement. */
    private fun storedHigh(score: Int, fullTextSearched: Boolean?) = TransparencyResult(
        transparencyScore = score,
        riskLevel = TransparencyRiskLevel.HIGH,
        dataSourcesUsed = listOf(TransparencyConstants.CROSSREF_SOURCE_NAME),
        fullTextSearched = fullTextSearched,
    )

    /** A low score is text-dependent exactly when the unsearched penalties alone carry it below the cut-off. */
    @Test
    fun `a low score is unassessed only when unsearched penalties carry it`() {
        val boundary = TransparencyConstants.HIGH_RISK_SCORE_THRESHOLD +
            TransparencyConstants.MISSING_COI_PENALTY + TransparencyConstants.NO_STATEMENT_PENALTY
        assertTrue(TransparencyRiskExplanation.isUnassessed(storedHigh(boundary, false)))
        assertFalse(TransparencyRiskExplanation.isUnassessed(storedHigh(boundary - 1, false)))
    }

    @Test
    fun `an unexplained high rating without text is not unassessed`() {
        val result = TransparencyResult(
            coiAnalysis = COIAnalysisResult(statement = "None declared."),
            dataAvailability = data(DataDisclosureLevel.FULL_OPEN),
            transparencyScore = 90,
            riskLevel = TransparencyRiskLevel.HIGH,
            dataSourcesUsed = listOf(TransparencyConstants.CROSSREF_SOURCE_NAME),
            fullTextSearched = false,
        )
        assertTrue(TransparencyScorer.highRiskTriggers(result).isEmpty())
        assertFalse(TransparencyRiskExplanation.isUnassessed(result))
        val explanation = TransparencyRiskExplanation.of(result)
        assertTrue(explanation.caveats.contains(TransparencyRiskExplanation.UNEXPLAINED_RATING_CAVEAT))
        assertFalse(explanation.caveats.contains(TransparencyRiskExplanation.UNASSESSED_CAVEAT))
    }

    @Test
    fun `the unassessed caveat agrees with the flag`() {
        val cases = listOf(
            build(fullTextSearched = false),
            build(fullTextSearched = null),
            build(fullTextSearched = true),
            storedHigh(10, false),
            TransparencyResult(transparencyScore = 30, riskLevel = TransparencyRiskLevel.MEDIUM, fullTextSearched = false),
        )
        for (result in cases) {
            val explanation = TransparencyRiskExplanation.of(result)
            assertEquals(
                "${result.riskLevel}, score ${result.transparencyScore}, searched ${result.fullTextSearched}",
                explanation.isUnassessed,
                explanation.caveats.contains(TransparencyRiskExplanation.UNASSESSED_CAVEAT),
            )
        }
    }

    @Test
    fun `score components flag missing statements`() {
        assertEquals(2, TransparencyScorer.scoreComponents(build()).count { it.recordsMissingStatement })
        assertFalse(
            TransparencyScorer.scoreComponents(build(coi = cleanCoi, data = data(DataDisclosureLevel.RESTRICTED)))
                .any { it.recordsMissingStatement },
        )
    }

    /** The CrossRef warning is not repeated as a concern beside the no-CrossRef caveat. */
    @Test
    fun `a CrossRef outage is not repeated as a concern`() {
        val builder = TransparencyResultBuilder(doi = "10.1000/x")
        builder.fullTextSearched = true
        builder.warnings = listOf(TransparencyConstants.CROSSREF_UNREACHABLE_WARNING)
        val explanation = TransparencyRiskExplanation.of(builder.build())
        assertTrue(explanation.caveats.contains(TransparencyRiskExplanation.NO_CROSSREF_CAVEAT))
        assertFalse(explanation.otherConcerns.contains(TransparencyConstants.CROSSREF_UNREACHABLE_WARNING))
    }

    @Test
    fun `the same finding from searched text is a real high rating`() {
        val result = build(fullTextSearched = true)
        assertEquals(TransparencyRiskLevel.HIGH, result.riskLevel)
        assertFalse(TransparencyRiskExplanation.isUnassessed(result))
    }

    @Test
    fun `a registry finding keeps the rating high`() {
        val result = build(
            coi = COIAnalysisResult(statement = "The authors declare no competing interests."),
            data = DataAvailabilityResult(disclosureLevel = DataDisclosureLevel.NOT_AVAILABLE),
            industry = true,
            fullTextSearched = false,
        )
        assertEquals(TransparencyRiskLevel.HIGH, result.riskLevel)
        assertFalse(TransparencyRiskExplanation.isUnassessed(result))
    }

    @Test
    fun `lower ratings are never unassessed`() {
        val result = build(
            coi = COIAnalysisResult(statement = "None."),
            data = DataAvailabilityResult(disclosureLevel = DataDisclosureLevel.FULL_OPEN),
            fullTextSearched = false,
        )
        assertFalse(result.riskLevel == TransparencyRiskLevel.HIGH)
        assertFalse(TransparencyRiskExplanation.isUnassessed(result))
    }

    @Test
    fun `unassessed summary`() {
        assertNull(HighRiskTransparencySection.unassessedSummary(0))
        assertTrue(HighRiskTransparencySection.unassessedSummary(1)!!.startsWith("1 study is shown as unassessed"))
        assertTrue(HighRiskTransparencySection.unassessedSummary(3)!!.startsWith("3 studies are shown as unassessed"))
    }

    @Test
    fun `a section with only unassessed studies says so rather than vanishing`() {
        assertTrue(HighRiskTransparencySection.plainText(emptyList(), 2)!!.contains("2 studies are shown as unassessed"))
        assertNull(HighRiskTransparencySection.plainText(emptyList(), 0))
    }
}
