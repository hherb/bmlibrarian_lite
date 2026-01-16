//
//  EuropePMCService.swift
//  MedicalFactChecker
//
//  Europe PMC REST API client for literature search.
//

import Foundation

// MARK: - Constants

/// Constants for Europe PMC service.
private enum EuropePMCConstants {
    /// Timeout for API requests in seconds.
    static let requestTimeoutSeconds: TimeInterval = 30

    /// Timeout for resource downloads in seconds.
    static let resourceTimeoutSeconds: TimeInterval = 60

    /// HTTP status code for successful response.
    static let httpStatusOK = 200

    /// Filter to exclude preprints.
    static let excludePreprintsFilter = " NOT SRC:PPR"

    /// Filter to require abstracts.
    static let hasAbstractFilter = " AND HAS_ABSTRACT:Y"

    /// Initial cursor mark for pagination.
    static let initialCursorMark = "*"

    /// Preprint source identifier.
    static let preprintSource = "PPR"
}

// MARK: - Europe PMC Service

/// Service for searching Europe PMC literature database.
///
/// Europe PMC provides access to:
/// - PubMed abstracts (mirrored)
/// - Full-text articles
/// - Preprints from 34 servers (bioRxiv, medRxiv, etc.)
/// - Patents and other sources
actor EuropePMCService {
    // MARK: - Configuration

    private let session: URLSession

    // MARK: - Initialization

    /// Initialize the service.
    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = EuropePMCConstants.requestTimeoutSeconds
        config.timeoutIntervalForResource = EuropePMCConstants.resourceTimeoutSeconds
        self.session = URLSession(configuration: config)
    }

    /// Create service (no settings needed - no auth required).
    ///
    /// - Returns: A configured EuropePMCService instance.
    static func create() -> EuropePMCService {
        EuropePMCService()
    }

    // MARK: - Search

    /// Search Europe PMC with a query string.
    ///
    /// Europe PMC uses cursor-based pagination. For the first page, pass nil
    /// for cursorMark. For subsequent pages, pass the nextCursorMark from the
    /// previous response.
    ///
    /// - Parameters:
    ///   - query: Europe PMC query string (or plain text).
    ///   - maxResults: Maximum results to return.
    ///   - cursorMark: Cursor for pagination (nil for first page, nextCursorMark for subsequent).
    ///   - includePreprints: Whether to include preprints.
    /// - Returns: Search result with article metadata.
    /// - Throws: `EuropePMCError` if the request fails.
    func search(
        query: String,
        maxResults: Int = SearchProviderConstants.defaultMaxResults,
        cursorMark: String? = nil,
        includePreprints: Bool = false
    ) async throws -> EuropePMCSearchResult {
        let finalQuery = buildQuery(query, includePreprints: includePreprints)

        guard var components = URLComponents(
            string: "\(SearchProviderConstants.europePMCBaseURL)/search"
        ) else {
            throw EuropePMCError.invalidURL
        }

        // Use "*" for initial cursor (first page), otherwise use provided cursor
        let effectiveCursor = cursorMark ?? EuropePMCConstants.initialCursorMark

        components.queryItems = [
            URLQueryItem(name: "query", value: finalQuery),
            URLQueryItem(name: "resultType", value: "core"),
            URLQueryItem(name: "pageSize", value: String(maxResults)),
            URLQueryItem(name: "cursorMark", value: effectiveCursor),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "sort", value: "RELEVANCE desc"),
        ]

        guard let url = components.url else {
            throw EuropePMCError.invalidURL
        }

        let request = URLRequest(url: url)
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == EuropePMCConstants.httpStatusOK else {
            throw EuropePMCError.searchFailed
        }

        return try parseSearchResponse(data, cursorMark: effectiveCursor)
    }

    // MARK: - Query Building

    /// Build the final query with filters.
    ///
    /// - Parameters:
    ///   - query: The base query string.
    ///   - includePreprints: Whether to include preprints.
    /// - Returns: The modified query with filters applied.
    private func buildQuery(_ query: String, includePreprints: Bool) -> String {
        var finalQuery = query

        // Add source filter if not including preprints
        if !includePreprints {
            finalQuery += EuropePMCConstants.excludePreprintsFilter
        }

        // Add abstract requirement if not already present
        if !finalQuery.contains("HAS_ABSTRACT") {
            finalQuery += EuropePMCConstants.hasAbstractFilter
        }

        return finalQuery
    }

    // MARK: - Response Parsing

    /// Parse the search response JSON.
    ///
    /// - Parameters:
    ///   - data: The response data.
    ///   - cursorMark: The cursor mark used for this request.
    /// - Returns: Parsed search result.
    /// - Throws: `EuropePMCError.parseError` if parsing fails.
    private func parseSearchResponse(_ data: Data, cursorMark: String) throws -> EuropePMCSearchResult {
        let decoder = JSONDecoder()
        let response: EPMCSearchResponse

        do {
            response = try decoder.decode(EPMCSearchResponse.self, from: data)
        } catch {
            throw EuropePMCError.parseError(error.localizedDescription)
        }

        let articles = response.resultList.result.enumerated().map { index, result in
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
                meshTerms: [],  // Europe PMC doesn't return MeSH in search
                source: result.source ?? "MED",
                isPreprint: result.source == EuropePMCConstants.preprintSource,
                resultPosition: index  // Position within this page
            )
        }

        return EuropePMCSearchResult(
            articles: articles,
            totalCount: Int(response.hitCount) ?? 0,
            currentCursorMark: cursorMark,
            nextCursorMark: response.nextCursorMark
        )
    }

    /// Parse author list from response.
    ///
    /// - Parameter authorList: The author list from the API response.
    /// - Returns: Array of author name strings.
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

    /// Parse publication year string to Int.
    ///
    /// - Parameter pubYear: The year string from the API response.
    /// - Returns: The year as an integer, or nil if parsing fails.
    private func parseYear(_ pubYear: String?) -> Int? {
        guard let yearString = pubYear else { return nil }
        return Int(yearString)
    }
}

