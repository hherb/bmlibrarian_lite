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

package com.bmlibrarian.factchecker.domain.transparency

import com.bmlibrarian.factchecker.data.local.entity.DocumentEntity

/**
 * The report's transparency sections, as markdown stored with the report.
 *
 * Written into the report body, which the report screen, the PDF export and
 * the shared text all render, so the three cannot disagree about which
 * studies were flagged or why. Every item is its own paragraph: the PDF
 * exporter lays out one paragraph per blank-line-separated block.
 */
object TransparencyReportMarkdown {
    /** Heads the summary of every analysed document. */
    const val SUMMARY_HEADING: String = "Transparency Analysis"

    /** Separates markdown blocks. */
    private const val BLOCK_SEPARATOR = "\n\n"

    /**
     * The transparency summary and, when any study was rated high, the
     * discussion of each.
     *
     * @param documents The session's documents.
     * @return The sections, or an empty string when no document was analysed.
     */
    fun sections(documents: List<DocumentEntity>): String {
        val analysed = documents.filter { it.transparencyResult != null }
        if (analysed.isEmpty()) return ""

        val blocks = mutableListOf("## $SUMMARY_HEADING", distribution(analysed))
        val limited = analysed.count { it.transparencyCertainty == TransparencyCertainty.LIMITED_NO_FULL_TEXT }
        if (limited > 0) {
            blocks += "**$limited of ${analysed.size} ratings were made without the full text. " +
                "${TransparencyConstants.LIMITED_CERTAINTY_NOTE}.**"
        }

        val entries = highRiskTransparencyEntries(documents)
        HighRiskTransparencySection.introduction(entries.size)?.let { introduction ->
            blocks += "## ${HighRiskTransparencySection.HEADING}"
            blocks += introduction
            entries.forEach { blocks += entryBlocks(it) }
        }
        return blocks.joinToString(BLOCK_SEPARATOR)
    }

    /** How many analysed documents fell at each risk level. */
    private fun distribution(analysed: List<DocumentEntity>): String {
        val levels = analysed.mapNotNull { it.transparencyResult?.riskLevel }
        val counts = listOf(
            TransparencyRiskLevel.LOW to "low",
            TransparencyRiskLevel.MEDIUM to "medium",
            TransparencyRiskLevel.HIGH to "high",
            TransparencyRiskLevel.UNKNOWN to "undetermined",
        ).mapNotNull { (level, label) ->
            levels.count { it == level }.takeIf { it > 0 }?.let { "$it $label" }
        }
        val documents = if (analysed.size == 1) "1 document" else "${analysed.size} documents"
        return "$documents analysed for transparency risk: ${counts.joinToString(", ")}."
    }

    /** One high-risk study as markdown blocks. */
    private fun entryBlocks(entry: HighRiskTransparencyEntry): List<String> {
        val explanation = entry.explanation
        val blocks = mutableListOf(
            "### ${entry.reference}",
            entry.citation,
            "Transparency score: ${explanation.score}/${TransparencyConstants.MAX_TRANSPARENCY_SCORE}",
        )
        explanation.certainty.note?.let { blocks += "**$it**" }
        blocks += list(HighRiskTransparencySection.REASONS_LABEL, explanation.reasons)
        blocks += list(
            HighRiskTransparencySection.SCORE_BREAKDOWN_LABEL,
            explanation.scoreBreakdown.map { "${it.label}: ${it.signedPoints}" },
        )
        blocks += list(HighRiskTransparencySection.OTHER_CONCERNS_LABEL, explanation.otherConcerns)
        blocks += list(HighRiskTransparencySection.CAVEATS_LABEL, explanation.caveats)
        return blocks
    }

    /** A labelled bullet list, or nothing when it has no items. */
    private fun list(label: String, items: List<String>): List<String> =
        if (items.isEmpty()) emptyList() else listOf("**$label:**") + items.map { "- $it" }
}
