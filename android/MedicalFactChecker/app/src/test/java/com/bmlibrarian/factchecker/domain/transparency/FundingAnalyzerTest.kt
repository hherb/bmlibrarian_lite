package com.bmlibrarian.factchecker.domain.transparency

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Port of the Swift `FundingAnalyzerTests`. */
class FundingAnalyzerTest {

    // ==================== classification ====================

    @Test
    fun `known industry funder by DOI`() {
        val (industry, confidence) = FundingAnalyzer.classifyFunder("Pfizer", "10.13039/100004319")
        assertTrue(industry)
        assertEquals(1.0, confidence, 0.0)
    }

    @Test
    fun `several known industry funder DOIs`() {
        val cases = listOf(
            "AstraZeneca" to "10.13039/100004325",
            "Novartis" to "10.13039/100004336",
            "Roche" to "10.13039/100004339",
            "Merck" to "10.13039/100004334",
        )
        for ((name, doi) in cases) {
            val (industry, confidence) = FundingAnalyzer.classifyFunder(name, doi)
            assertTrue(name, industry)
            assertEquals(name, 1.0, confidence, 0.0)
        }
    }

    @Test
    fun `NIH is government`() {
        val (industry, confidence) = FundingAnalyzer.classifyFunder("National Institutes of Health")
        assertFalse(industry)
        assertTrue(confidence > 0.8)
    }

    @Test
    fun `government funders are not industry`() {
        for (funder in listOf(
            "NIH", "National Science Foundation", "NSF", "Centers for Disease Control", "CDC",
            "Veterans Affairs", "Medical Research Council",
        )) {
            assertFalse(funder, FundingAnalyzer.classifyFunder(funder).isIndustry)
        }
    }

    @Test
    fun `academic funder`() {
        val (industry, confidence) = FundingAnalyzer.classifyFunder("Harvard University")
        assertFalse(industry)
        assertTrue(confidence > 0.7)
    }

    @Test
    fun `academic funders are not industry`() {
        for (funder in listOf(
            "University of Oxford", "Stanford Medical School", "Johns Hopkins Hospital", "Massachusetts General Hospital",
        )) {
            assertFalse(funder, FundingAnalyzer.classifyFunder(funder).isIndustry)
        }
    }

    @Test
    fun `corporate suffix`() {
        val (industry, confidence) = FundingAnalyzer.classifyFunder("Unknown Biotech Inc.")
        assertTrue(industry)
        assertTrue(confidence > 0.6)
    }

    @Test
    fun `corporate suffixes`() {
        for (name in listOf("Acme Pharma Inc.", "BioMed Corp.", "MedDevice Ltd.", "HealthTech GmbH", "Diagnostics PLC")) {
            assertTrue(name, FundingAnalyzer.classifyFunder(name).isIndustry)
        }
    }

    @Test
    fun `unknown funder has low confidence`() {
        val (industry, confidence) = FundingAnalyzer.classifyFunder("Some Foundation")
        assertFalse(industry)
        assertTrue(confidence < 0.5)
    }

    @Test
    fun `government takes precedence over corporate suffix`() {
        assertFalse(FundingAnalyzer.classifyFunder("Department of Veterans Affairs").isIndustry)
    }

    // ==================== createFunderInfo ====================

    @Test
    fun `createFunderInfo carries the classification`() {
        val funder = FundingAnalyzer.createFunderInfo(
            name = "Pfizer Inc.",
            doi = "10.13039/100004319",
            awardNumbers = listOf("R01-123456", "P50-789012"),
        )
        assertEquals("Pfizer Inc.", funder.name)
        assertEquals("10.13039/100004319", funder.funderDOI)
        assertEquals(2, funder.awardNumbers.size)
        assertTrue(funder.isIndustry)
        assertEquals(1.0, funder.confidence, 0.0)
    }

    @Test
    fun `createFunderInfo minimal`() {
        val funder = FundingAnalyzer.createFunderInfo(name = "Unknown Foundation")
        assertEquals("Unknown Foundation", funder.name)
        assertNull(funder.funderDOI)
        assertTrue(funder.awardNumbers.isEmpty())
        assertFalse(funder.isIndustry)
    }

    // ==================== sponsor type ====================

    @Test
    fun `industry only`() {
        val funders = listOf(
            FunderInfo(name = "Pfizer", isIndustry = true, confidence = 1.0),
            FunderInfo(name = "Novartis", isIndustry = true, confidence = 1.0),
        )
        assertEquals(SponsorType.INDUSTRY, FundingAnalyzer.determineSponsorType(funders))
    }