// MARK: - Search Result Types

/// Result from a Europe PMC search.
struct EuropePMCSearchResult: Sendable {
    /// The articles returned.
    let articles: [EuropePMCArticle]

    /// Total count of matching documents.
    let totalCount: Int

    /// Cursor mark used for this request.
    let currentCursorMark: String

    /// Cursor mark for next page (if any).
    let nextCursorMark: String?

    /// Check if more results are available.
    ///
    /// More results exist when nextCursorMark differs from currentCursorMark.
    /// Europe PMC returns the same cursor when you've reached the end.
    var hasMore: Bool {
        guard let next = nextCursorMark else { return false }
        return next != currentCursorMark && !articles.isEmpty
    }
}

/// Article metadata from Europe PMC.
struct EuropePMCArticle: Sendable {
    let pmid: String?
    let pmcId: String?
    let doi: String?
    let title: String
    let abstract: String
    let authors: [String]
    let journal: String
    let publicationDate: String?
    let year: Int?
    let meshTerms: [String]
    let source: String
    let isPreprint: Bool
    let resultPosition: Int

    /// Convert to ArticleMetadata for unified handling.
    ///
    /// - Parameter batchNumber: The batch number for this article.
    /// - Returns: An ArticleMetadata instance.
    func toArticleMetadata(batchNumber: Int) -> ArticleMetadata {
        ArticleMetadata(
            pmid: pmid ?? "",
            title: title,
            abstract: abstract,
            authors: authors,
            journal: journal,
            publicationDate: publicationDate,
            year: year,
            doi: doi,
            pmcId: pmcId,
            meshTerms: meshTerms,
            batchNumber: batchNumber,
            resultPosition: resultPosition
        )
    }
}

// MARK: - JSON Response Types

/// Root response from Europe PMC search API.
private struct EPMCSearchResponse: Codable {
    let hitCount: String
    let nextCursorMark: String?
    let resultList: EPMCResultList
}

/// Result list container.
private struct EPMCResultList: Codable {
    let result: [EPMCResult]

    /// Custom decoder to handle missing or null result arrays gracefully.
    ///
    /// The Europe PMC API may return null or omit the result array entirely
    /// when no results are found, instead of returning an empty array.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        result = try container.decodeIfPresent([EPMCResult].self, forKey: .result) ?? []
    }
}

/// Individual result from Europe PMC.
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

/// Author information.
private struct EPMCAuthor: Codable {
    let fullName: String?
    let firstName: String?
    let lastName: String?
}

// MARK: - Errors

/// Errors that can occur during Europe PMC operations.
enum EuropePMCError: LocalizedError, Sendable {
    case invalidURL
    case searchFailed
    case noResults
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid Europe PMC URL"
        case .searchFailed:
            return "Europe PMC search failed"
        case .noResults:
            return "No results found"
        case .parseError(let reason):
            return "Failed to parse response: \(reason)"
        }
    }
}
