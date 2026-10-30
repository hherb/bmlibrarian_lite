/*
 * BMLibrarian Lite - Biomedical Literature Research Tool
 * Copyright (C) 2024-2026 Dr Horst Herb
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU Affero General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

package com.bmlibrarian.factchecker.ui.factcheck.components

import com.bmlibrarian.factchecker.util.retraction.PaperRetractionCheck
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** What each status's badge says (Swift's `testBadgeContentPerStatus`). */
class RetractionBadgeContentTest {
    private fun check(status: String, unanswered: List<String> = emptyList()) =
        PaperRetractionCheck(status, unanswered = unanswered, checkedAtMs = 1)

    @Test
    fun `each status's badge, and none for clear`() {
        val retracted = RetractionBadgeContent.of(check("retracted"))!!
        assertEquals("RETRACTED", retracted.text)
        assertTrue(retracted.isRetracted)
        assertEquals("Retracted (PubMed's label)", retracted.statusLine)
        assertEquals("CONCERN", RetractionBadgeContent.of(check("concern"))!!.text)
        assertEquals("NOT CHECKED", RetractionBadgeContent.of(check("unchecked", listOf("crossref")))!!.text)
        assertNull(RetractionBadgeContent.of(check("clear")))
    }

    @Test
    fun `a paper never checked is NOT CHECKED only in a detail view`() {
        assertNull(RetractionBadgeContent.of(null))
        val detail = RetractionBadgeContent.of(null, inDetail = true)!!
        assertEquals("NOT CHECKED", detail.text)
        assertEquals("Retraction status never checked", detail.statusLine)
    }

    @Test
    fun `a status this build cannot read is NOT CHECKED, never clear`() {
        assertEquals("NOT CHECKED", RetractionBadgeContent.of(check("not-a-status"))!!.text)
    }
}
