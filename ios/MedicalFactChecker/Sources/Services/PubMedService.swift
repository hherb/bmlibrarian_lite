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

/// Service for searching PubMed via the NCBI E-utilities API.
///
/// Supports batch pagination, rate limiting, and XML parsing of article metadata.
/// Thread-safe using Swift's actor model.
actor PubMedService {
    // MARK: - Configuration

    private let baseSearchURL = URL(string: "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi")!
    private let baseFetchURL = URL(string: "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi")!

    private var email: String?
    private var apiKey: String?
    private let session: URLSession

    // MARK: - Rate Limiting

    /// Last request time for rate limiting.
    private var lastRequestTime: Date = .distantPast

    /// Delay between requests (3/sec without key, 10/sec with key).
    private var requestDelay: TimeInterval {
        apiKey != nil ? 0.1 : 0.34
    }

    // MARK: - Initialization

    init(email: String? = nil, apiKey: String? = nil) {
        self.email = email
        self.apiKey = apiKey

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    /// Create service from current app settings.
    static func create(from settings: AppSettings) -> PubMedService {
        let email = settings.ncbiEmail.isEmpty ? nil : settings.ncbiEmail
        let apiKey = settings.ncbiAPIKey.isEmpty ? nil : settings.ncbiAPIKey
        return PubMedService(email: email, apiKey: apiKey)
    }

    // MARK: - Search

    /// Search PubMed with a query string.
    ///
    /// Results are sorted by relevance. Within relevance tiers, newer articles
    /// tend to rank higher due to PubMed's algorithm.
    ///
    /// - Parameters:
    ///   - query: PubMed search query string.
    ///   - maxResults: Maximum results to return in this batch.
    ///   - offset: Starting position in the result set (for pagination).
    /// - Returns: Search result with PMIDs and total count.
    /// - Throws: `PubMedError.searchFailed` if the request fails.
    func search(
        query: String,
        maxResults: Int = 20,
        offset: Int = 0
    ) async throws -> PubMedSearchResult {
        await throttle()

        var components = URLComponents(url: baseSearchURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "db", value: "pubmed"),
            URLQueryItem(name: "term", value: query),
            URLQueryItem(name: "retmax", value: String(maxResults)),
            URLQueryItem(name: "retstart", value: String(offset)),
            URLQueryItem(name: "retmode", value: "json"),
            URLQueryItem(name: "sort", value: "relevance"),
        ]

        addAuthParams(&components)

        let request = URLRequest(url: components.url!)
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw PubMedError.searchFailed
        }

        let searchResponse = try JSONDecoder().decode(ESearchResponse.self, from: data)
        let result = searchResponse.esearchresult

        return PubMedSearchResult(
            pmids: result.idlist,
            totalCount: Int(result.count) ?? 0,
            offset: offset,
            webEnv: result.webenv,
            queryKey: result.querykey
        )
    }

    // MARK: - Fetch Articles

    /// Fetch article metadata for a list of PMIDs.
    ///
    /// - Parameters:
    ///   - pmids: List of PubMed IDs to fetch.
    ///   - batchNumber: Which batch this is (for tracking in Document).
    ///   - basePosition: Starting position in overall results.
    /// - Returns: Array of article metadata.
    func fetchArticles(
        pmids: [String],
        batchNumber: Int = 1,
        basePosition: Int = 0
    ) async throws -> [ArticleMetadata] {
        guard !pmids.isEmpty else { return [] }

        await throttle()

        var components = URLComponents(url: baseFetchURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "db", value: "pubmed"),
            URLQueryItem(name: "id", value: pmids.joined(separator: ",")),
            URLQueryItem(name: "retmode", value: "xml"),
        ]

        addAuthParams(&components)

        let request = URLRequest(url: components.url!)
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw PubMedError.fetchFailed
        }

        return try parseArticlesXML(data, batchNumber: batchNumber, basePosition: basePosition)
    }

    // MARK: - Rate Limiting

    private func throttle() async {
        let elapsed = Date().timeIntervalSince(lastRequestTime)
        if elapsed < requestDelay {
            let delay = requestDelay - elapsed
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        lastRequestTime = Date()
    }

    // MARK: - Auth Parameters

    private func addAuthParams(_ components: inout URLComponents) {
        if let email = email {
            components.queryItems?.append(URLQueryItem(name: "email", value: email))
        }
        if let apiKey = apiKey {
            components.queryItems?.append(URLQueryItem(name: "api_key", value: apiKey))
        }
    }

    // MARK: - XML Parsing

    private func parseArticlesXML(
        _ data: Data,
        batchNumber: Int,
        basePosition: Int
    ) throws -> [ArticleMetadata] {
        let parser = PubMedXMLParser(data: data, batchNumber: batchNumber, basePosition: basePosition)
        return try parser.parse()
    }
}

