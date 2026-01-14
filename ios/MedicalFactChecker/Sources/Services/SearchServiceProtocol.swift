//
//  SearchServiceProtocol.swift
//  MedicalFactChecker
//
//  Protocol for unified search service interface.
//

import Foundation

// MARK: - Unified Search Result

/// Unified search result that works with any provider.
struct UnifiedSearchResult: Sendable {
    /// The articles returned.
    let articles: [ArticleMetadata]

    /// Total count of matching documents across all sources.
    let totalCount: Int

    /// Current offset in the result set (PubMed style).
    let offset: Int

    /// The provider(s) that produced this result.
    let provider: SearchProvider

    /// Cursor mark for next page (Europe PMC only).
    ///
    /// For PubMed, this will be nil and you should use offset for pagination.
    /// For Europe PMC, pass this to SearchOptions.cursorMark for the next page.
    let nextCursorMark: String?

    /// Initialize with default cursor mark.
    init(
        articles: [ArticleMetadata],
        totalCount: Int,
        offset: Int,
        provider: SearchProvider,
        nextCursorMark: String? = nil
    ) {
        self.articles = articles
        self.totalCount = totalCount
        self.offset = offset
        self.provider = provider
        self.nextCursorMark = nextCursorMark
    }

    /// Check if more results are available.
    var hasMore: Bool {
        // For Europe PMC, check cursor; for PubMed, check offset
        if provider == .europePMC {
            return nextCursorMark != nil && !articles.isEmpty
        }
        return offset + articles.count < totalCount
    }

    /// Next offset for PubMed pagination.
    var nextOffset: Int {
        offset + articles.count
    }
}

// MARK: - Search Service Factory

/// Factory for creating and executing searches across providers.
///
/// Handles routing to the appropriate search service based on
/// the configured provider, and merges results when using both.
enum SearchServiceFactory {
    /// Execute a search using the specified options.
    ///
    /// - Parameters:
    ///   - query: The search query string.
    ///   - options: Search configuration options.
    ///   - settings: App settings for service configuration.
    /// - Returns: Unified search result.
    /// - Throws: Error if the search fails.
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

    // MARK: - Provider-Specific Search

    /// Search PubMed for articles.
    ///
    /// - Parameters:
    ///   - query: The search query.
    ///   - options: Search options.
    ///   - settings: App settings.
    /// - Returns: Unified search result from PubMed.
    private static func searchPubMed(
        query: String,
        options: SearchOptions,
        settings: AppSettings
    ) async throws -> UnifiedSearchResult {
        let service = PubMedService.create(from: settings)
        let result = try await service.search(
            query: query,
            maxResults: options.maxResults,
            offset: options.offset
        )

        let articles = try await service.fetchArticles(
            pmids: result.pmids,
            batchNumber: 1,
            basePosition: options.offset
        )

        return UnifiedSearchResult(
            articles: articles,
            totalCount: result.totalCount,
            offset: options.offset,
            provider: .pubmed
        )
    }

    /// Search Europe PMC for articles.
    ///
    /// Translates the query from PubMed syntax if needed.
    /// Uses cursor-based pagination (not offset).
    ///
    /// - Parameters:
    ///   - query: The search query (may be in PubMed syntax).
    ///   - options: Search options (cursorMark used for pagination).
    /// - Returns: Unified search result from Europe PMC.
    private static func searchEuropePMC(
        query: String,
        options: SearchOptions
    ) async throws -> UnifiedSearchResult {
        let service = EuropePMCService.create()

        // Translate query from PubMed syntax to Europe PMC syntax
        let translatedQuery = QueryTranslator.pubmedToEuropePMC(query)

        // Log validation warnings (non-fatal)
        let validation = QueryValidator.validateEuropePMCQuery(translatedQuery)
        if !validation.warnings.isEmpty {
            print("[Search] Query translation warnings: \(validation.warnings)")
        }

        let result = try await service.search(
            query: translatedQuery,
            maxResults: options.maxResults,
            cursorMark: options.cursorMark,
            includePreprints: options.includePreprints
        )

        let articles = result.articles.map { $0.toArticleMetadata(batchNumber: 1) }

        // Only include nextCursorMark if there are actually more results
        // (Europe PMC returns the same cursor at the end of results)
        return UnifiedSearchResult(
            articles: articles,
            totalCount: result.totalCount,
            offset: 0,  // Offset not used for cursor-based pagination
            provider: .europePMC,
            nextCursorMark: result.hasMore ? result.nextCursorMark : nil
        )
    }

    /// Search both PubMed and Europe PMC, merging results.
    ///
    /// Note: Pagination in "both" mode is complex since PubMed uses offset
    /// and Europe PMC uses cursors. For initial searches (first page), this
    /// works normally. For pagination, callers should search providers
    /// individually with their respective pagination tokens.
    ///
    /// - Parameters:
    ///   - query: The search query.
    ///   - options: Search options.
    ///   - settings: App settings.
    /// - Returns: Merged, deduplicated search result.
    private static func searchBoth(
        query: String,
        options: SearchOptions,
        settings: AppSettings
    ) async throws -> UnifiedSearchResult {
        // Search both providers concurrently
        async let pubmedResult = searchPubMed(
            query: query,
            options: SearchOptions(
                provider: .pubmed,
                includePreprints: false,
                maxResults: options.maxResults,
                offset: options.offset,
                cursorMark: nil
            ),
            settings: settings
        )

        async let europePMCResult = searchEuropePMC(
            query: query,
            options: SearchOptions(
                provider: .europePMC,
                includePreprints: options.includePreprints,
                maxResults: options.maxResults,
                offset: 0,
                cursorMark: options.cursorMark
            )
        )

        // Await both results (handle individual failures gracefully)
        do {
            let (pubmed, europePMC) = try await (pubmedResult, europePMCResult)

            // Merge and deduplicate
            return SearchResultMerger.merge(
                pubmedResult: pubmed,
                europePMCResult: europePMC
            )
        } catch {
            // If both fail, rethrow. If one succeeds, return that.
            // Try PubMed alone
            if let pubmed = try? await pubmedResult {
                return pubmed
            }
            // Try Europe PMC alone
            if let europePMC = try? await europePMCResult {
                return europePMC
            }
            // Both failed
            throw error
        }
    }
}
