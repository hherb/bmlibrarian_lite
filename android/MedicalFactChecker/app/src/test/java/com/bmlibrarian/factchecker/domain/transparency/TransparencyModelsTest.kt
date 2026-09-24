package com.bmlibrarian.factchecker.domain.transparency

import java.time.Instant
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Port of the Swift `TransparencyModelsTests`, plus the stored-JSON contract with Swift. */
class TransparencyModelsTest {

    // ==================== enums ====================

    @Test
    fun `sponsor type display names`() {
        assertEquals(
            listOf("Industry", "Government", "Academic", "Non-Profit", "Mixed", "Unknown"),
            SponsorType.entries.map { it.displayName },
        )
        assertEquals(6, SponsorType.entries.size)
    }

    @Test
    fun `data disclosure level display names and raw values`() {
        assertEquals(
            listOf("Fully Open", "Available on Request", "Restricted", "Not Available", "Not Stated", "Unknown"),
            DataDisclosureLevel.entries.map { it.displayName },
        )
        assertEquals(
            listOf("full_open", "on_request", "restricted", "not_available", "not_stated", "unknown"),
            DataDisclosureLevel.entries.map { it.rawValue },
        )
    }

    @Test
    fun `results compliance display names`() {
        assertEquals(
            listOf("Compliant", "Late", "Missing", "Not Required", "Unknown"),
            ResultsComplianceStatus.entries.map { it.displayName },
        )
    }

    @Test
    fun `risk level labels and colours`() {
        assertEquals(listOf("green", "orange", "red", "gray"), TransparencyRiskLevel.entries.map { it.colorName })
        assertEquals(listOf("Low", "Med", "High", "?"), TransparencyRiskLevel.entries.map { it.shortLabel })
        assertEquals(
            listOf("Low Risk", "Medium Risk", "High Risk", "Unknown"),
            TransparencyRiskLevel.entries.map { it.fullLabel },
        )
    }

    /** Every enum serializes as its Swift raw value. */
    @Test
    fun `enums serialize as their raw values`() {
        val json = TransparencyJson.format
        for (value in SponsorType.entries) {
            assertEquals("\"${value.rawValue}\"", json.encodeToString(SponsorType.serializer(), value))
        }
        for (value in ResultsComplianceStatus.entries) {
            assertEquals("\"${value.rawValue}\"", json.encodeToString(ResultsComplianceStatus.serializer(), value))
        }
        for (value in TransparencyRiskLevel.entries) {
            assertEquals("\"${value.rawValue}\"", json.encodeToString(TransparencyRiskLevel.serializer(), value))
        }
        for (value in DataDisclosureLevel.entries) {
            assertEquals("\"${value.rawValue}\"", json.encodeToString(DataDisclosureLevel.serializer(), value))
        }
    }

    // ==================== value types ====================

    @Test
    fun `funder info`() {
        val funder = FunderInfo(
            name = "Pfizer",
            funderDOI = "10.13039/100004319",
            awardNumbers = listOf("R01-12345"),
            isIndustry = true,
            confidence = 1.0,
        )
        assertEquals("Pfizer", funder.name)
        assertEquals("10.13039/100004319", funder.funderDOI)
        assertEquals(listOf("R01-12345"), funder.awardNumbers)
        assertTrue(funder.isIndustry)
    }

    /** Different ids make funders unequal; the same id makes them equal, as in Swift. */
    @Test
    fun `funder equality includes the id`() {
        assertNotEquals(FunderInfo(name = "Pfizer"), FunderInfo(name = "Pfizer"))
        assertEquals(FunderInfo(id = "A", name = "Pfizer"), FunderInfo(id = "A", name = "Pfizer"))
    }

    @Test
    fun `ids are uppercase UUIDs as Swift writes them`() {
        val id = FunderInfo(name = "x").id
        assertEquals(id.uppercase(), id)
        assertEquals(36, id.length)
    }

    @Test
    fun `funder info round-trips`() {
        val funder = FunderInfo(
            name = "NIH",
            funderDOI = "10.13039/100000002",
            awardNumbers = listOf("R01-67890"),
            isIndustry = false,
            confidence = 0.95,
        )
        val json = TransparencyJson.format
        assertEquals(funder, json.decodeFromString(FunderInfo.serializer(), json.encodeToString(FunderInfo.serializer(), funder)))
    }

