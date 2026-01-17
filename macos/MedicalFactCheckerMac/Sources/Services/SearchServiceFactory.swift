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
        let service = BioMedLit.PubMedService.create(from: settings)

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
        let service = BioMedLit.EuropePMCService.create()

        // Check if query is already in Europe PMC syntax
        let translatedQuery: String
        if QueryTranslator.isEuropePMCSyntax(query) {
            // Already in Europe PMC format (from EuropePMCQueryBuilder)
            translatedQuery = query
            AppLogger.search.debug("Using native Europe PMC query")
        } else if QueryTranslator.isPubMedSyntax(query) {
            // Legacy: translate from PubMed syntax (for resumed sessions)
            translatedQuery = QueryTranslator.pubmedToEuropePMC(query)
            AppLogger.search.debug("Translated PubMed query to Europe PMC syntax")

            // Log translation warnings
            let validation = QueryValidator.validateEuropePMCQuery(translatedQuery)
            if !validation.warnings.isEmpty {
                AppLogger.search.debug(
                    "Query translation warnings: \(validation.warnings.joined(separator: ", "))"
                )
            }
        } else {
            // Plain text query - use as-is
            translatedQuery = query
        }

        // Use provided cursor or "*" for initial request
        let searchCursor = cursor ?? "*"
        AppLogger.search.debug("Europe PMC search with cursor: \(searchCursor == "*" ? "initial" : searchCursor.prefix(20))")

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
            basePosition: options.offset
        )

        return unifiedResult
    }

    // MARK: - Combined Search

    /// Search both PubMed and Europe PMC concurrently and merge results.
    ///
    /// Uses TaskGroup for efficient concurrent execution. Results are merged
    /// and deduplicated, with PubMed given priority for metadata quality.
    ///
    /// - Parameters:
    ///   - query: Query string.
    ///   - options: Search options.
    ///   - settings: App settings.
    ///   - cursor: Optional cursor for Europe PMC pagination.
    /// - Returns: Merged, deduplicated search result.
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

        // Search both providers concurrently
        return try await withThrowingTaskGroup(of: UnifiedSearchResult.self) { group in
            group.addTask {
                try await searchPubMed(query: query, options: pubmedOptions, settings: settings)
            }
            group.addTask {
                try await searchEuropePMC(query: query, options: europePMCOptions, cursor: cursor)
            }

            var pubmedResult: UnifiedSearchResult?
            var europePMCResult: UnifiedSearchResult?

            // Collect results
            for try await result in group {
                switch result.provider {
                case .pubmed:
                    pubmedResult = result
                case .europePMC:
                    europePMCResult = result
                case .both:
                    // Shouldn't happen, but handle gracefully
                    break
                }
            }

            // Handle partial failures gracefully
            guard let pubmed = pubmedResult else {
                // PubMed failed, return Europe PMC results only
                return europePMCResult ?? .empty(provider: .both)
            }
            guard let europePMC = europePMCResult else {
                // Europe PMC failed, return PubMed results only
                return pubmed
            }

            // Merge and deduplicate
            return SearchResultMerger.merge(
                pubmedResult: pubmed,
                europePMCResult: europePMC
            )
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

// MARK: - Search Errors

/// Errors that can occur during search operations.
enum SearchError: LocalizedError {
    /// One or both providers returned partial results.
    case partialFailure(successfulProvider: SearchProvider)

    /// No results from any provider.
    case noResults

    /// Invalid search configuration.
    case invalidConfiguration(String)

    var errorDescription: String? {
        switch self {
        case .partialFailure(let provider):
            return "Partial results available from \(provider.displayName) only"
        case .noResults:
            return "No results found from any search provider"
        case .invalidConfiguration(let reason):
            return "Invalid search configuration: \(reason)"
        }
    }
}
