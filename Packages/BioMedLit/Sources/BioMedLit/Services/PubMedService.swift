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
/// A search asks for **one page**: a failed request is never an empty page
/// (#255, #256). The source is asked once for the page's PMIDs and once for
/// their articles; whatever of the page the answers lose is reported with the
/// articles that arrived, as ``SearchResult/shortfalls``, and a page that
/// failures leave with nothing throws ``SourceRequestError``.
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

    /// Search PubMed for one page of articles matching the query.
    ///
    /// - Parameters:
    ///   - query: PubMed search query.
    ///   - maxResults: Maximum number of results to return.
    ///   - offset: Starting offset for pagination.
    /// - Returns: The page's articles, how many articles match in all, what the
    ///   page failed to retrieve, and where the next page starts. Only
    ///   `PubmedArticle` records become articles, so a page can hold fewer
    ///   articles than the PMIDs it consumed: a `PubmedBookArticle` yields none,
    ///   and a record that could not be read is reported as missing.
    ///   `nextOffset` is therefore the position after the PMIDs consumed, not
    ///   after the articles. It is `nil` when there is no next page: the page
    ///   reached the last match, or the next page would pass the last record
    ///   PubMed lists (``SearchPaging/pubMedListableRecords``).
    /// - Throws: ``SourceRequestError`` if the page could not be listed at all:
    ///   the request failed after its retries, the answer reports an error or
    ///   cannot be read, or it lists none of the PMIDs it counts. A failed
    ///   search is never returned as an empty page.
    public func search(
        query: String,
        maxResults: Int = BioMedLitConstants.pubmedDefaultBatchSize,
        offset: Int = 0
    ) async throws -> SearchResult {
        guard offset >= 0, offset < SearchPaging.pubMedListableRecords else {
            // A page past the cap is one NCBI refuses, and asking for it would
            // report NCBI's refusal as the source's failure. The caller has a
            // nil `nextOffset` for exactly this, so reaching here is a defect.
            BioMedLitLib.logger?.error(
                "PubMed lists a search's records from offset 0 to "
                    + "\(SearchPaging.pubMedListableRecords - 1), so offset \(offset) was not requested",
                category: .search
            )
            throw SourceRequestError(source: .pubmed, failure: .requestFailed)
        }

        // Step 1: List this page's PMIDs and how many articles match
        let listing = try await listPMIDs(query: query, maxResults: maxResults, offset: offset)

        // Step 2: Fetch the articles for the PMIDs the page listed
        let fetched = listing.pmids.isEmpty
            ? FetchedArticles(articles: [], shortfalls: [])
            : await fetchArticles(for: listing.pmids)

        // The unlisted PMIDs are recorded as missing, so the next page starts after them
        let consumed = max(listing.expected, listing.pmids.count)
        let nextPosition = offset + consumed
        let nextOffset = SearchPaging.pubMedHasNextPage(offset: nextPosition, totalCount: listing.totalCount)
            ? nextPosition
            : nil
        let unlisted = RetrievalShortfall.missingRecords(
            listing.unlisted, from: .pubmed, failure: .incompleteResponse
        )

        return SearchResult(
            articles: fetched.articles,
            totalCount: listing.totalCount,
            nextOffset: nextOffset,
            query: query,
            provider: .pubmed,
            shortfalls: [unlisted].compactMap { $0 } + fetched.shortfalls,
            recordsReceived: consumed
        )
    }

    // MARK: - Private Types

    /// The PMIDs one esearch page listed, and what it should have listed.
    private struct PMIDListing {
        /// The search's total, from `count`.
        let totalCount: Int

        /// The PMIDs the page listed, in PubMed's order.
        let pmids: [String]

        /// How many PMIDs the page should have listed.
        let expected: Int

        /// How many of ``expected`` it left out.
        let unlisted: Int
    }

    /// The articles fetched for a page's PMIDs, and what the fetch failed to retrieve.
    private struct FetchedArticles {
        /// The articles that could be read.
        let articles: [SearchArticle]

        /// What the fetch lost, empty when it lost nothing.
        let shortfalls: [RetrievalShortfall]
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

    /// List one page of a search's PMIDs with esearch.
    ///
    /// E-utilities reports some failures inside an HTTP 200, as an `ERROR`
    /// field and no `count` (#255): that answer is a failed search, not a
    /// search that matched nothing, and its text is neither logged nor shown. A
    /// `count` that is missing or is no whole number is an answer that cannot
    /// be read, not a total of nothing.
    ///
    /// - Parameters:
    ///   - query: PubMed search query.
    ///   - maxResults: Maximum number of PMIDs in the page.
    ///   - offset: Position of the page's first PMID among all matches.
    /// - Returns: The page's PMIDs, esearch's `count` of every matching article
    ///   (#251), and how many PMIDs the page should have listed.
    /// - Throws: ``SourceRequestError`` if the request failed, the answer
    ///   reports an error or cannot be read, or it lists none of the PMIDs it
    ///   counts.
    private func listPMIDs(
        query: String,
        maxResults: Int,
        offset: Int
    ) async throws -> PMIDListing {
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

        guard let answer = LenientJSON.value(from: data) as? [String: Any] else {
            throw unreadableAnswer("esearch answer is not a JSON object")
        }
        guard let result = answer["esearchresult"] as? [String: Any] else {
            throw unreadableAnswer("esearch answer has no esearchresult object")
        }
        if result["ERROR"] != nil {
            BioMedLitLib.logger?.error(
                "E-utilities esearch answered with an ERROR instead of a result "
                    + "(its text is not logged: it can repeat the request)",
                category: .search
            )
            throw SourceRequestError(source: .pubmed, failure: .serviceError)
        }
        guard let count = result["count"] as? String, let totalCount = wholeNumber(count) else {
            throw unreadableAnswer("esearch result has no numeric count")
        }
        guard let pmids = result["idlist"] as? [String] else {
            throw unreadableAnswer("esearch result has no idlist of strings")
        }

        let expected = SearchPaging.expectedEsearchListing(
            totalCount: totalCount, offset: offset, pageSize: maxResults
        )
        if expected > 0 && pmids.isEmpty {
            BioMedLitLib.logger?.error(
                "Incomplete E-utilities answer: esearch listed 0 of \(expected) PMIDs",
                category: .search
            )
            throw SourceRequestError(source: .pubmed, failure: .incompleteResponse)
        }
        let unlisted = max(0, expected - pmids.count)
        if unlisted > 0 {
            BioMedLitLib.logger?.warning(
                "esearch listed \(pmids.count) of \(expected) PMIDs",
                category: .search
            )
        }

        BioMedLitLib.logger?.info(
            "PubMed search found \(pmids.count) PMIDs (total: \(totalCount))",
            category: .search
        )

        return PMIDListing(totalCount: totalCount, pmids: pmids, expected: expected, unlisted: unlisted)
    }

    /// Read a count E-utilities wrote as a decimal string.
    ///
    /// - Parameter text: The stated count.
    /// - Returns: The number, or `nil` for anything that is not decimal digits,
    ///   a sign and a space included.
    private func wholeNumber(_ text: String) -> Int? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(text)
    }

    /// Fetch the articles for a page's PMIDs with efetch.
    ///
    /// A fetch that fails after its retries costs its PMIDs, not the search:
    /// they are recorded as missing, as are the records of an answer that broke
    /// off and the articles that could not be read (#255, #256).
    ///
    /// - Parameter pmids: The PMIDs to fetch.
    /// - Returns: The `PubmedArticle` records the answer holds, and what the
    ///   fetch failed to retrieve. Records other than `PubmedArticle`, such as a
    ///   `PubmedBookArticle`, are not articles and are not missing either: NCBI
    ///   answered for them, with a record this app does not show.
    private func fetchArticles(for pmids: [String]) async -> FetchedArticles {
        let parameters = [
            (name: "db", value: "pubmed"),
            (name: "id", value: pmids.joined(separator: ",")),
            (name: "rettype", value: "xml"),
            (name: "retmode", value: "xml")
        ]

        let parsed: PubMedXMLParser.ParsedArticleSet
        do {
            let data = try await send(to: BioMedLitConstants.pubmedFetchURL, parameters: parameters)
            parsed = try articleSet(from: data)
        } catch let error as SourceRequestError {
            BioMedLitLib.logger?.warning(
                "PubMed articles for \(pmids.count) PMIDs could not be fetched: \(error.failure.describe())",
                category: .search
            )
            return FetchedArticles(
                articles: [],
                shortfalls: [
                    RetrievalShortfall.missingRecords(pmids.count, from: .pubmed, failure: error.failure)
                ].compactMap { $0 }
            )
        } catch {
            // `send` throws nothing else; saying so beats a page that silently holds no article
            BioMedLitLib.logger?.error(
                "PubMed articles for \(pmids.count) PMIDs could not be fetched "
                    + "(an unexpected error, whose text is not logged)",
                category: .search
            )
            return FetchedArticles(
                articles: [],
                shortfalls: [
                    RetrievalShortfall.missingRecords(pmids.count, from: .pubmed, failure: .requestFailed)
                ].compactMap { $0 }
            )
        }

        // An answer that broke off was never seen past the break, so every PMID
        // without an article is missing, not only the records that closed unreadable
        let unreadable = parsed.wellFormed ? parsed.unreadable : max(0, pmids.count - parsed.articles.count)
        if unreadable > 0 {
            BioMedLitLib.logger?.warning(
                "efetch delivered \(parsed.articles.count) readable articles for \(pmids.count) PMIDs",
                category: .search
            )
        }
        return FetchedArticles(
            articles: parsed.articles,
            shortfalls: [
                RetrievalShortfall.missingRecords(unreadable, from: .pubmed, failure: .malformedResponse)
            ].compactMap { $0 }
        )
    }

    /// Parse an efetch answer, refusing NCBI's error document.
    ///
    /// - Parameter data: The answer's body.
    /// - Returns: The articles, how many records closed unreadable, and whether
    ///   the document was well formed.
    /// - Throws: ``SourceRequestError`` for an `eFetchResult` error document, or
    ///   for a root element this build does not know.
    private func articleSet(from data: Data) throws -> PubMedXMLParser.ParsedArticleSet {
        let parsed = PubMedXMLParser(data: data).parseArticleSet()

        switch parsed.rootElement {
        case PubMedXMLParser.articleSetRoot:
            return parsed
        case PubMedXMLParser.errorDocumentRoot:
            BioMedLitLib.logger?.error(
                "E-utilities efetch answered with an error document instead of articles "
                    + "(its text is not logged: it can repeat the request)",
                category: .search
            )
            throw SourceRequestError(source: .pubmed, failure: .serviceError)
        case nil:
            throw unreadableAnswer("efetch answer has no XML root element")
        default:
            throw unreadableAnswer("efetch answer has an unexpected root element")
        }
    }

    /// Build the error for an E-utilities answer that cannot be read, and log why.
    ///
    /// - Parameter reason: What was wrong, naming fields only, never their
    ///   values: an answer can repeat the request, API key included.
    /// - Returns: The error to throw.
    private func unreadableAnswer(_ reason: String) -> SourceRequestError {
        BioMedLitLib.logger?.error("Unreadable E-utilities answer: \(reason)", category: .search)
        return SourceRequestError(source: .pubmed, failure: .malformedResponse)
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
    /// - Throws: ``SourceRequestError`` naming PubMed and, as its failure, a
    ///   refused redirect for a 3xx, the HTTP status for another unsuccessful
    ///   answer, or the kind the transport's own error belongs to — a timeout,
    ///   a failed connection, or a failed request.
    private func send(
        to endpoint: String,
        parameters: [(name: String, value: String)]
    ) async throws -> Data {
        guard let url = URL(string: endpoint) else {
            BioMedLitLib.logger?.error(
                "E-utilities endpoint '\(endpoint)' is not a URL", category: .search
            )
            throw SourceRequestError(source: .pubmed, failure: .requestFailed)
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

        do {
            return try await RetryHelper.retry(
                config: .networkDefault,
                shouldRetry: RetryHelper.retryOnlyTransient
            ) {
                let (data, response) = try await session.data(
                    for: request,
                    delegate: RedirectRefusingTaskDelegate()
                )

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw SourceRequestError(source: .pubmed, failure: .requestFailed)
                }

                let statusCode = httpResponse.statusCode

                if BioMedLitConstants.httpRedirectStatusCodes.contains(statusCode) {
                    BioMedLitLib.logger?.error(
                        "PubMed answered \(url.path) with HTTP \(statusCode), a redirect; not followed",
                        category: .search
                    )
                }

                // `data` is dropped unread on every failure: it may echo the key
                guard statusCode == BioMedLitConstants.httpStatusOK else {
                    throw SourceRequestError(
                        source: .pubmed, failure: .forHTTPStatus(statusCode)
                    )
                }

                return data
            }
        } catch let error as SourceRequestError {
            throw error
        } catch where error.isCancellation {
            // A cancelled request is the user's doing, not the source's: recorded
            // as a shortfall it would tell them PubMed lost records it never lost
            throw CancellationError()
        } catch {
            throw SourceRequestError(source: .pubmed, failure: SearchTransport.failure(for: error))
        }
    }
}

