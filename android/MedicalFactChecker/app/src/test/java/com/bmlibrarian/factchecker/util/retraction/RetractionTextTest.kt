// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2026 Dr Horst Herb
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.
package com.bmlibrarian.factchecker.util.retraction

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** Every sentence as the desktop and Swift word it (`RetractionTextTests.swift`). */
class RetractionTextTest {
    private val whenMs = 1_792_315_800_000L // 2026-10-18 09:30 UTC
    private val both = listOf("retraction_watch_export", "crossref")
    private val rwCause = "the Retraction Watch data could not be used (no up-to-date copy is on this device)"

    @Before
    fun setUp() = BmlibFfi.assumeAvailable()

    private fun evidence(
        source: String = "retraction_watch_export",
        kind: String = "retraction",
        notice: String? = "10.9/n",
        day: String? = "2026-03-09"
    ) = StoredRetractionEvidence(source = source, kind = kind, date = day, noticeDoi = notice)

    private fun check(
        status: String,
        deciding: StoredRetractionEvidence? = null,
        unanswered: List<String> = emptyList(),
        failure: String? = null,
        asOf: String? = "2026-10-01",
        atMs: Long = whenMs
    ) = PaperRetractionCheck(status, deciding, unanswered, atMs, asOf, failure)

    private fun paper(doi: String? = "10.1/x", pmid: String? = null) = RetractionPaper(doi, pmid, emptyList())

    @Test
    fun checkedOnLine() {
        assertEquals("Retraction status checked 2026-10-18", RetractionText.checkedOnLine(whenMs))
        assertEquals("Retraction status never checked", RetractionText.checkedOnLine(null))
        // late in the UTC day: still the UTC date
        assertEquals("Retraction status checked 2026-10-18", RetractionText.checkedOnLine(1_792_367_940_000L))
    }

    @Test
    fun statusLines() {
        val asOf = "; Retraction Watch data as of 2026-10-01"
        assertEquals("Retracted on 2026-03-09 (notice 10.9/n)$asOf", RetractionText.paperStatusLine(check("retracted", evidence())))
        val label = evidence(source = "pubmed_label", notice = null, day = null)
        assertEquals("Retracted (PubMed's label)", RetractionText.paperStatusLine(check("retracted", label, asOf = null)))
        assertEquals(
            "Expression of concern, 2026-03 (notice 10.9/n)$asOf",
            RetractionText.paperStatusLine(check("concern", evidence(kind = "expression_of_concern", day = "2026-03")))
        )
        assertEquals(
            "Expression of concern (notice 10.9/n)",
            RetractionText.paperStatusLine(check("concern", evidence(kind = "expression_of_concern", day = null), asOf = null))
        )
        assertEquals(
            "Expression of concern (PubMed's label)",
            RetractionText.paperStatusLine(
                check("concern", evidence(source = "pubmed_label", kind = "expression_of_concern", notice = null, day = null), asOf = null)
            )
        )
        assertEquals("Retracted on 2026-03-09", RetractionText.paperStatusLine(check("retracted", evidence(notice = null), asOf = null)))
        assertEquals(
            "Retracted",
            RetractionText.paperStatusLine(check("retracted", evidence(source = "crossref_publisher", notice = null, day = null), asOf = null))
        )
        assertEquals("No retraction found; Retraction Watch data as of 2026-10-01", RetractionText.paperStatusLine(check("clear")))
    }

    @Test
    fun uncheckedStatusLines() {
        assertEquals(
            "Retraction status not checked: Crossref (Crossref answered HTTP 503); Retraction Watch data as of 2026-10-01",
            RetractionText.paperStatusLine(check("unchecked", unanswered = listOf("crossref"), failure = "Crossref answered HTTP 503"))
        )
        assertEquals(
            "Retraction status not checked: Retraction Watch",
            RetractionText.paperStatusLine(check("unchecked", unanswered = listOf("retraction_watch_export"), asOf = null))
        )
        assertEquals(
            "Retraction status not checked: Retraction Watch, Crossref",
            RetractionText.paperStatusLine(check("unchecked", unanswered = both, asOf = null))
        )
        assertEquals("Retraction status not checked", RetractionText.paperStatusLine(check("unchecked", asOf = null)))
    }

    @Test
    fun summaryClauseCountsAndSingulars() {
        assertNull(RetractionText.runSummaryClause(0, 0, emptyList()))
        assertEquals("1 retracted paper left out", RetractionText.runSummaryClause(1, 0, emptyList()))
        assertEquals(
            "2 retracted papers left out; 3 papers' retraction status could not be checked",
            RetractionText.runSummaryClause(2, 3, emptyList())
        )
        assertEquals(
            "1 paper's retraction status could not be checked: no DOI or PMID",
            RetractionText.runSummaryClause(0, 1, listOf("no DOI or PMID"))
        )
        assertEquals(
            "1,234 retracted papers left out; 1,234 papers' retraction status could not be checked: a; b",
            RetractionText.runSummaryClause(1234, 1234, listOf("a", "b"))
        )
    }

