package com.bmlibrarian.factchecker.domain.transparency

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RegexHelperTest {

    @Test
    fun `anyMatch finds a pattern anywhere in text`() {
        assertTrue(RegexHelper.anyMatch(listOf("zenodo", "figshare"), "deposited in figshare today"))
        assertFalse(RegexHelper.anyMatch(listOf("zenodo"), "no repository named here"))
    }

    @Test
    fun `anyMatch respects word boundaries`() {
        assertTrue(RegexHelper.anyMatch(listOf("\\bgeo\\b"), "deposited in geo"))
        assertFalse(RegexHelper.anyMatch(listOf("\\bgeo\\b"), "across geographic regions"))
    }

    @Test
    fun `matches finds a single pattern anywhere in text`() {
        assertTrue(RegexHelper.matches("figshare", "deposited in figshare today"))
        assertFalse(RegexHelper.matches("zenodo", "no repository named here"))
    }

    @Test
    fun `word classes are unicode-aware to match python and swift`() {
        // Java/Kotlin regex defaults \w to ASCII; the canonical Python (str
        // patterns) and Swift (ICU NSRegularExpression) engines treat \w as
        // Unicode. An accented intervening word must therefore still be skipped
        // by a (?:\w+ )? group so a statement classifies identically on all
        // three platforms (review finding #1). Without the (?U) flag the
        // accented word would break the group and this would be false.
        assertTrue(RegexHelper.matches("cannot be (?:\\w+ )?shared", "these data cannot be résumé shared"))
    }

    @Test
    fun `firstMatch returns the whole first match`() {
        assertEquals(
            "https://zenodo.org/record/42",
            RegexHelper.firstMatch("https?://[^\\s<>\"]+", "see https://zenodo.org/record/42 for data"),
        )
        assertNull(RegexHelper.firstMatch("https?://[^\\s<>\"]+", "no url here"))
    }

    @Test
    fun `firstGroup returns capture group one with optional ignore case`() {
        assertEquals(
            "GSE123",
            RegexHelper.firstGroup("(?:accession|identifier)[:\\s]+([A-Z0-9]+)", "under accession GSE123", ignoreCase = true),
        )
        // Note: text deliberately omits "accession"/"identifier" entirely. Under
        // ignoreCase, [A-Z0-9]+ also matches lowercase letters (mirrors Python's
        // re.I), so any trailing word after those keywords would itself satisfy
        // the capture group — e.g. "no accession stated" would wrongly match
        // "stated". A true negative example must not contain the trigger words.
        assertNull(RegexHelper.firstGroup("(?:accession|identifier)[:\\s]+([A-Z0-9]+)", "no data provided", ignoreCase = true))
    }
}
