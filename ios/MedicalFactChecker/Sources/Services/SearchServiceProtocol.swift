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

// MARK: - Pagination State Protocol

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
struct OffsetPaginationState: PaginationState, Sendable, Equatable {
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
struct CursorPaginationState: PaginationState, Sendable, Equatable {
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

// MARK: - Combined Pagination State

/// Pagination state for merged results from multiple providers.
///
/// Tracks both PubMed offset-based and Europe PMC cursor-based pagination
/// to enable proper "fetch more" functionality in combined search mode.
struct CombinedPaginationState: PaginationState, Sendable {
    /// PubMed pagination state.
    let pubmedPagination: any PaginationState

    /// Europe PMC pagination state.
    let europePMCPagination: any PaginationState

    /// Combined total count from both providers.
    var totalCount: Int {
        pubmedPagination.totalCount + europePMCPagination.totalCount
    }

    /// Combined fetched count from both providers.
    var fetchedCount: Int {
        pubmedPagination.fetchedCount + europePMCPagination.fetchedCount
    }

    /// Whether more results are available from either provider.
    var hasMore: Bool {
        pubmedPagination.hasMore || europePMCPagination.hasMore
    }

    /// Logical offset for display purposes (uses PubMed offset as primary).
    var logicalOffset: Int {
        pubmedPagination.logicalOffset
    }

    /// Get the next PubMed offset for pagination.
    var nextPubMedOffset: Int {
        if let offsetPagination = pubmedPagination as? OffsetPaginationState {
            return offsetPagination.nextOffset
        }
        return pubmedPagination.logicalOffset
    }

    /// Get the next Europe PMC cursor for pagination.
    var nextEuropePMCCursor: String? {
        if let cursorPagination = europePMCPagination as? CursorPaginationState {
            return cursorPagination.nextCursor
        }
        return nil
    }

    /// Initialize with pagination states from both providers.
    ///
    /// - Parameters:
    ///   - pubmedPagination: Pagination state from PubMed.
    ///   - europePMCPagination: Pagination state from Europe PMC.
    init(pubmedPagination: any PaginationState, europePMCPagination: any PaginationState) {
        self.pubmedPagination = pubmedPagination
        self.europePMCPagination = europePMCPagination
    }
}

// MARK: - Unified Search Result

/// Unified search result that works with any provider.
///
/// Encapsulates search results along with pagination state and metadata
/// about the search provider used.
struct UnifiedSearchResult: Sendable {
    /// Articles returned by the search.
    let articles: [ArticleMetadata]

    /// Total number of results available (may exceed articles.count).
    let totalCount: Int

    /// Pagination state for fetching more results.
    let pagination: any PaginationState

    /// Provider that returned these results.
    let provider: SearchProvider

    /// Whether more results are available.
    var hasMore: Bool { pagination.hasMore }

    /// Logical offset for the next fetch.
    ///
    /// For offset-based pagination (PubMed), returns `offset + batchSize`.
    /// For cursor-based pagination (Europe PMC), returns `fetchedCount`.
    /// For combined pagination, returns the PubMed offset.
    var nextOffset: Int {
        if let offsetPagination = pagination as? OffsetPaginationState {
            return offsetPagination.nextOffset
        }
        if let combinedPagination = pagination as? CombinedPaginationState {
            return combinedPagination.nextPubMedOffset
        }
        return pagination.logicalOffset
    }

    /// Next cursor mark for Europe PMC pagination (convenience accessor).
    ///
    /// Returns the next cursor if using cursor-based pagination, nil otherwise.
    var nextCursorMark: String? {
        if let cursorPagination = pagination as? CursorPaginationState {
            return cursorPagination.nextCursor
        }
        return nil
    }

    /// Initialize a unified search result.
    ///
    /// - Parameters:
    ///   - articles: Articles returned.
    ///   - totalCount: Total available results.
    ///   - pagination: Pagination state.
    ///   - provider: Source provider.
    init(
        articles: [ArticleMetadata],
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

// MARK: - Search Errors

/// Errors that can occur during search operations.
enum SearchError: LocalizedError, Equatable {
    /// One or both providers returned partial results.
    case partialFailure(successfulProvider: SearchProvider)

    /// No results from any provider.
    case noResults

    /// Invalid search configuration.
    case invalidConfiguration(String)

    /// Network error during search.
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .partialFailure(let provider):
            return "Partial results available from \(provider.displayName) only"
        case .noResults:
            return "No results found from any search provider"
        case .invalidConfiguration(let reason):
            return "Invalid search configuration: \(reason)"
        case .networkError(let message):
            return "Network error: \(message)"
        }
    }
}

// MARK: - Search Service Factory

/// Factory for creating and executing literature searches across providers.
///
/// This factory abstracts the differences between search providers, providing
/// a unified interface for the rest of the application. It handles:
/// - Provider selection and routing
/// - Query translation between syntaxes
/// - Result merging and deduplication for "both" provider mode
/// - Pagination state management
enum SearchServiceFactory {
    // MARK: - Main Search Interface

