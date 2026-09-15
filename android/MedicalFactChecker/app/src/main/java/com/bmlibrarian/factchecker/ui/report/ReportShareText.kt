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

package com.bmlibrarian.factchecker.ui.report

import com.bmlibrarian.factchecker.data.local.entity.ReportEntity
import com.bmlibrarian.factchecker.domain.model.SearchFailureReporting

/**
 * Builds the plain text a report is shared as.
 */
object ReportShareText {

    /**
     * Build a report's shared text.
     *
     * The verdict and summary come before the report's own text, so an
     * incomplete search's notice is moved ahead of them: a reader must learn the
     * evidence base is partial before reading the verdict (#252).
     *
     * @param report The report
     * @return The title, the notice (if any), the verdict, the summary, the
     *   report and its footnotes
     */
    fun build(report: ReportEntity): String = buildString {
        val (notice, body) = SearchFailureReporting.splitPlainSearchShortfallNotice(report.fullReportMarkdown)
        appendLine("Medical Fact Check Report")
        appendLine("========================")
        appendLine()
        notice?.let {
            appendLine(it)
            appendLine()
        }
        appendLine("Verdict: ${report.verdict.displayName}")
        appendLine()
        appendLine(report.summary)
        appendLine()
        appendLine("---")
        appendLine()
        appendLine(body)
        report.footnotes?.let {
            appendLine()
            appendLine("---")
            appendLine()
            appendLine("References:")
            appendLine(it)
        }
    }
}
