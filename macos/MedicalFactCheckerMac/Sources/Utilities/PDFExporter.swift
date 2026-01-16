//
//  PDFExporter.swift
//  MedicalFactCheckerMac
//
//  PDF generation utility for evidence reports using text-based rendering on macOS.
//

import SwiftUI
import AppKit

/// Paper size options for PDF export.
enum PaperSize: String, CaseIterable, Identifiable {
    case a4 = "A4"
    case letter = "US Letter"

    var id: String { rawValue }

    /// Page dimensions in points (72 points per inch).
    var size: CGSize {
        switch self {
        case .a4:
            return CGSize(width: MacPDFLayout.a4Width, height: MacPDFLayout.a4Height)
        case .letter:
            return CGSize(width: MacPDFLayout.letterWidth, height: MacPDFLayout.letterHeight)
        }
    }

    /// Page margins.
    var margins: NSEdgeInsets {
        let margin = MacPDFLayout.pageMargin
        return NSEdgeInsets(top: margin, left: margin, bottom: margin, right: margin)
    }

    /// Printable content area.
    var contentRect: CGRect {
        CGRect(
            x: margins.left,
            y: margins.bottom,
            width: size.width - margins.left - margins.right,
            height: size.height - margins.top - margins.bottom
        )
    }
}

/// Utility for exporting evidence reports as text-based PDF documents.
///
/// Uses AppKit's text rendering for searchable, lightweight PDFs.
struct PDFExporter {

