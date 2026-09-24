package com.bmlibrarian.factchecker.domain.transparency

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Port of the Swift `TransparencyScorerTests`. */
class TransparencyScorerTest {

    private fun data(level: DataDisclosureLevel) = DataAvailabilityResult(disclosureLevel = level)

    private fun registration(resultsPosted: Boolean = false) =
        TrialRegistration(registry = "CT.gov", registrationId = "NCT123", resultsPosted = resultsPosted)

    private fun score(
        data: DataAvailabilityResult = DataAvailabilityResult.NOT_STATED,
        coi: COIAnalysisResult = COIAnalysisResult.NOT_AVAILABLE,
        registrations: List<TrialRegistration> = emptyList(),
        compliance: ResultsComplianceStatus = ResultsComplianceStatus.UNKNOWN,
        industry: Boolean = false,
        switching: Boolean = false,
    ) = TransparencyScorer.calculateScore(data, coi, registrations, compliance, industry, switching)

    private fun indicators(
        industry: Boolean = false,
        data: DataAvailabilityResult = DataAvailabilityResult.NOT_STATED,
        compliance: ResultsComplianceStatus = ResultsComplianceStatus.UNKNOWN,
        coi: COIAnalysisResult = COIAnalysisResult.NOT_AVAILABLE,
        switching: Boolean = false,
        title: String? = null,
    ) = TransparencyScorer.identifyRiskIndicators(industry, data, compliance, coi, emptyList(), switching, title)

    // ==================== score ====================

    /** Base (50) + data (-5) + COI (-5) = 40. */
    @Test fun `base case`() = assertEquals(40, score())

    /** Base (50) + data (20) + COI (5) + trial (10) + results (5) = 90. */
    @Test fun `good transparency`() = assertEquals(
        90,
        score(
            data(DataDisclosureLevel.FULL_OPEN),
            COIAnalysisResult(statement = "No conflicts"),
            listOf(registration(resultsPosted = true)),
            ResultsComplianceStatus.COMPLIANT,
        ),
    )

    /** Base (50) + data (-15) + COI (-5) + outcome (-15) + industry+nodata (-10) = 5. */
    @Test fun `poor transparency`() = assertEquals(
        5,
        score(
            data(DataDisclosureLevel.NOT_AVAILABLE),
            compliance = ResultsComplianceStatus.MISSING,
            industry = true,
            switching = true,
        ),
    )

    @Test
    fun `score is clamped`() {
        val value = score(
            data(DataDisclosureLevel.NOT_AVAILABLE),
            registrations = listOf(registration()),
            compliance = ResultsComplianceStatus.MISSING,
            industry = true,
            switching = true,
        )
        assertTrue(value in 0..100)
    }

    /** Base (50) + data (5) + COI (5) = 60. */
    @Test fun `on request data`() = assertEquals(
        60,
        score(data(DataDisclosureLevel.AVAILABLE_ON_REQUEST), COIAnalysisResult(statement = "None")),
    )

    @Test
    fun `data availability points`() {
        assertEquals(TransparencyConstants.FULL_OPEN_DATA_POINTS, TransparencyScorer.dataAvailabilityPoints(DataDisclosureLevel.FULL_OPEN))
        assertEquals(TransparencyConstants.ON_REQUEST_DATA_POINTS, TransparencyScorer.dataAvailabilityPoints(DataDisclosureLevel.AVAILABLE_ON_REQUEST))
        assertEquals(TransparencyConstants.RESTRICTED_DATA_PENALTY, TransparencyScorer.dataAvailabilityPoints(DataDisclosureLevel.RESTRICTED))
        assertEquals(TransparencyConstants.NO_DATA_PENALTY, TransparencyScorer.dataAvailabilityPoints(DataDisclosureLevel.NOT_AVAILABLE))
        assertEquals(TransparencyConstants.NO_STATEMENT_PENALTY, TransparencyScorer.dataAvailabilityPoints(DataDisclosureLevel.NOT_STATED))
        assertEquals(0, TransparencyScorer.dataAvailabilityPoints(DataDisclosureLevel.UNKNOWN))
    }

