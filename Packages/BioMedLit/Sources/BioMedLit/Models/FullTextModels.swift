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

/// Result of a full-text retrieval operation.
public enum FullTextResult: Sendable {
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

    /// The source of this full-text content.
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

    /// XML parsing failed.
    case xmlParseError(String)

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
        case .xmlParseError(let reason):
            return "Failed to parse XML: \(reason)"
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
             .xmlParseError, .cachingFailed, .invalidResponse:
            return false
        }
    }
}
