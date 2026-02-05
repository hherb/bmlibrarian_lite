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

// MARK: - Unified Article Metadata

/// Unified article metadata that normalizes data from different search providers.
///
/// This struct provides a common interface for article data regardless of source,
/// enabling consistent handling throughout the app. Each provider's response
/// format is converted to this unified representation.
struct UnifiedArticleMetadata: Sendable, Identifiable {
    // MARK: - Identification

    /// Unique identifier combining source and ID (e.g., "pubmed-12345678").
    var id: String { "\(source.rawValue)-\(pmid.isEmpty ? (doi ?? title.hashValue.description) : pmid)" }

    /// PubMed ID (may be empty for preprints or non-PubMed sources).
    let pmid: String

    /// PubMed Central ID (e.g., "PMC1234567").
    let pmcId: String?

    /// Digital Object Identifier.
    let doi: String?

    // MARK: - Bibliographic Data

    /// Article title.
    let title: String

    /// Article abstract text.
    let abstract: String

    /// List of author names in display format.
    let authors: [String]

    /// Journal or source name.
    let journal: String

    /// Publication date as string (format varies by source).
    let publicationDate: String?

    /// Publication year as integer for sorting/filtering.
    let year: Int?

    // MARK: - Indexing & Classification

    /// MeSH terms (Medical Subject Headings) for the article.
    let meshTerms: [String]

    // MARK: - Source Tracking

    /// Which provider this article came from.
    let source: SearchProvider

    /// Whether this is a preprint (Europe PMC only).
    let isPreprint: Bool

    /// Whether full text is available in PubMed Central.
    ///
    /// True if the article has a PMC ID or the `inPMC` flag is set.
    /// Used to show availability badge before user attempts to fetch full text.
    let hasFullTextInPMC: Bool

    /// Batch number for pagination tracking.
    let batchNumber: Int

    /// Position within search results (0-indexed).
    let resultPosition: Int

    // MARK: - Initialization

    /// Initialize unified metadata with all fields.
    ///
    /// - Parameters:
    ///   - pmid: PubMed ID.
    ///   - pmcId: PubMed Central ID.
    ///   - doi: Digital Object Identifier.
    ///   - title: Article title.
    ///   - abstract: Abstract text.
    ///   - authors: List of author names.
    ///   - journal: Journal name.
    ///   - publicationDate: Publication date string.
    ///   - year: Publication year.
    ///   - meshTerms: MeSH indexing terms.
    ///   - source: Provider that returned this article.
    ///   - isPreprint: Whether this is a preprint.
    ///   - hasFullTextInPMC: Whether full text is available in PMC.
    ///   - batchNumber: Batch number for tracking.
    ///   - resultPosition: Position in search results.
    init(
        pmid: String = "",
        pmcId: String? = nil,
        doi: String? = nil,
        title: String,
        abstract: String,
        authors: [String] = [],
        journal: String = "",
        publicationDate: String? = nil,
        year: Int? = nil,
        meshTerms: [String] = [],
        source: SearchProvider,
        isPreprint: Bool = false,
        hasFullTextInPMC: Bool = false,
        batchNumber: Int = 1,
        resultPosition: Int = 0
    ) {
        self.pmid = pmid
        self.pmcId = pmcId
        self.doi = doi
        self.title = title
        self.abstract = abstract
        self.authors = authors
        self.journal = journal
        self.publicationDate = publicationDate
        self.year = year
        self.meshTerms = meshTerms
        self.source = source
        self.isPreprint = isPreprint
        self.hasFullTextInPMC = hasFullTextInPMC
        self.batchNumber = batchNumber
        self.resultPosition = resultPosition
    }
}

// MARK: - Pagination State

/// Protocol for abstracting pagination state across different API pagination models.
///
/// Different APIs use different pagination approaches:
/// - **Offset-based** (PubMed): Uses numeric offsets (retstart parameter)
/// - **Cursor-based** (Europe PMC): Uses opaque cursor tokens (cursorMark)
///
/// This protocol provides a unified interface for tracking pagination state
/// regardless of the underlying implementation.
protocol PaginationState: Sendable {
    /// Total number of results available.
    var totalCount: Int { get }

    /// Number of results fetched so far.
    var fetchedCount: Int { get }

    /// Whether more results are available.
    var hasMore: Bool { get }

    /// Logical offset for display purposes (0-indexed).
    var logicalOffset: Int { get }
}

// MARK: - Offset-Based Pagination