    @Test
    fun `COI result has statement`() {
        assertTrue(COIAnalysisResult(statement = "No conflicts declared").hasStatement)
        assertFalse(COIAnalysisResult(statement = null).hasStatement)
        assertFalse(COIAnalysisResult(statement = "").hasStatement)
    }

    @Test
    fun `COI result not available`() {
        val coi = COIAnalysisResult.NOT_AVAILABLE
        assertNull(coi.statement)
        assertFalse(coi.hasIndustryTies)
        assertTrue(coi.disclosedRelationships.isEmpty())
        assertEquals(0.0, coi.confidence, 0.0)
    }

    @Test
    fun `transparency results have unique ids`() {
        assertNotEquals(TransparencyResult(pmid = "1").id, TransparencyResult(pmid = "1").id)
    }

    // ==================== builder ====================

    @Test
    fun `builder basic usage`() {
        val builder = TransparencyResultBuilder(pmid = "12345678")
        builder.title = "Test Study"
        builder.doi = "10.1000/test"
        builder.journal = "Test Journal"
        builder.authors = listOf("Smith J", "Doe J")
        builder.sponsorType = SponsorType.ACADEMIC
        val result = builder.build()
        assertEquals("12345678", result.pmid)
        assertEquals("Test Study", result.title)
        assertEquals("10.1000/test", result.doi)
        assertEquals("Test Journal", result.journal)
        assertEquals(listOf("Smith J", "Doe J"), result.authors)
        assertEquals(SponsorType.ACADEMIC, result.sponsorType)
    }

    @Test
    fun `builder defaults`() {
        val result = TransparencyResultBuilder().build()
        assertNull(result.doi)
        assertNull(result.pmid)
        assertEquals(SponsorType.UNKNOWN, result.sponsorType)
        assertEquals(ResultsComplianceStatus.UNKNOWN, result.resultsCompliance)
        assertEquals(DataDisclosureLevel.NOT_STATED, result.dataAvailability.disclosureLevel)
        assertNull(result.fullTextSearched)
    }

    @Test
    fun `builder score calculation`() {
        val good = TransparencyResultBuilder(pmid = "1")
        good.dataAvailability = DataAvailabilityResult(disclosureLevel = DataDisclosureLevel.FULL_OPEN)
        good.coiAnalysis = COIAnalysisResult(statement = "No conflicts declared")
        good.trialRegistrations = listOf(TrialRegistration(registry = "ClinicalTrials.gov", registrationId = "NCT12345678"))
        good.resultsCompliance = ResultsComplianceStatus.COMPLIANT
        val goodResult = good.build()
        assertTrue(goodResult.transparencyScore >= 70)
        assertEquals(TransparencyRiskLevel.LOW, goodResult.riskLevel)

        val poor = TransparencyResultBuilder(pmid = "2")
        poor.title = "A randomized controlled trial"
        poor.dataAvailability = DataAvailabilityResult(disclosureLevel = DataDisclosureLevel.NOT_AVAILABLE)
        poor.industryFundingDetected = true
        poor.resultsCompliance = ResultsComplianceStatus.MISSING
        poor.outcomeSwitchingDetected = true
        val poorResult = poor.build()
        assertTrue(poorResult.transparencyScore < 40)
        assertEquals(TransparencyRiskLevel.HIGH, poorResult.riskLevel)
    }

    @Test
    fun `builder risk indicators`() {
        val builder = TransparencyResultBuilder(pmid = "12345678")
        builder.industryFundingDetected = true
        builder.dataAvailability = DataAvailabilityResult(disclosureLevel = DataDisclosureLevel.NOT_AVAILABLE)
        builder.resultsCompliance = ResultsComplianceStatus.MISSING
        builder.outcomeSwitchingDetected = true
        val indicators = builder.build().riskIndicators
        assertTrue(indicators.contains("Industry funding detected"))
        assertTrue(indicators.contains("Data effectively unavailable despite sharing statement"))
        assertTrue(indicators.contains("Trial results not posted to ClinicalTrials.gov"))
        assertTrue(indicators.contains("Outcome switching detected"))
    }

