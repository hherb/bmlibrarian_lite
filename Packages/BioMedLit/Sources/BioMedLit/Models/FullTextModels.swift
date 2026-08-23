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

/// Sources for full-text article content.
public enum FullTextSource: String, Sendable, Codable, CaseIterable {
    /// Europe PMC XML converted to HTML/markdown.
    case europePMC = "europepmc"

    /// Europe PMC PDF (when XML is unavailable but free PDF exists).
    case europePMCPDF = "europepmc_pdf"

    /// Open access PDF via Unpaywall.
    case unpaywall = "unpaywall"

    /// DOI resolution (publisher website).
    case doi = "doi"

    /// Cached content (previously downloaded).
    case cached = "cached"

    /// Display name for the source.
    public var displayName: String {
        switch self {
        case .europePMC:
            return "Europe PMC"
        case .europePMCPDF:
            return "Europe PMC PDF"
        case .unpaywall:
            return "Unpaywall"
        case .doi:
            return "Publisher"
        case .cached:
            return "Cached"
        }
    }
}

/// Why a result is not the best source that existed for the article.
///
/// `fetchFullText` tries Europe PMC's machine-readable XML first and falls
/// through to a PDF or a publisher link when it cannot use it. That chain is
/// right — a reader who can be handed the publisher's PDF should get it rather
/// than an error — but without this the reader cannot tell the two outcomes
/// apart: "Europe PMC had no machine-readable text for this article" and
/// "Europe PMC had it and this parser choked on it" present identically (#183).
/// In a medical-literature tool the wrong conclusion is a reader attributing our
/// defect to the evidence base.
///
/// One case, no payload, on purpose. The parser's typed ``JATSParseError`` is
/// already logged at error level with its own message, which is where a bug
/// report gets its detail; persisting that error's `String` payloads would
/// repeat the mistake ``JATSParseWarnings`` exists to correct (#184). An
/// optional enum rather than a `Bool` because the field names a *reason* from a
/// set that happens to have one member today.
public enum FullTextDegradation: String, Sendable, Codable, Equatable {
    /// Europe PMC served machine-readable XML and this parser could not read it.
    case jatsParseFailed
}

/// What a full-text retrieval produced, and what it cost.
///
/// A struct rather than an enum of cases each carrying their own extras. The
/// content is the enum; the two facts *about the retrieval* sit beside it,
/// because that is what they describe. Burying them in the cases would make
/// every `case .europePMC(let html, let markdown, ...)` in a caller change
/// whenever a new fact is learned about a fetch — which is the reasoning the
/// app's own `AppFullTextResult` was already written down with, and which the
/// enum form of this type contradicted.
public struct FullTextResult: Sendable, Equatable {
    /// The content retrieved, in whichever form its source gave it.
    public let content: FullTextContent

    /// What the JATS parse of this content lost.
    ///
    /// Travels with the text because the audit that produces it only reached the
    /// logger, so the UI rendered a gutted article exactly as it rendered a
    /// complete one (#181). Clean for every source that involves no parse.
    public let warnings: JATSParseWarnings

    /// Why this is not the best source that existed, or `nil` when it is.
    public let degradation: FullTextDegradation?

    /// Create a retrieval result.
    ///
    /// - Parameters:
    ///   - content: The content retrieved.
    ///   - warnings: What the JATS parse lost. Clean — the default — for PDFs,
    ///     publisher links and anything else that was not parsed.
    ///   - degradation: Why this is not the best source that existed for the
    ///     article. `nil` — the default — when it is.
    public init(
        content: FullTextContent,
        warnings: JATSParseWarnings = JATSParseWarnings(),
        degradation: FullTextDegradation? = nil
    ) {
        // Two combinations the fallback chain never emits, and which the reader
        // would be shown as fact if it ever did. They were unspellable while
        // this type was an enum with `warnings` buried in the `.europePMC` case;
        // the struct that let the degradation travel also made them compile, so
        // they are asserted rather than left to the one producer's good conduct.
        //
        // Only a parsed source can have lost anything to a parse: warnings on a
        // PDF would put a truncation banner over a complete document, which is
        // the false alarm that teaches a reader to dismiss the banner on the
        // article where text really was discarded.
        assert(
            warnings.isClean || content.source == .europePMC,
            "parse warnings on \(content.source), which involves no parse"
        )
        // And a parse that succeeded is not a degradation: this flag means the
        // machine-readable source was lost, so it cannot travel with that
        // source's own content.
        assert(
            degradation == nil || content.source != .europePMC,
            "\(content.source) content marked as a degradation from itself"
        )
        self.content = content
        self.warnings = warnings
        self.degradation = degradation
    }

