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

/// Service for searching PubMed via NCBI E-utilities.
///
/// PubMed is the US National Library of Medicine's database of biomedical
/// literature citations and abstracts.
///
/// Usage:
/// ```swift
/// let service = PubMedService(email: "your@email.com")
/// let results = try await service.search(query: "COVID-19 treatment")
/// ```
public actor PubMedService {
    // MARK: - Properties

    private let session: URLSession
    private let email: String
    private let apiKey: String?

    /// Delay between requests to respect rate limits.
    private var requestDelay: TimeInterval {
        apiKey != nil
            ? 1.0 / Double(BioMedLitConstants.pubmedRateLimitWithKey)
            : 1.0 / Double(BioMedLitConstants.pubmedRateLimitNoKey)
    }

    private var lastRequestTime: Date?

    // MARK: - Initialization

    /// Initialize the PubMed service.
    ///
    /// - Parameters:
    ///   - email: Email address for NCBI identification (recommended).
    ///   - apiKey: Optional NCBI API key for higher rate limits.
    ///   - session: URLSession to use for requests.
    public init(email: String, apiKey: String? = nil, session: URLSession? = nil) {
        self.email = email
        self.apiKey = apiKey

        if let session = session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = BioMedLitConstants.searchRequestTimeout
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: - Search

    /// Search PubMed for articles matching the query.
    ///
    /// - Parameters:
    ///   - query: PubMed search query.
    ///   - maxResults: Maximum number of results to return.
    ///   - offset: Starting offset for pagination.
    /// - Returns: Search results with articles and pagination info.
    /// - Throws: `PubMedError` if the search fails.
    public func search(
        query: String,
        maxResults: Int = BioMedLitConstants.pubmedDefaultBatchSize,
        offset: Int = 0
    ) async throws -> SearchResult {
        // Respect rate limits
        await waitForRateLimit()

        // Step 1: Search to get PMIDs
        let pmids = try await searchForPMIDs(query: query, maxResults: maxResults, offset: offset)

        guard !pmids.isEmpty else {
            return SearchResult(
                articles: [],
                totalCount: 0,
                nextOffset: nil,
                query: query,
                provider: .pubmed
            )
        }

        // Step 2: Fetch article details
        let (articles, totalCount) = try await fetchArticleDetails(pmids: pmids, query: query)

        // Calculate next offset
        let nextOffset = offset + pmids.count < totalCount && offset + pmids.count < BioMedLitConstants.pubmedMaxOffset
            ? offset + pmids.count
            : nil

        return SearchResult(
            articles: articles,
            totalCount: totalCount,
            nextOffset: nextOffset,
            query: query,
            provider: .pubmed
        )
    }

    // MARK: - Private Methods

    /// Wait for rate limit if needed.
    private func waitForRateLimit() async {
        if let lastTime = lastRequestTime {
            let elapsed = Date().timeIntervalSince(lastTime)
            if elapsed < requestDelay {
                let waitTime = requestDelay - elapsed
                try? await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))
            }
        }
        lastRequestTime = Date()
    }

    /// Search PubMed and return PMIDs.
    private func searchForPMIDs(
        query: String,
        maxResults: Int,
        offset: Int
    ) async throws -> [String] {
        var components = URLComponents(string: BioMedLitConstants.pubmedSearchURL)!
        var queryItems = [
            URLQueryItem(name: "db", value: "pubmed"),
            URLQueryItem(name: "term", value: query),
            URLQueryItem(name: "retmax", value: String(maxResults)),
            URLQueryItem(name: "retstart", value: String(offset)),
            URLQueryItem(name: "retmode", value: "json"),
            URLQueryItem(name: "email", value: email)
        ]

        if let apiKey = apiKey {
            queryItems.append(URLQueryItem(name: "api_key", value: apiKey))
        }

        components.queryItems = queryItems

        guard let url = components.url else {
            throw PubMedError.invalidQuery(query)
        }

        BioMedLit.logger?.debug("PubMed search URL: \(url.absoluteString)", category: .search)

        let data = try await RetryHelper.retry(
            config: .networkDefault,
            shouldRetry: RetryHelper.retryOnlyTransient
        ) {
            let (data, response) = try await self.session.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw PubMedError.networkError("Invalid response")
            }

            if BioMedLitConstants.retryableStatusCodes.contains(httpResponse.statusCode) {
                throw PubMedError.serverError(statusCode: httpResponse.statusCode)
            }

            guard httpResponse.statusCode == BioMedLitConstants.httpStatusOK else {
                throw PubMedError.httpError(statusCode: httpResponse.statusCode)
            }

            return data
        }

        // Parse response
        let response = try JSONDecoder().decode(PubMedSearchResponse.self, from: data)
        let pmids = response.esearchresult?.idlist ?? []

        BioMedLit.logger?.info(
            "PubMed search found \(pmids.count) PMIDs (total: \(response.esearchresult?.count ?? "0"))",
            category: .search
        )

        return pmids
    }

    /// Fetch article details for given PMIDs.
    private func fetchArticleDetails(
        pmids: [String],
        query: String
    ) async throws -> ([SearchArticle], Int) {
        await waitForRateLimit()

        var components = URLComponents(string: BioMedLitConstants.pubmedFetchURL)!
        var queryItems = [
            URLQueryItem(name: "db", value: "pubmed"),
            URLQueryItem(name: "id", value: pmids.joined(separator: ",")),
            URLQueryItem(name: "rettype", value: "xml"),
            URLQueryItem(name: "retmode", value: "xml"),
            URLQueryItem(name: "email", value: email)
        ]

        if let apiKey = apiKey {
            queryItems.append(URLQueryItem(name: "api_key", value: apiKey))
        }

        components.queryItems = queryItems

        guard let url = components.url else {
            throw PubMedError.invalidQuery(query)
        }

        let data = try await RetryHelper.retry(
            config: .networkDefault,
            shouldRetry: RetryHelper.retryOnlyTransient
        ) {
            let (data, response) = try await self.session.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw PubMedError.networkError("Invalid response")
            }

            guard httpResponse.statusCode == BioMedLitConstants.httpStatusOK else {
                throw PubMedError.httpError(statusCode: httpResponse.statusCode)
            }

            return data
        }

        // Parse XML response
        let parser = PubMedXMLParser(data: data)
        let articles = parser.parse()

        return (articles, pmids.count)
    }
}

