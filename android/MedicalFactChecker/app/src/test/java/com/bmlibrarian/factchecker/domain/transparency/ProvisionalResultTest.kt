package com.bmlibrarian.factchecker.domain.transparency

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A result a source could not be read for is provisional (#385): offered for re-analysis,
 * captioned for the reader, and stored so that older rows still load. Swift's
 * `TransparencySourcesUnreachableTests` pins the same rules.
 */
class ProvisionalResultTest {

    @Test
    fun `stored JSON without the flag still decodes, as not provisional`() {
        val json = TransparencyJson.encode(TransparencyResult(pmid = "1"))
            .replace(Regex(""","sourcesUnreachable":(null|true|false)"""), "")
        assertFalse(json.contains("sourcesUnreachable"))

        val decoded = TransparencyJson.decode(json)

        assertNull(decoded.sourcesUnreachable)
        assertFalse(decoded.isProvisional)
        assertFalse("a current result missing the flag is not re-run", decoded.needsReanalysis)
    }

    @Test
    fun `a result built here records the flag`() {
        assertEquals(false, TransparencyResult(pmid = "1").sourcesUnreachable)
    }

    @Test
    fun `the flag survives a round trip`() {
        val decoded = TransparencyJson.decode(TransparencyJson.encode(TransparencyResult(pmid = "1", sourcesUnreachable = true)))
        assertEquals(true, decoded.sourcesUnreachable)
    }

    /** A newer build's result would be overwritten with an older analyzer's answer (#374). */
    @Test
    fun `a newer build's provisional result is not re-analysed`() {
        val newer = TransparencyResult(
            pmid = "1",
            analyzerVersion = TransparencyConstants.ANALYZER_VERSION + 1,
            sourcesUnreachable = true,
        )
        assertTrue(newer.isProvisional)
        assertFalse(newer.needsReanalysis)
    }

    @Test
    fun `a current final result is kept`() {
        assertFalse(TransparencyResult(pmid = "1", sourcesUnreachable = false).needsReanalysis)
    }

    @Test
    fun `an older build's result is re-analysed whatever its sources`() {
        val older = TransparencyResult(pmid = "1", analyzerVersion = TransparencyConstants.ANALYZER_VERSION - 1)
        assertTrue(older.needsReanalysis)
    }

    @Test
    fun `a provisional result carries the caveat and a final one does not`() {
        fun caveats(unreachable: Boolean) = TransparencyRiskExplanation.of(
            TransparencyResult(
                pmid = "1",
                transparencyScore = 20,
                riskLevel = TransparencyRiskLevel.HIGH,
                fullTextSearched = true,
                sourcesUnreachable = unreachable,
            ),
        ).caveats

        assertTrue(TransparencyConstants.PROVISIONAL_RESULT_CAVEAT in caveats(true))
        assertFalse(TransparencyConstants.PROVISIONAL_RESULT_CAVEAT in caveats(false))
    }
}
