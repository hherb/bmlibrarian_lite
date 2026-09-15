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

package com.bmlibrarian.factchecker.data.local.entity

import com.bmlibrarian.factchecker.domain.model.RequestFailure
import com.bmlibrarian.factchecker.domain.model.RequestFailureKind
import com.bmlibrarian.factchecker.domain.model.RetrievalShortfall
import com.bmlibrarian.factchecker.domain.model.SearchProvider
import com.bmlibrarian.factchecker.domain.model.Verdict
import com.bmlibrarian.factchecker.domain.workflow.ReportText
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Whether a saved report says its search was incomplete (#252), for a surface
 * such as the history list that shows the verdict without the report's text.
 */
class ReportEntitySearchNoticeTest {

    @Test
    fun `a report written from an incomplete search says so`() {
        val shortfall = RetrievalShortfall(SearchProvider.PUBMED, RequestFailure(RequestFailureKind.TIMEOUT))

        assertTrue(report(ReportText.fullReport("Analysis.", "Refs.", listOf(shortfall))).searchWasIncomplete)
        assertTrue(report(ReportText.standInReport("No evidence.", listOf(shortfall))).searchWasIncomplete)
    }

    @Test
    fun `a report written from a complete search does not`() {
        assertFalse(report(ReportText.fullReport("Analysis.", "Refs.", emptyList())).searchWasIncomplete)
        assertFalse(report("> **Incomplete search:** quoted inside, with no blank line after").searchWasIncomplete)
    }

    /** A report holding this text. */
    private fun report(fullReport: String) = ReportEntity(
        sessionId = "session",
        verdict = Verdict.SUPPORTED,
        summary = "Summary.",
        fullReportMarkdown = fullReport,
        modelUsed = "model",
        totalDocumentsReviewed = 1,
        relevantDocumentsCount = 1,
        citationsCount = 1
    )
}
