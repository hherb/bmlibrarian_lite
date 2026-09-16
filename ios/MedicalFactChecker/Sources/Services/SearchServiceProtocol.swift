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

    /// Whether the source said there is no page after this one (#253).
    ///
    /// BioMedLit answers `nextOffset == nil` when the batch reached the last
    /// match or the next page would pass the last record PubMed lists. Judging
    /// only by counts missed the cap, and in a search of both providers it
    /// judged PubMed's next page against the two providers' combined total, so
    /// a user who paged to 9,999 was offered a page NCBI refuses.
    let isExhausted: Bool

    /// Number of results fetched so far.
    var fetchedCount: Int { offset + batchSize }

    /// Whether more results are available.
    var hasMore: Bool { !isExhausted && fetchedCount < totalCount }

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
    ///   - isExhausted: Whether the source said there is no next page.
    init(totalCount: Int, offset: Int, batchSize: Int, isExhausted: Bool = false) {
        self.totalCount = totalCount
        self.offset = offset
        self.batchSize = batchSize
        self.isExhausted = isExhausted
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

    /// How many records the search's pages have held, readable or not.
    ///
    /// Not the same as ``fetchedCount``, which counts the articles that could be
    /// shown: a record that could not be read still came off the cursor, and
    /// what the cursor owes is judged against this. `nil` for a session saved
    /// before the count was kept, whose cursor can outlive its last hit.
    let recordsReceived: Int?

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
    ///   - recordsReceived: Records the search's pages held, readable or not.
    ///   - currentCursor: Current cursor token.
    ///   - nextCursor: Next cursor token from API response.
    init(
        totalCount: Int,
        fetchedCount: Int,
        recordsReceived: Int? = nil,
        currentCursor: String?,
        nextCursor: String?
    ) {
        self.totalCount = totalCount
        self.fetchedCount = fetchedCount
        self.recordsReceived = recordsReceived
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
            recordsReceived: 0,
            currentCursor: nil,
            nextCursor: nil
        )
    }
}

// MARK: - Where a session's paging stands

/// Where a session's PubMed paging stands, for a page that continues it.
struct PubMedContinuation: Sendable, Equatable {
    /// The offset of the next page to list.
    let offset: Int

    /// The search's total, as PubMed last counted it; `nil` before a first page
    /// has counted it, when nothing is expected of the page.
    let totalResults: Int?

    /// Where a search's first PubMed page starts.
    static let firstPage = PubMedContinuation(offset: 0, totalResults: nil)
}

/// Where a session's Europe PMC paging stands, for a page that continues it.
struct EuropePMCContinuation: Sendable, Equatable {
    /// The cursor of the next page; `nil` for a search's first page.
    let cursor: String?

    /// The search's hit count, as Europe PMC last counted it; `nil` before a
    /// first page has counted it.
    let totalResults: Int?

    /// How many records the search's pages have held, readable or not; `nil` for
    /// a session saved before the count was kept, which stays unknown.
    let recordsReceived: Int?

    /// Where a search's first Europe PMC page starts.
    static let firstPage = EuropePMCContinuation(cursor: nil, totalResults: nil, recordsReceived: 0)
}

/// Where a session's paging stands with both providers.
///
/// A provider whose side is `nil` has no next page and is not asked for one:
/// its last search failed, or it ran out of results.
struct SearchContinuation: Sendable, Equatable {
    /// Where its PubMed paging stands, or `nil` when PubMed has no next page.
    let pubMed: PubMedContinuation?

    /// Where its Europe PMC paging stands, or `nil` when the cursor has ended.
    let europePMC: EuropePMCContinuation?
}

// MARK: - Unified Search Result

/// One page of a search, whatever the providers behind it.
///
/// Carries what the page retrieved, what it failed to retrieve (#256), and
/// where each provider's paging goes next. A provider's paging is `nil` when
/// this page must leave it as it was: it was not searched, or its first page
/// failed, so asking again asks for the same page.
struct UnifiedSearchResult: Sendable {
    /// Articles returned by the search.
    let articles: [UnifiedArticleMetadata]

    /// Total number of results available (may exceed articles.count).
    let totalCount: Int

    /// Provider that returned these results.
    let provider: SearchProvider

    /// What this page failed to retrieve, the same failure of one source once.
    let shortfalls: [RetrievalShortfall]

