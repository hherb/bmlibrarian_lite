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
import com.bmlibrarian.factchecker.util.retraction.RetractionReportSection

/**
 * Assembles the stored report text around what the LLM wrote.
 *
 * What the search failed to retrieve is added here, by code, never left to the
 * LLM (#252): an incomplete search's report opens with the incomplete-search
 * notice and records the gap in a Methodology section before its references.
 * So is what the retraction check left out and could not check: its notice,
 * its Methodology line and the "Left out as retracted" section.
 */
object ReportText {

    /** Separates the report's blocks. */
    private const val BLOCK_SEPARATOR = "\n\n"

    /** Heads the references the workflow lists after the analysis. */
    private const val REFERENCES_HEADING = "## References"

    /** Heads the Methodology section when the search's completeness adds nothing to it. */
    private const val METHODOLOGY_HEADING = "## Methodology"

    /**
     * Build a report's full text.
     *
     * @param analysis The report the LLM wrote
     * @param references The reference list, one entry per relevant document
     * @param shortfalls What the session's searches failed to retrieve
     * @param transparency The transparency sections, built by code from the
     *   stored analyses (`TransparencyReportMarkdown`); empty when none ran
     * @param retraction What the run's retraction check left out and could not
     *   check; null for a session never checked
     * @return The search notice (if any), the retraction notice (if any), the
     *   analysis, the transparency sections (if any), the Methodology section
     *   (if any), the "Left out as retracted" section (if any) and the references
     */
    fun fullReport(
        analysis: String,
        references: String,
        shortfalls: List<RetrievalShortfall>,
        transparency: String = "",
        retraction: RetractionReportSection? = null
    ): String {
        val blocks = listOf(
            analysis,
            transparency,
            methodology(SearchFailureReporting.searchCompletenessMethodology(shortfalls), retraction),
            retraction?.leftOutMarkdown.orEmpty(),
            "$REFERENCES_HEADING$BLOCK_SEPARATOR$references"
        ).filter { it.isNotEmpty() }
        return withNotices(blocks.joinToString(BLOCK_SEPARATOR), shortfalls, retraction)
    }

    /**
     * Build the text of a message saved in place of a report, such as "no relevant evidence".
     *
     * @param text The message
     * @param shortfalls What the session's searches failed to retrieve
     * @param retraction As for [fullReport]
     * @return The message, opening with the notice when the search was
     *   incomplete and the retraction notice when there is one, then the
     *   retraction Methodology line and the "Left out as retracted" section
     */
    fun standInReport(text: String, shortfalls: List<RetrievalShortfall>, retraction: RetractionReportSection? = null): String {
        val blocks = listOf(text, methodology("", retraction), retraction?.leftOutMarkdown.orEmpty()).filter { it.isNotEmpty() }
        return withNotices(blocks.joinToString(BLOCK_SEPARATOR), shortfalls, retraction)
    }

    /** The search notice before the retraction notice before [body]. */
    private fun withNotices(body: String, shortfalls: List<RetrievalShortfall>, retraction: RetractionReportSection?): String =
        SearchFailureReporting.withSearchShortfallNotice(retraction?.withNotice(body) ?: body, shortfalls)

    /**
     * The Methodology section: [search]'s, with the retraction line added, or
     * the heading over the retraction line alone; "" when neither has one.
     */
    private fun methodology(search: String, retraction: RetractionReportSection?): String {
        val line = retraction?.methodsMarkdown ?: return search
        return (search.ifEmpty { METHODOLOGY_HEADING }) + BLOCK_SEPARATOR + line
    }
}
