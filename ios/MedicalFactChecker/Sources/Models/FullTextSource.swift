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
import BioMedLit

/// Source from which full text was retrieved.
///
/// Represents the origin of a full-text article, used for display,
/// attribution, and debugging purposes.
/// Note: Renamed from FullTextSource to avoid collision with BioMedLit.FullTextSource.
enum AppFullTextSource: String, Codable, CaseIterable, Sendable {
    /// Europe PMC XML full text (highest quality, machine-readable).
    case europePMC = "europepmc"

    /// Europe PMC PDF (when XML is unavailable but free PDF exists).
    case europePMCPDF = "europepmc_pdf"

    /// Unpaywall open access PDF.
    case unpaywall = "unpaywall"

    /// DOI resolution to publisher website.
    case doi = "doi"

    /// Previously cached content.
    case cached = "cached"

    /// User-uploaded content (PDF, HTML, or Markdown).
    case uploaded = "uploaded"

    /// Human-readable display name for the source.
    var displayName: String {
        switch self {
        case .europePMC: return "Europe PMC"
        case .europePMCPDF: return "Europe PMC PDF"
        case .unpaywall: return "Unpaywall"
        case .doi: return "Publisher"
        case .cached: return "Cached"
        case .uploaded: return "Uploaded"
        }
    }

    /// SF Symbol icon name for the source.
    var iconName: String {
        switch self {
        case .europePMC: return "building.columns"
        case .europePMCPDF: return "doc.richtext"
        case .unpaywall: return "lock.open"
        case .doi: return "link"
        case .cached: return "arrow.down.circle"
        case .uploaded: return "square.and.arrow.up"
        }
    }

    /// Whether this source provides in-app viewable content.
    ///
    /// Europe PMC and Unpaywall provide content that can be displayed
    /// within the app. DOI sources require opening in an external browser.
    var canDisplayInApp: Bool {
        switch self {
        case .europePMC, .europePMCPDF, .unpaywall, .cached, .uploaded:
            return true
        case .doi:
            return false
        }
    }
}

/// The type of content retrieved from a full-text source.
/// Note: Renamed from FullTextContentType to avoid collision with BioMedLit types.
enum AppFullTextContentType: Equatable, Sendable {
    /// Markdown-formatted text (from Europe PMC XML conversion).
    /// Deprecated: prefer `.html` for better table and figure rendering.
    case markdown(String)

    /// HTML-formatted text (from Europe PMC XML conversion).
    /// Preferred over markdown for proper table and figure rendering.
    case html(content: String, markdown: String)

    /// URL to a downloadable PDF file.
    case pdfURL(URL)

    /// URL to open in an external web browser.
    case webURL(URL)

    /// Whether this content can be displayed in-app.
    var canDisplayInApp: Bool {
        switch self {
        case .markdown, .html, .pdfURL:
            return true
        case .webURL:
            return false
        }
    }

    /// Extract the HTML content if this is an HTML type.
    var htmlContent: String? {
        if case .html(let content, _) = self {
            return content
        }
        return nil
    }

    /// Extract the markdown content if this is a markdown or HTML type.
    var markdownContent: String? {
        switch self {
        case .markdown(let content):
            return content
        case .html(_, let markdown):
            return markdown
        default:
            return nil
        }
    }

    /// Extract the PDF URL if this is a PDF type.
    var pdfURL: URL? {
        if case .pdfURL(let url) = self {
            return url
        }
        return nil
    }

    /// Extract the web URL if this is a web URL type.
    var webURL: URL? {
        if case .webURL(let url) = self {
            return url
        }
        return nil
    }
}

/// Result of a full-text retrieval attempt.
///
/// Contains the retrieved content and metadata about its source.
/// Note: Renamed from FullTextResult to avoid collision with BioMedLit.FullTextResult.
struct AppFullTextResult: Equatable, Sendable {
    /// The type of content retrieved.
    let content: AppFullTextContentType

    /// The source from which the content was retrieved.
    let source: AppFullTextSource

    /// What the JATS parse lost, for the sources that involve one.
    ///
    /// Sits beside `content` rather than inside `.html` because it describes the
    /// *retrieval*, not the content type — and because burying it in the enum
    /// case would make every `case .html(let content, let markdown)` in the views
    /// change for no benefit. Clean for PDFs and publisher links, which are not
    /// parsed at all.
    let warnings: JATSParseWarnings

