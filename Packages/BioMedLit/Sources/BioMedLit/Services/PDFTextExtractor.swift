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

/// How much of a PDF an extraction actually recovered text from.
///
/// The two counts travel as one value because they are one fact. Carried
/// separately they can be written independently and disagree, and a coverage
/// figure that disagrees with the text it describes is worse than none: it
/// tells the reader a precise, wrong thing.
///
/// Split out of ``PDFExtractionResult`` so it can outlive it. The result is a
/// package-internal detail of one call; this is what ``FullTextResult`` carries
/// to the app, and the app persists, so a reader who reopens a partially
/// extracted article is still told it was partial.
public struct PDFExtractionCoverage: Sendable, Equatable, Codable {
    /// Pages that yielded text.
    public let convertedPages: Int

    /// Pages the document holds.
    public let pageCount: Int

    /// Whether every page yielded text.
    ///
    /// A zero-page document is not complete. It is a document we recovered
    /// nothing from, and answering `true` for it would report the emptiest
    /// possible extraction as the most successful kind.
    public var isComplete: Bool {
        pageCount > 0 && convertedPages == pageCount
    }

    /// The share of pages that yielded text, `0` for a document with no pages.
    public var ratio: Double {
        guard pageCount > 0 else { return 0 }
        return Double(convertedPages) / Double(pageCount)
    }

    /// Create a coverage figure.
    ///
    /// - Parameters:
    ///   - convertedPages: Pages that yielded text.
    ///   - pageCount: Pages the document holds.
    public init(convertedPages: Int, pageCount: Int) {
        self.convertedPages = convertedPages
        self.pageCount = pageCount
    }
}

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

    /// How much of the document yielded text.
    ///
    /// The pair the app persists and shows the reader. ``isComplete`` and
    /// ``completionRatio`` below are this value's own answers, forwarded so the
    /// package's callers need not reach through.
    public var coverage: PDFExtractionCoverage {
        PDFExtractionCoverage(convertedPages: convertedPages, pageCount: pageCount)
    }

    /// Whether every page of a readable document yielded text.
    ///
    /// All three clauses are load-bearing, though not for the reasons a reader
    /// of bmlib's `is_complete` would expect, because the page loop below
    /// counts differently from bmlib's on purpose — see ``extract(from:)``.
    /// Here: a failed read is not complete; a document with a page that gave
    /// nothing is not complete, which is the clause that catches a scan; and
    /// `charCount > 0` catches a document with **no pages at all**, for which
    /// the second clause is vacuously true.
    ///
    /// It does *not* catch a page that yielded a single stray character — a
    /// watermark or a download stamp over a scanned page counts that page as
    /// converted. bmlib has the same hole. Closing it needs a minimum-prose
    /// floor agreed across both, and is tracked rather than fixed one-sidedly.
    public var isComplete: Bool {
        success && pageCount == convertedPages && charCount > 0
    }

    /// The share of pages that yielded text, `0` for a document with no pages.
    public var completionRatio: Double {
        coverage.ratio
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
    /// Implementations should stop early when the calling task is cancelled.
    /// They must not report that as a failure — a cancelled read is not an
    /// unreadable file — so the partial value they return is meaningless and
    /// the caller is expected to discard it by checking cancellation itself.
    /// ``FullTextService`` does exactly that.
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
        //
        // `isLocked` alone, deliberately: it is PDFKit's `needs_pass`, and
        // bmlib names widening this to `is_encrypted` as the wrong rule
        // (DECISIONS.md, "fulltext — the PDF converter"). An *owner* password
        // restricts permissions — printing, copying — without blocking reads,
        // so such a file reports `isEncrypted == true`, `isLocked == false` and
        // extracts perfectly. `Fixtures/PDF/ownerpassword.pdf` is exactly that
        // file, and it is why this guard is not a check that cannot fail.
        if document.isLocked {
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
            // A long document must not pin the `FullTextService` actor after
            // the reader has walked away. The partial value this returns is
            // discarded: `downloadAndExtract` checks cancellation immediately
            // after calling us and throws, so nothing downstream ever sees a
            // truncated-by-cancellation extraction reported as a real one.
            if Task.isCancelled { break }

            guard let page = document.page(at: index) else {
                warnings.append("page \(index + 1) could not be read")
                continue
            }
            let pageText = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if pageText.isEmpty {
                // Counted as *not* converted, deliberately diverging from
                // bmlib's `PyMuPDFConverter`, which increments
                // `converted_pages` on this branch too. Under bmlib's rule a
                // two-page article whose second page is a scan reports
                // `2/2` — complete — and the reader is told nothing. The
                // divergence is what makes `isComplete`'s second clause catch
                // a partial extraction at all, and it is why `completionRatio`
                // is a share of pages that gave prose rather than of pages
                // visited. Tracked for bmlib so the two converge on this rule.
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
