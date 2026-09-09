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
    /// Set when a better source existed and could not be used, and carrying
    /// which one and why: our parser choked on the XML, Europe PMC could not be
    /// reached, or a record from a newer build names a reason this one does not
    /// know. Without it the reader cannot tell any of those outcomes from an
    /// article that was simply never deposited as full text (#183, #186).
    ///
    /// See ``FullTextDegradation`` for the canonical list of what sets each
    /// case. This is the value every iOS and macOS view reads, via
    /// `BioMedLitAdapters.toAppFullTextResult` or `Document.cachedFullTextResult`.
    ///
    /// Note this type deliberately does *not* carry `FullTextResult`'s asserts.
    /// It is built from persisted values as well as from live ones, and
    /// ``FullTextDegradation/unspecified`` is a legitimate thing to read back —
    /// asserting against it here would crash every debug build that opened a
    /// record written by a newer build.
    let degradation: FullTextDegradation?

    /// What this result's text actually is.
    ///
    /// `nil`-free because a result always holds one of the four kinds, but note
    /// this type carries no asserts about it, for the reason `degradation`
    /// documents: it is built from persisted values as well as live ones, and a
    /// record written by a newer build must decode rather than crash a debug
    /// build.
    let contentKind: FullTextContentKind

    /// Prose recovered from a PDF, or `nil` when none was.
    ///
    /// This is what transparency analysis and report generation read for a
    /// PDF-sourced article. `content` stays the PDF, because extraction recovers
    /// the prose and loses the figures, tables and layout.
    let extractedText: String?

    /// Where the downloaded PDF now is on disk, or `nil` when none was cached.
    let localPDFPath: String?

    /// Create a full-text result.
    ///
    /// Replaces the synthesised memberwise initialiser so `warnings` and
    /// `degradation` can default: only a parsed source can have warnings, only a
    /// fallback can be degraded, and every other source would otherwise have to
    /// pass an empty value at each call site. `contentKind`, `extractedText` and
    /// `localPDFPath` default the same way, for the same reason.
    ///
    /// - Parameters:
    ///   - content: The retrieved content, in whichever form the source gave it.
    ///   - source: Where the content came from.
    ///   - warnings: What the JATS parse of this content lost. Empty — the
    ///     default — for PDFs, publisher links and any source that was not parsed.
    ///   - degradation: Why this is not the best source that existed. `nil` —
    ///     the default — when it is.
    ///   - contentKind: What the text actually is. ``FullTextContentKind/none``
    ///     — the default — for a result that holds no text.
    ///   - extractedText: Prose recovered from a PDF, or `nil` — the default —
    ///     when none was.
    ///   - localPDFPath: Where a downloaded PDF now is on disk, or `nil` — the
    ///     default — when none was cached.
    init(
        content: AppFullTextContentType,
        source: AppFullTextSource,
        warnings: JATSParseWarnings = JATSParseWarnings(),
        degradation: FullTextDegradation? = nil,
        contentKind: FullTextContentKind = .none,
        extractedText: String? = nil,
        localPDFPath: String? = nil
    ) {
        self.content = content
        self.source = source
        self.warnings = warnings
        self.degradation = degradation
        self.contentKind = contentKind
        self.extractedText = extractedText
        self.localPDFPath = localPDFPath
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

// MARK: - PDF Content Loading

/// Reads the bytes behind a `.pdfURL` full-text result, from disk or over HTTP.
///
/// The URL such a result carries is not always remote. Since extraction landed,
/// a PDF-sourced article reopened from the cache rebuilds as
/// `URL(fileURLWithPath:)` for the file the retrieval tier already downloaded —
/// `Document.cachedFullTextResult` does exactly that. The iOS viewer had only an
/// HTTP path: it called `URLSession.data(from:)` and then cast the response to
/// `HTTPURLResponse`. `URLSession` will happily open a `file://` URL, but it
/// answers with a plain `NSURLResponse`, so the cast failed and *every*
/// PDF-sourced article reopened from the cache showed "bad server response" over
/// an "Open in Browser" link pointing at a `file:///` path. macOS never had the
/// problem because `MacPDFView` takes a filesystem path rather than a URL.
///
/// Lives beside ``AppFullTextContentType/pdfURL(_:)`` because that is the case
/// it reads, and outside `FullTextViewer.swift` because that file is wrapped in
/// `#if os(iOS)` — this logic is platform-independent, and putting it here is
/// what lets the suite exercise it on the host that runs it.
enum PDFContentLoader {
    /// Why a PDF could not be shown, phrased for the reader.
    ///
    /// A local file and a remote fetch fail for different reasons and deserve
    /// different words: telling someone the *server* misbehaved when the file
    /// on their own device is missing sends them to retry the wrong thing.
    enum LoadError: LocalizedError, Equatable {
        /// The cached file is gone — evicted, or the record outlived it.
        case fileMissing

        /// The file is there but could not be read.
        case fileUnreadable(String)

        /// A remote fetch answered with something other than HTTP 200.
        case badServerResponse

        /// The bytes are not a PDF, whatever their origin.
        case notAPDF

        var errorDescription: String? {
            switch self {
            case .fileMissing:
                return "The cached PDF is no longer on this device. Fetch the full text again."
            case .fileUnreadable(let reason):
                return "The cached PDF could not be read: \(reason)"
            case .badServerResponse:
                return "The server did not return the PDF."
            case .notAPDF:
                return "That did not turn out to be a valid PDF file."
            }
        }
    }

    /// Load and validate the PDF `url` points at.
    ///
    /// - Parameters:
    ///   - url: A `file://` URL for a cached PDF, or a remote one.
    ///   - session: Injected so the remote branch has offline coverage.
    /// - Returns: The PDF's bytes, magic-byte checked.
    /// - Throws: ``LoadError``, or whatever the transport threw.
    static func loadData(
        from url: URL,
        session: URLSession = .shared
    ) async throws -> Data {
        let data = url.isFileURL
            ? try loadFromDisk(at: url)
            : try await loadOverHTTP(from: url, session: session)

        // Checked for both origins. A cached entry can be corrupt too — that is
        // the whole reason `FullTextService.cachedPDFPath` validates on the way
        // out — and rendering a truncated file as an article is worse than
        // saying so.
        let magic = Data(FullTextConstants.pdfMagicBytes)
        guard data.count > magic.count, data.prefix(magic.count) == magic else {
            throw LoadError.notAPDF
        }
        return data
    }

    /// Read a cached PDF off the filesystem.
    private static func loadFromDisk(at url: URL) throws -> Data {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LoadError.fileMissing
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw LoadError.fileUnreadable(error.localizedDescription)
        }
    }

    /// Fetch a PDF that really is remote — a live result whose tier returned a
    /// link without downloading it, which is what the extraction flag being off
    /// looks like.
    private static func loadOverHTTP(from url: URL, session: URLSession) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == FullTextConstants.httpStatusOK else {
            throw LoadError.badServerResponse
        }
        return data
    }
}
