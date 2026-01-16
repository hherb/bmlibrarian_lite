//
//  EuropePMCService.swift
//  MedicalFactChecker
//
//  Europe PMC REST API client for literature search.
//  Provides access to biomedical literature including preprints.
//

import Foundation

/// Service for searching Europe PMC literature database.
///
/// Europe PMC provides access to:
/// - PubMed abstracts (mirrored from NCBI)
/// - Full-text articles from PubMed Central
/// - Preprints from 34 servers (bioRxiv, medRxiv, etc.)
/// - Patents, agricultural literature, and other sources
///
/// Uses cursor-based pagination for efficient deep pagination.
/// Thread-safe using Swift's actor model.
actor EuropePMCService {
    // MARK: - Configuration Constants

    /// Configuration constants for the Europe PMC service.
    private enum Config {
        /// Base URL for the Europe PMC REST API.
        static let baseURL = "https://www.ebi.ac.uk/europepmc/webservices/rest"

        /// Timeout for individual requests (seconds).
        static let requestTimeout: TimeInterval = 45

        /// Timeout for total resource loading (seconds).
        static let resourceTimeout: TimeInterval = 90

        /// Maximum concurrent connections to the host.
        static let maxConnectionsPerHost = 4

        // Note: No sort parameter needed - Europe PMC defaults to relevance sorting.
        // The "RELEVANCE desc" parameter was deprecated by Europe PMC API in late 2025.

        /// Result type for comprehensive metadata.
        static let resultType = "core"

        /// Response format.
        static let responseFormat = "json"
    }

    // MARK: - Properties

    /// URL session configured for Europe PMC API.
    private let session: URLSession

    // MARK: - Initialization

    /// Initialize the Europe PMC service.
    ///
    /// Configures URLSession with appropriate timeouts for macOS desktop use.
    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = Config.requestTimeout
        config.timeoutIntervalForResource = Config.resourceTimeout
        config.waitsForConnectivity = true
        config.httpMaximumConnectionsPerHost = Config.maxConnectionsPerHost
        self.session = URLSession(configuration: config)
    }

    /// Create a new Europe PMC service instance.
    ///
    /// - Returns: Configured service instance.
    static func create() -> EuropePMCService {
        return EuropePMCService()
    }

    // MARK: - Search

    /// Search Europe PMC with a query string.
    ///
    /// Supports cursor-based pagination for efficient iteration through large result sets.
    /// The first request should pass `nil` for cursor; subsequent requests use the
    /// `nextCursor` from the previous response.
    ///
    /// - Parameters:
    ///   - query: Europe PMC query string (or plain text).
    ///   - maxResults: Maximum results to return per page.
    ///   - cursor: Pagination cursor (nil for first request, or value from previous response).
    ///   - includePreprints: Whether to include preprints in results.
    /// - Returns: Search result with articles and pagination state.
    /// - Throws: `EuropePMCError` if the request fails.
    func search(
        query: String,
        maxResults: Int = SearchOptions.SearchOptionsDefaults.defaultMaxResults,
        cursor: String? = nil,
        includePreprints: Bool = false
    ) async throws -> EuropePMCSearchResult {
        // Build query with source filtering
        let finalQuery = buildQuery(query, includePreprints: includePreprints)

        // Build URL
        guard let url = buildSearchURL(
            query: finalQuery,
            maxResults: maxResults,
            cursor: cursor
        ) else {
            throw EuropePMCError.invalidURL
        }

        // Log the query URL for debugging
        AppLogger.network.info("Europe PMC query: \(url.absoluteString)")

        // Execute request with retry
        let data = try await RetryHelper.retry(
            config: .networkDefault,
            shouldRetry: RetryHelper.retryOnlyTransient
        ) {
            let request = URLRequest(url: url)
            let (data, response) = try await self.session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw EuropePMCError.invalidResponse
            }

            // Handle rate limiting
            if httpResponse.statusCode == EuropePMCError.rateLimitStatusCode {
                throw EuropePMCError.rateLimited
            }

            guard httpResponse.statusCode == EuropePMCError.successStatusCode else {
                AppLogger.network.error("Europe PMC search failed with status \(httpResponse.statusCode)")
                throw EuropePMCError.searchFailed(statusCode: httpResponse.statusCode)
            }

            return data
        }

        return try parseSearchResponse(data, previousCursor: cursor)
    }

    // MARK: - Query Building

    /// Build the final query with source filtering and abstract requirement.
    ///
    /// - Parameters:
    ///   - query: Original query string.
    ///   - includePreprints: Whether to include preprints.
    /// - Returns: Modified query with filters applied.
    private func buildQuery(_ query: String, includePreprints: Bool) -> String {
        var finalQuery = query

        // Exclude preprints if not requested
        if !includePreprints {
            finalQuery += " NOT SRC:PPR"
        }

        // Require abstract (unless already specified)
        if !finalQuery.uppercased().contains("HAS_ABSTRACT") {
            finalQuery += " AND HAS_ABSTRACT:Y"
        }

        return finalQuery
    }

    /// Build the search URL with query parameters.
    ///
    /// - Parameters:
    ///   - query: Search query.
    ///   - maxResults: Maximum results per page.
    ///   - cursor: Pagination cursor.
    /// - Returns: Constructed URL, or nil if invalid.
    private func buildSearchURL(
        query: String,
        maxResults: Int,
        cursor: String?
    ) -> URL? {
        var components = URLComponents(string: "\(Config.baseURL)/search")
        // Note: No sort parameter needed - Europe PMC defaults to relevance sorting.
        // The "RELEVANCE desc" parameter was deprecated by Europe PMC API in late 2025.
        components?.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "resultType", value: Config.resultType),
            URLQueryItem(name: "pageSize", value: String(maxResults)),
            URLQueryItem(name: "cursorMark", value: cursor ?? CursorPaginationState.initialCursor),
            URLQueryItem(name: "format", value: Config.responseFormat),
        ]
        return components?.url
    }

    // MARK: - Response Parsing

    /// Parse the search response JSON.
    ///
    /// - Parameters:
    ///   - data: Raw JSON data from API.
    ///   - previousCursor: The cursor used for this request (for pagination state).
    /// - Returns: Parsed search result.
    /// - Throws: `EuropePMCError.parseError` if parsing fails.
    private func parseSearchResponse(
        _ data: Data,
        previousCursor: String?
    ) throws -> EuropePMCSearchResult {
        let decoder = JSONDecoder()

        let response: EPMCSearchResponse
        do {
            response = try decoder.decode(EPMCSearchResponse.self, from: data)
        } catch {
            AppLogger.network.error("Europe PMC JSON parse error: \(error.localizedDescription)")
            throw EuropePMCError.parseError(error.localizedDescription)
        }

        let totalCount = Int(response.hitCount) ?? 0
        let articles = parseArticles(response.resultList.result)

        // Build pagination state
        // Note: For cursor pagination, fetchedCount represents articles in THIS response only.
        // Cumulative tracking must be done by the caller if needed.
        let pagination = CursorPaginationState(
            totalCount: totalCount,
            fetchedCount: articles.count,
            currentCursor: previousCursor ?? CursorPaginationState.initialCursor,
            nextCursor: response.nextCursorMark
        )

        return EuropePMCSearchResult(
            articles: articles,
            totalCount: totalCount,
            pagination: pagination
        )
    }

    /// Parse individual articles from the response.
    ///
    /// - Parameter results: Array of raw article results.
    /// - Returns: Array of parsed articles.
    private func parseArticles(_ results: [EPMCResult]) -> [EuropePMCArticle] {
        return results.enumerated().map { index, result in
            EuropePMCArticle(
                pmid: result.pmid,
                pmcId: result.pmcid,
                doi: result.doi,
                title: result.title ?? "",
                abstract: result.abstractText ?? "",
                authors: parseAuthors(result.authorList),
                journal: result.journalTitle ?? "",
                publicationDate: result.firstPublicationDate,
                year: parseYear(result.pubYear),
                source: result.source ?? "MED",
                isPreprint: result.source == "PPR",
                resultPosition: index
            )
        }
    }

    /// Parse author list from the response.
    ///
    /// - Parameter authorList: Raw author list from API.
    /// - Returns: Array of formatted author names.
    private func parseAuthors(_ authorList: EPMCAuthorList?) -> [String] {
        guard let authors = authorList?.author else { return [] }
        return authors.compactMap { author in
            if let fullName = author.fullName {
                return fullName
            } else if let lastName = author.lastName {
                let firstName = author.firstName ?? ""
                return firstName.isEmpty ? lastName : "\(lastName) \(firstName)"
            }
            return nil
        }
    }

    /// Parse publication year from string.
    ///
    /// - Parameter pubYear: Year string from API.
    /// - Returns: Integer year, or nil if invalid.
    private func parseYear(_ pubYear: String?) -> Int? {
        guard let yearString = pubYear else { return nil }
        return Int(yearString)
    }
}

