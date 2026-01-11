//
//  PDFExporter.swift
//  MedicalFactChecker
//
//  PDF generation utility for evidence reports.
//

import SwiftUI
import UIKit
import PDFKit

/// Utility for exporting evidence reports as PDF documents.
///
/// Uses SwiftUI's ImageRenderer to convert the printable report view
/// to PDF format with proper page sizing.
@MainActor
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

    /// Generate a PDF from an evidence report.
    ///
    /// - Parameters:
    ///   - report: The evidence report to export.
    ///   - paperSize: The paper size for the PDF.
    /// - Returns: PDF data, or nil if generation failed.
    static func generatePDF(for report: EvidenceReport, paperSize: PaperSize) -> Data? {
        let view = PrintableReportView(report: report, paperSize: paperSize)

        // Create renderer with the paper size
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2.0  // High resolution for print quality

        // Generate PDF
        let pdfData = NSMutableData()

        renderer.render { size, context in
            // Create PDF with proper page size
            var box = CGRect(origin: .zero, size: paperSize.size)

            guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
                  let pdfContext = CGContext(consumer: consumer, mediaBox: &box, nil) else {
                return
            }

            // For now, render as single page (scrollable content)
            // TODO: Implement proper pagination for very long reports
            pdfContext.beginPDFPage(nil)
            context(pdfContext)
            pdfContext.endPDFPage()
            pdfContext.closePDF()
        }

        return pdfData.length > 0 ? pdfData as Data : nil
    }

    /// Generate a PDF using UIKit's graphics renderer for better pagination.
    ///
    /// - Parameters:
    ///   - report: The evidence report to export.
    ///   - paperSize: The paper size for the PDF.
    /// - Returns: PDF data, or nil if generation failed.
    static func generatePDFWithPagination(for report: EvidenceReport, paperSize: PaperSize) -> Data? {
        let view = PrintableReportView(report: report, paperSize: paperSize)

        // Render the view to get its size
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2.0

        guard let uiImage = renderer.uiImage else {
            return nil
        }

        let pageSize = paperSize.size
        let imageSize = uiImage.size
        let scale = pageSize.width / imageSize.width
        let scaledHeight = imageSize.height * scale

        // Calculate pages
        let pageCount = max(1, Int(ceil(scaledHeight / pageSize.height)))

        // Create PDF
        let pdfRenderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize))

        let data = pdfRenderer.pdfData { context in
            for pageIndex in 0..<pageCount {
                context.beginPage()

                let yOffset = CGFloat(pageIndex) * pageSize.height / scale
                let sourceRect = CGRect(
                    x: 0,
                    y: yOffset,
                    width: imageSize.width,
                    height: min(pageSize.height / scale, imageSize.height - yOffset)
                )

                // Crop and draw the portion of the image for this page
                if let cgImage = uiImage.cgImage?.cropping(to: sourceRect) {
                    let pageImage = UIImage(cgImage: cgImage)
                    let drawRect = CGRect(
                        x: 0,
                        y: 0,
                        width: pageSize.width,
                        height: sourceRect.height * scale
                    )
                    pageImage.draw(in: drawRect)
                }
            }
        }

        return data
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
