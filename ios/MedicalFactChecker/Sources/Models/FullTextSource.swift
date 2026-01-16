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

/// Source from which full text was retrieved.
enum FullTextSource: String, Codable, Sendable {
    case europePMC = "europepmc"
    case unpaywall = "unpaywall"
    case doi = "doi"
    case cached = "cached"

    /// Human-readable display name.
    var displayName: String {
        switch self {
        case .europePMC: return "Europe PMC"
        case .unpaywall: return "Unpaywall"
        case .doi: return "Publisher"
        case .cached: return "Cached"
        }
    }

    /// Icon name for the source.
    var iconName: String {
        switch self {
        case .europePMC: return "building.columns"
        case .unpaywall: return "lock.open"
        case .doi: return "link"
        case .cached: return "arrow.down.circle"
        }
    }
}

/// Result of a full-text retrieval attempt.
struct FullTextResult: Sendable {
    /// Type of content retrieved from full-text sources.
    enum ContentType: Sendable {
        case markdown(String)    // Europe PMC XML converted to markdown
        case pdfURL(URL)         // URL to downloadable PDF
        case webURL(URL)         // Fallback URL to open in browser
    }

    let content: ContentType
    let source: FullTextSource

    /// Whether this result can be displayed in-app.
    var canDisplayInApp: Bool {
        switch content {
        case .markdown, .pdfURL:
            return true
        case .webURL:
            return false
        }
    }

    /// Get the markdown content if available.
    var markdownContent: String? {
        if case .markdown(let text) = content {
            return text
        }
        return nil
    }

    /// Get the PDF URL if available.
    var pdfURL: URL? {
        if case .pdfURL(let url) = content {
            return url
        }
        return nil
    }

    /// Get the web URL if this is a fallback result.
    var webURL: URL? {
        if case .webURL(let url) = content {
            return url
        }
        return nil
    }
}
