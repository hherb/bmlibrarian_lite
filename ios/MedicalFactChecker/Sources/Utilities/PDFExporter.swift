//
//  PDFExporter.swift
//  MedicalFactChecker
//
//  PDF generation utility for evidence reports using text-based rendering.
//

import SwiftUI
import UIKit

/// Paper size options for PDF export.
enum PaperSize: String, CaseIterable, Identifiable {
    case a4 = "A4"
    case letter = "US Letter"

    var id: String { rawValue }

    /// Page dimensions in points (72 points per inch).
    var size: CGSize {
        switch self {
        case .a4:
            // A4: 210 x 297 mm = 595.28 x 841.89 points
            return CGSize(width: 595.28, height: 841.89)
        case .letter:
            // US Letter: 8.5 x 11 inches = 612 x 792 points
            return CGSize(width: 612, height: 792)
        }
    }

    /// Page margins.
    var margins: UIEdgeInsets {
        UIEdgeInsets(top: 50, left: 50, bottom: 50, right: 50)
    }

    /// Printable content area.
    var contentRect: CGRect {
        CGRect(
            x: margins.left,
            y: margins.top,
            width: size.width - margins.left - margins.right,
            height: size.height - margins.top - margins.bottom
        )
    }
}

/// Utility for exporting evidence reports as text-based PDF documents.
///
/// Uses UIKit's text rendering for searchable, lightweight PDFs.
struct PDFExporter {

    /// UserDefaults key for storing paper size preference.
    private static let paperSizeKey = "pdf_paper_size"