/// Pagination state for offset-based APIs like PubMed.
///
/// Uses simple numeric offsets to track position in the result set.
struct OffsetPaginationState: PaginationState, Sendable {
    /// Total number of results available.
    let totalCount: Int

    /// Current offset position.
    let offset: Int

    /// Number of results in the current batch.
    let batchSize: Int

    /// Number of results fetched so far.
    var fetchedCount: Int { offset + batchSize }

    /// Whether more results are available.
    var hasMore: Bool { fetchedCount < totalCount }

    /// Logical offset for display purposes.
    var logicalOffset: Int { offset }

    /// Calculate the next offset for pagination.
    var nextOffset: Int { offset + batchSize }

    /// Initialize with pagination parameters.
    ///
    /// - Parameters:
    ///   - totalCount: Total results available.
    ///   - offset: Current offset position.
    ///   - batchSize: Size of current batch.
    init(totalCount: Int, offset: Int, batchSize: Int) {
        self.totalCount = totalCount
        self.offset = offset
        self.batchSize = batchSize
    }
}

// MARK: - Cursor-Based Pagination

/// Pagination state for cursor-based APIs like Europe PMC.
///
/// Uses opaque cursor tokens for efficient deep pagination.
/// Cursors are more efficient than offsets for large result sets
/// and provide consistent results even when the underlying data changes.
struct CursorPaginationState: PaginationState, Sendable {
    /// Initial cursor value for the first page.
    static let initialCursor = "*"

    /// Total number of results available.
    let totalCount: Int

    /// Number of results fetched so far.
    let fetchedCount: Int

    /// Current cursor token (nil for first request).
    let currentCursor: String?

    /// Next cursor token returned by the API (nil if no more results).
    let nextCursor: String?

    /// Whether more results are available.
    var hasMore: Bool {
        nextCursor != nil && fetchedCount < totalCount
    }

    /// Logical offset for display purposes.
    var logicalOffset: Int { fetchedCount }

    /// Initialize with cursor pagination parameters.
    ///
    /// - Parameters:
    ///   - totalCount: Total results available.
    ///   - fetchedCount: Number of results fetched so far.
    ///   - currentCursor: Current cursor token.
    ///   - nextCursor: Next cursor token from API response.
    init(
        totalCount: Int,
        fetchedCount: Int,
        currentCursor: String?,
        nextCursor: String?
    ) {
        self.totalCount = totalCount
        self.fetchedCount = fetchedCount
        self.currentCursor = currentCursor
        self.nextCursor = nextCursor
    }

    /// Create initial state for a new search.
    ///
    /// - Returns: Initial pagination state with empty cursor.
    static func initial() -> CursorPaginationState {
        CursorPaginationState(
            totalCount: 0,
            fetchedCount: 0,
            currentCursor: nil,
            nextCursor: nil
        )
    }
}

// MARK: - Unified Search Result

/// Unified search result that works with any provider.
///
/// Encapsulates search results along with pagination state and metadata
/// about the search provider used.
struct UnifiedSearchResult: Sendable {
    /// Articles returned by the search.
    let articles: [UnifiedArticleMetadata]

    /// Total number of results available (may exceed articles.count).
    let totalCount: Int

    /// Pagination state for fetching more results.
    let pagination: any PaginationState

    /// Provider that returned these results.
    let provider: SearchProvider

    /// Whether more results are available.
    var hasMore: Bool { pagination.hasMore }

    /// Logical offset for the next fetch.
    var nextOffset: Int { pagination.logicalOffset }

    /// Initialize a unified search result.
    ///
    /// - Parameters:
    ///   - articles: Articles returned.
    ///   - totalCount: Total available results.
    ///   - pagination: Pagination state.
    ///   - provider: Source provider.
    init(
        articles: [UnifiedArticleMetadata],
        totalCount: Int,
        pagination: any PaginationState,
        provider: SearchProvider
    ) {
        self.articles = articles
        self.totalCount = totalCount
        self.pagination = pagination
        self.provider = provider
    }

    /// Create an empty result for error cases.
    ///
    /// - Parameter provider: The provider that returned no results.
    /// - Returns: Empty search result.
    static func empty(provider: SearchProvider) -> UnifiedSearchResult {
        UnifiedSearchResult(
            articles: [],
            totalCount: 0,
            pagination: OffsetPaginationState(totalCount: 0, offset: 0, batchSize: 0),
            provider: provider
        )
    }
}
