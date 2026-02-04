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

/// Source from which full text was retrieved.
///
/// Represents the origin of a full-text article, used for display,
/// attribution, and debugging purposes.
enum FullTextSource: String, Codable, CaseIterable, Sendable {
    /// Europe PMC XML full text (highest quality, machine-readable).
    case europePMC = "europepmc"

    /// Unpaywall open access PDF.
    case unpaywall = "unpaywall"

    /// DOI resolution to publisher website.
    case doi = "doi"

    /// Previously cached content.
    case cached = "cached"

    /// Human-readable display name for the source.
    var displayName: String {
        switch self {
        case .europePMC: return "Europe PMC"
        case .unpaywall: return "Unpaywall"
        case .doi: return "Publisher"
        case .cached: return "Cached"
        }
    }

    /// SF Symbol icon name for the source.
    var iconName: String {
        switch self {
        case .europePMC: return "building.columns"
        case .unpaywall: return "lock.open"
        case .doi: return "link"
        case .cached: return "arrow.down.circle"
        }
    }

    /// Whether this source provides in-app viewable content.
    ///
    /// Europe PMC and Unpaywall provide content that can be displayed
    /// within the app. DOI sources require opening in an external browser.
    var canDisplayInApp: Bool {
        switch self {
        case .europePMC, .unpaywall, .cached:
            return true
        case .doi:
            return false
        }
    }
}

/// The type of content retrieved from a full-text source.
enum FullTextContentType: Equatable, Sendable {
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
struct FullTextResult: Equatable, Sendable {
    /// The type of content retrieved.
    let content: FullTextContentType

    /// The source from which the content was retrieved.
    let source: FullTextSource

    /// Whether this result can be displayed within the app.
    ///
    /// Markdown and PDF content can be displayed in-app, while
    /// web URLs require opening in an external browser.
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

    /// Create a markdown result from Europe PMC.
    ///
    /// - Parameter markdown: The markdown content.
    /// - Returns: A full-text result with Europe PMC source.
    /// - Note: Prefer `europePMC(html:markdown:)` for better table rendering.
    static func europePMC(markdown: String) -> FullTextResult {
        FullTextResult(content: .markdown(markdown), source: .europePMC)
    }

    /// Create an HTML result from Europe PMC.
    ///
    /// HTML provides better table and figure rendering than markdown.
    ///
    /// - Parameters:
    ///   - html: The HTML content (body only, no wrapper).
    ///   - markdown: The markdown content (fallback and for text search/export).
    /// - Returns: A full-text result with Europe PMC source.
    static func europePMC(html: String, markdown: String) -> FullTextResult {
        FullTextResult(content: .html(content: html, markdown: markdown), source: .europePMC)
    }

    /// Create a PDF URL result from Unpaywall.
    ///
    /// - Parameter url: The PDF download URL.
    /// - Returns: A full-text result with Unpaywall source.
    static func unpaywall(pdfURL url: URL) -> FullTextResult {
        FullTextResult(content: .pdfURL(url), source: .unpaywall)
    }

    /// Create a web URL result for DOI resolution.
    ///
    /// - Parameter url: The web URL to open.
    /// - Returns: A full-text result with DOI source.
    static func doi(webURL url: URL) -> FullTextResult {
        FullTextResult(content: .webURL(url), source: .doi)
    }

    /// Create a cached result.
    ///
    /// - Parameter content: The cached content type.
    /// - Returns: A full-text result with cached source.
    static func cached(content: FullTextContentType) -> FullTextResult {
        FullTextResult(content: content, source: .cached)
    }
}