// MARK: - Supporting Types

/// Result from a PubMed search.
struct PubMedSearchResult {
    let pmids: [String]
    let totalCount: Int
    let offset: Int
    let webEnv: String?
    let queryKey: String?

    /// Check if more results are available.
    var hasMore: Bool {
        offset + pmids.count < totalCount
    }

    /// Next offset for pagination.
    var nextOffset: Int {
        offset + pmids.count
    }
}

/// Article metadata from PubMed.
struct ArticleMetadata {
    let pmid: String
    let title: String
    let abstract: String
    let authors: [String]
    let journal: String
    let publicationDate: String?
    let year: Int?
    let doi: String?
    let pmcId: String?
    let meshTerms: [String]
    let batchNumber: Int
    let resultPosition: Int
}

// MARK: - JSON Response Types

struct ESearchResponse: Codable {
    let esearchresult: ESearchResult
}

struct ESearchResult: Codable {
    let count: String
    let idlist: [String]
    let webenv: String?
    let querykey: String?
}

// MARK: - XML Parser

/// Parser for PubMed XML responses.
///
/// Extracts article metadata including title, abstract, authors, journal,
/// publication date, DOI, PMC ID, and MeSH terms from PubMed efetch XML.
final class PubMedXMLParser: NSObject, XMLParserDelegate {
    private let parser: XMLParser
    private let batchNumber: Int
    private let basePosition: Int

    private var articles: [ArticleMetadata] = []
    private var currentArticle: ArticleBuilder?
    private var currentElement: String = ""
    private var currentText: String = ""
    private var articleIndex: Int = 0

    // Nested element tracking
    private var inAbstract = false
    private var inAuthor = false
    private var abstractLabel: String?
    private var currentArticleIdType: String?

    /// Initialize the parser with XML data.
    ///
    /// - Parameters:
    ///   - data: Raw XML data from PubMed efetch.
    ///   - batchNumber: Which batch this is (1-indexed).
    ///   - basePosition: Starting position in overall results.
    init(data: Data, batchNumber: Int, basePosition: Int) {
        self.parser = XMLParser(data: data)
        self.batchNumber = batchNumber
        self.basePosition = basePosition
        super.init()
        parser.delegate = self
    }

    /// Parse the XML and return article metadata.
    ///
    /// - Returns: Array of parsed article metadata.
    /// - Throws: `PubMedError.xmlParseError` if parsing fails.
    func parse() throws -> [ArticleMetadata] {
        guard parser.parse() else {
            throw PubMedError.xmlParseError(parser.parserError?.localizedDescription ?? "Unknown error")
        }
        return articles
    }

    // MARK: - XMLParserDelegate

    /// Elements that contain text content we want to capture.
    /// Text is only reset when starting these elements, not embedded formatting tags.
    private static let textContentElements: Set<String> = [
        "PMID", "ArticleTitle", "AbstractText", "LastName", "ForeName",
        "Title", "Year", "ArticleId", "DescriptorName"
    ]

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName

        // Only reset text for elements we capture content from.
        // This preserves text when embedded formatting tags (i, b, sub, sup, etc.)
        // appear within AbstractText or other content elements.
        if Self.textContentElements.contains(elementName) {
            currentText = ""
        }