    @Test
    fun `COI disclosure points`() {
        assertEquals(TransparencyConstants.COI_STATEMENT_POINTS, TransparencyScorer.coiDisclosurePoints(true, false))
        assertEquals(TransparencyConstants.MISSING_COI_PENALTY, TransparencyScorer.coiDisclosurePoints(false))
        assertEquals(
            TransparencyConstants.COI_STATEMENT_POINTS + TransparencyConstants.COI_INDUSTRY_TIES_PENALTY,
            TransparencyScorer.coiDisclosurePoints(true, true),
        )
    }

    /** fullOpen (+20) + COI statement (+5): 75 without ties, 70 with the -5 ties penalty. */
    @Test
    fun `disclosed COI ties lower the score`() {
        assertEquals(75, score(data(DataDisclosureLevel.FULL_OPEN), COIAnalysisResult(statement = "Grants from a foundation")))
        assertEquals(
            70,
            score(data(DataDisclosureLevel.FULL_OPEN), COIAnalysisResult(statement = "Grants from Pfizer", hasIndustryTies = true)),
        )
    }

    /** Base (50) + restricted (-5) + COI (+5) + ties (-5) + combined (-10) = 35. */
    @Test fun `COI ties with restricted data`() = assertEquals(
        35,
        score(data(DataDisclosureLevel.RESTRICTED), COIAnalysisResult(statement = "Grants from Pfizer", hasIndustryTies = true)),
    )

    @Test
    fun `trial registration points`() {
        assertEquals(0, TransparencyScorer.trialRegistrationPoints(emptyList(), ResultsComplianceStatus.UNKNOWN))
        assertEquals(
            TransparencyConstants.TRIAL_REGISTRATION_POINTS + TransparencyConstants.COMPLIANT_RESULTS_POINTS,
            TransparencyScorer.trialRegistrationPoints(listOf(registration()), ResultsComplianceStatus.COMPLIANT),
        )
        assertEquals(
            TransparencyConstants.TRIAL_REGISTRATION_POINTS + TransparencyConstants.MISSING_RESULTS_PENALTY,
            TransparencyScorer.trialRegistrationPoints(listOf(registration()), ResultsComplianceStatus.MISSING),
        )
    }

    // ==================== risk level ====================

    private fun level(
        score: Int,
        industry: Boolean = false,
        data: DataDisclosureLevel = DataDisclosureLevel.FULL_OPEN,
        coi: Boolean = true,
    ) = TransparencyScorer.calculateRiskLevel(score, industry, data, coi)

    @Test fun `low`() = assertEquals(TransparencyRiskLevel.LOW, level(80))

    @Test fun `medium by score`() = assertEquals(TransparencyRiskLevel.MEDIUM, level(55))

    @Test fun `medium at the medium threshold`() = assertEquals(TransparencyRiskLevel.MEDIUM, level(70))

    @Test fun `medium by industry`() = assertEquals(TransparencyRiskLevel.MEDIUM, level(80, industry = true))

    @Test fun `high by score`() = assertEquals(TransparencyRiskLevel.HIGH, level(30))

    @Test fun `high by industry with withheld data`() =
        assertEquals(TransparencyRiskLevel.HIGH, level(60, industry = true, data = DataDisclosureLevel.NOT_AVAILABLE))

    @Test fun `high by industry with no data statement`() =
        assertEquals(TransparencyRiskLevel.HIGH, level(60, industry = true, data = DataDisclosureLevel.NOT_STATED))

    @Test fun `high by missing COI`() = assertEquals(TransparencyRiskLevel.HIGH, level(60, coi = false))

    @Test fun `custom threshold`() = assertEquals(
        TransparencyRiskLevel.MEDIUM,
        TransparencyScorer.calculateRiskLevel(50, false, DataDisclosureLevel.FULL_OPEN, true, scoreThreshold = 30),
    )

    @Test fun `industry data trigger disabled`() = assertEquals(
        TransparencyRiskLevel.MEDIUM,
        TransparencyScorer.calculateRiskLevel(
            60, true, DataDisclosureLevel.NOT_AVAILABLE, true, industryDataTriggersHighRisk = false,
        ),
    )

    // ==================== risk indicators ====================

    @Test
    fun `industry indicators`() {
        val result = indicators(industry = true, data = data(DataDisclosureLevel.NOT_AVAILABLE))
        assertTrue(result.contains("Industry funding detected"))
        assertTrue(result.contains("Industry-funded with restricted data access"))
    }

    @Test fun `missing results indicator`() = assertTrue(
        indicators(compliance = ResultsComplianceStatus.MISSING).any { it.contains("Trial results not posted") },
    )