    @Test
    fun `builder with explicit scoring`() {
        val builder = TransparencyResultBuilder(pmid = "12345678")
        val result = builder.build(score = 85, riskLevel = TransparencyRiskLevel.LOW, riskIndicators = listOf("Custom indicator"))
        assertEquals(85, result.transparencyScore)
        assertEquals(TransparencyRiskLevel.LOW, result.riskLevel)
        assertEquals(listOf("Custom indicator"), result.riskIndicators)
    }

    @Test
    fun `builder preserves warnings, errors, sources and full-text record`() {
        val builder = TransparencyResultBuilder(pmid = "12345678")
        builder.warnings = listOf("CrossRef timeout")
        builder.errors = listOf("ClinicalTrials.gov unavailable")
        builder.dataSourcesUsed = listOf("PubMed", "Europe PMC")
        builder.fullTextSearched = false
        val result = builder.build()
        assertEquals(listOf("CrossRef timeout"), result.warnings)
        assertEquals(listOf("ClinicalTrials.gov unavailable"), result.errors)
        assertEquals(listOf("PubMed", "Europe PMC"), result.dataSourcesUsed)
        assertEquals(false, result.fullTextSearched)
    }

    // ==================== stored JSON (the Swift Codable shape) ====================

    /** A result as the iOS app stores it: Swift `JSONEncoder` with `.iso8601` dates, nil fields omitted. */
    private val swiftStoredJson = """
        {
          "id": "E621E1F8-C36C-495A-93FC-0C247A3E6E5F",
          "doi": "10.1000/test",
          "pmid": "12345678",
          "title": "Test Study",
          "publicationDate": "2024-03-15T00:00:00Z",
          "authors": ["Smith, John"],
          "sponsorType": "nonprofit",
          "funders": [{"id": "0B7D3F2A-1111-2222-3333-444455556666", "name": "Pfizer Inc.",
                       "funderDOI": "10.13039/100004319", "awardNumbers": ["G-1"], "isIndustry": true,
                       "confidence": 1}],
          "industryFundingDetected": true,
          "industryFundingConfidence": 0.9,
          "trialRegistrations": [{"id": "7C9E6679-7425-40DE-944B-E07FC1F90AE7", "registry": "ClinicalTrials.gov",
                                  "registrationId": "NCT01234567", "sponsorClass": "INDUSTRY", "resultsPosted": false,
                                  "completionDate": "2023-06-30T00:00:00Z",
                                  "primaryOutcomesRegistered": [], "secondaryOutcomesRegistered": []}],
          "resultsCompliance": "not_required",
          "coiAnalysis": {"statement": "none declared", "hasIndustryTies": false,
                          "disclosedRelationships": [], "confidence": 0.9},
          "dataAvailability": {"statement": "see zenodo", "disclosureLevel": "full_open",
                               "repositoryName": "Zenodo", "repositoryURL": "https://zenodo.org/record/1",
                               "restrictions": []},
          "outcomeSwitchingDetected": false,
          "outcomeSwitchingDetails": [],
          "transparencyScore": 75,
          "riskLevel": "medium",
          "riskIndicators": ["Industry funding detected"],
          "analysisTimestamp": "2026-09-01T10:20:30Z",
          "dataSourcesUsed": ["PubMed", "CrossRef"],
          "warnings": [],
          "errors": [],
          "analyzerVersion": 3,
          "fullTextSearched": true,
          "someFieldAFutureSwiftBuildAdds": {"nested": [1, 2]}
        }
    """

    @Test
    fun `decodes a result the Swift app stored`() {
        val result = TransparencyJson.decode(swiftStoredJson)
        assertEquals("E621E1F8-C36C-495A-93FC-0C247A3E6E5F", result.id)
        assertEquals("10.1000/test", result.doi)
        assertNull(result.pmcid)
        assertEquals(Instant.parse("2024-03-15T00:00:00Z"), result.publicationDate)
        assertEquals(SponsorType.NONPROFIT, result.sponsorType)
        assertEquals("10.13039/100004319", result.funders.single().funderDOI)
        assertEquals(1.0, result.funders.single().confidence, 0.0)
        assertEquals(Instant.parse("2023-06-30T00:00:00Z"), result.trialRegistrations.single().completionDate)
        assertEquals(ResultsComplianceStatus.NOT_REQUIRED, result.resultsCompliance)
        assertEquals("https://zenodo.org/record/1", result.dataAvailability.repositoryUrl)
        assertEquals(DataDisclosureLevel.FULL_OPEN, result.dataAvailability.disclosureLevel)
        assertEquals(TransparencyRiskLevel.MEDIUM, result.riskLevel)
        assertEquals(Instant.parse("2026-09-01T10:20:30Z"), result.analysisTimestamp)
        assertEquals(3, result.analyzerVersion)
        assertEquals(true, result.fullTextSearched)
    }

