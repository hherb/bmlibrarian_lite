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

package com.bmlibrarian.factchecker.util

import android.content.Context
import com.bmlibrarian.factchecker.data.local.entity.ReportEntity
import com.bmlibrarian.factchecker.domain.model.RequestFailure
import com.bmlibrarian.factchecker.domain.model.RequestFailureKind
import com.bmlibrarian.factchecker.domain.model.RetrievalShortfall
import com.bmlibrarian.factchecker.domain.model.SearchProvider
import com.bmlibrarian.factchecker.domain.model.Verdict
import com.bmlibrarian.factchecker.domain.workflow.ReportText
import com.bmlibrarian.factchecker.ui.report.PaperSize
import com.itextpdf.kernel.pdf.PdfDocument
import com.itextpdf.kernel.pdf.PdfReader
import com.itextpdf.kernel.pdf.canvas.parser.PdfTextExtractor
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

/**
 * An exported PDF says its search was incomplete before its verdict (#252).
 *
 * Measured through the real renderer: the PDF is written and its text read back.
 */
class PdfExporterSearchNoticeTest {

    @get:Rule
    val folder = TemporaryFolder()

    @Test
    fun `the notice comes before the verdict, as plain text`() = runTest {
        val text = exportedText(ReportText.fullReport("## Analysis\n\nAspirin helps.", "**1.** A reference.", listOf(PUBMED_DOWN)))

        val notice = text.indexOf("Incomplete search: PubMed could not be searched")
        val verdict = text.indexOf("VERDICT")
        assertTrue("no notice in: $text", notice >= 0)
        assertTrue("the notice follows the verdict in: $text", notice < verdict)
        assertEquals("the notice is drawn more than once in: $text", notice, text.lastIndexOf("Incomplete search:"))
        assertFalse("markup printed literally in: $text", text.contains("> ") || text.contains("**"))
    }

    @Test
    fun `the methodology line prints without its markup`() = runTest {
        val text = exportedText(ReportText.fullReport("## Analysis\n\nAspirin helps.", "**1.** A reference.", listOf(PUBMED_DOWN)))

        assertTrue("no methodology in: $text", text.contains("Search Completeness: Incomplete: PubMed could not be searched"))
        assertFalse("markup printed literally in: $text", text.contains("**"))
    }

    @Test
    fun `a complete search's PDF says nothing about completeness`() = runTest {
        val text = exportedText(ReportText.fullReport("## Analysis\n\nAspirin helps.", "**1.** A reference.", emptyList()))

        assertFalse(text.contains("Incomplete search"))
        assertFalse(text.contains("Search Completeness"))
    }

    /** Export a report holding this text, and read the PDF's text back. */
    private suspend fun exportedText(fullReport: String): String {
        val context = mockk<Context> { every { cacheDir } returns folder.root }
        val report = ReportEntity(
            sessionId = "session",
            verdict = Verdict.SUPPORTED,
            summary = "Aspirin reduces strokes.",
            fullReportMarkdown = fullReport,
            modelUsed = "model",
            totalDocumentsReviewed = 3,
            relevantDocumentsCount = 2,
            citationsCount = 1
        )

        val file: File = PdfExporter(context).exportReport(report, emptyList(), PaperSize.A4)

        PdfDocument(PdfReader(file)).use { pdf ->
            return (1..pdf.numberOfPages).joinToString("\n") { PdfTextExtractor.getTextFromPage(pdf.getPage(it)) }
        }
    }

    private companion object {
        val PUBMED_DOWN = RetrievalShortfall(SearchProvider.PUBMED, RequestFailure(RequestFailureKind.HTTP_STATUS, 429))
    }
}