// MARK: - PubMed XML Parser

/// Simple XML parser for PubMed efetch responses.
///
/// Reports what it could not read rather than returning fewer articles in
/// silence (#255): a record that closes without a PMID or a title is counted,
/// a document that breaks off is reported as not well formed, and the root
/// element is kept so an `eFetchResult` error document is told apart from an
/// empty article set.
final class PubMedXMLParser: NSObject, XMLParserDelegate {
    /// The root element of an answer that holds articles.
    static let articleSetRoot = "PubmedArticleSet"

    /// The root element of NCBI's error document (#255).
    static let errorDocumentRoot = "eFetchResult"

    /// An efetch answer as parsed.
    struct ParsedArticleSet {
        /// The articles that carried a PMID and a title.
        let articles: [SearchArticle]

        /// `PubmedArticle` records that closed without a PMID or a title.
        let unreadable: Int

        /// `false` when the XML broke off, so records after the break were never seen.
        let wellFormed: Bool

        /// The document's root element, or `nil` when it opened none.
        let rootElement: String?
    }

    private let parser: XMLParser
    private var articles: [SearchArticle] = []

    /// `PubmedArticle` records that closed without a PMID or a title.
    private var unreadable = 0

    /// The document's root element, once it has opened.
    private var rootElement: String?

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