    @Test
    fun everyUncheckedPaperHasANamedCause() {
        val cases: List<Pair<Triple<String, RetractionPaper, PaperRetractionCheck?>, Set<RetractionPaper>>> = listOf(
            Triple("no DOI, which Crossref needs", paper(null, pmid = "12345678"), check("unchecked", unanswered = listOf("crossref"))) to emptySet(),
            Triple("Crossref had no usable answer for the DOI", paper(), check("unchecked", unanswered = listOf("crossref"))) to emptySet(),
            Triple("a Retraction Watch notice could not be read", paper(), check("unchecked", unanswered = listOf("retraction_watch_export"))) to emptySet(),
            Triple(rwCause, paper(), check("unchecked", unanswered = listOf("retraction_watch_export"), asOf = null)) to emptySet(),
            Triple("no DOI or PMID", paper(null), check("unchecked", unanswered = both, asOf = null)) to emptySet(),
            Triple("the check was cancelled before reaching them", paper(), null) to emptySet(),
            Triple("the check failed", paper(), PaperRetractionCheck.failed(whenMs)) to setOf(paper()),
            Triple("the check failed", paper(), null) to setOf(paper()),
        )
        for ((case, failed) in cases) {
            val (cause, p, c) = case
            assertEquals(cause, listOf(cause), RetractionText.uncheckedCauses(listOf(p to c), failed))
        }
        // decided papers give no cause, even when listed as failed
        assertEquals(emptyList<String>(), RetractionText.uncheckedCauses(listOf(paper() to check("clear")), emptySet()))
        assertEquals(emptyList<String>(), RetractionText.uncheckedCauses(listOf(paper() to check("clear")), setOf(paper())))
    }

    @Test
    fun aMixedRunNamesEveryCauseOnceInOrder() {
        val rows = listOf<Pair<RetractionPaper, PaperRetractionCheck?>>(
            paper("10.1/c") to null,
            paper(null) to check("unchecked", unanswered = both, asOf = null),
            paper("10.1/a") to check("unchecked", unanswered = both, failure = "Crossref answered HTTP 429", asOf = null),
            paper("10.1/b") to check("unchecked", unanswered = both, failure = "Crossref answered HTTP 429", asOf = null),
            paper("10.1/d") to check("unchecked", unanswered = listOf("crossref"), failure = "Crossref timed out"),
        )
        assertEquals(
            listOf(
                rwCause,
                "Crossref could not be used (Crossref answered HTTP 429, Crossref timed out)",
                "no DOI or PMID",
                "the check was cancelled before reaching them",
            ),
            RetractionText.uncheckedCauses(rows, emptySet())
        )
        // the failure cause leads, and the silent / no-DOI causes follow Crossref's
        val more = listOf<Pair<RetractionPaper, PaperRetractionCheck?>>(
            paper(null, pmid = "5") to check("unchecked", unanswered = listOf("crossref")),
            paper("10.1/s") to check("unchecked", unanswered = listOf("crossref")),
            paper("10.1/f") to PaperRetractionCheck.failed(whenMs),
        )
        assertEquals(
            listOf("the check failed", "no DOI, which Crossref needs", "Crossref had no usable answer for the DOI"),
            RetractionText.uncheckedCauses(more, setOf(paper("10.1/f")))
        )
    }

    @Test
    fun methodsLine() {
        assertEquals("Retraction status checked 2026-10-18", RetractionText.methodsLine(whenMs, 0, true))
        assertEquals("Retraction status checked 2026-10-18; 1 paper could not be checked", RetractionText.methodsLine(whenMs, 1, true))
        assertEquals("Retraction status checked 2026-10-18; 2 papers could not be checked", RetractionText.methodsLine(whenMs, 2, true))
        assertEquals("Retraction status checked 2026-10-18; 1,234 papers could not be checked", RetractionText.methodsLine(whenMs, 1234, true))
        assertEquals("Retraction status could not be checked", RetractionText.methodsLine(null, 3, true))
        assertEquals("Retraction status never checked", RetractionText.methodsLine(null, 0, false))
    }

    @Test
    fun leftOutEntries() {
        assertEquals("## Left out as retracted", RetractionText.LEFT_OUT_HEADING)
        assertEquals("- Title rw. Retracted 2026-03-09", RetractionText.leftOutEntry("Title rw", check("retracted", evidence(notice = null))))
        assertEquals("- Title rw. Retracted 2026-03-09; notice 10.9/n", RetractionText.leftOutEntry("Title rw", check("retracted", evidence())))
        assertEquals(
            "- Title label. Retracted (PubMed's label)",
            RetractionText.leftOutEntry("Title label", check("retracted", evidence(source = "pubmed_label", notice = null, day = null)))
        )
        assertEquals("- No evidence. Retracted (PubMed's label)", RetractionText.leftOutEntry("No evidence", check("retracted")))
        assertEquals(
            "- A \\*bold\\* \\[x\\]\\_y\\_ \\<b\\> \\`c\\` \\\\. Retracted 2026-03-09; notice 10.9/n",
            RetractionText.leftOutEntry("A  *bold*\n[x]_y_ <b> `c` \\", check("retracted", evidence()))
        )
        // a special before a combining mark is still escaped (#649), and Unicode spaces collapse
        assertEquals("- \\*\u0301 a b. Retracted (PubMed's label)", RetractionText.leftOutEntry("*\u0301\u00a0a\u2003b", check("retracted")))
    }

