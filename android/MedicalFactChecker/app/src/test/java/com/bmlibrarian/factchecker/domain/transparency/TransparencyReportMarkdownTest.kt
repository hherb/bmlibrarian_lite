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
import com.bmlibrarian.factchecker.domain.workflow.ReportText
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The transparency sections a report carries. */
class TransparencyReportMarkdownTest {

    private fun analysed(surname: String, coiStatement: String?) = DocumentEntity(
        sessionId = "s",
        pmid = surname.length.toString(),
        title = "Study by $surname",
        authors = listOf("$surname A", "Other B"),
        publicationYear = 2020,
        transparencyResultJson = TransparencyJson.encode(
            TransparencyResultBuilder(pmid = "1").apply {
                coiAnalysis = COIAnalysisResult(statement = coiStatement)
                dataAvailability = DataAvailabilityResult(disclosureLevel = DataDisclosureLevel.FULL_OPEN)
                dataSourcesUsed = listOf(TransparencyConstants.PUBMED_SOURCE_NAME)
                fullTextSearched = false
            }.build(),
        ),
    )

    @Test
    fun `nothing is written when no document was analysed`() {
        assertEquals("", TransparencyReportMarkdown.sections(listOf(DocumentEntity(sessionId = "s", title = "t"))))
    }

    @Test
    fun `summary counts the levels and always states limited certainty`() {
        val text = TransparencyReportMarkdown.sections(
            listOf(analysed("Adams", "None declared."), analysed("Baker", null)),
        )
        assertTrue(text, text.startsWith("## Transparency Analysis"))
        assertTrue(text, text.contains("2 documents analysed for transparency risk: 1 low, 1 high."))
        assertTrue(
            text,
            text.contains(
                "**2 of 2 ratings were made without the full text. " +
                    "Limited certainty because of lack of full text access.**",
            ),
        )
    }

    @Test
    fun `each high-risk study is discussed with its reasons and its certainty`() {
        val text = TransparencyReportMarkdown.sections(listOf(analysed("Baker", null)))
        assertTrue(text, text.contains("## ${HighRiskTransparencySection.HEADING}"))
        assertTrue(text, text.contains("### Baker et al., 2020"))
        assertTrue(text, text.contains("**Limited certainty because of lack of full text access**"))
        assertTrue(text, text.contains("**${HighRiskTransparencySection.REASONS_LABEL}:**"))
        assertTrue(text, text.contains("- No conflict of interest statement was found"))
        assertTrue(text, text.contains("Treat the rating as unassessed"))
    }

    /** The PDF exporter lays out one paragraph per blank-line block, so no block may hold two lines. */
    @Test
    fun `every item is its own block, as the PDF exporter needs`() {
        val text = TransparencyReportMarkdown.sections(listOf(analysed("Baker", null)))
        text.split("\n\n").forEach { block -> assertFalse("block spans lines: $block", block.contains('\n')) }
    }

    @Test
    fun `no high-risk section when nothing was rated high`() {
        val text = TransparencyReportMarkdown.sections(listOf(analysed("Adams", "None declared.")))
        assertFalse(text, text.contains(HighRiskTransparencySection.HEADING))
    }

    @Test
    fun `the report carries the sections between the analysis and the references`() {
        val report = ReportText.fullReport(
            "The analysis.",
            "**1.** A reference",
            emptyList(),
            TransparencyReportMarkdown.sections(listOf(analysed("Baker", null))),
        )
        val analysis = report.indexOf("The analysis.")
        val transparency = report.indexOf("## Transparency Analysis")
        val references = report.indexOf("## References")
        assertTrue(report, analysis in 0 until transparency && transparency < references)
    }
}
