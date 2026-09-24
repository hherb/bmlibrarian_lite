package com.bmlibrarian.factchecker.domain.transparency

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Port of the Swift `COIAnalyzerTests`. */
class COIAnalyzerTest {

    // ==================== analyze ====================

    @Test
    fun `null statement is not available`() {
        val result = COIAnalyzer.analyze(null)
        assertNull(result.statement)
        assertFalse(result.hasIndustryTies)
        assertEquals(0.0, result.confidence, 0.0)
    }

    @Test
    fun `empty statement is not available`() = assertNull(COIAnalyzer.analyze("").statement)

    @Test
    fun `no conflict statement`() {
        val statement = "The authors declare no conflict of interest."
        val result = COIAnalyzer.analyze(statement)
        assertEquals(statement, result.statement)
        assertFalse(result.hasIndustryTies)
        assertEquals(0.9, result.confidence, 0.0)
    }

    @Test
    fun `nothing to disclose`() {
        val result = COIAnalyzer.analyze("Nothing to disclose.")
        assertFalse(result.hasIndustryTies)
        assertEquals(0.9, result.confidence, 0.0)
    }

    @Test
    fun `no competing interests`() {
        val result = COIAnalyzer.analyze("The authors declare no competing interests.")
        assertFalse(result.hasIndustryTies)
        assertEquals(0.9, result.confidence, 0.0)
    }

    @Test
    fun `none declared`() {
        val result = COIAnalyzer.analyze("Conflicts of interest: None declared.")
        assertFalse(result.hasIndustryTies)
        assertEquals(0.9, result.confidence, 0.0)
    }

    @Test
    fun `industry ties`() {
        val result = COIAnalyzer.analyze(
            "Author X received grants from Pfizer Inc. and serves as a consultant for Novartis.",
        )
        assertTrue(result.hasIndustryTies)
        assertTrue(result.confidence > 0.5)
    }

    /** 0.5 + 0.1 per keyword match, capped at 0.95. */
    @Test
    fun `confidence grows per match and is capped`() {
        // "grants from", "inc." and "consultant for": three matches.
        val three = COIAnalyzer.analyze("Received grants from Acme Inc. and is a consultant for Beta.")
        assertEquals(0.8, three.confidence, 1e-9)
        val many = COIAnalyzer.analyze(
            "Employee of Acme Inc., shareholder, stock, advisory board, honoraria, grants from Beta Ltd., consultant for Gamma GmbH.",
        )
        assertEquals(0.95, many.confidence, 1e-9)
    }

    @Test
    fun `honoraria`() = assertTrue(COIAnalyzer.analyze("Author received honoraria from pharmaceutical companies.").hasIndustryTies)

    @Test
    fun `employee of`() {
        val result = COIAnalyzer.analyze("Dr. Smith is an employee of Bristol-Myers Squibb.")
        assertTrue(result.hasIndustryTies)
        assertFalse(result.disclosedRelationships.isEmpty())
    }

    @Test
    fun `stock ownership`() =
        assertTrue(COIAnalyzer.analyze("The author owns stock in Gilead Sciences and Moderna.").hasIndustryTies)

    @Test
    fun `advisory board`() =
        assertTrue(COIAnalyzer.analyze("Dr. Jones serves on the advisory board for AstraZeneca.").hasIndustryTies)

    @Test
    fun `speaker fees`() = assertTrue(
        COIAnalyzer.analyze("Author has received speaker fees from several pharmaceutical companies.").hasIndustryTies,
    )

    /** An existing statement that says nothing either way is uncertain, not tie-free. */
    @Test
    fun `ambiguous statement is uncertain`() {
        val result = COIAnalyzer.analyze("The authors have disclosed all potential conflicts of interest.")
        assertFalse(result.hasIndustryTies)
        assertEquals(0.5, result.confidence, 0.0)
    }

    // ==================== no-conflict detection ====================

    @Test
    fun `no conflict declarations`() {
        assertTrue(COIAnalyzer.containsNoConflictDeclaration("no conflict of interest"))
        assertTrue(COIAnalyzer.containsNoConflictDeclaration("nothing to disclose"))
        assertTrue(COIAnalyzer.containsNoConflictDeclaration("no competing interests"))
        assertTrue(COIAnalyzer.containsNoConflictDeclaration("none declared"))
        assertTrue(COIAnalyzer.containsNoConflictDeclaration("no financial interest"))
        assertTrue(COIAnalyzer.containsNoConflictDeclaration("no potential conflict"))
        assertFalse(COIAnalyzer.containsNoConflictDeclaration("received grants from pfizer"))
    }

    @Test
    fun `no conflict detection is case-insensitive`() {
        assertTrue(COIAnalyzer.containsNoConflictDeclaration("NO CONFLICT OF INTEREST"))
        assertTrue(COIAnalyzer.containsNoConflictDeclaration("Nothing To Disclose"))
        assertTrue(COIAnalyzer.containsNoConflictDeclaration("NONE DECLARED"))
    }

    // ==================== industry match counting ====================

    @Test fun `count single`() = assertTrue(COIAnalyzer.countIndustryMatches("works for pfizer inc.") >= 1)

    @Test fun `count multiple`() =
        assertTrue(COIAnalyzer.countIndustryMatches("consultant for pharma corp. and biotech ltd.") >= 2)

    @Test fun `count none`() = assertEquals(0, COIAnalyzer.countIndustryMatches("funded by nih and university grant"))