    @Test
    fun `mixed`() {
        val funders = listOf(
            FunderInfo(name = "Pfizer", isIndustry = true, confidence = 1.0),
            FunderInfo(name = "National Institutes of Health", isIndustry = false, confidence = 0.9),
        )
        assertEquals(SponsorType.MIXED, FundingAnalyzer.determineSponsorType(funders))
    }

    @Test
    fun `government`() {
        val funders = listOf(
            FunderInfo(name = "National Institutes of Health", isIndustry = false, confidence = 0.9),
            FunderInfo(name = "NIH", isIndustry = false, confidence = 0.85),
        )
        assertEquals(SponsorType.GOVERNMENT, FundingAnalyzer.determineSponsorType(funders))
    }

    @Test
    fun `academic`() {
        val funders = listOf(FunderInfo(name = "Harvard University", isIndustry = false, confidence = 0.8))
        assertEquals(SponsorType.ACADEMIC, FundingAnalyzer.determineSponsorType(funders))
    }

    @Test
    fun `nonprofit`() {
        val funders = listOf(FunderInfo(name = "American Heart Association", isIndustry = false, confidence = 0.3))
        assertEquals(SponsorType.NONPROFIT, FundingAnalyzer.determineSponsorType(funders))
    }

    /** One public agency outranks any number of universities: the government half is tested first. */
    @Test
    fun `government outranks academic`() {
        val funders = listOf(
            FunderInfo(name = "Harvard University", isIndustry = false, confidence = 0.8),
            FunderInfo(name = "NIH", isIndustry = false, confidence = 0.85),
        )
        assertEquals(SponsorType.GOVERNMENT, FundingAnalyzer.determineSponsorType(funders))
    }

    @Test
    fun `no funders is unknown`() {
        assertEquals(SponsorType.UNKNOWN, FundingAnalyzer.determineSponsorType(emptyList()))
    }

    // ==================== industry funding status ====================

    @Test
    fun `industry funding detected`() {
        val funders = listOf(
            FunderInfo(name = "NIH", isIndustry = false, confidence = 0.9),
            FunderInfo(name = "Pfizer", isIndustry = true, confidence = 1.0),
        )
        assertEquals(IndustryFundingStatus(true, 1.0), FundingAnalyzer.industryFundingStatus(funders))
    }

    @Test
    fun `industry funding not detected`() {
        val funders = listOf(FunderInfo(name = "NIH", isIndustry = false, confidence = 0.9))
        assertEquals(IndustryFundingStatus(false, 0.0), FundingAnalyzer.industryFundingStatus(funders))
    }

    @Test
    fun `industry funding status reports the max confidence`() {
        val funders = listOf(
            FunderInfo(name = "Company A", isIndustry = true, confidence = 0.7),
            FunderInfo(name = "Company B", isIndustry = true, confidence = 0.9),
            FunderInfo(name = "Company C", isIndustry = true, confidence = 0.8),
        )
        assertEquals(0.9, FundingAnalyzer.industryFundingStatus(funders).confidence, 0.0)
    }

    // ==================== merge ====================

    @Test
    fun `merge removes case-insensitive duplicates keeping higher confidence`() {
        val merged = FundingAnalyzer.mergeFunders(
            listOf(FunderInfo(name = "Pfizer", isIndustry = true, confidence = 0.7)),
            listOf(FunderInfo(name = "pfizer", isIndustry = true, confidence = 1.0)),
        )
        assertEquals(1, merged.size)
        assertEquals(1.0, merged.first().confidence, 0.0)
    }

    @Test
    fun `merge preserves distinct funders in first-seen order`() {
        val merged = FundingAnalyzer.mergeFunders(
            listOf(FunderInfo(name = "Pfizer", isIndustry = true, confidence = 1.0)),
            listOf(FunderInfo(name = "Novartis", isIndustry = true, confidence = 1.0)),
        )
        assertEquals(listOf("Pfizer", "Novartis"), merged.map { it.name })
    }

    @Test
    fun `merge of empty lists is empty`() {
        assertTrue(FundingAnalyzer.mergeFunders(emptyList(), emptyList()).isEmpty())
    }

    // ==================== trial sponsor update ====================

    @Test
    fun `unknown to industry`() =
        assertEquals(SponsorType.INDUSTRY, FundingAnalyzer.updateSponsorType(SponsorType.UNKNOWN, "INDUSTRY"))

    @Test
    fun `government to mixed`() =
        assertEquals(SponsorType.MIXED, FundingAnalyzer.updateSponsorType(SponsorType.GOVERNMENT, "INDUSTRY"))

    @Test
    fun `industry stays industry`() =
        assertEquals(SponsorType.INDUSTRY, FundingAnalyzer.updateSponsorType(SponsorType.INDUSTRY, "INDUSTRY"))

    @Test
    fun `null sponsor class changes nothing`() =
        assertEquals(SponsorType.GOVERNMENT, FundingAnalyzer.updateSponsorType(SponsorType.GOVERNMENT, null))