    /// Why this is not the best source that existed for the article, or `nil`
    /// when it is.
    ///
    /// Set when Europe PMC served machine-readable XML that the parser could not
    /// read, so the reader was handed a PDF or a publisher link instead. Without
    /// it the reader cannot tell that outcome from an article that was simply
    /// never deposited as full text (#183).
    let degradation: FullTextDegradation?

    /// Create a full-text result.
    ///
    /// Replaces the synthesised memberwise initialiser so `warnings` and
    /// `degradation` can default: only a parsed source can have warnings, only a
    /// fallback can be degraded, and every other source would otherwise have to
    /// pass an empty value at each call site.
    ///
    /// - Parameters:
    ///   - content: The retrieved content, in whichever form the source gave it.
    ///   - source: Where the content came from.
    ///   - warnings: What the JATS parse of this content lost. Empty — the
    ///     default — for PDFs, publisher links and any source that was not parsed.
    ///   - degradation: Why this is not the best source that existed. `nil` —
    ///     the default — when it is.
    init(
        content: AppFullTextContentType,
        source: AppFullTextSource,
        warnings: JATSParseWarnings = JATSParseWarnings(),
        degradation: FullTextDegradation? = nil
    ) {
        self.content = content
        self.source = source
        self.warnings = warnings
        self.degradation = degradation
    }

    /// Whether this result can be displayed within the app.
    var canDisplayInApp: Bool {
        content.canDisplayInApp
    }

    /// Get the HTML content if available.
    var htmlContent: String? {
        content.htmlContent
    }

    /// Get the markdown content if available.
    var markdownContent: String? {
        content.markdownContent
    }

    /// Get the PDF URL if available.
    var pdfURL: URL? {
        content.pdfURL
    }

    /// Get the web URL if this is a fallback result.
    var webURL: URL? {
        content.webURL
    }

    // MARK: - Factory Methods

    /// Create a markdown result from Europe PMC.
    ///
    /// - Parameter markdown: The markdown content.
    /// - Returns: A full-text result with Europe PMC source.
    /// - Note: Prefer `europePMC(html:markdown:)` for better table rendering.
    static func europePMC(markdown: String) -> AppFullTextResult {
        AppFullTextResult(content: .markdown(markdown), source: .europePMC)
    }

    /// Create an HTML result from Europe PMC.
    ///
    /// HTML provides better table and figure rendering than markdown.
    ///
    /// - Parameters:
    ///   - html: The HTML content (body only, no wrapper).
    ///   - markdown: The markdown content (fallback and for text search/export).
    /// - Returns: A full-text result with Europe PMC source.
    static func europePMC(html: String, markdown: String) -> AppFullTextResult {
        AppFullTextResult(content: .html(content: html, markdown: markdown), source: .europePMC)
    }

    /// Create a PDF URL result from Unpaywall.
    ///
    /// - Parameter url: The PDF download URL.
    /// - Returns: A full-text result with Unpaywall source.
    static func unpaywall(pdfURL url: URL) -> AppFullTextResult {
        AppFullTextResult(content: .pdfURL(url), source: .unpaywall)
    }

    /// Create a web URL result for DOI resolution.
    ///
    /// - Parameter url: The web URL to open.
    /// - Returns: A full-text result with DOI source.
    static func doi(webURL url: URL) -> AppFullTextResult {
        AppFullTextResult(content: .webURL(url), source: .doi)
    }

    /// Create a cached result.
    ///
    /// - Parameter content: The cached content type.
    /// - Returns: A full-text result with cached source.
    static func cached(content: AppFullTextContentType) -> AppFullTextResult {
        AppFullTextResult(content: content, source: .cached)
    }

    /// Create an uploaded result from user-provided content.
    ///
    /// - Parameter content: The uploaded content type (markdown, HTML, or PDF).
    /// - Returns: A full-text result with uploaded source.
    static func uploaded(content: AppFullTextContentType) -> AppFullTextResult {
        AppFullTextResult(content: content, source: .uploaded)
    }
}