    /// Where PubMed's paging goes next, or `nil` to leave it as it was.
    let pubMedPagination: OffsetPaginationState?

    /// Where Europe PMC's paging goes next, or `nil` to leave it as it was.
    let europePMCPagination: CursorPaginationState?

    /// Whether more results are available from any provider this page searched.
    var hasMore: Bool {
        (pubMedPagination?.hasMore ?? false) || (europePMCPagination?.hasMore ?? false)
    }

    /// Whether PubMed has a page after this one.
    ///
    /// `false` when PubMed was not searched, which is what a session whose
    /// PubMed search failed reads: nothing was learned about its next page.
    var pubMedHasMore: Bool { pubMedPagination?.hasMore ?? false }

    /// Whether Europe PMC has a page after this one.
    var europePMCHasMore: Bool { europePMCPagination?.hasMore ?? false }

    /// How far through the result sets this page has reached.
    ///
    /// Across both providers for a search of both, which is what tells a
    /// refresh of a resumed session's paging when it has covered the documents
    /// the session already holds.
    var fetchedCount: Int {
        (pubMedPagination?.fetchedCount ?? 0) + (europePMCPagination?.fetchedCount ?? 0)
    }

    /// The offset PubMed's next page starts at.
    var nextOffset: Int? { pubMedPagination?.nextOffset }

    /// Next cursor mark for Europe PMC pagination.
    var nextCursorMark: String? { europePMCPagination?.nextCursor }

    /// Initialize a page of a search.
    ///
    /// - Parameters:
    ///   - articles: Articles returned.
    ///   - totalCount: Total available results.
    ///   - provider: The provider, or providers, the page was searched from.
    ///   - shortfalls: What the page failed to retrieve.
    ///   - pubMedPagination: Where PubMed's paging goes next.
    ///   - europePMCPagination: Where Europe PMC's paging goes next.
    init(
        articles: [UnifiedArticleMetadata],
        totalCount: Int,
        provider: SearchProvider,
        shortfalls: [RetrievalShortfall] = [],
        pubMedPagination: OffsetPaginationState? = nil,
        europePMCPagination: CursorPaginationState? = nil
    ) {
        self.articles = articles
        self.totalCount = totalCount
        self.provider = provider
        self.shortfalls = shortfalls
        self.pubMedPagination = pubMedPagination
        self.europePMCPagination = europePMCPagination
    }

    /// Create an empty result, for a provider that was not searched.
    ///
    /// - Parameter provider: The provider that returned no results.
    /// - Returns: Empty search result.
    static func empty(provider: SearchProvider) -> UnifiedSearchResult {
        UnifiedSearchResult(articles: [], totalCount: 0, provider: provider)
    }
}

// MARK: - Search Errors

/// Errors that can occur during search operations.
///
/// A source that failed is **not** one of these: it is a
/// ``BioMedLit/RetrievalShortfall`` the page carries, or — when failures left
/// the page with nothing — a ``BioMedLit/SearchFailedError``.
enum SearchError: LocalizedError, Equatable {
    /// No results from any provider.
    case noResults

    /// Invalid search configuration.
    case invalidConfiguration(String)

