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
import org.junit.Test

/**
 * A reopened session's knowledge since its run: an outage never replaces a
 * decided check, and only a cited paper's change for the worse warns
 * (Swift's `RetractionSavedWorkTests`).
 */
class RetractionSavedWorkTest {
    private val run = 1_792_315_800_000L // 2026-10-18 09:30 UTC
    private val later = run + 86_400_000L

    private fun check(status: String, atMs: Long) =
        PaperRetractionCheck(status, unanswered = if (status == "unchecked") listOf("crossref") else emptyList(), checkedAtMs = atMs)

    @Test
    fun `rechecked checks keep the run against an outage`() {
        val rows = RetractionSavedWork.recheckedChecks(
            run = mapOf("a" to check("clear", run), "b" to check("unchecked", run), "c" to check("clear", run)),
            stored = mapOf(
                "a" to check("unchecked", later), "b" to check("retracted", later),
                "c" to check("clear", run - 1), "x" to check("retracted", later)
            )
        )
        assertEquals("an outage is not knowledge", "clear", rows["a"]?.status)
        assertEquals("a newer answer replaces the run's", "retracted", rows["b"]?.status)
        assertEquals("an older stored check never does", run, rows["c"]?.checkedAtMs)
        assertNull("a document the run did not check gets no row", rows["x"])
        val predating = RetractionSavedWork.recheckedChecks(emptyMap(), mapOf("x" to check("clear", later)))
        assertEquals("a run that recorded none reads the stored checks", "clear", predating["x"]?.status)
    }

    @Test
    fun `only a cited paper's change for the worse warns`() {
        val runChecks = mapOf("a" to check("clear", run), "b" to check("retracted", run), "c" to check("clear", run))
        val latest = mapOf(
            "a" to check("retracted", later), // worse: warns
            "b" to check("retracted", later), // what the run saw already
            "c" to check("concern", run - 1), // older than the run's
            "d" to check("concern", later), // never checked by the run: news
            "e" to check("retracted", later) // not cited
        )
        assertEquals(listOf("d", "a"), RetractionSavedWork.changedSinceRun(runChecks, latest, listOf("d", "a", "b", "c")))
    }

    /** A run whose check got no answer knew nothing: a retraction known before it is still news. */
    @Test
    fun `an unchecked run row is no check time`() {
        val older = run - 86_400_000L
        assertEquals(
            "control: a decided run row older than the warning still anchors it",
            listOf("a"),
            RetractionSavedWork.changedSinceRun(
                run = mapOf("a" to check("unchecked", run), "b" to check("clear", run)),
                latest = mapOf("a" to check("retracted", older), "b" to check("retracted", older)),
                cited = listOf("a", "b")
            )
        )
    }
}