    /// Get the user's preferred paper size.
    static var preferredPaperSize: PaperSize {
        get {
            if let rawValue = UserDefaults.standard.string(forKey: MacUserDefaultsKeys.pdfPaperSize),
               let size = PaperSize(rawValue: rawValue) {
                return size
            }
            return .a4
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: MacUserDefaultsKeys.pdfPaperSize)
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

        let pdfData = NSMutableData()
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData) else { return nil }

        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }

        var currentY: CGFloat = pageSize.height - paperSize.margins.top
        var pageStarted = false

        func startNewPageIfNeeded() {
            if !pageStarted {
                context.beginPDFPage(nil)
                currentY = pageSize.height - paperSize.margins.top
                pageStarted = true
            }
        }

        func endCurrentPage() {
            if pageStarted {
                context.endPDFPage()
                pageStarted = false
            }
        }

        func ensureSpace(for height: CGFloat) {
            let minY = paperSize.margins.bottom
            if currentY - height < minY {
                endCurrentPage()
                startNewPageIfNeeded()
            }
        }

        // MARK: - Text Drawing Helpers

        func drawText(_ text: String, font: NSFont, color: NSColor = .black, maxWidth: CGFloat? = nil, wrapByCharacter: Bool = false) -> CGFloat {
            startNewPageIfNeeded()

            let paragraphStyle = NSMutableParagraphStyle()
            // Use character wrapping for code/monospace text, word wrapping otherwise
            paragraphStyle.lineBreakMode = wrapByCharacter ? .byCharWrapping : .byWordWrapping

            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraphStyle
            ]

            let width = maxWidth ?? contentRect.width
            let boundingRect = text.boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine],
                attributes: attributes,
                context: nil
            )

            let textHeight = ceil(boundingRect.height)
            ensureSpace(for: textHeight)

            let drawRect = CGRect(
                x: contentRect.minX,
                y: currentY - textHeight,
                width: width,
                height: textHeight
            )

            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            text.draw(with: drawRect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes, context: nil)
            NSGraphicsContext.restoreGraphicsState()

            currentY -= textHeight
            return textHeight
        }

        func drawCenteredText(_ text: String, font: NSFont, color: NSColor = .black) -> CGFloat {
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

            let textHeight = ceil(boundingRect.height)
            ensureSpace(for: textHeight)

            let drawRect = CGRect(
                x: contentRect.minX,
                y: currentY - textHeight,
                width: contentRect.width,
                height: textHeight
            )

            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            text.draw(with: drawRect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes, context: nil)
            NSGraphicsContext.restoreGraphicsState()

            currentY -= textHeight
            return textHeight
        }

        func addSpacing(_ height: CGFloat) {
            currentY -= height
        }

        func drawDivider() {
            startNewPageIfNeeded()
            ensureSpace(for: 10)

            context.setStrokeColor(NSColor.lightGray.cgColor)
            context.setLineWidth(0.5)
            context.move(to: CGPoint(x: contentRect.minX, y: currentY - 5))
            context.addLine(to: CGPoint(x: contentRect.maxX, y: currentY - 5))
            context.strokePath()

            currentY -= 10
        }

        func drawBadge(_ text: String, color: NSColor) {
            startNewPageIfNeeded()

            let font = NSFont.boldSystemFont(ofSize: 14)
            let padding: CGFloat = 12
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.white
            ]

            let textSize = text.size(withAttributes: attributes)
            let badgeWidth = textSize.width + padding * 2
            let badgeHeight = textSize.height + padding

            ensureSpace(for: badgeHeight + 10)

            let badgeX = contentRect.midX - badgeWidth / 2
            let badgeRect = CGRect(x: badgeX, y: currentY - badgeHeight, width: badgeWidth, height: badgeHeight)

            let path = NSBezierPath(roundedRect: badgeRect, xRadius: badgeHeight / 2, yRadius: badgeHeight / 2)
            context.setFillColor(color.cgColor)
            context.addPath(path.cgPath)
            context.fillPath()

            let textRect = CGRect(
                x: badgeX + padding,
                y: currentY - badgeHeight + padding / 2,
                width: textSize.width,
                height: textSize.height
            )

            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            text.draw(in: textRect, withAttributes: attributes)
            NSGraphicsContext.restoreGraphicsState()

            currentY -= badgeHeight + 10
        }

        // MARK: - Markdown Rendering Helpers

        /// Render markdown text with proper formatting for headers, bold, lists, etc.
        func drawMarkdown(_ markdown: String) {
            let normalizedText = normalizeLineBreaks(markdown)
            let blocks = parseMarkdownBlocks(normalizedText)

            for block in blocks {
                switch block {
                case .heading(let level, let text):
                    addSpacing(level == 1 ? 12 : 8)
                    let font: NSFont = switch level {
                    case 1: .boldSystemFont(ofSize: 16)
                    case 2: .boldSystemFont(ofSize: 14)
                    default: .boldSystemFont(ofSize: 12)
                    }
                    _ = drawText(text, font: font)
                    addSpacing(4)

                case .paragraph(let text):
                    let cleanedText = convertReferencesToPlainText(text)
                    _ = drawFormattedText(cleanedText, baseFont: .systemFont(ofSize: 11))
                    addSpacing(6)

                case .listItem(let text, let ordered, let number):
                    let cleanedText = convertReferencesToPlainText(text)
                    let bullet = ordered ? "\(number ?? 1)." : "•"
                    _ = drawFormattedText("\(bullet) \(cleanedText)", baseFont: .systemFont(ofSize: 11))
                    addSpacing(3)
                }
            }
        }

        /// Draw text with inline bold formatting preserved.
        func drawFormattedText(_ text: String, baseFont: NSFont) -> CGFloat {
            startNewPageIfNeeded()

            let attributedString = NSMutableAttributedString()
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineBreakMode = .byWordWrapping

            // Parse bold markers and create attributed string
            var remaining = text
            while !remaining.isEmpty {
                if let boldStart = remaining.range(of: "**") {
                    // Add text before bold marker
                    let beforeBold = String(remaining[..<boldStart.lowerBound])
                    if !beforeBold.isEmpty {
                        attributedString.append(NSAttributedString(
                            string: beforeBold,
                            attributes: [.font: baseFont, .paragraphStyle: paragraphStyle]
                        ))
                    }

                    // Find closing bold marker
                    let afterStart = remaining[boldStart.upperBound...]
                    if let boldEnd = afterStart.range(of: "**") {
                        let boldText = String(afterStart[..<boldEnd.lowerBound])
                        let boldFont = NSFont.boldSystemFont(ofSize: baseFont.pointSize)
                        attributedString.append(NSAttributedString(
                            string: boldText,
                            attributes: [.font: boldFont, .paragraphStyle: paragraphStyle]
                        ))
                        remaining = String(afterStart[boldEnd.upperBound...])
                    } else {
                        // No closing marker, treat as regular text
                        remaining = String(remaining[boldStart.upperBound...])
                    }
                } else {
                    // No more bold markers
                    attributedString.append(NSAttributedString(
                        string: remaining,
                        attributes: [.font: baseFont, .paragraphStyle: paragraphStyle]
                    ))
                    remaining = ""
                }
            }

            let boundingRect = attributedString.boundingRect(
                with: CGSize(width: contentRect.width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            )

            let textHeight = ceil(boundingRect.height)
            ensureSpace(for: textHeight)

            let drawRect = CGRect(
                x: contentRect.minX,
                y: currentY - textHeight,
                width: contentRect.width,
                height: textHeight
            )

            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            attributedString.draw(with: drawRect, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            NSGraphicsContext.restoreGraphicsState()

            currentY -= textHeight
            return textHeight
        }

        // MARK: - Render Report Content

        // Header
        startNewPageIfNeeded()
        _ = drawText("Medical Fact Check Report", font: .boldSystemFont(ofSize: 20))
        _ = drawText("Generated: \(report.generatedAt.formatted(date: .abbreviated, time: .shortened))",
                    font: .systemFont(ofSize: 10), color: .gray)
        addSpacing(15)

        // Verdict Badge
        let verdictColor: NSColor = switch report.verdict {
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
            _ = drawText("Claim", font: .boldSystemFont(ofSize: 14), color: .darkGray)
            addSpacing(4)
            let italicFont = NSFontManager.shared.convert(.systemFont(ofSize: 12), toHaveTrait: .italicFontMask)
            _ = drawText(session.claim, font: italicFont)
            addSpacing(8)

            if let query = session.pubmedQuery {
                _ = drawText("PubMed Query", font: .boldSystemFont(ofSize: 11), color: .gray)
                addSpacing(2)
                // Use a slightly smaller monospace font with character wrapping for long queries
                let monoFont = NSFont(name: "Menlo", size: 8) ?? .monospacedSystemFont(ofSize: 8, weight: .regular)
                _ = drawText(query, font: monoFont, color: .systemBlue, wrapByCharacter: true)
            }
            addSpacing(15)
        }

        drawDivider()

        // Summary
        _ = drawText("Summary", font: .boldSystemFont(ofSize: 16))
        addSpacing(6)
        _ = drawText(report.summary, font: .systemFont(ofSize: 11))
        addSpacing(15)

        drawDivider()

        // Detailed Report - now with proper markdown rendering
        _ = drawText("Detailed Analysis", font: .boldSystemFont(ofSize: 16))
        addSpacing(8)
        drawMarkdown(report.fullReport)
        addSpacing(15)

        drawDivider()

        // Statistics
        _ = drawText("Statistics", font: .boldSystemFont(ofSize: 16))
        addSpacing(6)
        _ = drawText("Documents Reviewed: \(report.documentsReviewed)", font: .systemFont(ofSize: 11))
        _ = drawText("Relevant Sources: \(report.uniqueSourceCount)", font: .systemFont(ofSize: 11))
        _ = drawText("Citations: \(report.citationCount)", font: .systemFont(ofSize: 11))
        addSpacing(15)

        // Reviewed Documents
        if let session = report.session {
            let relevantDocs = (session.documents ?? []).filter { ($0.relevanceScore ?? 0) >= 3 }
                .sorted { ($0.relevanceScore ?? 0) > ($1.relevanceScore ?? 0) }

            if !relevantDocs.isEmpty {
                drawDivider()
                _ = drawText("Reviewed Documents", font: .boldSystemFont(ofSize: 16))
                addSpacing(8)

                for doc in relevantDocs {
                    // Estimate height needed for this document entry
                    let estimatedHeight: CGFloat = 70
                    ensureSpace(for: estimatedHeight)

                    _ = drawText("• \(doc.title)", font: .boldSystemFont(ofSize: 10))
                    _ = drawText("  \(doc.formattedAuthors)", font: .systemFont(ofSize: 9), color: .darkGray)
                    if let journal = doc.journal, let year = doc.year {
                        _ = drawText("  \(journal), \(year) • PMID: \(doc.pmid)", font: .systemFont(ofSize: 9), color: .gray)
                    } else {
                        _ = drawText("  PMID: \(doc.pmid)", font: .systemFont(ofSize: 9), color: .gray)
                    }
                    if let score = doc.relevanceScore {
                        _ = drawText("  Relevance Score: \(score)/5", font: .systemFont(ofSize: 9), color: .systemBlue)
                    }
                    addSpacing(8)
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
        _ = drawText("Important Disclaimer", font: .boldSystemFont(ofSize: 11), color: .systemOrange)
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

        // Finish PDF
        endCurrentPage()
        context.closePDF()

        return pdfData as Data
    }

    // MARK: - Markdown Parsing Types

    /// Block types for markdown parsing.
    private enum MarkdownBlock {
        case heading(level: Int, text: String)
        case paragraph(text: String)
        case listItem(text: String, ordered: Bool, number: Int?)
    }

    // MARK: - Markdown Parsing

    /// Normalize line breaks in markdown text.
    private static func normalizeLineBreaks(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: "\\n", with: "\n")
        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Parse markdown text into structured blocks.
    private static func parseMarkdownBlocks(_ text: String) -> [MarkdownBlock] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var currentParagraph: [String] = []
        var listNumber = 0

        func flushParagraph() {
            if !currentParagraph.isEmpty {
                blocks.append(.paragraph(text: currentParagraph.joined(separator: " ")))
                currentParagraph = []
            }
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                listNumber = 0
                continue
            }

            // Headers
            if trimmed.hasPrefix("### ") {
                flushParagraph()
                blocks.append(.heading(level: 3, text: String(trimmed.dropFirst(4))))
                listNumber = 0
                continue
            }
            if trimmed.hasPrefix("## ") {
                flushParagraph()
                blocks.append(.heading(level: 2, text: String(trimmed.dropFirst(3))))
                listNumber = 0
                continue
            }
            if trimmed.hasPrefix("# ") {
                flushParagraph()
                blocks.append(.heading(level: 1, text: String(trimmed.dropFirst(2))))
                listNumber = 0
                continue
            }

            // Unordered list
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flushParagraph()
                blocks.append(.listItem(text: String(trimmed.dropFirst(2)), ordered: false, number: nil))
                listNumber = 0
                continue
            }

            // Ordered list
            if let match = parseOrderedListItem(trimmed) {
                flushParagraph()
                listNumber += 1
                blocks.append(.listItem(text: match, ordered: true, number: listNumber))
                continue
            }

            currentParagraph.append(trimmed)
        }

        flushParagraph()
        return blocks
    }

    /// Parse an ordered list item line.
    private static func parseOrderedListItem(_ line: String) -> String? {
        let pattern = "^\\d+\\.\\s+(.+)$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let textRange = Range(match.range(at: 1), in: line) else {
            return nil
        }
        return String(line[textRange])
    }

    /// Convert interactive references to plain text with PMIDs.
    ///
    /// Converts `[Author, Year](doc:pmid-12345)` to `Author, Year (PMID: 12345)`.
    private static func convertReferencesToPlainText(_ text: String) -> String {
        var result = text

        // Pattern for references with document ID: [Author, Year](doc:pmid-12345)
        let patternWithId = "\\[([^\\]]+)\\]\\(doc:pmid-(\\d+)\\)"
        if let regex = try? NSRegularExpression(pattern: patternWithId) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: "$1 (PMID: $2)"
            )
        }

        // Pattern for references with generic doc ID: [Author, Year](doc:id)
        let patternGenericId = "\\[([^\\]]+)\\]\\(doc:[^)]+\\)"
        if let regex = try? NSRegularExpression(pattern: patternGenericId) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: "$1"
            )
        }

        // Remove remaining markdown link syntax: [text](url) -> text
        let linkPattern = "\\[([^\\]]+)\\]\\([^)]+\\)"
        if let regex = try? NSRegularExpression(pattern: linkPattern) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: "$1"
            )
        }

        return result
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

// MARK: - NSBezierPath CGPath Extension

extension NSBezierPath {
    /// Convert NSBezierPath to CGPath for use with Core Graphics.
    var cgPath: CGPath {
        let path = CGMutablePath()
        var points = [CGPoint](repeating: .zero, count: 3)

        for i in 0..<elementCount {
            let type = element(at: i, associatedPoints: &points)
            switch type {
            case .moveTo:
                path.move(to: points[0])
            case .lineTo:
                path.addLine(to: points[0])
            case .curveTo:
                path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .closePath:
                path.closeSubpath()
            case .cubicCurveTo:
                path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .quadraticCurveTo:
                path.addQuadCurve(to: points[1], control: points[0])
            @unknown default:
                break
            }
        }

        return path
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