// MARK: - Europe PMC Search Result

/// Result from a Europe PMC search operation.
struct EuropePMCSearchResult: Sendable {
    /// Articles returned by the search.
    let articles: [EuropePMCArticle]

    /// Total number of results available.
    let totalCount: Int

    /// Cursor-based pagination state.
    let pagination: CursorPaginationState

    /// Whether more results are available.
    var hasMore: Bool { pagination.hasMore }

    /// The cursor to use for the next page.
    var nextCursor: String? { pagination.nextCursor }
}

// MARK: - Europe PMC Article

/// Article metadata from Europe PMC search.
struct EuropePMCArticle: Sendable {
    /// PubMed ID (may be nil for preprints).
    let pmid: String?

    /// PubMed Central ID.
    let pmcId: String?

    /// Digital Object Identifier.
    let doi: String?

    /// Article title.
    let title: String

    /// Abstract text.
    let abstract: String

    /// Author names.
    let authors: [String]

    /// Journal or source name.
    let journal: String

    /// Publication date string.
    let publicationDate: String?

    /// Publication year.
    let year: Int?

    /// Source database (MED, PMC, PPR, etc.).
    let source: String

    /// Whether this is a preprint.
    let isPreprint: Bool

    /// Position in search results.
    let resultPosition: Int