    /// Get the user's preferred paper size.
    static var preferredPaperSize: PaperSize {
        get {
            if let rawValue = UserDefaults.standard.string(forKey: paperSizeKey),
               let size = PaperSize(rawValue: rawValue) {
                return size
            }
            return .a4
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: paperSizeKey)
        }
    }

    /// Generate a text-based PDF from an evidence report.
    ///
    /// - Parameters:
    ///   - report: The evidence report to export.
    ///   - paperSize: The paper size for the PDF.
    /// - Returns: PDF data, or nil if generation failed.
    static func generatePDFWithPagination(for report: EvidenceReport, paperSize: PaperSize) -> Data? {
        let pageSize = paperSize.size
        let contentRect = paperSize.contentRect
        let pdfRenderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize))

        let data = pdfRenderer.pdfData { context in
            var currentY: CGFloat = 0
            var pageStarted = false

            func startNewPageIfNeeded() {
                if !pageStarted {
                    context.beginPage()
                    currentY = paperSize.margins.top
                    pageStarted = true
                }
            }

            func ensureSpace(for height: CGFloat) {
                let maxY = pageSize.height - paperSize.margins.bottom
                if currentY + height > maxY {
                    pageStarted = false
                    startNewPageIfNeeded()
                }
            }

            // MARK: - Text Drawing Helpers

            func drawText(_ text: String, font: UIFont, color: UIColor = .black, maxWidth: CGFloat? = nil) -> CGFloat {
                startNewPageIfNeeded()

                let paragraphStyle = NSMutableParagraphStyle()
                paragraphStyle.lineBreakMode = .byWordWrapping

                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: color,
                    .paragraphStyle: paragraphStyle
                ]

                let width = maxWidth ?? contentRect.width
                let boundingRect = text.boundingRect(
                    with: CGSize(width: width, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: attributes,
                    context: nil
                )

                ensureSpace(for: boundingRect.height)

                let drawRect = CGRect(
                    x: contentRect.minX,
                    y: currentY,
                    width: width,
                    height: boundingRect.height
                )

                text.draw(with: drawRect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes, context: nil)

                currentY += boundingRect.height
                return boundingRect.height
            }

            func drawCenteredText(_ text: String, font: UIFont, color: UIColor = .black) -> CGFloat {
                startNewPageIfNeeded()

                let paragraphStyle = NSMutableParagraphStyle()
                paragraphStyle.alignment = .center

                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: color,
                    .paragraphStyle: paragraphStyle
                ]

                let boundingRect = text.boundingRect(
                    with: CGSize(width: contentRect.width, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: attributes,
                    context: nil
                )

                ensureSpace(for: boundingRect.height)

                let drawRect = CGRect(
                    x: contentRect.minX,
                    y: currentY,
                    width: contentRect.width,
                    height: boundingRect.height
                )

                text.draw(with: drawRect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes, context: nil)

                currentY += boundingRect.height
                return boundingRect.height
            }

            func addSpacing(_ height: CGFloat) {
                currentY += height
            }

            func drawDivider() {
                startNewPageIfNeeded()
                ensureSpace(for: 10)

                let path = UIBezierPath()
                path.move(to: CGPoint(x: contentRect.minX, y: currentY + 5))
                path.addLine(to: CGPoint(x: contentRect.maxX, y: currentY + 5))
                UIColor.lightGray.setStroke()
                path.lineWidth = 0.5
                path.stroke()

                currentY += 10
            }

            func drawBadge(_ text: String, color: UIColor) {
                startNewPageIfNeeded()

                let font = UIFont.boldSystemFont(ofSize: 14)
                let padding: CGFloat = 12
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: UIColor.white
                ]

                let textSize = text.size(withAttributes: attributes)
                let badgeWidth = textSize.width + padding * 2
                let badgeHeight = textSize.height + padding

                ensureSpace(for: badgeHeight + 10)

                let badgeX = contentRect.midX - badgeWidth / 2
                let badgeRect = CGRect(x: badgeX, y: currentY, width: badgeWidth, height: badgeHeight)

                let path = UIBezierPath(roundedRect: badgeRect, cornerRadius: badgeHeight / 2)
                color.setFill()
                path.fill()

                let textRect = CGRect(
                    x: badgeX + padding,
                    y: currentY + padding / 2,
                    width: textSize.width,
                    height: textSize.height
                )
                text.draw(in: textRect, withAttributes: attributes)

                currentY += badgeHeight + 10
            }

            // MARK: - Render Report Content

            // Header
            startNewPageIfNeeded()
            _ = drawText("Medical Fact Check Report", font: .boldSystemFont(ofSize: 18))
            _ = drawText("Generated: \(report.generatedAt.formatted(date: .abbreviated, time: .shortened))",
                        font: .systemFont(ofSize: 10), color: .gray)
            addSpacing(15)

            // Verdict Badge
            let verdictColor: UIColor = switch report.verdict {
            case .supported: .systemGreen
            case .partiallySupported: .systemOrange
            case .notSupported: .systemRed
            case .insufficientEvidence: .systemGray
            case .conflicting: .systemPurple
            }
            drawBadge(report.verdict.rawValue, color: verdictColor)
            addSpacing(10)

            // Claim
            if let session = report.session {
                _ = drawText("Claim", font: .boldSystemFont(ofSize: 12), color: .darkGray)
                addSpacing(4)
                _ = drawText(session.claim, font: .italicSystemFont(ofSize: 12))
                addSpacing(8)

                if let query = session.pubmedQuery {
                    _ = drawText("PubMed Query", font: .boldSystemFont(ofSize: 10), color: .gray)
                    addSpacing(2)
                    _ = drawText(query, font: UIFont(name: "Menlo", size: 9) ?? .systemFont(ofSize: 9), color: .systemBlue)
                }
                addSpacing(15)
            }

            drawDivider()

            // Summary
            _ = drawText("Summary", font: .boldSystemFont(ofSize: 14))
            addSpacing(6)
            _ = drawText(report.summary, font: .systemFont(ofSize: 11))
            addSpacing(15)

            drawDivider()

            // Detailed Report
            _ = drawText("Detailed Analysis", font: .boldSystemFont(ofSize: 14))
            addSpacing(8)

            // Render markdown as plain text
            let plainReport = convertMarkdownToPlainText(report.fullReport)
            _ = drawText(plainReport, font: .systemFont(ofSize: 11))
            addSpacing(15)

            drawDivider()

            // Statistics
            _ = drawText("Statistics", font: .boldSystemFont(ofSize: 14))
            addSpacing(6)
            _ = drawText("Documents Reviewed: \(report.documentsReviewed)", font: .systemFont(ofSize: 11))
            _ = drawText("Relevant Sources: \(report.uniqueSourceCount)", font: .systemFont(ofSize: 11))
            _ = drawText("Citations: \(report.citationCount)", font: .systemFont(ofSize: 11))
            addSpacing(15)

            // Reviewed Documents
            if let session = report.session {
                let relevantDocs = session.documents.filter { ($0.relevanceScore ?? 0) >= 3 }
                    .sorted { ($0.relevanceScore ?? 0) > ($1.relevanceScore ?? 0) }

                if !relevantDocs.isEmpty {
                    drawDivider()
                    _ = drawText("Reviewed Documents", font: .boldSystemFont(ofSize: 14))
                    addSpacing(8)

                    for doc in relevantDocs.prefix(10) {
                        ensureSpace(for: 50)
                        _ = drawText("• \(doc.title)", font: .boldSystemFont(ofSize: 10))
                        _ = drawText("  \(doc.formattedAuthors)", font: .systemFont(ofSize: 9), color: .darkGray)
                        if let journal = doc.journal, let year = doc.year {
                            _ = drawText("  \(journal), \(year) • PMID: \(doc.pmid)", font: .systemFont(ofSize: 9), color: .gray)
                        }
                        if let score = doc.relevanceScore {
                            _ = drawText("  Relevance Score: \(score)/5", font: .systemFont(ofSize: 9), color: .systemBlue)
                        }
                        addSpacing(6)
                    }

                    if relevantDocs.count > 10 {
                        _ = drawText("+ \(relevantDocs.count - 10) additional relevant documents", font: .italicSystemFont(ofSize: 9), color: .gray)
                    }
                    addSpacing(15)
                }
            }

            // Footer with disclaimer
            drawDivider()
            addSpacing(5)

            // Generation footnote
            _ = drawText(report.generationFootnote, font: .systemFont(ofSize: 9), color: .gray)
            addSpacing(10)

            // Disclaimer
            _ = drawText("⚠️ Important Disclaimer", font: .boldSystemFont(ofSize: 10), color: .systemOrange)
            addSpacing(4)
            _ = drawText(
                "This report is generated by AI and is intended for informational purposes only. " +
                "It should not be used for self-diagnosis or treatment. Always consult qualified " +
                "healthcare professionals for medical advice and discuss any findings from this " +
                "report with your doctor.",
                font: .systemFont(ofSize: 9),
                color: .darkGray
            )
            addSpacing(15)

            _ = drawText("Generated by Medical Fact Checker", font: .systemFont(ofSize: 8), color: .lightGray)
        }

        return data
    }

    /// Convert markdown text to plain text, preserving structure.
    private static func convertMarkdownToPlainText(_ markdown: String) -> String {
        var result = markdown

        // Convert escaped newlines
        result = result.replacingOccurrences(of: "\\n", with: "\n")

        // Remove reference links: [Author, Year](doc:pmid-12345) -> Author, Year (PMID: 12345)
        let refPattern = "\\[([^\\]]+)\\]\\(doc:pmid-(\\d+)\\)"
        if let regex = try? NSRegularExpression(pattern: refPattern) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "$1 (PMID: $2)"
            )
        }

        // Remove generic doc links: [text](doc:id) -> text
        let genericDocPattern = "\\[([^\\]]+)\\]\\(doc:[^)]+\\)"
        if let regex = try? NSRegularExpression(pattern: genericDocPattern) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "$1"
            )
        }

        // Remove other markdown links: [text](url) -> text
        let linkPattern = "\\[([^\\]]+)\\]\\([^)]+\\)"
        if let regex = try? NSRegularExpression(pattern: linkPattern) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "$1"
            )
        }

        // Convert headers to uppercase with newlines
        result = result.replacingOccurrences(of: "### ", with: "\n")
        result = result.replacingOccurrences(of: "## ", with: "\n")
        result = result.replacingOccurrences(of: "# ", with: "\n")

        // Remove bold/italic markers
        result = result.replacingOccurrences(of: "**", with: "")
        result = result.replacingOccurrences(of: "__", with: "")
        result = result.replacingOccurrences(of: "*", with: "")
        result = result.replacingOccurrences(of: "_", with: "")

        // Clean up multiple newlines
        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Create a temporary file URL for the PDF.
    ///
    /// - Parameter report: The report to generate a filename for.
    /// - Returns: A temporary file URL for saving the PDF.
    static func temporaryFileURL(for report: EvidenceReport) -> URL {
        let filename = "FactCheck_\(report.generatedAt.formatted(.dateTime.year().month().day().hour().minute())).pdf"
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: ":", with: "-")

        return FileManager.default.temporaryDirectory.appendingPathComponent(filename)
    }

    /// Save PDF data to a temporary file and return the URL.
    ///
    /// - Parameters:
    ///   - data: The PDF data to save.
    ///   - report: The report (used for filename generation).
    /// - Returns: The file URL where the PDF was saved, or nil if saving failed.
    static func savePDFToTemporaryFile(_ data: Data, for report: EvidenceReport) -> URL? {
        let url = temporaryFileURL(for: report)

        do {
            try data.write(to: url)
            return url
        } catch {
            print("[PDFExporter] Failed to save PDF: \(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: - PDF Document Wrapper

/// A wrapper for PDF data that can be used with ShareLink.
struct PDFDocument: Transferable {
    let data: Data
    let filename: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .pdf) { document in
            document.data
        }
        .suggestedFileName { document in
            document.filename
        }
    }
}
