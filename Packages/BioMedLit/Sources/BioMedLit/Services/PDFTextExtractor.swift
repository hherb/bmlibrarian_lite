// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2025 Dr Horst Herb
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
import PDFKit

/// What extracting a PDF's text produced, and how much of the document it
/// covered.
///
/// Mirrors bmlib's `ConversionResult`, including the distinction its comments
/// insist on: a file that could not be opened is a *failure*, while a scan that
/// opened fine and holds no text is a *success with no text*. Collapsing the two
/// tells an operator to go looking for OCR when the real problem is a password.
public struct PDFExtractionResult: Sendable, Equatable {
    /// The recovered prose, empty when there was none.
    public let text: String

    /// Whether the document could be opened and read at all.
    public let success: Bool

    /// Pages the document holds, `0` when it could not be opened.
    public let pageCount: Int

    /// Pages that yielded any text.
    public let convertedPages: Int

    /// Human-readable notes about pages that gave nothing, one per page.
    public let warnings: [String]

    /// Why the document could not be read, or `nil` when it could.
    public let errorMessage: String?

    /// Characters recovered.
    public var charCount: Int { text.count }

    /// Whether every page of a readable document yielded text.
    ///
    /// All three clauses are load-bearing. A failed read is not complete; a
    /// document with an unconverted page is not complete; and an empty
    /// successful extraction — a scan — is not complete either, or a scanned
    /// article would report as a whole one.
    public var isComplete: Bool {
        success && pageCount == convertedPages && charCount > 0
    }

    /// The share of pages that yielded text, `0` for a document with no pages.
    public var completionRatio: Double {
        guard pageCount > 0 else { return 0 }
        return Double(convertedPages) / Double(pageCount)
    }

    /// Create a result.
    ///
    /// - Parameters:
    ///   - text: The recovered prose.
    ///   - success: Whether the document could be read.
    ///   - pageCount: Pages the document holds.
    ///   - convertedPages: Pages that yielded text.
    ///   - warnings: One note per page that gave nothing.
    ///   - errorMessage: Why the read failed, `nil` when it did not.
    public init(
        text: String,
        success: Bool,
        pageCount: Int,
        convertedPages: Int,
        warnings: [String],
        errorMessage: String? = nil
    ) {
        self.text = text
        self.success = success
        self.pageCount = pageCount
        self.convertedPages = convertedPages
        self.warnings = warnings
        self.errorMessage = errorMessage
    }
}

/// Recovers text from a PDF on disk.
///
/// A protocol with one production implementation, mirroring bmlib's
/// `PDFConverter` abstract base and its `PyMuPDFConverter`. The seam is what
/// lets ``FullTextService``'s PDF tiers be tested without a real PDF, which is
/// the same reason its `URLSession` and `EuropePMCService` are injectable.
public protocol PDFTextExtracting: Sendable {
    /// Extract text from the PDF at `fileURL`.
    ///
    /// Never throws: an unreadable file is a result that says so, because the
    /// caller's next move is the same either way and a thrown error at that
    /// point discards the page counts an operator needs.
    ///
    /// - Parameter fileURL: A file URL for the PDF to read.
    /// - Returns: What was recovered and how much of the document it covered.
    func extract(from fileURL: URL) -> PDFExtractionResult
}

/// The production extractor, backed by PDFKit.
///
/// `PDFPage.string` is the native equivalent of what bmlib does with PyMuPDF.
public struct PDFKitTextExtractor: PDFTextExtracting {
    /// Create an extractor.
    public init() {}

    public func extract(from fileURL: URL) -> PDFExtractionResult {
        guard let document = PDFDocument(url: fileURL) else {
            return PDFExtractionResult(
                text: "", success: false, pageCount: 0, convertedPages: 0, warnings: [],
                errorMessage: "the file could not be opened as a PDF"
            )
        }

        // Checked before reading rather than inferred from empty output. A
        // locked document hands back nil for every page, which is
        // indistinguishable from a scan unless the lock is asked about first.
        if document.isLocked || document.isEncrypted {
            return PDFExtractionResult(
                text: "", success: false, pageCount: document.pageCount,
                convertedPages: 0, warnings: [],
                errorMessage: "the PDF is password-protected"
            )
        }

        var pages: [String] = []
        var warnings: [String] = []
        var convertedPages = 0

        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else {
                warnings.append("page \(index + 1) could not be read")
                continue
            }
            let pageText = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if pageText.isEmpty {
                warnings.append("page \(index + 1) yielded no text")
                continue
            }
            pages.append(pageText)
            convertedPages += 1
        }

        return PDFExtractionResult(
            text: pages.joined(separator: "\n\n"),
            success: true,
            pageCount: document.pageCount,
            convertedPages: convertedPages,
            warnings: warnings
        )
    }
}
