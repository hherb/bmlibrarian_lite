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

/**
 * What a report says about its run's retraction check (Swift's
 * `RetractionReportSection`): the opening notice, the methods line and the
 * "Left out as retracted" section.
 *
 * @param papers Every paper the run held (kept and left out), by title, with the check it used
 * @param causes Why kept papers are unchecked ([RetractionText.uncheckedCauses]),
 *   when the live run knows; empty gives the count alone, as the desktop's restored snapshot does
 * @param unread The run's record cannot be read: the methods line says so ([UNREAD])
 * @param unreadEntries The run's papers whose snapshot entries this build cannot read:
 *   counted as such, never unchecked and never listed as left out (#727)
 */
class RetractionReportSection(
    papers: List<Pair<String, PaperRetractionCheck>>,
    causes: List<String> = emptyList(),
    unread: Boolean = false,
    unreadEntries: Int = 0
) {

    /** The papers left out as retracted, in the order given. */
    val leftOut: List<Pair<String, PaperRetractionCheck>> = papers.filter { it.second.isRetracted }

    /** [RetractionText.savedWorkLine] for the run (as the desktop, the oldest decided check), or [RetractionText.STATUS_UNREAD] when [unread]. */
    val methodsLine: String = if (unread) RetractionText.STATUS_UNREAD
        else RetractionText.savedWorkLine(papers.map { it.second }, unread = unreadEntries)

    /** The report's opening notice, or null when nothing was left out and every paper was checked. */
    val notice: String? = RetractionText.runSummaryClause(
        excluded = leftOut.size,
        unchecked = papers.count { it.second.isUnchecked },
        causes = causes,
        unread = unreadEntries
    )?.let(RetractionText::reportNotice)

    /** [text] with the notice in front (the desktop's `with_retraction_notice`); unchanged when it already opens with one. */
    fun withNotice(text: String): String =
        if (notice == null || text.startsWith(RetractionText.NOTICE_OPENING)) text else "$notice\n\n$text"

    /** The left-out section, or "" when nothing was left out. */
    val leftOutMarkdown: String
        get() = if (leftOut.isEmpty()) "" else
            (listOf(RetractionText.LEFT_OUT_HEADING, "") + leftOut.map { RetractionText.leftOutEntry(it.first, it.second) }).joinToString("\n")

    /** The methods line as a Methodology list item. */
    val methodsMarkdown: String
        get() = "- **Retraction Check:** $methodsLine"

    companion object {
        /**
         * A run whose snapshot this build cannot read: the methods line says
         * so, with no notice and nothing left out (the desktop's and Swift's, #662).
         */
        val UNREAD = RetractionReportSection(emptyList(), unread = true)
    }
}