    @Test fun `industry ties indicator`() = assertTrue(
        indicators(
            data = data(DataDisclosureLevel.FULL_OPEN),
            coi = COIAnalysisResult(statement = "Grants from Pfizer", hasIndustryTies = true),
        ).contains("Authors have disclosed industry financial ties"),
    )

    @Test fun `missing COI indicator`() = assertTrue(
        indicators(data = data(DataDisclosureLevel.FULL_OPEN)).contains("No conflict of interest statement found"),
    )

    @Test fun `empty COI statement counts as missing`() = assertTrue(
        indicators(data = data(DataDisclosureLevel.FULL_OPEN), coi = COIAnalysisResult(statement = ""))
            .contains("No conflict of interest statement found"),
    )

    @Test fun `missing registration indicator`() = assertTrue(
        indicators(
            data = data(DataDisclosureLevel.FULL_OPEN),
            coi = COIAnalysisResult(statement = "None"),
            title = "Randomized Controlled Trial",
        ).any { it.contains("without detected registration") },
    )

    @Test fun `outcome switching indicator`() = assertTrue(
        indicators(data = data(DataDisclosureLevel.FULL_OPEN), coi = COIAnalysisResult(statement = "None"), switching = true)
            .contains("Outcome switching detected"),
    )

    @Test
    fun `data availability indicators`() {
        assertTrue(
            indicators(data = data(DataDisclosureLevel.NOT_AVAILABLE), coi = COIAnalysisResult(statement = "None"))
                .contains("Data effectively unavailable despite sharing statement"),
        )
        assertTrue(
            indicators(data = data(DataDisclosureLevel.RESTRICTED), coi = COIAnalysisResult(statement = "None"))
                .contains("Data access restricted"),
        )
    }

    @Test
    fun `institutional intermediary indicator`() {
        val result = indicators(
            data = data(DataDisclosureLevel.FULL_OPEN),
            coi = COIAnalysisResult(
                statement = "Dr. Smith reports grants to the University of Example from AstraZeneca, but no personal funding.",
                hasIndustryTies = true,
            ),
        )
        assertTrue(result.contains("Authors have disclosed industry financial ties"))
        assertTrue(result.contains("Industry funding routed through institutional intermediaries"))
    }

    @Test fun `no institutional intermediary for a plain tie`() = assertFalse(
        indicators(
            data = data(DataDisclosureLevel.FULL_OPEN),
            coi = COIAnalysisResult(statement = "Grants from Pfizer", hasIndustryTies = true),
        ).contains("Industry funding routed through institutional intermediaries"),
    )

    @Test fun `combined industry data indicator via COI ties`() = assertTrue(
        indicators(
            data = data(DataDisclosureLevel.RESTRICTED),
            coi = COIAnalysisResult(statement = "Grants from Pfizer", hasIndustryTies = true),
        ).contains("Industry ties combined with restricted/unavailable data"),
    )

    /** The exact indicator order a maximal case produces, pinned against the Swift sequence. */
    @Test
    fun `indicators are deduplicated and ordered`() {
        val result = indicators(
            industry = true,
            data = data(DataDisclosureLevel.NOT_AVAILABLE),
            compliance = ResultsComplianceStatus.MISSING,
            coi = COIAnalysisResult(statement = "Grants from Pfizer", hasIndustryTies = true),
            switching = true,
            title = "Randomized Controlled Trial",
        )
        assertEquals(
            listOf(
                RiskIndicatorStrings.INDUSTRY_FUNDING,
                RiskIndicatorStrings.INDUSTRY_RESTRICTED_DATA,
                RiskIndicatorStrings.RESULTS_NOT_POSTED,
                RiskIndicatorStrings.INDUSTRY_TIES_DISCLOSED,
                RiskIndicatorStrings.DATA_EFFECTIVELY_UNAVAILABLE,
                RiskIndicatorStrings.OUTCOME_SWITCHING,
                RiskIndicatorStrings.COMBINED_INDUSTRY_DATA,
                RiskIndicatorStrings.MISSING_TRIAL_REGISTRATION,
            ),
            result,
        )
    }

    // ==================== tooltip ====================