        switch elementName {
        case "PubmedArticle":
            currentArticle = ArticleBuilder()

        case "AbstractText":
            inAbstract = true
            abstractLabel = attributeDict["Label"]

        case "Author":
            inAuthor = true

        case "ArticleId":
            // Track the IdType attribute for DOI/PMC extraction
            currentArticleIdType = attributeDict["IdType"]

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard var article = currentArticle else { return }

        switch elementName {
        case "PMID":
            if article.pmid.isEmpty {
                article.pmid = text
            }

        case "ArticleTitle":
            article.title = text

        case "AbstractText":
            if let label = abstractLabel, !label.isEmpty {
                article.abstractParts.append("**\(label.uppercased()):** \(text)")
            } else {
                article.abstractParts.append(text)
            }
            inAbstract = false
            abstractLabel = nil

        case "LastName":
            if inAuthor {
                article.currentAuthorLastName = text
            }

        case "ForeName":
            if inAuthor {
                article.currentAuthorForeName = text
            }

        case "Author":
            inAuthor = false
            if !article.currentAuthorLastName.isEmpty {
                let fullName = article.currentAuthorForeName.isEmpty
                    ? article.currentAuthorLastName
                    : "\(article.currentAuthorLastName) \(article.currentAuthorForeName)"
                article.authors.append(fullName)
            }
            article.currentAuthorLastName = ""
            article.currentAuthorForeName = ""

        case "Title":  // Journal title
            if !inAbstract && article.journal.isEmpty {
                article.journal = text
            }

        case "Year":
            if article.year == nil, let year = Int(text) {
                article.year = year
                article.publicationDate = text
            }

        case "ArticleId":
            // Extract DOI and PMC ID based on IdType attribute
            if let idType = currentArticleIdType {
                switch idType.lowercased() {
                case "doi":
                    article.doi = text
                case "pmc":
                    article.pmcId = text
                default:
                    break
                }
            }
            currentArticleIdType = nil

        case "DescriptorName":
            article.meshTerms.append(text)

        case "PubmedArticle":
            if let metadata = article.build(
                batchNumber: batchNumber,
                resultPosition: basePosition + articleIndex
            ) {
                articles.append(metadata)
                articleIndex += 1
            }
            currentArticle = nil

        default:
            break
        }

        currentArticle = article
    }
}

/// Builder for constructing ArticleMetadata from XML.
private struct ArticleBuilder {
    var pmid: String = ""
    var title: String = ""
    var abstractParts: [String] = []
    var authors: [String] = []
    var journal: String = ""
    var publicationDate: String?
    var year: Int?
    var doi: String?
    var pmcId: String?
    var meshTerms: [String] = []

    // Temporary state for parsing
    var currentAuthorLastName: String = ""
    var currentAuthorForeName: String = ""

    func build(batchNumber: Int, resultPosition: Int) -> ArticleMetadata? {
        guard !pmid.isEmpty else { return nil }

        return ArticleMetadata(
            pmid: pmid,
            title: title,
            abstract: abstractParts.joined(separator: "\n\n"),
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

// MARK: - PubMed Filters

/// Pre-defined PubMed search filters for common use cases.
enum PubMedFilters {
    /// Filter to exclude non-clinical publication types.
    ///
    /// Excludes news, editorials, letters, comments, errata, and other non-research content
    /// that lacks substantive clinical evidence. This helps focus results on:
    /// - Clinical trials
    /// - Systematic reviews and meta-analyses
    /// - Observational studies
    /// - Case reports (minimal clinical evidence but sometimes useful)
    ///
    /// Publication types excluded:
    /// - News, Newspaper Article
    /// - Editorial, Comment, Letter
    /// - Published Erratum, Retracted Publication
    /// - Biography, Historical Article, Personal Narrative
    /// - Directory, Guideline (non-research)
    static let clinicalPublicationFilter = """
        NOT (News[pt] OR "Newspaper Article"[pt] OR Editorial[pt] OR Letter[pt] \
        OR Comment[pt] OR "Published Erratum"[pt] OR Biography[pt] \
        OR "Historical Article"[pt] OR "Personal Narrative"[pt] \
        OR Directory[pt] OR "Retracted Publication"[pt])
        """

    /// Filter for high-quality evidence only (RCTs, systematic reviews, meta-analyses).
    static let highQualityEvidenceFilter = """
        (Randomized Controlled Trial[pt] OR "Systematic Review"[pt] \
        OR "Meta-Analysis"[pt] OR "Clinical Trial"[pt])
        """
}

// MARK: - Errors

enum PubMedError: LocalizedError {
    case searchFailed
    case fetchFailed
    case xmlParseError(String)
    case noResults

    var errorDescription: String? {
        switch self {
        case .searchFailed:
            return "PubMed search failed"
        case .fetchFailed:
            return "Failed to fetch article details"
        case .xmlParseError(let reason):
            return "Failed to parse PubMed response: \(reason)"
        case .noResults:
            return "No results found for this search"
        }
    }
}