    /** Swift's decoder requires every non-optional key and rejects fractional seconds, so both are written that way. */
    @Test
    fun `encodes the keys and date form Swift reads`() {
        val builder = TransparencyResultBuilder(doi = "10.1000/x", pmid = "1")
        builder.publicationDate = Instant.parse("2024-03-15T10:20:30.987Z")
        builder.funders = listOf(FunderInfo(name = "NIH"))
        builder.trialRegistrations = listOf(TrialRegistration(registry = "ClinicalTrials.gov", registrationId = "NCT1"))
        builder.fullTextSearched = true
        val encoded = Json.parseToJsonElement(TransparencyJson.encode(builder.build())).jsonObject

        assertEquals(
            setOf(
                "id", "doi", "pmid", "publicationDate", "authors", "sponsorType", "funders",
                "industryFundingDetected", "industryFundingConfidence", "trialRegistrations", "resultsCompliance",
                "coiAnalysis", "dataAvailability", "outcomeSwitchingDetected", "outcomeSwitchingDetails",
                "transparencyScore", "riskLevel", "riskIndicators", "analysisTimestamp", "dataSourcesUsed",
                "warnings", "errors", "analyzerVersion", "fullTextSearched",
            ),
            encoded.keys,
        )
        assertEquals("2024-03-15T10:20:30Z", encoded["publicationDate"]!!.jsonPrimitive.content)
        assertTrue(encoded["analysisTimestamp"]!!.jsonPrimitive.content.matches(Regex("""\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ""")))
        assertEquals(
            setOf("id", "name", "awardNumbers", "isIndustry", "confidence"),
            encoded["funders"]!!.jsonArray.single().jsonObject.keys,
        )
        assertEquals(
            setOf("id", "registry", "registrationId", "resultsPosted", "primaryOutcomesRegistered", "secondaryOutcomesRegistered"),
            encoded["trialRegistrations"]!!.jsonArray.single().jsonObject.keys,
        )
        assertEquals(
            setOf("hasIndustryTies", "disclosedRelationships", "confidence"),
            encoded["coiAnalysis"]!!.jsonObject.keys,
        )
        assertEquals(setOf("disclosureLevel", "restrictions"), encoded["dataAvailability"]!!.jsonObject.keys)
    }

    @Test
    fun `repository URL travels under Swift's key`() {
        val encoded = Json.parseToJsonElement(
            TransparencyJson.format.encodeToString(
                DataAvailabilityResult.serializer(),
                DataAvailabilityResult(disclosureLevel = DataDisclosureLevel.FULL_OPEN, repositoryUrl = "https://x.org"),
            ),
        ).jsonObject
        assertEquals(JsonPrimitive("https://x.org"), encoded["repositoryURL"])
    }

    @Test
    fun `a result round-trips`() {
        val builder = TransparencyResultBuilder(doi = "10.1000/test", pmid = "12345678")
        builder.title = "Test Study"
        builder.sponsorType = SponsorType.INDUSTRY
        builder.industryFundingDetected = true
        builder.fullTextSearched = false
        val original = builder.build()
        val decoded = TransparencyJson.decode(TransparencyJson.encode(original))
        assertEquals(original.copy(analysisTimestamp = decoded.analysisTimestamp), decoded)
    }

    /** As Swift's synthesized decoder would, a stored object missing a required key is refused. */
    @Test(expected = SerializationException::class)
    fun `a result missing a required key is refused`() {
        val stored = Json.parseToJsonElement(TransparencyJson.encode(TransparencyResult(pmid = "1"))).jsonObject
        TransparencyJson.decode(JsonObject(stored - "transparencyScore").toString())
    }
}