    @Test fun `count employee`() = assertTrue(COIAnalyzer.countIndustryMatches("is an employee of merck") >= 1)

    // ==================== relationship extraction ====================

    @Test fun `extract grants`() =
        assertEquals(listOf("pfizer and novartis"), COIAnalyzer.extractRelationships("received grants from pfizer and novartis"))

    @Test fun `extract consultant`() =
        assertFalse(COIAnalyzer.extractRelationships("serves as consultant for medtronic").isEmpty())

    @Test fun `extract employee`() = assertFalse(COIAnalyzer.extractRelationships("employee of astrazeneca").isEmpty())

    @Test fun `extract stock`() =
        assertFalse(COIAnalyzer.extractRelationships("owns stock in moderna and johnson & johnson").isEmpty())

    @Test fun `extract advisory board`() =
        assertFalse(COIAnalyzer.extractRelationships("serves on the advisory board for genentech").isEmpty())

    @Test
    fun `extract multiple`() {
        val relationships = COIAnalyzer.extractRelationships(
            "received grants from pfizer, consultant for novartis, and employee of roche",
        )
        assertTrue(relationships.size >= 2)
    }

    @Test
    fun `extract deduplicates`() {
        val relationships = COIAnalyzer.extractRelationships(
            "received grants from pfizer. also received grants from pfizer for another project",
        )
        assertEquals(listOf("pfizer", "pfizer for another project"), relationships)
    }

    /** Captures come from lowercased text, as Swift's `extractAll` lowercases first. */
    @Test
    fun `extracted relationships are lowercased`() {
        assertEquals(listOf("pfizer"), COIAnalyzer.extractRelationships("Employee of PFIZER"))
    }

    // ==================== discrepancy ====================

    @Test
    fun `discrepancy when ties are not mentioned`() {
        val warning = COIAnalyzer.checkFundingCOIDiscrepancy(
            COIAnalysisResult(statement = "No conflicts declared", hasIndustryTies = false, confidence = 0.9),
            industryFundingDetected = true,
        )
        assertEquals("Industry funding detected but COI statement does not mention industry ties", warning)
    }

    @Test
    fun `no discrepancy without industry funding`() {
        assertNull(
            COIAnalyzer.checkFundingCOIDiscrepancy(
                COIAnalysisResult(statement = "No conflicts declared", confidence = 0.9),
                industryFundingDetected = false,
            ),
        )
    }

    @Test
    fun `no discrepancy with proper disclosure`() {
        assertNull(
            COIAnalyzer.checkFundingCOIDiscrepancy(
                COIAnalysisResult(statement = "Received grants from Pfizer", hasIndustryTies = true, confidence = 0.8),
                industryFundingDetected = true,
            ),
        )
    }

    @Test
    fun `discrepancy with no statement`() {
        val warning = COIAnalyzer.checkFundingCOIDiscrepancy(COIAnalysisResult.NOT_AVAILABLE, true)
        assertEquals("Industry funding detected but no COI statement found", warning)
    }

    // ==================== significant ties ====================

    @Test
    fun `significant with multiple relationships`() {
        assertTrue(
            COIAnalyzer.hasSignificantIndustryTies(
                COIAnalysisResult("Grants from Pfizer and Novartis", true, listOf("pfizer", "novartis"), 0.7),
            ),
        )
    }

    @Test
    fun `significant with high confidence`() {
        assertTrue(
            COIAnalyzer.hasSignificantIndustryTies(COIAnalysisResult("Employee of Merck", true, listOf("merck"), 0.85)),
        )
    }

    @Test
    fun `not significant without ties`() {
        assertFalse(COIAnalyzer.hasSignificantIndustryTies(COIAnalysisResult("No conflicts declared", false, confidence = 0.9)))
    }

    // ==================== summary ====================

    @Test fun `summary without statement`() =
        assertEquals("No conflict of interest statement found", COIAnalyzer.formatSummary(COIAnalysisResult.NOT_AVAILABLE))

    @Test fun `summary no conflicts`() =
        assertEquals("No conflicts declared", COIAnalyzer.formatSummary(COIAnalysisResult("None declared", false, confidence = 0.9)))

    @Test fun `summary one relationship`() = assertEquals(
        "Industry ties disclosed (1 relationship)",
        COIAnalyzer.formatSummary(COIAnalysisResult("Received grants from Pfizer", true, listOf("pfizer"), 0.8)),
    )

    @Test fun `summary two relationships`() = assertEquals(
        "Industry ties disclosed (2 relationships)",
        COIAnalyzer.formatSummary(COIAnalysisResult("Grants", true, listOf("pfizer", "novartis"), 0.8)),
    )

    @Test fun `summary ties without relationships`() = assertEquals(
        "Industry ties indicated",
        COIAnalyzer.formatSummary(COIAnalysisResult("Has pharmaceutical ties", true, emptyList(), 0.6)),
    )

    // ==================== format relationships ====================

    @Test fun `format empty`() = assertEquals("None disclosed", COIAnalyzer.formatRelationships(emptyList()))

    @Test fun `format single`() = assertEquals("Pfizer", COIAnalyzer.formatRelationships(listOf("pfizer")))

    @Test fun `format multiple`() =
        assertEquals("Pfizer; Novartis", COIAnalyzer.formatRelationships(listOf("pfizer", "novartis")))

    @Test fun `format capitalises every word`() =
        assertEquals("Johnson & Johnson", COIAnalyzer.formatRelationships(listOf("johnson & JOHNSON")))
}