    /// Execute a search using the specified options.
    ///
    /// Routes the search to the appropriate provider(s) based on configuration.
    /// For "both" provider mode, searches are executed concurrently and results
    /// are merged with deduplication.
    ///
    /// - Parameters:
    ///   - query: The search query string (in PubMed or plain text syntax).
    ///   - options: Search configuration options.
    ///   - settings: App settings for service configuration.
    ///   - cursor: Optional cursor for Europe PMC pagination. Pass nil for initial search.
    /// - Returns: Unified search result with articles and pagination.
    /// - Throws: Provider-specific errors if search fails.
    static func search(
        query: String,
        options: SearchOptions,
        settings: AppSettings,
        cursor: String? = nil
    ) async throws -> UnifiedSearchResult {
        switch options.provider {
        case .pubmed:
            return try await searchPubMed(query: query, options: options, settings: settings)

        case .europePMC:
            return try await searchEuropePMC(query: query, options: options, cursor: cursor)

        case .both:
            return try await searchBoth(query: query, options: options, settings: settings, cursor: cursor)
        }
    }

    // MARK: - PubMed Search

    /// Search PubMed with the given query and options.
    ///
    /// - Parameters:
    ///   - query: PubMed query string.
    ///   - options: Search options.
    ///   - settings: App settings for NCBI credentials.
    /// - Returns: Unified search result.
    private static func searchPubMed(
        query: String,
        options: SearchOptions,
        settings: AppSettings
    ) async throws -> UnifiedSearchResult {
        // Use BioMedLit PubMedService
        let service = BMLPubMedService.create(from: settings)

        // Execute search
        let searchResult = try await service.search(
            query: query,
            maxResults: options.maxResults,
            offset: options.offset
        )

        // Convert BioMedLit articles to unified format using adapter
        let batchNumber = calculateBatchNumber(offset: options.offset, batchSize: options.maxResults)
        let unifiedResult = BioMedLitAdapters.toUnifiedSearchResult(
            searchResult,
            appProvider: .pubmed,
            batchNumber: batchNumber,
            basePosition: options.offset
        )

        return unifiedResult
    }

    // MARK: - Europe PMC Search

    /// Search Europe PMC with the given query and options.
    ///
    /// The query should ideally be in native Europe PMC syntax (built by
    /// `EuropePMCQueryBuilder`). For backwards compatibility with resumed
    /// sessions, PubMed syntax queries will be auto-translated.
    ///
    /// - Parameters:
    ///   - query: Query string (ideally Europe PMC syntax, PubMed syntax auto-translated).
    ///   - options: Search options.
    ///   - cursor: Optional cursor for pagination. Pass nil or "*" for initial search.
    /// - Returns: Unified search result.
    private static func searchEuropePMC(
        query: String,
        options: SearchOptions,
        cursor: String? = nil
    ) async throws -> UnifiedSearchResult {
        // Use BioMedLit EuropePMCService
        let service = BMLEuropePMCService.create()

        // Check if query is already in Europe PMC syntax
        let translatedQuery: String
        if QueryTranslator.isEuropePMCSyntax(query) {
            // Already in Europe PMC format (from EuropePMCQueryBuilder)
            translatedQuery = query
            print("[Search] Using native Europe PMC query")
        } else if QueryTranslator.isPubMedSyntax(query) {
            // Legacy: translate from PubMed syntax (for resumed sessions)
            translatedQuery = QueryTranslator.pubmedToEuropePMC(query)
            print("[Search] Translated PubMed query to Europe PMC syntax")

            // Log translation warnings
            let validation = QueryValidator.validateEuropePMCQuery(translatedQuery)
            if !validation.warnings.isEmpty {
                print("[Search] Query translation warnings: \(validation.warnings.joined(separator: ", "))")
            }
        } else {
            // Plain text query - use as-is
            translatedQuery = query
        }

        // Use provided cursor or "*" for initial request
        let searchCursor = cursor ?? CursorPaginationState.initialCursor
        let cursorDescription = searchCursor == CursorPaginationState.initialCursor ? "initial" : String(searchCursor.prefix(20))
        print("[Search] Europe PMC search with cursor: \(cursorDescription)")

        let result = try await service.search(
            query: translatedQuery,
            pageSize: options.maxResults,
            cursor: searchCursor,
            includePreprints: options.includePreprints
        )

        // Convert BioMedLit articles to unified format using adapter
        let batchNumber = calculateBatchNumber(offset: options.offset, batchSize: options.maxResults)
        let unifiedResult = BioMedLitAdapters.toUnifiedSearchResult(
            result,
            appProvider: .europePMC,
            batchNumber: batchNumber,
            basePosition: options.offset,
            currentCursor: searchCursor,
            nextCursor: result.nextCursor
        )

        return unifiedResult
    }