    /// Convert to unified article metadata.
    ///
    /// - Parameter batchNumber: Batch number for tracking.
    /// - Returns: Unified metadata representation.
    func toUnifiedMetadata(batchNumber: Int) -> UnifiedArticleMetadata {
        UnifiedArticleMetadata(
            pmid: pmid ?? "",
            pmcId: pmcId,
            doi: doi,
            title: title,
            abstract: abstract,
            authors: authors,
            journal: journal,
            publicationDate: publicationDate,
            year: year,
            meshTerms: [],  // Europe PMC doesn't return MeSH in search results
            source: .europePMC,
            isPreprint: isPreprint,
            batchNumber: batchNumber,
            resultPosition: resultPosition
        )
    }
}

// MARK: - JSON Response Types

/// Root response from Europe PMC search API.
private struct EPMCSearchResponse: Codable {
    /// Total hit count as string.
    let hitCount: String

    /// Cursor for next page (nil if no more results).
    let nextCursorMark: String?

    /// Container for result list.
    let resultList: EPMCResultList

    /// Custom decoder to handle missing or null resultList gracefully.
    ///
    /// The Europe PMC API may return null or omit resultList entirely
    /// when no results are found.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hitCount = try container.decodeIfPresent(String.self, forKey: .hitCount) ?? "0"
        nextCursorMark = try container.decodeIfPresent(String.self, forKey: .nextCursorMark)
        resultList = try container.decodeIfPresent(EPMCResultList.self, forKey: .resultList)
            ?? EPMCResultList(result: [])
    }
}

/// Container for result array.
private struct EPMCResultList: Codable {
    /// Array of article results.
    let result: [EPMCResult]

    /// Direct initializer for creating an empty result list.
    init(result: [EPMCResult]) {
        self.result = result
    }

    /// Custom decoder to handle missing or null result arrays gracefully.
    ///
    /// The Europe PMC API may return null or omit the result array entirely
    /// when no results are found, instead of returning an empty array.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        result = try container.decodeIfPresent([EPMCResult].self, forKey: .result) ?? []
    }
}

/// Individual article result from Europe PMC.
private struct EPMCResult: Codable {
    let pmid: String?
    let pmcid: String?
    let doi: String?
    let title: String?
    let abstractText: String?
    let authorList: EPMCAuthorList?
    let journalTitle: String?
    let pubYear: String?
    let firstPublicationDate: String?
    let source: String?
}

/// Author list container.
private struct EPMCAuthorList: Codable {
    let author: [EPMCAuthor]?
}

/// Individual author entry.
private struct EPMCAuthor: Codable {
    let fullName: String?
    let firstName: String?
    let lastName: String?
}

// MARK: - Errors

/// Errors that can occur during Europe PMC operations.
enum EuropePMCError: LocalizedError {
    /// HTTP status code for success.
    static let successStatusCode = 200

    /// HTTP status code for rate limiting.
    static let rateLimitStatusCode = 429

    /// Search request failed.
    case searchFailed(statusCode: Int)

    /// No results found.
    case noResults

    /// Failed to parse response.
    case parseError(String)

    /// Invalid URL construction.
    case invalidURL

    /// Invalid response from server.
    case invalidResponse

    /// Rate limited by API.
    case rateLimited

    var errorDescription: String? {
        switch self {
        case .searchFailed(let statusCode):
            return "Europe PMC search failed with status code \(statusCode)"
        case .noResults:
            return "No results found in Europe PMC"
        case .parseError(let reason):
            return "Failed to parse Europe PMC response: \(reason)"
        case .invalidURL:
            return "Failed to construct Europe PMC request URL"
        case .invalidResponse:
            return "Invalid response from Europe PMC"
        case .rateLimited:
            return "Europe PMC rate limit exceeded. Please try again later."
        }
    }
}
