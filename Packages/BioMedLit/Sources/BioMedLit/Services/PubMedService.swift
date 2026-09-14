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
        if let apiKey = apiKey, !apiKey.isEmpty {
            self.apiKey = apiKey
        } else {
            self.apiKey = nil
        }

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
    /// - Returns: Search results with articles and pagination info. Only
    ///   `PubmedArticle` records become articles, so a batch can hold fewer
    ///   articles than the PMIDs it consumed: a `PubmedBookArticle` yields none.
    ///   `nextOffset` is therefore the position after the PMIDs consumed, not
    ///   after the articles. It is `nil` when there is no next page: the batch
    ///   reached the last match, the next page would pass PubMed's offset cap
    ///   (``BioMedLitConstants/pubmedMaxOffset``), or esearch gave no usable count.
    /// - Throws: `PubMedError` if the search fails.
    public func search(
        query: String,
        maxResults: Int = BioMedLitConstants.pubmedDefaultBatchSize,
        offset: Int = 0
    ) async throws -> SearchResult {
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
    ///   article (#251). Without a usable `count`, the total is the articles seen
    ///   so far, which ends pagination here, and a warning says so.
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
                "PubMed search answered without a usable result count; ending pagination at the \(articlesSeen) articles seen",
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
    /// - Returns: The `PubmedArticle` records the efetch answer holds. Other
    ///   records, such as a `PubmedBookArticle`, are skipped, so there can be
    ///   fewer articles than PMIDs.
    private func fetchArticleDetails(
        pmids: [String]
    ) async throws -> [SearchArticle] {
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
    /// Every request waits its turn under the rate limit first, as Python's
    /// `_make_request` does. The parameters travel in a POST body together with
    /// the email and API key (``EutilsRequest`` says why), and a redirect is
    /// refused rather than followed (``RedirectRefusingTaskDelegate`` says why).
    /// The statuses in ``BioMedLitConstants/retryableStatusCodes`` and transient
    /// transport errors are retried with backoff; every other status fails at
    /// once. The body of a failed answer is never read: NCBI's 400 for a bad key
    /// echoes the key in it.
    ///
    /// - Parameters:
    ///   - endpoint: The E-utilities endpoint, such as
    ///     ``BioMedLitConstants/pubmedSearchURL``.
    ///   - parameters: The request's own parameters. Identification is added here.
    /// - Returns: The body of a 200 response.
    /// - Throws: ``PubMedError/redirectRefused(statusCode:)`` for a 3xx;
    ///   ``PubMedError/rateLimited`` for a 429 and
    ///   ``PubMedError/serverError(statusCode:)`` for another retryable status,
    ///   when still failing after the last attempt;
    ///   ``PubMedError/httpError(statusCode:)`` for any other status;
    ///   ``PubMedError/networkError(_:)`` for an endpoint that is not a URL or
    ///   an answer that is not HTTP; or the transport's own error.
    private func send(
        to endpoint: String,
        parameters: [(name: String, value: String)]
    ) async throws -> Data {
        guard let url = URL(string: endpoint) else {
            let reason = "E-utilities endpoint '\(endpoint)' is not a URL"
            BioMedLitLib.logger?.error(reason, category: .search)
            throw PubMedError.networkError(reason)
        }

        // Outside the retry, so a retry's backoff is not lengthened by a second wait
        await waitForRateLimit()

        // Identification goes last, and only ever into the body
        var bodyParameters = parameters + [(name: "email", value: email)]
        if let apiKey = apiKey {
            bodyParameters.append((name: "api_key", value: apiKey))
        }
        let request = EutilsRequest.post(to: url, parameters: bodyParameters)
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

            if statusCode == BioMedLitConstants.httpStatusRateLimited {
                throw PubMedError.rateLimited
            }

            if BioMedLitConstants.retryableStatusCodes.contains(statusCode) {
                throw PubMedError.serverError(statusCode: statusCode)
            }

            // `data` is dropped unread on every failure: it may echo the key
            guard statusCode == BioMedLitConstants.httpStatusOK else {
                throw PubMedError.httpError(statusCode: statusCode)
            }

            return data
        }
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
    /// NCBI answered with a redirect, which is never followed (#243). A 307 or
    /// 308 would re-send the body, API key included, to whatever host it names;
    /// a 301, 302 or 303 would re-send the request as a GET without its parameters.
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
            return "PubMed server error (HTTP \(statusCode)). Try again later."
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
