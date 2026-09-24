package com.bmlibrarian.factchecker.domain.transparency

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The stored-result analyzer version stamp (port of the Swift `AnalyzerVersionTests`).
 */
class AnalyzerVersionTest {

    private fun makeResult(): TransparencyResult {
        val builder = TransparencyResultBuilder(pmid = "12345678")
        builder.title = "A Study"
        return builder.build()
    }

    /** Must move with Swift's `TransparencyConstants.analyzerVersion`: results sync between platforms. */
    @Test
    fun `analyzer version matches Swift`() = assertEquals(3, TransparencyConstants.ANALYZER_VERSION)

    @Test
    fun `built result carries the current version`() =
        assertEquals(TransparencyConstants.ANALYZER_VERSION, makeResult().analyzerVersion)

    @Test fun `built result is not stale`() = assertFalse(makeResult().isStale)

    @Test
    fun `explicit-score build also stamps`() {
        val result = TransparencyResultBuilder(pmid = "1")
            .build(score = 60, riskLevel = TransparencyRiskLevel.MEDIUM, riskIndicators = emptyList())
        assertEquals(TransparencyConstants.ANALYZER_VERSION, result.analyzerVersion)
    }

    @Test
    fun `an older version is stale`() =
        assertTrue(TransparencyResult(pmid = "1", analyzerVersion = TransparencyConstants.ANALYZER_VERSION - 1).isStale)

    /** Staleness is one-directional: a result from a newer build synced to this one is not stale. */
    @Test
    fun `a newer version is not stale`() =
        assertFalse(TransparencyResult(pmid = "1", analyzerVersion = TransparencyConstants.ANALYZER_VERSION + 1).isStale)

    @Test
    fun `the current version is not stale`() =
        assertFalse(TransparencyResult(pmid = "1", analyzerVersion = TransparencyConstants.ANALYZER_VERSION).isStale)

    @Test
    fun `a result with no version is stale`() {
        val unversioned = TransparencyResult(pmid = "1", analyzerVersion = null)
        assertNull(unversioned.analyzerVersion)
        assertTrue(unversioned.isStale)
    }

    @Test
    fun `version survives encode and decode`() {
        val decoded = TransparencyJson.decode(TransparencyJson.encode(makeResult()))
        assertEquals(TransparencyConstants.ANALYZER_VERSION, decoded.analyzerVersion)
        assertFalse(decoded.isStale)
    }

    /**
     * JSON written before the field existed must decode as unversioned — not as the
     * current version, which the constructor's default would silently supply.
     */
    @Test
    fun `JSON written before versioning decodes as unversioned`() {
        val stored = Json.parseToJsonElement(TransparencyJson.encode(makeResult())).jsonObject
        val decoded = TransparencyJson.decode(JsonObject(stored - "analyzerVersion").toString())
        assertNull(decoded.analyzerVersion)
        assertTrue(decoded.isStale)
        assertEquals("12345678", decoded.pmid)
    }
}