    @Test
    fun `tooltip`() {
        val tooltip = TransparencyScorer.formatTooltip(
            TransparencyResult(
                title = "Test Study",
                transparencyScore = 65,
                riskLevel = TransparencyRiskLevel.MEDIUM,
                riskIndicators = listOf("Industry funding detected"),
            ),
        )
        assertTrue(tooltip.contains("65/100"))
        assertTrue(tooltip.contains("Medium Risk"))
        assertTrue(tooltip.contains("Risk Indicators:"))
        assertTrue(tooltip.contains("  • Industry funding detected"))
    }

    @Test
    fun `tooltip with industry funding truncates the percentage`() {
        val tooltip = TransparencyScorer.formatTooltip(
            TransparencyResult(
                industryFundingDetected = true,
                industryFundingConfidence = 0.859,
                transparencyScore = 50,
                riskLevel = TransparencyRiskLevel.MEDIUM,
            ),
        )
        assertTrue(tooltip.contains("Industry Funding: Detected (85% confidence)"))
    }

    @Test
    fun `tooltip with trial registration`() {
        val tooltip = TransparencyScorer.formatTooltip(
            TransparencyResult(
                trialRegistrations = listOf(registration(resultsPosted = true)),
                transparencyScore = 70,
                riskLevel = TransparencyRiskLevel.LOW,
            ),
        )
        assertTrue(tooltip.contains("Trial Registration: Registered (Results Compliant)"))
    }

    @Test
    fun `tooltip summarises indicators beyond five`() {
        val tooltip = TransparencyScorer.formatTooltip(
            TransparencyResult(riskIndicators = (1..7).map { "Indicator $it" }),
        )
        assertTrue(tooltip.contains("  ... and 2 more"))
        assertFalse(tooltip.contains("Indicator 6"))
    }

    /** The whole tooltip, pinned line for line against the Swift format. */
    @Test
    fun `tooltip layout`() {
        val tooltip = TransparencyScorer.formatTooltip(
            TransparencyResult(
                coiAnalysis = COIAnalysisResult(statement = "None declared"),
                dataAvailability = data(DataDisclosureLevel.FULL_OPEN),
                transparencyScore = 75,
                riskLevel = TransparencyRiskLevel.LOW,
                fullTextSearched = true,
            ),
        )
        assertEquals(
            listOf(
                "Transparency Score: 75/100",
                "Risk Level: Low Risk",
                "",
                "Industry Funding: Not detected",
                "Data Availability: Fully Open",
                "Conflicts of Interest: No conflicts",
            ).joinToString("\n"),
            tooltip,
        )
    }

    // ==================== score category ====================

    @Test
    fun `score categories`() {
        assertEquals("Good transparency", TransparencyScorer.scoreCategory(90))
        assertEquals("Good transparency", TransparencyScorer.scoreCategory(76))
        assertEquals("Average transparency", TransparencyScorer.scoreCategory(75))
        assertEquals("Average transparency", TransparencyScorer.scoreCategory(60))
        assertEquals("Average transparency", TransparencyScorer.scoreCategory(51))
        assertEquals("Below average transparency", TransparencyScorer.scoreCategory(50))
        assertEquals("Below average transparency", TransparencyScorer.scoreCategory(40))
        assertEquals("Below average transparency", TransparencyScorer.scoreCategory(26))
        assertEquals("Poor transparency", TransparencyScorer.scoreCategory(25))
        assertEquals("Poor transparency", TransparencyScorer.scoreCategory(10))
        assertEquals("Poor transparency", TransparencyScorer.scoreCategory(0))
    }

    // ==================== builder integration ====================

    /** Base (50) + data (20) + COI (5) = 75. */
    @Test
    fun `builder uses the scorer`() {
        val builder = TransparencyResultBuilder(pmid = "12345678")
        builder.dataAvailability = data(DataDisclosureLevel.FULL_OPEN)
        builder.coiAnalysis = COIAnalysisResult(statement = "No conflicts")
        val result = builder.build()
        assertEquals(75, result.transparencyScore)
        assertEquals(TransparencyRiskLevel.LOW, result.riskLevel)
    }

    @Test
    fun `builder with industry funding and withheld data rates high`() {
        val builder = TransparencyResultBuilder(pmid = "12345678")
        builder.dataAvailability = data(DataDisclosureLevel.NOT_AVAILABLE)
        builder.coiAnalysis = COIAnalysisResult(statement = "No conflicts")
        builder.industryFundingDetected = true
        assertEquals(TransparencyRiskLevel.HIGH, builder.build().riskLevel)
    }
}
