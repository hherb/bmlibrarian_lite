//
//  SearchProvider.swift
//  MedicalFactChecker
//
//  Enum representing available literature search providers.
//

import Foundation
import SwiftUI

// MARK: - Constants

/// Constants for search providers.
enum SearchProviderConstants {
    /// Base URL for PubMed E-utilities API.
    static let pubmedBaseURL = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils"

    /// Base URL for Europe PMC REST API.
    static let europePMCBaseURL = "https://www.ebi.ac.uk/europepmc/webservices/rest"

    /// Default maximum results per search.
    static let defaultMaxResults = 20

    /// Default offset for pagination.
    static let defaultOffset = 0
}

// MARK: - Search Provider

/// Available search providers for literature searches.
enum SearchProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case pubmed = "pubmed"
    case europePMC = "europepmc"
    case both = "both"

    var id: String { rawValue }

    /// Human-readable display name.
    var displayName: String {
        switch self {
        case .pubmed: return "PubMed"
        case .europePMC: return "Europe PMC"
        case .both: return "Both (merged)"
        }
    }

    /// Detailed description for the provider.
    var description: String {
        switch self {
        case .pubmed:
            return "Search the US National Library of Medicine's PubMed database. Best for comprehensive medical literature coverage."
        case .europePMC:
            return "Search Europe PMC, which includes PubMed plus additional European sources and preprints."
        case .both:
            return "Search both PubMed and Europe PMC simultaneously. Results are deduplicated. Best for comprehensive coverage."
        }
    }

    /// Icon for the provider.
    var iconName: String {
        switch self {
        case .pubmed: return "building.columns"
        case .europePMC: return "globe.europe.africa"
        case .both: return "arrow.triangle.merge"
        }
    }

    /// Theme color for the provider.
    var themeColor: Color {
        switch self {
        case .pubmed: return .blue
        case .europePMC: return .green
        case .both: return .purple
        }
    }

    /// Whether this provider supports preprint filtering.
    var supportsPreprints: Bool {
        switch self {
        case .pubmed: return false
        case .europePMC, .both: return true
        }
    }

    /// Whether an API key is required (or recommended).
    var requiresAPIKey: Bool {
        // None of our providers strictly require an API key
        // PubMed recommends one for higher rate limits
        false
    }

    /// Base URL for the provider API.
    var baseURL: String {
        switch self {
        case .pubmed:
            return SearchProviderConstants.pubmedBaseURL
        case .europePMC:
            return SearchProviderConstants.europePMCBaseURL
        case .both:
            return ""  // Uses both base URLs
        }
    }
}

// MARK: - Search Options

/// Options for search configuration.
struct SearchOptions: Sendable {
    /// The search provider(s) to use.
    var provider: SearchProvider = .pubmed

    /// Whether to include preprints (Europe PMC only).
    var includePreprints: Bool = false

    /// Maximum results per provider.
    var maxResults: Int = SearchProviderConstants.defaultMaxResults

    /// Starting offset for pagination (PubMed style).
    var offset: Int = SearchProviderConstants.defaultOffset

    /// Cursor mark for Europe PMC pagination (nil for first page).
    ///
    /// Europe PMC uses cursor-based pagination. For the first page, pass nil
    /// (which will use "*"). For subsequent pages, pass the nextCursorMark
    /// from the previous response.
    var cursorMark: String?

    /// Create default options for a provider.
    ///
    /// - Parameter provider: The search provider.
    /// - Returns: Default search options for the provider.
    static func defaults(for provider: SearchProvider) -> SearchOptions {
        SearchOptions(
            provider: provider,
            includePreprints: false,
            maxResults: SearchProviderConstants.defaultMaxResults,
            offset: SearchProviderConstants.defaultOffset,
            cursorMark: nil
        )
    }
}