    var errorDescription: String? {
        switch self {
        case .noResults:
            return "No results found from any search provider"
        case .invalidConfiguration(let reason):
            return "Invalid search configuration: \(reason)"
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
/// - Reporting what a failed source cost the page (#256)
enum SearchServiceFactory {
    // MARK: - Main Search Interface

    /// Search one page from the providers the options name.
    ///
    /// A source that fails is recorded as a ``BioMedLit/RetrievalShortfall`` and
    /// the other source's articles still count: a failed source is not an empty
    /// one. A provider's paging moves only where this page learned something
    /// about it — a first page that failed leaves it where it was, so asking
    /// again asks for the same page.
    ///
    /// Whether the page is one to proceed on is the caller's to decide, after
    /// it knows which of the articles are new: a page that failures leave with
    /// no new document changes nothing, and is a ``BioMedLit/SearchFailedError``.
    ///
    /// - Parameters:
    ///   - query: The search query string (in PubMed or plain text syntax).
    ///   - options: Search configuration options, including where paging stands.
    ///   - settings: App settings for service configuration.
    ///
    /// - Returns: The page's articles, what it failed to retrieve, and where
    ///   each provider's paging goes next.
    /// - Throws: `CancellationError` when the caller cancelled.
    static func search(
        query: String,
        options: SearchOptions,
        settings: AppSettings
    ) async throws -> UnifiedSearchResult {
        switch options.provider {
        case .pubmed:
            return try await searchPubMed(query: query, options: options, settings: settings)

        case .europePMC:
            return try await searchEuropePMC(query: query, options: options)

        case .both:
            return try await searchBoth(query: query, options: options, settings: settings)
        }
    }

    // MARK: - PubMed Search

    /// Search one PubMed page.
    ///
    /// - Parameters:
    ///   - query: PubMed query string.
    ///   - options: Search options.
    ///   - settings: App settings for NCBI credentials.
    /// - Returns: The page, or a page holding only the shortfall its failure left.
    private static func searchPubMed(
        query: String,
        options: SearchOptions,
        settings: AppSettings
    ) async throws -> UnifiedSearchResult {
        singleProviderResult(
            try await pubMedPage(query: query, options: options, settings: settings), provider: .pubmed
        )
    }

    // MARK: - Europe PMC Search

    /// Search one Europe PMC page.
    ///
    /// The query should ideally be in native Europe PMC syntax (built by
    /// `EuropePMCQueryBuilder`). For backwards compatibility with resumed
    /// sessions, PubMed syntax queries will be auto-translated.
    ///
    /// - Parameters:
    ///   - query: Query string (ideally Europe PMC syntax, PubMed syntax auto-translated).
    ///   - options: Search options.
    /// - Returns: The page, or a page holding only the shortfall its failure left.
    private static func searchEuropePMC(
        query: String,
        options: SearchOptions
    ) async throws -> UnifiedSearchResult {
        singleProviderResult(try await europePMCPage(query: query, options: options), provider: .europePMC)
    }

    // MARK: - Combined Search

    /// Search both PubMed and Europe PMC concurrently and merge the two pages.
    ///
    /// Uses a task group for concurrent execution. Results are merged and
    /// deduplicated, with PubMed given priority for metadata quality.
    ///
    /// A provider that failed contributes its shortfall and no articles, and the
    /// other provider's page still counts (#256). Before this, a failed provider
    /// was reported with a `print` that goes nowhere in a release build, and the
    /// run looked like a complete search of both.
    ///
    /// - Parameters:
    ///   - query: Query string.
    ///   - options: Search options.
    ///   - settings: App settings.
    /// - Returns: Merged, deduplicated page.
    /// - Throws: `CancellationError` when the caller cancelled.
    private static func searchBoth(
        query: String,
        options: SearchOptions,
        settings: AppSettings
    ) async throws -> UnifiedSearchResult {
        async let pubMed = pubMedPage(query: query, options: options, settings: settings)
        async let europePMC = europePMCPage(query: query, options: options)

        let pages = try await (pubMed: pubMed, europePMC: europePMC)
        try Task.checkCancellation()

        return SearchResultMerger.merge(
            pubMedPage: pages.pubMed,
            europePMCPage: pages.europePMC,
            shortfalls: SearchFailureReporting.combined(pages.pubMed.shortfalls + pages.europePMC.shortfalls)
        )
    }

    // MARK: - One provider's page

    /// What one provider contributed to a page.
    struct ProviderPage: Sendable {
        /// The articles it delivered.
        let articles: [UnifiedArticleMetadata]

        /// What it failed to retrieve.
        let shortfalls: [RetrievalShortfall]

        /// Where PubMed's paging goes next, or `nil` to leave it as it was.
        let pubMedPagination: OffsetPaginationState?

        /// Where Europe PMC's paging goes next, or `nil` to leave it as it was.
        let europePMCPagination: CursorPaginationState?

        /// The search's total, as this provider last counted it.
        let totalCount: Int

        /// A provider this page did not ask.
        static let notSearched = ProviderPage(
            articles: [],
            shortfalls: [],
            pubMedPagination: nil,
            europePMCPagination: nil,
            totalCount: 0
        )
    }

    /// Search PubMed's page of the request, reporting a failure rather than raising it.
    ///
    /// - Parameters:
    ///   - query: The query string.
    ///   - options: Search options, including where paging stands.
    ///   - settings: App settings for NCBI credentials.
    /// - Returns: PubMed's articles, shortfalls and paging.
    /// - Throws: `CancellationError` when the caller cancelled, which is the
    ///   user's doing rather than the source's and records nothing as missing.
    private static func pubMedPage(
        query: String,
        options: SearchOptions,
        settings: AppSettings
    ) async throws -> ProviderPage {
        let pageSize = options.maxResults
        // A provider with no next page is not asked for one
        guard let continuation = options.pubMedContinuation else { return .notSearched }
        let offset = continuation.offset
        // How many PMIDs a continuing page should list; unknown before a first page counts them
        let expected = continuation.totalResults.map {
            SearchPaging.expectedEsearchListing(totalCount: $0, offset: offset, pageSize: pageSize)
        }
        if expected == 0 { return .notSearched }

        do {
            let result = try await BMLPubMedService.create(from: settings).search(
                query: query, maxResults: pageSize, offset: offset
            )
            let articles = BioMedLitAdapters.toUnifiedArticleMetadataArray(
                result,
                appProvider: .pubmed,
                batchNumber: options.batchNumber,
                basePosition: options.pubMedBasePosition
            )
            return ProviderPage(
                articles: articles,
                shortfalls: result.shortfalls,
                pubMedPagination: BioMedLitAdapters.pubMedPagination(
                    for: result, basePosition: offset, articleCount: articles.count
                ),
                europePMCPagination: nil,
                totalCount: result.totalCount
            )
        } catch let error as SourceRequestError {
            return failedPubMedPage(error, continuation: continuation, offset: offset, expected: expected)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return failedPubMedPage(
                SourceRequestError(source: .pubmed, failure: .requestFailed),
                continuation: continuation,
                offset: offset,
                expected: expected
            )
        }
    }

    /// Build the page a failed PubMed request leaves.
    ///
    /// A first page that failed leaves the paging where it was, so the source is
    /// not paged past records nobody has seen. A later page that failed is
    /// recorded as missing and paged past, so asking again asks for the page
    /// after it (the contract's **Android** section, which is this app's shape too).
    ///
    /// - Parameters:
    ///   - error: Why the request failed.
    ///   - continuation: Where paging stood; its total is `nil` for a first page,
    ///     which has counted nothing yet.
    ///   - offset: The offset the page was asked for at.
    ///   - expected: How many PMIDs the page should have listed, or `nil` for a first page.
    /// - Returns: The page, holding the shortfall and no article.
    private static func failedPubMedPage(
        _ error: SourceRequestError,
        continuation: PubMedContinuation,
        offset: Int,
        expected: Int?
    ) -> ProviderPage {
        guard let totalResults = continuation.totalResults, let expected, expected > 0,
              let missed = RetrievalShortfall.missingRecords(expected, from: .pubmed, failure: error.failure) else {
            return ProviderPage(
                articles: [],
                shortfalls: [error.shortfall],
                pubMedPagination: nil,
                europePMCPagination: nil,
                totalCount: 0
            )
        }
        return ProviderPage(
            articles: [],
            shortfalls: [missed],
            pubMedPagination: OffsetPaginationState(
                totalCount: totalResults,
                offset: offset,
                batchSize: expected,
                isExhausted: !SearchPaging.pubMedHasNextPage(
                    offset: offset + expected, totalCount: totalResults
                )
            ),
            europePMCPagination: nil,
            totalCount: totalResults
        )
    }

    /// Search Europe PMC's page of the request, reporting a failure rather than raising it.
    ///
    /// - Parameters:
    ///   - query: The query string, translated where a resumed session stored
    ///     PubMed syntax.
    ///   - options: Search options, including where paging stands.
    /// - Returns: Europe PMC's articles, shortfalls and paging.
    /// - Throws: `CancellationError` when the caller cancelled, which is the
    ///   user's doing rather than the source's and records nothing as missing.
    private static func europePMCPage(query: String, options: SearchOptions) async throws -> ProviderPage {
        let pageSize = options.maxResults
        // A cursor that has ended is not asked for another page
        guard let continuation = options.europePMCContinuation else { return .notSearched }
        let cursor = continuation.cursor ?? CursorPaginationState.initialCursor
        let recordsReceived = continuation.recordsReceived

        do {
            let result = try await BMLEuropePMCService.create().search(
                query: europePMCQuery(from: query),
                pageSize: pageSize,
                cursor: cursor,
                includePreprints: options.includePreprints,
                recordsReceived: recordsReceived
            )
            let articles = BioMedLitAdapters.toUnifiedArticleMetadataArray(
                result,
                appProvider: .europePMC,
                batchNumber: options.batchNumber,
                basePosition: options.europePMCBasePosition
            )
            return ProviderPage(
                articles: articles,
                shortfalls: result.shortfalls,
                pubMedPagination: nil,
                europePMCPagination: BioMedLitAdapters.europePMCPagination(
                    for: result,
                    basePosition: options.europePMCBasePosition,
                    articleCount: articles.count,
                    currentCursor: cursor,
                    recordsReceived: recordsReceived
                ),
                totalCount: result.totalCount
            )
        } catch let error as SourceRequestError {
            return failedEuropePMCPage(
                error, continuation: continuation, cursor: cursor,
                recordsReceived: recordsReceived, pageSize: pageSize
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return failedEuropePMCPage(
                SourceRequestError(source: .europePMC, failure: .requestFailed),
                continuation: continuation, cursor: cursor,
                recordsReceived: recordsReceived, pageSize: pageSize
            )
        }
    }

    /// Build the page a failed Europe PMC request leaves.
    ///
    /// A first page that failed leaves the paging where it was. A later page
    /// that failed ends the cursor, since a cursor cannot skip a page, and what
    /// the page would have held is recorded as missing.
    ///
    /// - Parameters:
    ///   - error: Why the request failed.
    ///   - continuation: Where paging stood; its cursor and total are `nil` for a
    ///     first page, which has counted nothing yet.
    ///   - cursor: The cursor the page was asked for with.
    ///   - recordsReceived: Records the search's earlier pages held, or `nil` when unknown.
    ///   - pageSize: The page size asked for.
    /// - Returns: The page, holding the shortfall and no article.
    private static func failedEuropePMCPage(
        _ error: SourceRequestError,
        continuation: EuropePMCContinuation,
        cursor: String,
        recordsReceived: Int?,
        pageSize: Int
    ) -> ProviderPage {
        guard let totalResults = continuation.totalResults, continuation.cursor != nil else {
            return ProviderPage(
                articles: [],
                shortfalls: [error.shortfall],
                pubMedPagination: nil,
                europePMCPagination: nil,
                totalCount: 0
            )
        }
        // The cursor promised more, so at least one record is missing; not knowing
        // how many came before claims the most the page could have held
        let missing = max(1, SearchPaging.expectedEuropePMCPage(
            hitCount: totalResults,
            recordsReceived: recordsReceived ?? 0,
            pageSize: pageSize
        ))
        return ProviderPage(
            articles: [],
            shortfalls: [RetrievalShortfall.missingRecords(
                missing, from: .europePMC, failure: error.failure
            )].compactMap { $0 },
            pubMedPagination: nil,
            europePMCPagination: CursorPaginationState(
                totalCount: totalResults,
                fetchedCount: recordsReceived ?? 0,
                recordsReceived: recordsReceived,
                currentCursor: cursor,
                nextCursor: nil
            ),
            totalCount: totalResults
        )
    }

    // MARK: - Helpers

    /// Build the result of a search of one provider.
    ///
    /// - Parameters:
    ///   - page: What the provider contributed.
    ///   - provider: Which provider it was.
    /// - Returns: The page as a result.
    private static func singleProviderResult(
        _ page: ProviderPage,
        provider: SearchProvider
    ) -> UnifiedSearchResult {
        UnifiedSearchResult(
            articles: page.articles,
            totalCount: page.totalCount,
            provider: provider,
            shortfalls: page.shortfalls,
            pubMedPagination: page.pubMedPagination,
            europePMCPagination: page.europePMCPagination
        )
    }

    /// The query as Europe PMC is asked it.
    ///
    /// - Parameter query: The stored query, which a resumed session may hold in
    ///   PubMed syntax.
    /// - Returns: The query in Europe PMC syntax.
    private static func europePMCQuery(from query: String) -> String {
        if QueryTranslator.isEuropePMCSyntax(query) {
            return query
        }
        guard QueryTranslator.isPubMedSyntax(query) else {
            // Plain text: Europe PMC takes it as it is
            return query
        }
        let translated = QueryTranslator.pubmedToEuropePMC(query)
        let validation = QueryValidator.validateEuropePMCQuery(translated)
        if !validation.warnings.isEmpty {
            BioMedLitLib.logger?.warning(
                "Translated a stored PubMed query for Europe PMC with "
                    + "\(validation.warnings.count) warning(s)",
                category: .search
            )
        }
        return translated
    }
}