    @Test
    fun `non-industry sponsor class changes nothing`() =
        assertEquals(SponsorType.UNKNOWN, FundingAnalyzer.updateSponsorType(SponsorType.UNKNOWN, "NIH"))

    @Test
    fun `sponsor class is case-insensitive`() =
        assertEquals(SponsorType.INDUSTRY, FundingAnalyzer.updateSponsorType(SponsorType.UNKNOWN, "industry"))

    // ==================== CrossRef parsing ====================

    private fun funderObjects(json: String) = Json.parseToJsonElement(json).jsonArray.map { it.jsonObject }

    @Test
    fun `parse CrossRef funders`() {
        val funders = FundingAnalyzer.parseCrossRefFunders(
            funderObjects("""[{"name": "Pfizer Inc.", "DOI": "10.13039/100004319", "award": ["R01-123456"]}, {"name": "NIH"}]"""),
        )
        assertEquals(2, funders.size)
        assertEquals("Pfizer Inc.", funders[0].name)
        assertEquals("10.13039/100004319", funders[0].funderDOI)
        assertEquals(listOf("R01-123456"), funders[0].awardNumbers)
        assertTrue(funders[0].isIndustry)
        assertEquals("NIH", funders[1].name)
        assertFalse(funders[1].isIndustry)
    }

    @Test
    fun `parse CrossRef funders null`() = assertTrue(FundingAnalyzer.parseCrossRefFunders(null).isEmpty())

    @Test
    fun `parse CrossRef funders skips entries without a name`() {
        val funders = FundingAnalyzer.parseCrossRefFunders(
            funderObjects("""[{"DOI": "10.13039/100004319"}, {"name": "Valid Funder"}]"""),
        )
        assertEquals(1, funders.size)
    }

    /** Swift's `as? [String]` is all-or-nothing, and a numeric DOI is not a string. */
    @Test
    fun `parse CrossRef funders reads fields with Swift's casts`() {
        val funder = FundingAnalyzer.parseCrossRefFunders(
            funderObjects("""[{"name": "Acme Foundation", "DOI": 42, "award": ["A-1", 7]}]"""),
        ).single()
        assertNull(funder.funderDOI)
        assertTrue(funder.awardNumbers.isEmpty())
    }

    // ==================== PubMed grants ====================

    @Test
    fun `parse PubMed grants`() {
        val funders = FundingAnalyzer.parsePubMedGrants(
            listOf(
                mapOf("agency" to "National Cancer Institute", "grant_id" to "R01-CA123456"),
                mapOf("agency" to "NHLBI", "grant_id" to null),
            ),
        )
        assertEquals(2, funders.size)
        assertEquals("National Cancer Institute", funders[0].name)
        assertEquals(listOf("R01-CA123456"), funders[0].awardNumbers)
        assertFalse(funders[0].isIndustry)
        assertTrue(funders[1].awardNumbers.isEmpty())
    }

    @Test
    fun `parse PubMed grants null`() = assertTrue(FundingAnalyzer.parsePubMedGrants(null).isEmpty())

    @Test
    fun `parse PubMed grants skips empty agencies`() {
        val funders = FundingAnalyzer.parsePubMedGrants(
            listOf(mapOf("agency" to "", "grant_id" to "123"), mapOf("agency" to "Valid Agency", "grant_id" to null)),
        )
        assertEquals(1, funders.size)
    }

    // ==================== summary ====================

    @Test
    fun `summary industry`() {
        val summary = FundingAnalyzer.formatSummary(
            listOf(FunderInfo(name = "Pfizer", isIndustry = true, confidence = 1.0)),
            SponsorType.INDUSTRY,
        )
        assertEquals("Industry-funded (1 funder)", summary)
    }

    @Test
    fun `summary mixed`() {
        val summary = FundingAnalyzer.formatSummary(
            listOf(
                FunderInfo(name = "Pfizer", isIndustry = true, confidence = 1.0),
                FunderInfo(name = "NIH", isIndustry = false, confidence = 0.9),
            ),
            SponsorType.MIXED,
        )
        assertEquals("Mixed funding (1 industry, 1 non-industry)", summary)
    }

    @Test
    fun `summary empty`() {
        assertEquals("No funding information available", FundingAnalyzer.formatSummary(emptyList(), SponsorType.UNKNOWN))
    }

    @Test
    fun `summary plural`() {
        val funders = listOf(
            FunderInfo(name = "NIH", isIndustry = false),
            FunderInfo(name = "NSF", isIndustry = false),
        )
        assertEquals("Government-funded (2 funders)", FundingAnalyzer.formatSummary(funders, SponsorType.GOVERNMENT))
    }
}