// MARK: - PubMed Errors

/// Errors that can occur during PubMed operations.
public enum PubMedError: LocalizedError, RetryableError, Sendable {
    case invalidQuery(String)
    case networkError(String)
    case httpError(statusCode: Int)
    case serverError(statusCode: Int)
    case parseError(String)
    case rateLimited

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
        case .rateLimited:
            return "Rate limited. Please wait and try again."
        }
    }

    public var isRetryable: Bool {
        switch self {
        case .serverError, .networkError, .rateLimited:
            return true
        case .invalidQuery, .httpError, .parseError:
            return false
        }
    }
}

// MARK: - Response Types

/// PubMed esearch response.
struct PubMedSearchResponse: Codable {
    let esearchresult: PubMedSearchResult?
}

/// PubMed search result.
struct PubMedSearchResult: Codable {
    let count: String?
    let idlist: [String]?
}

// MARK: - PubMed XML Parser

/// Simple XML parser for PubMed efetch responses.
final class PubMedXMLParser: NSObject, XMLParserDelegate {
    private let parser: XMLParser
    private var articles: [SearchArticle] = []

    // Current article state
    private var currentPMID = ""
    private var currentPMCID: String?
    private var currentDOI: String?
    private var currentTitle = ""
    private var currentAbstract = ""
    private var currentAuthors: [String] = []
    private var currentJournal = ""
    private var currentYear = ""

    // Parsing state
    private var currentElement = ""
    private var textBuffer = ""
    private var inArticle = false
    private var inAbstract = false
    private var currentAuthorLastName = ""
    private var currentAuthorForeName = ""

    init(data: Data) {
        self.parser = XMLParser(data: data)
        super.init()
        parser.delegate = self
    }

    func parse() -> [SearchArticle] {
        parser.parse()
        return articles
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
        textBuffer = ""

        switch elementName {
        case "PubmedArticle":
            inArticle = true
            resetCurrentArticle()
        case "Abstract":
            inAbstract = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        textBuffer += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let text = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)

        switch elementName {
        case "PMID":
            if currentPMID.isEmpty {
                currentPMID = text
            }
        case "ArticleId":
            // This would need attribute handling for IdType
            break
        case "ArticleTitle":
            currentTitle = text
        case "AbstractText":
            if !currentAbstract.isEmpty {
                currentAbstract += " "
            }
            currentAbstract += text
        case "Abstract":
            inAbstract = false
        case "LastName":
            currentAuthorLastName = text
        case "ForeName":
            currentAuthorForeName = text
        case "Author":
            if !currentAuthorLastName.isEmpty {
                let authorName = currentAuthorForeName.isEmpty
                    ? currentAuthorLastName
                    : "\(currentAuthorLastName), \(currentAuthorForeName)"
                currentAuthors.append(authorName)
            }
            currentAuthorLastName = ""
            currentAuthorForeName = ""
        case "Title":
            // Journal title
            if currentJournal.isEmpty {
                currentJournal = text
            }
        case "Year":
            if currentYear.isEmpty {
                currentYear = text
            }
        case "PubmedArticle":
            // Save the article
            let article = SearchArticle(
                pmid: currentPMID,
                pmcId: currentPMCID,
                doi: currentDOI,
                title: currentTitle,
                abstract: currentAbstract,
                authors: formatAuthors(currentAuthors),
                journal: currentJournal,
                year: currentYear,
                hasFullText: currentPMCID != nil,
                source: .pubmed
            )
            articles.append(article)
            inArticle = false
        default:
            break
        }

        textBuffer = ""
    }

    private func resetCurrentArticle() {
        currentPMID = ""
        currentPMCID = nil
        currentDOI = nil
        currentTitle = ""
        currentAbstract = ""
        currentAuthors = []
        currentJournal = ""
        currentYear = ""
    }

    private func formatAuthors(_ authors: [String]) -> String {
        if authors.count <= 3 {
            return authors.joined(separator: ", ")
        } else {
            return "\(authors[0]), \(authors[1]), \(authors[2]) et al."
        }
    }
}
