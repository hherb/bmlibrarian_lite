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
        guard var components = URLComponents(string: BioMedLitConstants.europePMCSearchURL) else {
            throw EuropePMCError.invalidQuery("Invalid search URL configuration")
        }
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

        BioMedLitLib.logger?.debug("Europe PMC search URL: \(url.absoluteString)", category: .search)

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

        let results = response.resultList?.result ?? []
        var articles: [SearchArticle] = []
        articles.reserveCapacity(results.count)

        for result in results {
            let pmid = result.pmid ?? result.id ?? ""
            let title = result.title ?? ""
            let abstract = cleanAbstract(result.abstractText)
            let authors = result.authorString ?? ""
            let journal = result.journalTitle ?? result.journalInfo?.journal?.title ?? ""
            let year = result.pubYear ?? ""
            let hasFullText = result.inPMC == "Y"
            let isOpenAccess = result.isOpenAccess == "Y"

            // Extract free PDF render URL from fullTextUrlList
            let pdfRenderURL = EuropePMCService.extractFreePDFURL(from: result)

            let article = SearchArticle(
                pmid: pmid,
                pmcId: result.pmcid,
                doi: result.doi,
                title: title,
                abstract: abstract,
                authors: authors,
                journal: journal,
                year: year,
                publicationDate: result.firstPublicationDate,
                hasFullText: hasFullText,
                isOpenAccess: isOpenAccess,
                source: .europePMC,
                pdfRenderURL: pdfRenderURL
            )
            articles.append(article)
        }

        BioMedLitLib.logger?.info(
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

    // MARK: - Free PDF Selection

    /// Extract a free PDF URL from a result's ``fullTextUrlList``.
    ///
    /// The search API includes `fullTextUrlList` with `?pdf=render` entries for
    /// PDFs Europe PMC serves itself, even when JATS XML is unavailable — which
    /// is exactly when the PDF tier needs one.
    ///
    /// Entries that are PDFs but not downloadable are logged rather than dropped
    /// silently, so "a PDF entry was seen and not taken" is visible in a trace.
    ///
    /// - Parameter result: One Europe PMC search result.
    /// - Returns: The first downloadable PDF URL, or `nil` if the result offers none.
    ///
    /// - SeeAlso: ``reportRejectedPDFEntry(_:)`` for how a rejection is reported.
    static func extractFreePDFURL(from result: EuropePMCResult) -> String? {
        guard let entries = result.fullTextUrlList?.fullTextUrl else { return nil }

        for entry in entries
        where entry.documentStyle == BioMedLitConstants.europePMCPDFDocumentStyle {
            guard entry.isFreeToDownload else {
                reportRejectedPDFEntry(entry)
                continue
            }
            if let url = entry.url { return url }
        }
        return nil
    }

    /// Report a PDF entry that was seen and not taken.
    ///
    /// The two reasons are not equally interesting, so they are not logged at the
    /// same level. A recognised paywall code is the allow-list working as designed
    /// and stays at debug. A code in neither the allow-list nor the known-paywalled
    /// set means Europe PMC has started publishing a value this build has never
    /// evaluated: the allow-list then rejects it fail-closed, silently costing
    /// free PDFs, which is exactly how bmlib issue #79 happened. That warrants a
    /// warning naming the code, so the fix is a one-line constant edit rather than
    /// another measurement campaign.
    ///
    /// - Parameter entry: The rejected `fullTextUrl` entry.
    private static func reportRejectedPDFEntry(_ entry: EuropePMCFullTextUrlEntry) {
        let code = entry.availabilityCode ?? ""
        let label = entry.availability ?? "nil"

        guard !code.isEmpty,
              !BioMedLitConstants.europePMCFreePDFAvailabilityCodes.contains(code),
              !BioMedLitConstants.europePMCKnownUnavailablePDFCodes.contains(code) else {
            BioMedLitLib.logger?.debug(
                "Skipping Europe PMC PDF entry: availability=\(label) code=\(code.isEmpty ? "nil" : code)",
                category: .fullText
            )
            return
        }

        BioMedLitLib.logger?.warning(
            """
            Unrecognised Europe PMC availabilityCode '\(code)' (availability=\(label)); \
            the PDF was rejected fail-closed. If this is a free tier, add it to \
            BioMedLitConstants.europePMCFreePDFAvailabilityCodes.
            """,
            category: .fullText
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
    let hasPDF: String?
    let fullTextUrlList: EuropePMCFullTextUrlList?
}

/// Europe PMC full-text URL list wrapper.
struct EuropePMCFullTextUrlList: Codable {
    let fullTextUrl: [EuropePMCFullTextUrlEntry]?
}

/// Europe PMC full-text URL entry.
struct EuropePMCFullTextUrlEntry: Codable {
    let documentStyle: String?
    let site: String?
    let url: String?
    let availability: String?
    let availabilityCode: String?
}

extension EuropePMCFullTextUrlEntry {
    /// Whether this entry is one the app may download.
    ///
    /// `true` when the entry's access code is one of
    /// ``BioMedLitConstants/europePMCFreePDFAvailabilityCodes``, or — for an entry
    /// carrying no code — its display string is one of
    /// ``BioMedLitConstants/europePMCFreePDFAvailabilityLabels``.
    ///
    /// A code that is present but unrecognised returns `false` **without**
    /// consulting the string: falling back there would let a future code the app
    /// has never evaluated through on the strength of a label, which is the
    /// opposite of the under-credit rule the allow-list exists to keep.
    var isFreeToDownload: Bool {
        if let code = availabilityCode, !code.isEmpty {
            return BioMedLitConstants.europePMCFreePDFAvailabilityCodes.contains(code)
        }
        guard let availability = availability else { return false }
        return BioMedLitConstants.europePMCFreePDFAvailabilityLabels.contains(availability)
    }
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
