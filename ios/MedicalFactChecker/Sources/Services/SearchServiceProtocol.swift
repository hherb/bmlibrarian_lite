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

    /// Current offset in the result set.
    let offset: Int

    /// The provider(s) that produced this result.
    let provider: SearchProvider

    /// Check if more results are available.
    var hasMore: Bool {
        offset + articles.count < totalCount
    }

    /// Next offset for pagination.
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
    /// - Parameters:
    ///   - query: The search query.
    ///   - options: Search options.
    /// - Returns: Unified search result from Europe PMC.
    private static func searchEuropePMC(
        query: String,
        options: SearchOptions
    ) async throws -> UnifiedSearchResult {
        let service = EuropePMCService.create()

        // Use query as-is for now (QueryTranslator in Phase 4 will handle conversion)
        let result = try await service.search(
            query: query,
            maxResults: options.maxResults,
            offset: options.offset,
            includePreprints: options.includePreprints
        )

        let articles = result.articles.map { $0.toArticleMetadata(batchNumber: 1) }

        return UnifiedSearchResult(
            articles: articles,
            totalCount: result.totalCount,
            offset: options.offset,
            provider: .europePMC
        )
    }

    /// Search both PubMed and Europe PMC, merging results.
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
                offset: options.offset
            ),
            settings: settings
        )

        async let europePMCResult = searchEuropePMC(
            query: query,
            options: SearchOptions(
                provider: .europePMC,
                includePreprints: options.includePreprints,
                maxResults: options.maxResults,
                offset: options.offset
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
