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

/// Service for searching the Europe PMC literature database.
///
/// Europe PMC provides access to biomedical and life sciences literature,
/// including articles from PubMed, PubMed Central, and other sources.
///
/// Usage:
/// ```swift
/// let service = EuropePMCService()
/// let results = try await service.search(query: "COVID-19 treatment")
/// ```
public actor EuropePMCService {
    // MARK: - Properties

    private let session: URLSession
    private let baseURL: String

    // MARK: - Initialization

    /// Initialize the Europe PMC service.
    ///
    /// - Parameter session: URLSession to use for requests. Defaults to shared session.
    public init(session: URLSession? = nil) {
        self.baseURL = BioMedLitConstants.europePMCBaseURL

        if let session = session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = BioMedLitConstants.searchRequestTimeout
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: - Search

    /// Search Europe PMC for articles matching the query.
    ///
    /// - Parameters:
    ///   - query: Search query string (supports Europe PMC query syntax).
    ///   - pageSize: Number of results per page (default: 25, max: 1000).
    ///   - cursor: Cursor for pagination (use "*" for first page).
    ///   - includePreprints: Whether to include preprints in results.
    ///   - requireAbstract: Whether to only return articles with abstracts.
    /// - Returns: Search results with articles and pagination info.
    /// - Throws: `EuropePMCError` if the search fails.
    public func search(
        query: String,
        pageSize: Int = BioMedLitConstants.europePMCDefaultPageSize,
        cursor: String = "*",
        includePreprints: Bool = false,
        requireAbstract: Bool = true
    ) async throws -> SearchResult {
        // Build the full query with filters
        var fullQuery = query

        // Exclude preprints unless requested
        if !includePreprints && !query.uppercased().contains("SRC:PPR") {
            fullQuery += " NOT SRC:PPR"
        }

        // Require abstracts unless the query already specifies
        if requireAbstract && !query.uppercased().contains("HAS_ABSTRACT") {
            fullQuery += " AND HAS_ABSTRACT:Y"
        }

        // Build URL
        var components = URLComponents(string: BioMedLitConstants.europePMCSearchURL)!
        components.queryItems = [
            URLQueryItem(name: "query", value: fullQuery),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "pageSize", value: String(min(pageSize, BioMedLitConstants.europePMCMaxPageSize))),
            URLQueryItem(name: "cursorMark", value: cursor),
            URLQueryItem(name: "resultType", value: "core")
        ]

        guard let url = components.url else {
            throw EuropePMCError.invalidQuery(query)
        }

        BioMedLit.logger?.debug("Europe PMC search URL: \(url.absoluteString)", category: .search)

        // Execute request with retry
        let data = try await RetryHelper.retry(
            config: .networkDefault,
            shouldRetry: RetryHelper.retryOnlyTransient
        ) {
            let (data, response) = try await self.session.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw EuropePMCError.networkError("Invalid response")
            }

            if BioMedLitConstants.retryableStatusCodes.contains(httpResponse.statusCode) {
                throw EuropePMCError.serverError(statusCode: httpResponse.statusCode)
            }

            guard httpResponse.statusCode == BioMedLitConstants.httpStatusOK else {
                throw EuropePMCError.httpError(statusCode: httpResponse.statusCode)
            }

            return data
        }

        // Parse response
        let response = try JSONDecoder().decode(EuropePMCResponse.self, from: data)

        let articles = (response.resultList?.result ?? []).map { result in
            SearchArticle(
                pmid: result.pmid ?? result.id ?? "",
                pmcId: result.pmcid,
                doi: result.doi,
                title: result.title ?? "",
                abstract: cleanAbstract(result.abstractText),
                authors: result.authorString ?? "",
                journal: result.journalTitle ?? result.journalInfo?.journal?.title ?? "",
                year: result.pubYear ?? "",
                publicationDate: result.firstPublicationDate,
                hasFullText: result.inPMC == "Y",
                isOpenAccess: result.isOpenAccess == "Y",
                source: .europePMC
            )
        }

        BioMedLit.logger?.info(
            "Europe PMC search returned \(articles.count) of \(response.hitCount ?? 0) results",
            category: .search
        )

        return SearchResult(
            articles: articles,
            totalCount: response.hitCount ?? 0,
            nextCursor: response.nextCursorMark,
            query: fullQuery,
            provider: .europePMC
        )
    }

    // MARK: - Helpers

    /// Clean abstract text by removing HTML tags.
    private func cleanAbstract(_ text: String?) -> String {
        guard let text = text else { return "" }

        // Convert <h4>Section</h4> to **Section:**
        var result = text
        if let regex = try? NSRegularExpression(pattern: "<h4>([^<]+)</h4>", options: .caseInsensitive) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "\n\n**$1:** "
            )
        }

        // Remove paragraph tags
        result = result.replacingOccurrences(of: "<p>", with: "\n\n")
        result = result.replacingOccurrences(of: "</p>", with: "")

        // Remove any remaining HTML tags
        if let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: .caseInsensitive) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }

        // Clean up whitespace
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)

        return result
    }
}

// MARK: - Europe PMC Errors

/// Errors that can occur during Europe PMC operations.
public enum EuropePMCError: LocalizedError, RetryableError, Sendable {
    case invalidQuery(String)
    case networkError(String)
    case httpError(statusCode: Int)
    case serverError(statusCode: Int)
    case parseError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidQuery(let query):
            return "Invalid search query: \(query)"
        case .networkError(let message):
            return "Network error: \(message)"
        case .httpError(let statusCode):
            return "HTTP error: \(statusCode)"
        case .serverError(let statusCode):
            return "Server error (HTTP \(statusCode)). Retrying..."
        case .parseError(let message):
            return "Failed to parse response: \(message)"
        }
    }

    public var isRetryable: Bool {
        switch self {
        case .serverError, .networkError:
            return true
        case .invalidQuery, .httpError, .parseError:
            return false
        }
    }
}

// MARK: - Response Types

/// Europe PMC search response.
struct EuropePMCResponse: Codable {
    let hitCount: Int?
    let nextCursorMark: String?
    let resultList: EuropePMCResultList?
}

/// Europe PMC result list wrapper.
struct EuropePMCResultList: Codable {
    let result: [EuropePMCResult]?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Handle null or missing result array
        result = try container.decodeIfPresent([EuropePMCResult].self, forKey: .result) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case result
    }
}

/// Europe PMC article result.
struct EuropePMCResult: Codable {
    let id: String?
    let source: String?
    let pmid: String?
    let pmcid: String?
    let doi: String?
    let title: String?
    let authorString: String?
    let journalTitle: String?
    let journalInfo: EuropePMCJournalInfo?
    let pubYear: String?
    let firstPublicationDate: String?
    let abstractText: String?
    let isOpenAccess: String?
    let inPMC: String?
}

/// Europe PMC journal info.
struct EuropePMCJournalInfo: Codable {
    let journal: EuropePMCJournal?
}

/// Europe PMC journal details.
struct EuropePMCJournal: Codable {
    let title: String?
    let medlineAbbreviation: String?
}
