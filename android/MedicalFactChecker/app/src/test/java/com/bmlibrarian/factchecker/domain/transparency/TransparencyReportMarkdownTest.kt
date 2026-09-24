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

    /**
     * A document analysed without full text. With a COI statement, industry funding and
     * unavailable data it is rated high on findings that stand without the text.
     */
    private fun analysed(surname: String, coiStatement: String?, industryWithoutData: Boolean = false) = DocumentEntity(
        sessionId = "s",
        pmid = surname.length.toString(),
        title = "Study by $surname",
        authors = listOf("$surname A", "Other B"),
        publicationYear = 2020,
        transparencyResultJson = TransparencyJson.encode(
            TransparencyResultBuilder(pmid = "1").apply {
                coiAnalysis = COIAnalysisResult(statement = coiStatement)
                dataAvailability = DataAvailabilityResult(
                    disclosureLevel = if (industryWithoutData) DataDisclosureLevel.NOT_AVAILABLE else DataDisclosureLevel.FULL_OPEN,
                )
                industryFundingDetected = industryWithoutData
                dataSourcesUsed = listOf(TransparencyConstants.PUBMED_SOURCE_NAME)
                fullTextSearched = false
            }.build(),
        ),
    )

    @Test
    fun `nothing is written for a report resting on no documents`() {
        assertEquals("", TransparencyReportMarkdown.sections(emptyList()))
    }

    /** A document left unanalysed must not read as one examined and found clean. */
    @Test
    fun `a document with no readable analysis is named as unanalysed`() {
        val damaged = analysed("Cole", "None declared.").copy(transparencyResultJson = "{broken")
        val never = DocumentEntity(sessionId = "s", title = "Never analysed", authors = listOf("Dunn A"))
        val text = TransparencyReportMarkdown.sections(listOf(analysed("Adams", "None declared."), damaged, never))
        assertTrue(
            text,
            text.contains(
                "**2 of 3 documents could not be analysed for transparency, and carry no rating:** " +
                    "Cole et al., 2020 (Study by Cole); Dunn, n.d. (Never analysed)",
            ),
        )
        assertTrue(text, text.contains("1 document analysed for transparency risk: 1 low."))
    }

    @Test
    fun `summary counts the levels and always states limited certainty`() {
        val text = TransparencyReportMarkdown.sections(
            listOf(analysed("Adams", "None declared."), analysed("Baker", null)),
        )
        assertTrue(text, text.startsWith("## Transparency Analysis"))
        assertTrue(text, text.contains("2 documents analysed for transparency risk: 1 low, 1 unassessed."))
        assertTrue(text, text.contains("1 study is shown as unassessed rather than high risk"))
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
        val text = TransparencyReportMarkdown.sections(listOf(analysed("Baker", "None.", industryWithoutData = true)))
        assertTrue(text, text.contains("## ${HighRiskTransparencySection.HEADING}"))
        assertTrue(text, text.contains("### Baker et al., 2020"))
        assertTrue(text, text.contains("**Limited certainty because of lack of full text access**"))
        assertTrue(text, text.contains("**${HighRiskTransparencySection.REASONS_LABEL}:**"))
        assertTrue(text, text.contains("- Industry funding was detected"))
    }

    /** A high rating resting only on unsearched text is summarised, not discussed as high risk. */
    @Test
    fun `a text-only high rating is counted as unassessed, not discussed`() {
        val text = TransparencyReportMarkdown.sections(listOf(analysed("Baker", null)))
        assertFalse(text, text.contains(HighRiskTransparencySection.HEADING))
        assertTrue(text, text.contains("1 document analysed for transparency risk: 1 unassessed."))
        assertTrue(text, text.contains("1 study is shown as unassessed rather than high risk"))
    }

    /** The PDF exporter lays out one paragraph per blank-line block, so no block may hold two lines. */
    @Test
    fun `every item is its own block, as the PDF exporter needs`() {
        val text = TransparencyReportMarkdown.sections(
            listOf(analysed("Baker", "None.", industryWithoutData = true), analysed("Cole", null)),
        )
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
