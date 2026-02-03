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

/// Available search providers for literature searches.
///
/// Supports searching PubMed, Europe PMC, or both simultaneously with
/// automatic deduplication of results.
enum SearchProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    /// NCBI PubMed - the primary biomedical literature database.
    case pubmed = "pubmed"

    /// Europe PMC - includes preprints and full-text articles.
    case europePMC = "europepmc"

    /// Search both providers and merge results with deduplication.
    case both = "both"

    var id: String { rawValue }

    /// Human-readable display name for UI.
    var displayName: String {
        switch self {
        case .pubmed: return "PubMed"
        case .europePMC: return "Europe PMC"
        case .both: return "Both (merged)"
        }
    }

    /// Short description for settings UI.
    var description: String {
        switch self {
        case .pubmed:
            return "NCBI's biomedical literature database"
        case .europePMC:
            return "Europe PMC with preprints from 34 servers"
        case .both:
            return "Search both and merge results"
        }
    }

    /// SF Symbol icon name for the provider.
    var iconName: String {
        switch self {
        case .pubmed: return "building.columns"
        case .europePMC: return "globe.europe.africa"
        case .both: return "rectangle.on.rectangle"
        }
    }

    /// Whether this provider supports preprint filtering.
    var supportsPreprints: Bool {
        switch self {
        case .pubmed: return false
        case .europePMC, .both: return true
        }
    }

    /// Whether an API key is required (or recommended) for this provider.
    var requiresAPIKey: Bool {
        // None of these require API keys, though NCBI recommends one for higher rate limits
        return false
    }

    /// Base URL for the provider's REST API.
    var baseURL: String {
        switch self {
        case .pubmed:
            return "https://eutils.ncbi.nlm.nih.gov/entrez/eutils"
        case .europePMC:
            return "https://www.ebi.ac.uk/europepmc/webservices/rest"
        case .both:
            return ""  // Uses both base URLs
        }
    }
}

// MARK: - Search Options

/// Configuration options for a literature search.
///
/// Encapsulates all parameters needed to execute a search, including
/// provider selection, pagination, and filtering options.
struct SearchOptions: Sendable {
    /// The search provider(s) to use.
    var provider: SearchProvider = .pubmed

    /// Whether to include preprints (Europe PMC only).
    var includePreprints: Bool = false

    /// Maximum results to return per provider.
    var maxResults: Int = SearchOptionsDefaults.defaultMaxResults

    /// Starting offset for pagination (provider-agnostic).
    ///
    /// For offset-based APIs (PubMed), this is used directly.
    /// For cursor-based APIs (Europe PMC), this represents the logical position.
    var offset: Int = 0

    /// Cursor mark for Europe PMC pagination (nil for first page).
    ///
    /// Europe PMC uses cursor-based pagination. For the first page, pass nil
    /// (which will use "*"). For subsequent pages, pass the nextCursorMark
    /// from the previous response.
    var cursorMark: String?

    /// Default values for search options.
    enum SearchOptionsDefaults {
        /// Default maximum results per search.
        static let defaultMaxResults = 20
    }

    /// Create default options for a provider.
    ///
    /// - Parameter provider: The search provider.
    /// - Returns: Default search options for the provider.
    static func defaults(for provider: SearchProvider) -> SearchOptions {
        SearchOptions(
            provider: provider,
            includePreprints: false,
            maxResults: SearchOptionsDefaults.defaultMaxResults,
            offset: 0,
            cursorMark: nil
        )
    }
}
