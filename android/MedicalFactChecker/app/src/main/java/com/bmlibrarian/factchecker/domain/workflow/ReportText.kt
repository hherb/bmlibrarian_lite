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

import com.bmlibrarian.factchecker.domain.model.RetrievalShortfall
import com.bmlibrarian.factchecker.domain.model.SearchFailureReporting

/**
 * Assembles the stored report text around what the LLM wrote.
 *
 * What the search failed to retrieve is added here, by code, never left to the
 * LLM (#252): an incomplete search's report opens with the incomplete-search
 * notice and records the gap in a Methodology section before its references.
 */
object ReportText {

    /** Separates the report's blocks. */
    private const val BLOCK_SEPARATOR = "\n\n"

    /** Heads the references the workflow lists after the analysis. */
    private const val REFERENCES_HEADING = "## References"

    /**
     * Build a report's full text.
     *
     * @param analysis The report the LLM wrote
     * @param references The reference list, one entry per relevant document
     * @param shortfalls What the session's searches failed to retrieve
     * @return The notice (if any), the analysis, the Methodology section (if
     *   any) and the references
     */
    fun fullReport(analysis: String, references: String, shortfalls: List<RetrievalShortfall>): String {
        val blocks = listOf(
            analysis,
            SearchFailureReporting.searchCompletenessMethodology(shortfalls),
            "$REFERENCES_HEADING$BLOCK_SEPARATOR$references"
        ).filter { it.isNotEmpty() }
        return SearchFailureReporting.withSearchShortfallNotice(blocks.joinToString(BLOCK_SEPARATOR), shortfalls)
    }

    /**
     * Build the text of a message saved in place of a report, such as "no relevant evidence".
     *
     * @param text The message
     * @param shortfalls What the session's searches failed to retrieve
     * @return The message, opening with the notice when the search was incomplete
     */
    fun standInReport(text: String, shortfalls: List<RetrievalShortfall>): String =
        SearchFailureReporting.withSearchShortfallNotice(text, shortfalls)
}
