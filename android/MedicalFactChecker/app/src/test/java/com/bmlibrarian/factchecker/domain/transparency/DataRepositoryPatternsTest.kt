package com.bmlibrarian.factchecker.domain.transparency

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DataRepositoryPatternsTest {

    // ==================== full-open ====================

    @Test
    fun `full open patterns include repositories and #113 affirmations`() {
        val p = DataRepositoryPatterns.fullOpenPatterns
        assertTrue(p.contains("zenodo"))
        assertTrue(p.contains("\\bgeo\\b"))
        assertTrue(p.contains("(?<!not )openly (?:available|shared|accessible)"))
        assertTrue(p.contains("(?<!not )freely (?:available|shared|accessible)"))
        assertTrue(p.contains("(?<!not )available (?:in|within|as|via|through) (?:the )?supplement"))
        assertEquals(24, p.size)
    }

    // ==================== restricted / refusal ====================

    @Test
    fun `restricted patterns include the #104 privacy legal set`() {
        val p = DataRepositoryPatterns.restrictedPatterns
        assertTrue(p.contains("\\bgdpr\\b"))
        assertTrue(p.contains("\\bhipaa\\b"))
        assertTrue(p.contains("\\bprivacy\\b"))
        assertTrue(p.contains("\\bpatient consent\\b"))
        assertEquals(23, p.size)
    }

    @Test
    fun `strong refusal is a subset of restricted`() {
        assertEquals(7, DataRepositoryPatterns.strongRefusalPatterns.size)
        assertTrue(
            DataRepositoryPatterns.restrictedPatterns
                .containsAll(DataRepositoryPatterns.strongRefusalPatterns),
        )
    }

    @Test
    fun `effectively unavailable has three patterns`() {
        assertEquals(3, DataRepositoryPatterns.effectivelyUnavailablePatterns.size)
    }

    // ==================== labels ====================

    @Test
    fun `restriction label lookup returns mapped labels`() {
        assertEquals("GDPR restrictions", DataRepositoryPatterns.restrictionLabel("\\bgdpr\\b"))
        assertEquals("Requires IRB approval", DataRepositoryPatterns.restrictionLabel("institutional review board"))
        assertEquals("Requires IRB approval", DataRepositoryPatterns.restrictionLabel("irb approval"))
    }

    @Test
    fun `restriction label falls back to the pattern when unmapped`() {
        assertEquals("unmapped-pattern", DataRepositoryPatterns.restrictionLabel("unmapped-pattern"))
    }
}