    // MARK: - Combined Search

    /// Search both PubMed and Europe PMC concurrently and merge results.
    ///
    /// Uses TaskGroup for efficient concurrent execution. Results are merged
    /// and deduplicated, with PubMed given priority for metadata quality.
    ///
    /// If one provider fails, returns results from the successful provider only.
    /// If both fail, throws the first error encountered.
    ///
    /// - Parameters:
    ///   - query: Query string.
    ///   - options: Search options.
    ///   - settings: App settings.
    ///   - cursor: Optional cursor for Europe PMC pagination.
    /// - Returns: Merged, deduplicated search result.
    /// - Throws: SearchError if both providers fail.
    private static func searchBoth(
        query: String,
        options: SearchOptions,
        settings: AppSettings,
        cursor: String? = nil
    ) async throws -> UnifiedSearchResult {
        // Create options for each provider
        let pubmedOptions = SearchOptions(
            provider: .pubmed,
            includePreprints: false,  // PubMed doesn't support preprints
            maxResults: options.maxResults,
            offset: options.offset
        )

        let europePMCOptions = SearchOptions(
            provider: .europePMC,
            includePreprints: options.includePreprints,
            maxResults: options.maxResults,
            offset: options.offset
        )

        // Use throwing TaskGroup with Result to handle partial failures gracefully
        return try await withThrowingTaskGroup(of: Result<UnifiedSearchResult, Error>.self) { group in
            group.addTask {
                do {
                    let result = try await searchPubMed(query: query, options: pubmedOptions, settings: settings)
                    return .success(result)
                } catch {
                    print("[Search] PubMed search failed: \(error.localizedDescription)")
                    return .failure(error)
                }
            }
            group.addTask {
                do {
                    let result = try await searchEuropePMC(query: query, options: europePMCOptions, cursor: cursor)
                    return .success(result)
                } catch {
                    print("[Search] Europe PMC search failed: \(error.localizedDescription)")
                    return .failure(error)
                }
            }

            var pubmedResult: UnifiedSearchResult?
            var europePMCResult: UnifiedSearchResult?
            var firstError: Error?

            // Collect results from both providers
            for try await result in group {
                switch result {
                case .success(let searchResult):
                    switch searchResult.provider {
                    case .pubmed:
                        pubmedResult = searchResult
                    case .europePMC:
                        europePMCResult = searchResult
                    case .both:
                        // Shouldn't happen, but handle gracefully
                        break
                    }
                case .failure(let error):
                    // Store first error in case both fail
                    if firstError == nil {
                        firstError = error
                    }
                }
            }

            // Handle partial failures gracefully
            if let pubmed = pubmedResult, let europePMC = europePMCResult {
                // Both succeeded - merge and deduplicate
                return SearchResultMerger.merge(
                    pubmedResult: pubmed,
                    europePMCResult: europePMC
                )
            } else if let pubmed = pubmedResult {
                // Only PubMed succeeded
                print("[Search] Returning PubMed results only (Europe PMC failed)")
                return pubmed
            } else if let europePMC = europePMCResult {
                // Only Europe PMC succeeded
                print("[Search] Returning Europe PMC results only (PubMed failed)")
                return europePMC
            } else {
                // Both failed - throw the first error
                throw firstError ?? SearchError.noResults
            }
        }
    }

    // MARK: - Helpers

    /// Calculate batch number from offset and batch size.
    ///
    /// - Parameters:
    ///   - offset: Current offset in results.
    ///   - batchSize: Size of each batch.
    /// - Returns: 1-indexed batch number.
    private static func calculateBatchNumber(offset: Int, batchSize: Int) -> Int {
        guard batchSize > 0 else { return 1 }
        return (offset / batchSize) + 1
    }
}