    /// The source of this full-text content.
    public var source: FullTextSource { content.source }

    /// HTML content if available (only for Europe PMC).
    public var html: String? { content.html }

    /// Markdown content if available (only for Europe PMC).
    public var markdown: String? { content.markdown }

    /// PDF URL if available (Europe PMC PDF, Unpaywall, or cached).
    public var pdfURL: URL? { content.pdfURL }

    /// Web URL if available (DOI resolution).
    public var webURL: URL? { content.webURL }
}

/// The content a full-text retrieval produced, by the source that gave it.
public enum FullTextContent: Sendable, Equatable {
    /// Europe PMC XML converted to HTML and markdown.
    case europePMC(html: String, markdown: String)

    /// Europe PMC PDF URL (when XML is unavailable but free PDF exists).
    case europePMCPDF(pdfURL: URL)

    /// Open access PDF URL from Unpaywall.
    case unpaywall(pdfURL: URL)

    /// DOI resolution URL (opens publisher website).
    case doi(webURL: URL)

    /// Cached PDF file path.
    case cached(filePath: String)

    /// The source this content came from.
    public var source: FullTextSource {
        switch self {
        case .europePMC:
            return .europePMC
        case .europePMCPDF:
            return .europePMCPDF
        case .unpaywall:
            return .unpaywall
        case .doi:
            return .doi
        case .cached:
            return .cached
        }
    }

    /// HTML content if available (only for Europe PMC).
    public var html: String? {
        if case .europePMC(let html, _) = self {
            return html
        }
        return nil
    }

    /// Markdown content if available (only for Europe PMC).
    public var markdown: String? {
        if case .europePMC(_, let markdown) = self {
            return markdown
        }
        return nil
    }

    /// PDF URL if available (Europe PMC PDF, Unpaywall, or cached).
    public var pdfURL: URL? {
        switch self {
        case .europePMCPDF(let url):
            return url
        case .unpaywall(let url):
            return url
        case .cached(let path):
            return URL(fileURLWithPath: path)
        default:
            return nil
        }
    }

    /// Web URL if available (DOI resolution).
    public var webURL: URL? {
        if case .doi(let url) = self {
            return url
        }
        return nil
    }
}

/// Errors that can occur during full-text retrieval.
public enum FullTextError: LocalizedError, RetryableError, Sendable {
    /// Document has no identifiers suitable for full-text lookup.
    case noIdentifiers

    /// Network error during retrieval.
    case networkError(String)

    /// No full text available from any source.
    case noFullTextAvailable

    /// PDF download failed.
    case pdfDownloadFailed(String)

    /// JATS parsing failed, with the parser's own error preserved.
    ///
    /// Keeps `.noContent`, `.alreadyParsed` and `.parsingFailed` distinguishable
    /// rather than flattening them to one string. There is deliberately no
    /// string-carrying twin: a second case that rendered identically only gave a
    /// future edit somewhere to put an error it had not classified, and silently
    /// stole the pattern matches aimed at this one.
    case jatsParseFailure(JATSParseError)

    /// PDF caching failed.
    case cachingFailed(String)

    /// Invalid response from API.
    case invalidResponse(String)

    /// Server error (5xx) - retryable.
    case serverError(statusCode: Int)

    public var errorDescription: String? {
        switch self {
        case .noIdentifiers:
            return "Document has no DOI or PMC ID for full-text lookup"
        case .networkError(let message):
            return "Network error: \(message)"
        case .noFullTextAvailable:
            return "No full text available from any source"
        case .pdfDownloadFailed(let reason):
            return "Failed to download PDF: \(reason)"
        case .jatsParseFailure(let error):
            return "Failed to parse XML: \(error.localizedDescription)"
        case .cachingFailed(let reason):
            return "Failed to cache PDF: \(reason)"
        case .invalidResponse(let reason):
            return "Invalid API response: \(reason)"
        case .serverError(let statusCode):
            return "Server temporarily unavailable (HTTP \(statusCode)). Retrying..."
        }
    }

    /// Whether this error is transient and should be retried.
    public var isRetryable: Bool {
        switch self {
        case .networkError, .serverError:
            return true
        case .noIdentifiers, .noFullTextAvailable, .pdfDownloadFailed,
             .jatsParseFailure, .cachingFailed, .invalidResponse:
            // A parse failure is deterministic: retrying spends the network
            // budget to reach the same result.
            return false
        }
    }
}
