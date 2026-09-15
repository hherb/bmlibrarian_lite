/*
 * BMLibrarian Lite - Biomedical Literature Research Tool
 * Copyright (C) 2024-2025 Dr Horst Herb
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

package com.bmlibrarian.factchecker.domain.workflow

import com.bmlibrarian.factchecker.domain.model.RequestFailure
import com.bmlibrarian.factchecker.domain.model.RequestFailureKind
import com.bmlibrarian.factchecker.domain.model.RetrievalShortfall
import com.bmlibrarian.factchecker.domain.model.SearchProvider
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The report text code assembles around what the LLM wrote (#252).
 *
 * The incomplete-search notice and the Methodology line are added by code,
 * never left to the LLM.
 */
class ReportTextTest {

    @Test
    fun `a complete search's report is the analysis and its references`() {
        assertEquals(
            "## Analysis\n\nText.\n\n## References\n\n**1.** Ref.",
            ReportText.fullReport(analysis = "## Analysis\n\nText.", references = "**1.** Ref.", shortfalls = emptyList())
        )
    }

    @Test
    fun `an incomplete search's report opens with the notice and records the gap before the references`() {
        assertEquals(
            "> **Incomplete search:** PubMed could not be searched (HTTP 429 Too Many Requests). " +
                "Everything below rests only on the records that were retrieved.\n\n" +
                "## Analysis\n\nText.\n\n" +
                "## Methodology\n\n- **Search Completeness:** Incomplete: PubMed could not be searched (HTTP 429 Too Many Requests)\n\n" +
                "## References\n\n**1.** Ref.",
            ReportText.fullReport(analysis = "## Analysis\n\nText.", references = "**1.** Ref.", shortfalls = listOf(PUBMED_DOWN))
        )
    }

    @Test
    fun `a message standing in for a report opens with the notice`() {
        assertEquals(
            "> **Incomplete search:** PubMed could not be searched (HTTP 429 Too Many Requests). " +
                "Everything below rests only on the records that were retrieved.\n\n## Evidence Report\n\nNothing.",
            ReportText.standInReport("## Evidence Report\n\nNothing.", listOf(PUBMED_DOWN))
        )
        assertEquals("## Evidence Report\n\nNothing.", ReportText.standInReport("## Evidence Report\n\nNothing.", emptyList()))
    }

    private companion object {
        val PUBMED_DOWN = RetrievalShortfall(SearchProvider.PUBMED, RequestFailure(RequestFailureKind.HTTP_STATUS, 429))
    }
}
