package com.bmlibrarian.factchecker.util

import android.content.Context
import com.bmlibrarian.factchecker.data.local.entity.DocumentEntity
import com.bmlibrarian.factchecker.data.local.entity.ReportEntity
import com.bmlibrarian.factchecker.ui.report.PaperSize
import com.itextpdf.kernel.colors.ColorConstants
import com.itextpdf.kernel.colors.DeviceRgb
import com.itextpdf.kernel.geom.PageSize
import com.itextpdf.kernel.pdf.PdfDocument
import com.itextpdf.kernel.pdf.PdfWriter
import com.itextpdf.layout.Document
import com.itextpdf.layout.element.Paragraph
import com.itextpdf.layout.element.Text
import com.itextpdf.layout.properties.TextAlignment
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Utility for exporting evidence reports as PDF files.
 *
 * Uses iTextG library to generate professional-quality PDF documents
 * with proper typography, margins, and formatting.
 *
 * @property context Application context for file access
 */
@Singleton
class PdfExporter @Inject constructor(
    @ApplicationContext private val context: Context
) {

    /**
     * Export a report to PDF.
     *
     * Creates a formatted PDF document containing the verdict, summary,
     * full report, statistics, and references.
     *
     * @param report The report to export
     * @param documents Referenced documents for the citation list
     * @param paperSize Paper size for the PDF (A4 or Letter)
     * @return The generated PDF file
     * @throws Exception if PDF generation fails
     */
    suspend fun exportReport(
        report: ReportEntity,
        documents: List<DocumentEntity>,
        paperSize: PaperSize
    ): File = withContext(Dispatchers.IO) {
        // Create output directory and file
        val outputDir = File(context.cacheDir, Constants.PDF_EXPORT_DIRECTORY)
        outputDir.mkdirs()

        val dateFormat = SimpleDateFormat(Constants.PDF_FILENAME_DATE_PATTERN, Locale.US)
        val timestamp = dateFormat.format(Date())
        val fileName = "${Constants.PDF_FILENAME_PREFIX}$timestamp.pdf"
        val outputFile = File(outputDir, fileName)

        // Create PDF document
        val pdfWriter = PdfWriter(outputFile)
        val pdfDocument = PdfDocument(pdfWriter)
        val pageSize = when (paperSize) {
            PaperSize.A4 -> PageSize.A4
            PaperSize.LETTER -> PageSize.LETTER
        }
        pdfDocument.defaultPageSize = pageSize

        val document = Document(pdfDocument)
        document.setMargins(
            Constants.PDF_PAGE_MARGIN_POINTS,
            Constants.PDF_PAGE_MARGIN_POINTS,
            Constants.PDF_PAGE_MARGIN_POINTS,
            Constants.PDF_PAGE_MARGIN_POINTS
        )

        try {
            // Add content to PDF
            addTitle(document)
            addGeneratedDate(document, report.createdAt)
            addVerdict(document, report)
            addSummary(document, report)
            addFullReport(document, report)
            addStatistics(document, report)
            addReferences(document, documents)
            addFootnotes(document, report)
            addDisclaimer(document)

            document.close()
        } catch (e: Exception) {
            document.close()
            outputFile.delete()
            throw e
        }

        outputFile
    }

    /**
     * Add the document title.
     */
    private fun addTitle(document: Document) {
        val title = Paragraph("MEDICAL FACT CHECK REPORT")
            .setFontSize(Constants.PDF_TITLE_FONT_SIZE)
            .setBold()
            .setTextAlignment(TextAlignment.CENTER)
            .setMarginBottom(SPACING_SMALL)

        document.add(title)
    }

    /**
     * Add generation date.
     */
    private fun addGeneratedDate(document: Document, date: Date) {
        val dateFormat = SimpleDateFormat(Constants.REPORT_DATE_DISPLAY_PATTERN, Locale.US)
        val formattedDate = dateFormat.format(date)

        val dateParagraph = Paragraph("Generated: $formattedDate")
            .setFontSize(Constants.PDF_SMALL_FONT_SIZE)
            .setTextAlignment(TextAlignment.CENTER)
            .setFontColor(ColorConstants.GRAY)
            .setMarginBottom(SPACING_LARGE)

        document.add(dateParagraph)
    }

    /**
     * Add verdict section with colored badge.
     */
    private fun addVerdict(document: Document, report: ReportEntity) {
        val verdictColor = getVerdictColor(report.verdict.displayName)

        val verdictLabel = Text("VERDICT: ")
            .setFontSize(Constants.PDF_HEADING_FONT_SIZE)
            .setBold()

        val verdictValue = Text(report.verdict.displayName.uppercase())
            .setFontSize(Constants.PDF_HEADING_FONT_SIZE)
            .setBold()
            .setFontColor(verdictColor)

        val verdictParagraph = Paragraph()
            .add(verdictLabel)
            .add(verdictValue)
            .setMarginBottom(SPACING_MEDIUM)

        document.add(verdictParagraph)
    }

    /**
     * Add summary section.
     */
    private fun addSummary(document: Document, report: ReportEntity) {
        addSectionHeading(document, "SUMMARY")

        val summary = Paragraph(report.summary)
            .setFontSize(Constants.PDF_BODY_FONT_SIZE)
            .setMultipliedLeading(Constants.PDF_LINE_SPACING)
            .setMarginBottom(SPACING_LARGE)

        document.add(summary)
    }

    /**
     * Add full report content.
     */
    private fun addFullReport(document: Document, report: ReportEntity) {
        addSectionHeading(document, "DETAILED ANALYSIS")

        // Split markdown into paragraphs and render
        val paragraphs = report.fullReportMarkdown.split("\n\n")
        for (para in paragraphs) {
            if (para.isBlank()) continue

            val trimmed = para.trim()

            // Handle markdown headings
            val paragraph = when {
                trimmed.startsWith("### ") -> {
                    Paragraph(trimmed.removePrefix("### "))
                        .setFontSize(Constants.PDF_BODY_FONT_SIZE)
                        .setBold()
                        .setMarginTop(SPACING_SMALL)
                        .setMarginBottom(SPACING_SMALL)
                }
                trimmed.startsWith("## ") -> {
                    Paragraph(trimmed.removePrefix("## "))
                        .setFontSize(Constants.PDF_HEADING_FONT_SIZE)
                        .setBold()
                        .setMarginTop(SPACING_MEDIUM)
                        .setMarginBottom(SPACING_SMALL)
                }
                trimmed.startsWith("# ") -> {
                    Paragraph(trimmed.removePrefix("# "))
                        .setFontSize(Constants.PDF_TITLE_FONT_SIZE)
                        .setBold()
                        .setMarginTop(SPACING_MEDIUM)
                        .setMarginBottom(SPACING_SMALL)
                }
                trimmed.startsWith("- ") || trimmed.startsWith("* ") -> {
                    // Bullet point - add indent
                    Paragraph("• ${trimmed.substring(2)}")
                        .setFontSize(Constants.PDF_BODY_FONT_SIZE)
                        .setMultipliedLeading(Constants.PDF_LINE_SPACING)
                        .setMarginLeft(BULLET_INDENT)
                }
                else -> {
                    // Regular paragraph - strip basic markdown formatting
                    val cleanText = trimmed
                        .replace(Regex("\\*\\*(.+?)\\*\\*"), "$1") // Bold
                        .replace(Regex("\\*(.+?)\\*"), "$1") // Italic
                        .replace(Regex("__(.+?)__"), "$1") // Bold
                        .replace(Regex("_(.+?)_"), "$1") // Italic

                    Paragraph(cleanText)
                        .setFontSize(Constants.PDF_BODY_FONT_SIZE)
                        .setMultipliedLeading(Constants.PDF_LINE_SPACING)
                        .setMarginBottom(SPACING_SMALL)
                }
            }

            document.add(paragraph)
        }

        // Add spacing after report content
        document.add(Paragraph().setMarginBottom(SPACING_MEDIUM))
    }

    /**
     * Add statistics section.
     */
    private fun addStatistics(document: Document, report: ReportEntity) {
        addSectionHeading(document, "STATISTICS")

        val stats = listOf(
            "Documents reviewed: ${report.totalDocumentsReviewed}",
            "Relevant documents: ${report.relevantDocumentsCount}",
            "Citations extracted: ${report.citationsCount}",
            "Model used: ${report.modelUsed}"
        )

        for (stat in stats) {
            val statParagraph = Paragraph(stat)
                .setFontSize(Constants.PDF_BODY_FONT_SIZE)

            document.add(statParagraph)
        }

        document.add(Paragraph().setMarginBottom(SPACING_LARGE))
    }

    /**
     * Add references section.
     */
    private fun addReferences(document: Document, documents: List<DocumentEntity>) {
        if (documents.isEmpty()) return

        addSectionHeading(document, "REFERENCES")

        documents.forEachIndexed { index, doc ->
            val refNumber = "[${index + 1}] "
            val citation = doc.citationString

            val refParagraph = Paragraph()
                .add(Text(refNumber).setBold())
                .add(Text(citation))
                .setFontSize(Constants.PDF_SMALL_FONT_SIZE)
                .setMultipliedLeading(Constants.PDF_LINE_SPACING)

            doc.pmid?.let {
                refParagraph.add(Text("\n      PMID: $it").setFontColor(ColorConstants.GRAY))
            }

            doc.doi?.let {
                refParagraph.add(Text("\n      DOI: $it").setFontColor(ColorConstants.GRAY))
            }

            refParagraph.setMarginBottom(SPACING_SMALL)
            document.add(refParagraph)
        }

        document.add(Paragraph().setMarginBottom(SPACING_MEDIUM))
    }

    /**
     * Add footnotes section if present.
     */
    private fun addFootnotes(document: Document, report: ReportEntity) {
        report.footnotes?.let { footnotes ->
            if (footnotes.isBlank()) return

            addSectionHeading(document, "NOTES")

            val footnotesParagraph = Paragraph(footnotes)
                .setFontSize(Constants.PDF_SMALL_FONT_SIZE)
                .setFontColor(ColorConstants.GRAY)
                .setMultipliedLeading(Constants.PDF_LINE_SPACING)
                .setMarginBottom(SPACING_LARGE)

            document.add(footnotesParagraph)
        }
    }

    /**
     * Add disclaimer at the end.
     */
    private fun addDisclaimer(document: Document) {
        val divider = Paragraph("─".repeat(DIVIDER_LENGTH))
            .setFontSize(Constants.PDF_SMALL_FONT_SIZE)
            .setTextAlignment(TextAlignment.CENTER)
            .setFontColor(ColorConstants.LIGHT_GRAY)

        document.add(divider)

        val disclaimer = Paragraph(
            "DISCLAIMER: This report is generated by AI and should not be used as a substitute " +
                "for professional medical advice. Always consult with qualified healthcare " +
                "professionals for medical decisions."
        )
            .setFontSize(Constants.PDF_SMALL_FONT_SIZE)
            .setFontColor(ColorConstants.GRAY)
            .setTextAlignment(TextAlignment.CENTER)
            .setItalic()

        document.add(disclaimer)
    }

    /**
     * Add a section heading with underline.
     */
    private fun addSectionHeading(document: Document, text: String) {
        val heading = Paragraph(text)
            .setFontSize(Constants.PDF_HEADING_FONT_SIZE)
            .setBold()
            .setMarginTop(SPACING_MEDIUM)
            .setMarginBottom(SPACING_SMALL)

        document.add(heading)

        // Add underline
        val underline = Paragraph("─".repeat(text.length + UNDERLINE_EXTRA_LENGTH))
            .setFontSize(Constants.PDF_SMALL_FONT_SIZE)
            .setFontColor(ColorConstants.LIGHT_GRAY)
            .setMarginBottom(SPACING_SMALL)

        document.add(underline)
    }

    /**
     * Get color for verdict display.
     */
    private fun getVerdictColor(verdict: String): DeviceRgb {
        return when (verdict.lowercase()) {
            "supported" -> DeviceRgb(76, 175, 80) // Green
            "likely supported" -> DeviceRgb(139, 195, 74) // Light green
            "unclear" -> DeviceRgb(255, 152, 0) // Orange
            "likely refuted" -> DeviceRgb(255, 152, 0) // Orange
            "refuted" -> DeviceRgb(244, 67, 54) // Red
            else -> DeviceRgb(158, 158, 158) // Gray
        }
    }

    companion object {
        /** Small spacing between elements. */
        private const val SPACING_SMALL = 8f

        /** Medium spacing between sections. */
        private const val SPACING_MEDIUM = 16f

        /** Large spacing for major sections. */
        private const val SPACING_LARGE = 24f

        /** Indent for bullet points. */
        private const val BULLET_INDENT = 20f

        /** Length of divider line. */
        private const val DIVIDER_LENGTH = 50

        /** Extra length for section heading underlines. */
        private const val UNDERLINE_EXTRA_LENGTH = 5
    }
}