    @Test
    fun concernCaveat() {
        assertEquals(
            "    ⚠️ Expression of concern (2026-03, notice 10.9/n)",
            RetractionText.concernCaveat(check("concern", evidence(kind = "expression_of_concern", day = "2026-03")))
        )
        assertEquals(
            "    ⚠️ Expression of concern",
            RetractionText.concernCaveat(check("concern", evidence(kind = "expression_of_concern", notice = null, day = null)))
        )
        assertEquals("    ⚠️ Expression of concern", RetractionText.concernCaveat(check("concern")))
    }

    @Test
    fun savedWorkLine() {
        assertEquals("Retraction status never checked", RetractionText.savedWorkLine(emptyList()))
        assertEquals("Retraction status could not be checked", RetractionText.savedWorkLine(listOf(check("unchecked", unanswered = both))))
        val older = check("clear", asOf = null, atMs = whenMs - 86_400_000L)
        assertEquals(
            "the oldest decided check, never an unchecked one's time",
            "Retraction status checked 2026-10-17; 1 paper could not be checked",
            RetractionText.savedWorkLine(listOf(check("retracted", evidence()), older, check("unchecked", unanswered = both)))
        )
    }

    @Test
    fun `savedWorkLine names why papers stay unchecked, after Check again`() {
        val unchecked = check("unchecked", unanswered = both, asOf = null)
        assertEquals(
            "Retraction status checked 2026-10-18; 1 paper could not be checked: $rwCause",
            RetractionText.savedWorkLine(listOf(check("clear"), unchecked), listOf(rwCause))
        )
        assertEquals("Retraction status could not be checked: $rwCause", RetractionText.savedWorkLine(listOf(unchecked), listOf(rwCause)))
        assertEquals("no paper unchecked, no causes", "Retraction status checked 2026-10-18", RetractionText.savedWorkLine(listOf(check("clear")), listOf(rwCause)))
    }

    @Test
    fun notCheckedAgainClause() {
        assertEquals("", RetractionText.notCheckedAgainClause(0))
        assertEquals("; 1 paper could not be checked again", RetractionText.notCheckedAgainClause(1))
        assertEquals("; 1,200 papers could not be checked again", RetractionText.notCheckedAgainClause(1_200))
        assertEquals("; 2 papers could not be checked again: a; b", RetractionText.notCheckedAgainClause(2, listOf("a", "b")))
    }

    @Test
    fun savedWorkWarning() {
        assertNull(RetractionText.savedWorkWarning(emptyList()))
        assertEquals(
            "Since this report was written, 1 paper this report cites has a retraction warning:\n" +
                "• A trial: Retracted on 2026-03-09 (notice 10.9/n); Retraction Watch data as of 2026-10-01\n" +
                "The report has not been changed; re-run the question to bring it up to date.",
            RetractionText.savedWorkWarning(listOf("A\n  trial" to check("retracted", evidence())))
        )
        val two = RetractionText.savedWorkWarning(
            listOf("A" to check("retracted", evidence()), "B" to check("concern", evidence(kind = "expression_of_concern"), asOf = null))
        )!!
        assertTrue(two.startsWith("Since this report was written, 2 papers this report cites have"))
        assertTrue(two.contains("• B: Expression of concern, 2026-03-09 (notice 10.9/n)\n"))
    }

    @Test
    fun excludedLine() {
        val run = check("retracted", evidence(notice = "10.9/notice"), asOf = null)
        val runLine = "Excluded: retracted. Retracted on 2026-03-09 (notice 10.9/notice)"
        assertEquals(runLine, RetractionText.excludedLine(run, run))
        assertEquals("$runLine. Checked again: No retraction found", RetractionText.excludedLine(run, check("clear", asOf = null)))
    }

    @Test
    fun reportNotice() {
        assertEquals("> **Retraction check:** 1 retracted paper left out.", RetractionText.reportNotice("1 retracted paper left out"))
    }

    @Test
    fun paperKey() {
        assertEquals(paper("10.1/x").paperKey, paper("https://doi.org/10.1/X").paperKey)
        assertEquals("pmid:123", paper(null, pmid = "123").paperKey)
        assertNull("a PMID that is not canonical is no PMID", paper(null, pmid = "x").paperKey)
        assertNull(paper(null).paperKey)
    }
}
