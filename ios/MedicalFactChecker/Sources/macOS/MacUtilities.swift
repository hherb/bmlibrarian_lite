#if os(macOS)
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

import Foundation
import os.log
import AppKit
import CoreGraphics

// MARK: - macOS Notification Names

extension Notification.Name {
    /// Posted when the user wants to view full text for a document.
    ///
    /// The notification's userInfo contains the document under the "document" key.
    /// Used by document detail sheets to navigate to the Full Text tab.
    static let showDocumentFullText = Notification.Name("showDocumentFullText")
}

// MARK: - macOS Logger

/// Unified logging for macOS app.
///
/// Provides structured logging categories for different subsystems.
enum AppLogger {
    /// Logger for workflow operations.
    static let workflow = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.bmlibrarian.MedicalFactChecker", category: "Workflow")

    /// Logger for UI operations.
    static let ui = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.bmlibrarian.MedicalFactChecker", category: "UI")

    /// Logger for network operations.
    static let network = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.bmlibrarian.MedicalFactChecker", category: "Network")

    /// Logger for data operations.
    static let data = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.bmlibrarian.MedicalFactChecker", category: "Data")

    /// Logger for full-text operations.
    static let fullText = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.bmlibrarian.MedicalFactChecker", category: "FullText")
}

// MARK: - Paper Size

/// Paper size options for PDF export.
enum PaperSize: String, CaseIterable, Identifiable {
    case a4 = "A4"
    case letter = "US Letter"

    var id: String { rawValue }

    /// Page dimensions in points (72 points per inch).
    var size: CGSize {
        switch self {
        case .a4:
            return CGSize(width: 595.28, height: 841.89)
        case .letter:
            return CGSize(width: 612, height: 792)
        }
    }
}

// MARK: - PDF Exporter Stub (macOS)

/// PDF exporter stub for macOS.
///
/// This is a placeholder implementation. Full PDF export functionality
/// needs to be implemented using AppKit/PDFKit APIs.
enum PDFExporter {
    /// Generate a PDF from an evidence report (stub implementation).
    ///
    /// - Parameters:
    ///   - report: The evidence report to export.
    ///   - paperSize: The paper size for the PDF.
    /// - Returns: PDF data, or nil if not implemented.
    static func generatePDFWithPagination(for report: EvidenceReport, paperSize: PaperSize) -> Data? {
        // TODO: Implement macOS PDF export using PDFKit
        // For now, return nil to indicate PDF export is not available
        print("[PDFExporter] macOS PDF export not yet implemented")
        return nil
    }
}

#endif // os(macOS)