    /// Parse the answer.
    ///
    /// - Returns: The articles, the records that could not be read, whether the
    ///   document was well formed, and its root element.
    func parseArticleSet() -> ParsedArticleSet {
        let wellFormed = parser.parse()
        if !wellFormed, let error = parser.parserError as NSError? {
            // The message can name an entity from the body, so only where and which code
            BioMedLitLib.logger?.error(
                "efetch answer is not well-formed XML (code \(error.code), "
                    + "line \(parser.lineNumber), column \(parser.columnNumber))",
                category: .search
            )
        }
        return ParsedArticleSet(
            articles: articles,
            unreadable: unreadable,
            wellFormed: wellFormed,
            rootElement: rootElement
        )
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if rootElement == nil {
            rootElement = elementName
        }
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
            saveCurrentArticle()
            inArticle = false
        default:
            break
        }

        textBuffer = ""
    }

    /// Keep the article that just closed, or count it as one that could not be read.
    ///
    /// A record with no PMID or no title names nothing a reader could look up
    /// and shows nothing in a list, so it is missing rather than empty (#255).
    private func saveCurrentArticle() {
        guard !currentPMID.isEmpty, !currentTitle.isEmpty else {
            unreadable += 1
            return
        }
        articles.append(
            SearchArticle(
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
        )
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
