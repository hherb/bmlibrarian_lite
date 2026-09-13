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
    ///   - apiKey: Optional NCBI API key for higher rate limits. It is sent only
    ///     in request bodies, never in a URL. An empty key counts as none.
    ///   - session: URLSession to use for requests. It must not be a background
    ///     session, which follows redirects without asking.
    public init(email: String, apiKey: String? = nil, session: URLSession? = nil) {
        self.email = email
        self.apiKey = (apiKey?.isEmpty ?? true) ? nil : apiKey

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

        // Step 1: Search to get this batch's PMIDs and how many articles match
        let (pmids, totalCount) = try await searchForPMIDs(query: query, maxResults: maxResults, offset: offset)

        guard !pmids.isEmpty else {
            return SearchResult(
                articles: [],
                totalCount: totalCount,
                nextOffset: nil,
                query: query,
                provider: .pubmed
            )
        }

        // Step 2: Fetch article details
        let articles = try await fetchArticleDetails(pmids: pmids)

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

    /// Search PubMed for one batch of PMIDs and the number of matches in all.
    ///
    /// - Parameters:
    ///   - query: PubMed search query.
    ///   - maxResults: Maximum number of PMIDs in the batch.
    ///   - offset: Position of the batch's first PMID among all matches.
    /// - Returns: The batch's PMIDs, and esearch's `count` of every matching
    ///   article. The total once came from the batch size instead, so no PubMed
    ///   search paginated past its first batch (#251). Without a usable `count`,
    ///   the total is the articles seen so far, which ends pagination here, and a
    ///   warning says so.
    private func searchForPMIDs(
        query: String,
        maxResults: Int,
        offset: Int
    ) async throws -> (pmids: [String], totalCount: Int) {
        let parameters = [
            (name: "db", value: "pubmed"),
            (name: "term", value: query),
            (name: "retmax", value: String(maxResults)),
            (name: "retstart", value: String(offset)),
            (name: "retmode", value: "json")
        ]

        BioMedLitLib.logger?.debug(
            "PubMed search request to \(BioMedLitConstants.pubmedSearchURL) (retstart \(offset), retmax \(maxResults))",
            category: .search
        )

        let data = try await send(to: BioMedLitConstants.pubmedSearchURL, parameters: parameters)

        // Parse response
        let response = try JSONDecoder().decode(PubMedSearchResponse.self, from: data)
        let pmids = response.esearchresult?.idlist ?? []
        let articlesSeen = offset + pmids.count

        let totalCount: Int
        if let statedCount = response.esearchresult?.count.flatMap({ Int($0) }) {
            totalCount = statedCount
        } else {
            totalCount = articlesSeen
            BioMedLitLib.logger?.warning(
                "PubMed search answered without a usable result count; treating the \(articlesSeen) articles seen as all there are",
                category: .search
            )
        }

        BioMedLitLib.logger?.info(
            "PubMed search found \(pmids.count) PMIDs (total: \(totalCount))",
            category: .search
        )

        return (pmids, totalCount)
    }

    /// Fetch article details for given PMIDs.
    ///
    /// - Parameter pmids: The PMIDs to fetch.
    /// - Returns: The articles the efetch answer describes.
    private func fetchArticleDetails(
        pmids: [String]
    ) async throws -> [SearchArticle] {
        await waitForRateLimit()

        let parameters = [
            (name: "db", value: "pubmed"),
            (name: "id", value: pmids.joined(separator: ",")),
            (name: "rettype", value: "xml"),
            (name: "retmode", value: "xml")
        ]

        let data = try await send(to: BioMedLitConstants.pubmedFetchURL, parameters: parameters)

        // Parse XML response
        let parser = PubMedXMLParser(data: data)
        return parser.parse()
    }

    /// Send one E-utilities request and return the body of its answer.
    ///
    /// The parameters travel in a POST body together with the email and API key,
    /// and a redirect is refused rather than followed; ``EutilsRequest`` says
    /// why. Rate-limit and server statuses are retried with backoff, and every
    /// other status fails at once.
    ///
    /// - Parameters:
    ///   - endpoint: The E-utilities endpoint, such as
    ///     ``BioMedLitConstants/pubmedSearchURL``.
    ///   - parameters: The request's own parameters. Identification is added here.
    /// - Returns: The body of a 200 response.
    /// - Throws: ``PubMedError/redirectRefused(statusCode:)`` for a 3xx,
    ///   ``PubMedError/serverError(statusCode:)`` for a retryable status that
    ///   stayed retryable, ``PubMedError/httpError(statusCode:)`` for any other
    ///   status, or the transport's own error.
    private func send(
        to endpoint: String,
        parameters: [(name: String, value: String)]
    ) async throws -> Data {
        guard let url = URL(string: endpoint) else {
            let reason = "E-utilities endpoint '\(endpoint)' is not a URL"
            BioMedLitLib.logger?.error(reason, category: .search)
            throw PubMedError.networkError(reason)
        }

        let request = EutilsRequest.post(to: url, parameters: parameters + identificationParameters)
        let session = self.session

        return try await RetryHelper.retry(
            config: .networkDefault,
            shouldRetry: RetryHelper.retryOnlyTransient
        ) {
            let (data, response) = try await session.data(
                for: request,
                delegate: RedirectRefusingTaskDelegate()
            )

            guard let httpResponse = response as? HTTPURLResponse else {
                throw PubMedError.networkError("Invalid response")
            }

            let statusCode = httpResponse.statusCode

            if BioMedLitConstants.httpRedirectStatusCodes.contains(statusCode) {
                BioMedLitLib.logger?.error(
                    "PubMed answered \(url.path) with HTTP \(statusCode), a redirect; not followed",
                    category: .search
                )
                throw PubMedError.redirectRefused(statusCode: statusCode)
            }

            if BioMedLitConstants.retryableStatusCodes.contains(statusCode) {
                throw PubMedError.serverError(statusCode: statusCode)
            }

            guard statusCode == BioMedLitConstants.httpStatusOK else {
                throw PubMedError.httpError(statusCode: statusCode)
            }

            return data
        }
    }

    /// The email and, when there is one, the API key, as E-utilities parameters.
    private var identificationParameters: [(name: String, value: String)] {
        var parameters = [(name: "email", value: email)]
        if let apiKey = apiKey {
            parameters.append((name: "api_key", value: apiKey))
        }
        return parameters
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
    case noResults
    /// NCBI answered with a redirect, which is never followed: it would re-send
    /// the request, API key included, to another address (#243).
    case redirectRefused(statusCode: Int)

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
        case .noResults:
            return "No results found for the search query"
        case .redirectRefused(let statusCode):
            return "PubMed answered with a redirect (HTTP \(statusCode)), which was not followed"
        }
    }

    public var isRetryable: Bool {
        switch self {
        case .serverError, .networkError, .rateLimited:
            return true
        case .invalidQuery, .httpError, .parseError, .noResults, .redirectRefused:
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
                source: .pubmed,
                // Stated, not left to be guessed back later. PubMed returns
                // MEDLINE records and nothing else, so this is knowledge we
                // hold at the decode site and would otherwise discard — after
                // which the shape rule has to stand in, and a bare decimal is a
                // shape PubMed IDs share with Europe PMC's thesis and
                // case-report accessions (#212).
                identifierKind: .pubmed
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
