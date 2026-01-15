# Phase 3: Search Provider Abstraction & Europe PMC Service

This document details the implementation of the search provider abstraction layer and the Europe PMC search service.

---

## Goals

1. Create `SearchProvider` enum for provider selection
2. Create `EuropePMCService` actor for Europe PMC API
3. Define common `SearchResult` and `ArticleMetadata` protocols
4. Extend `AppSettings` with search provider preferences
5. Maintain backward compatibility with existing `PubMedService`

---

## 1. Search Provider Enum

### File: `Sources/Models/SearchProvider.swift` (new file)

```swift
//
//  SearchProvider.swift
//  MedicalFactChecker
//
//  Enum representing available literature search providers.
//

import Foundation

/// Available search providers for literature searches.
enum SearchProvider: String, CaseIterable, Codable, Identifiable {
    case pubmed = "pubmed"
    case europePMC = "europepmc"
    case both = "both"

    var id: String { rawValue }

    /// Human-readable display name.
    var displayName: String {
        switch self {
        case .pubmed: return "PubMed"
        case .europePMC: return "Europe PMC"
        case .both: return "Both (merged)"
        }
    }

    /// Short description for settings UI.
    var description: String {
        switch self {
        case .pubmed:
            return "NCBI's biomedical literature database"
        case .europePMC:
            return "Europe PMC with preprints from 34 servers"
        case .both:
            return "Search both and merge results"
        }
    }

    /// Icon for the provider.
    var iconName: String {
        switch self {
        case .pubmed: return "building.columns"
        case .europePMC: return "globe.europe.africa"
        case .both: return "rectangle.on.rectangle"
        }
    }

    /// Whether this provider supports preprint filtering.
    var supportsPreprints: Bool {
        switch self {
        case .pubmed: return false
        case .europePMC, .both: return true
        }
    }

    /// Whether an API key is required (or recommended).
    var requiresAPIKey: Bool {
        switch self {
        case .pubmed: return false  // Recommended but not required
        case .europePMC: return false
        case .both: return false
        }
    }

    /// Base URL for the provider API.
    var baseURL: String {
        switch self {
        case .pubmed:
            return "https://eutils.ncbi.nlm.nih.gov/entrez/eutils"
        case .europePMC:
            return "https://www.ebi.ac.uk/europepmc/webservices/rest"
        case .both:
            return ""  // Uses both base URLs
        }
    }
}

/// Options for search configuration.
struct SearchOptions {
    /// The search provider(s) to use.
    var provider: SearchProvider = .pubmed

    /// Whether to include preprints (Europe PMC only).
    var includePreprints: Bool = false

    /// Maximum results per provider.
    var maxResults: Int = 20

    /// Starting offset for pagination.
    var offset: Int = 0
}
```

---

## 2. Europe PMC Service

### File: `Sources/Services/EuropePMCService.swift` (new file)

```swift
//
//  EuropePMCService.swift
//  MedicalFactChecker
//
//  Europe PMC REST API client for literature search.
//

import Foundation

/// Service for searching Europe PMC literature database.
///
/// Europe PMC provides access to:
/// - PubMed abstracts (mirrored)
/// - Full-text articles
/// - Preprints from 34 servers (bioRxiv, medRxiv, etc.)
/// - Patents and other sources
actor EuropePMCService {
    // MARK: - Configuration

    private let baseURL = "https://www.ebi.ac.uk/europepmc/webservices/rest"
    private let session: URLSession

    // MARK: - Initialization

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    /// Create service (no settings needed - no auth required).
    static func create() -> EuropePMCService {
        return EuropePMCService()
    }

    // MARK: - Search

    /// Search Europe PMC with a query string.
    ///
    /// - Parameters:
    ///   - query: Europe PMC query string (or plain text).
    ///   - maxResults: Maximum results to return.
    ///   - offset: Starting position for pagination.
    ///   - includePreprints: Whether to include preprints.
    /// - Returns: Search result with article metadata.
    /// - Throws: `EuropePMCError` if the request fails.
    func search(
        query: String,
        maxResults: Int = 20,
        offset: Int = 0,
        includePreprints: Bool = false
    ) async throws -> EuropePMCSearchResult {
        // Build query with source filtering
        var finalQuery = query

        // Add source filter if not including preprints
        if !includePreprints {
            // Exclude preprint sources
            finalQuery += " NOT SRC:PPR"
        }

        // Add abstract requirement
        if !finalQuery.contains("HAS_ABSTRACT") {
            finalQuery += " AND HAS_ABSTRACT:Y"
        }

        var components = URLComponents(string: "\(baseURL)/search")!
        components.queryItems = [
            URLQueryItem(name: "query", value: finalQuery),
            URLQueryItem(name: "resultType", value: "core"),
            URLQueryItem(name: "pageSize", value: String(maxResults)),
            URLQueryItem(name: "cursorMark", value: offset == 0 ? "*" : String(offset)),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "sort", value: "RELEVANCE desc"),
        ]

        let request = URLRequest(url: components.url!)
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw EuropePMCError.searchFailed
        }

        return try parseSearchResponse(data, offset: offset)
    }

    // MARK: - Response Parsing

    private func parseSearchResponse(_ data: Data, offset: Int) throws -> EuropePMCSearchResult {
        let decoder = JSONDecoder()
        let response = try decoder.decode(EPMCSearchResponse.self, from: data)

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
                isPreprint: result.source == "PPR",
                resultPosition: offset + index
            )
        }

        return EuropePMCSearchResult(
            articles: articles,
            totalCount: Int(response.hitCount) ?? 0,
            offset: offset,
            nextCursorMark: response.nextCursorMark
        )
    }

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

    private func parseYear(_ pubYear: String?) -> Int? {
        guard let yearString = pubYear else { return nil }
        return Int(yearString)
    }
}

// MARK: - Response Types

struct EuropePMCSearchResult {
    let articles: [EuropePMCArticle]
    let totalCount: Int
    let offset: Int
    let nextCursorMark: String?

    var hasMore: Bool {
        offset + articles.count < totalCount
    }

    var nextOffset: Int {
        offset + articles.count
    }
}

struct EuropePMCArticle {
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

private struct EPMCSearchResponse: Codable {
    let hitCount: String
    let nextCursorMark: String?
    let resultList: EPMCResultList
}

private struct EPMCResultList: Codable {
    let result: [EPMCResult]
}

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

private struct EPMCAuthorList: Codable {
    let author: [EPMCAuthor]?
}

private struct EPMCAuthor: Codable {
    let fullName: String?
    let firstName: String?
    let lastName: String?
}

// MARK: - Errors

enum EuropePMCError: LocalizedError {
    case searchFailed
    case noResults
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .searchFailed:
            return "Europe PMC search failed"
        case .noResults:
            return "No results found"
        case .parseError(let reason):
            return "Failed to parse response: \(reason)"
        }
    }
}
```

---

## 3. App Settings Extension

### File: `Sources/Models/AppSettings.swift` (modify)

Add search provider settings:

```swift
// MARK: - Search Provider Settings

/// Selected search provider.
var selectedSearchProvider: SearchProvider {
    get {
        if let stored = UserDefaults.standard.string(forKey: "selectedSearchProvider"),
           let provider = SearchProvider(rawValue: stored) {
            return provider
        }
        return .pubmed  // Default
    }
    set {
        UserDefaults.standard.set(newValue.rawValue, forKey: "selectedSearchProvider")
    }
}

/// Whether to include preprints when using Europe PMC.
var includePreprints: Bool {
    get { UserDefaults.standard.bool(forKey: "includePreprints") }
    set { UserDefaults.standard.set(newValue, forKey: "includePreprints") }
}

/// Build SearchOptions from current settings.
func buildSearchOptions(overrideProvider: SearchProvider? = nil) -> SearchOptions {
    SearchOptions(
        provider: overrideProvider ?? selectedSearchProvider,
        includePreprints: includePreprints,
        maxResults: batchSize,
        offset: 0
    )
}
```

---

## 4. Unified Search Result Protocol

### File: `Sources/Services/SearchServiceProtocol.swift` (new file)

```swift
//
//  SearchServiceProtocol.swift
//  MedicalFactChecker
//
//  Protocol for unified search service interface.
//

import Foundation

/// Unified search result that works with any provider.
struct UnifiedSearchResult {
    let articles: [ArticleMetadata]
    let totalCount: Int
    let offset: Int
    let provider: SearchProvider

    var hasMore: Bool {
        offset + articles.count < totalCount
    }

    var nextOffset: Int {
        offset + articles.count
    }
}

/// Factory for creating search services based on provider.
enum SearchServiceFactory {
    /// Execute a search using the specified options.
    ///
    /// - Parameters:
    ///   - query: The search query string.
    ///   - options: Search configuration options.
    ///   - settings: App settings for service configuration.
    /// - Returns: Unified search result.
    static func search(
        query: String,
        options: SearchOptions,
        settings: AppSettings
    ) async throws -> UnifiedSearchResult {
        switch options.provider {
        case .pubmed:
            return try await searchPubMed(query: query, options: options, settings: settings)

        case .europePMC:
            return try await searchEuropePMC(query: query, options: options)

        case .both:
            return try await searchBoth(query: query, options: options, settings: settings)
        }
    }

    // MARK: - Provider-Specific Search

    private static func searchPubMed(
        query: String,
        options: SearchOptions,
        settings: AppSettings
    ) async throws -> UnifiedSearchResult {
        let service = PubMedService.create(from: settings)
        let result = try await service.search(
            query: query,
            maxResults: options.maxResults,
            offset: options.offset
        )

        let articles = try await service.fetchArticles(
            pmids: result.pmids,
            batchNumber: 1,
            basePosition: options.offset
        )

        return UnifiedSearchResult(
            articles: articles,
            totalCount: result.totalCount,
            offset: options.offset,
            provider: .pubmed
        )
    }

    private static func searchEuropePMC(
        query: String,
        options: SearchOptions
    ) async throws -> UnifiedSearchResult {
        let service = EuropePMCService.create()

        // Translate query if it looks like PubMed syntax
        let translatedQuery = QueryTranslator.pubmedToEuropePMC(query)

        let result = try await service.search(
            query: translatedQuery,
            maxResults: options.maxResults,
            offset: options.offset,
            includePreprints: options.includePreprints
        )

        let articles = result.articles.map { $0.toArticleMetadata(batchNumber: 1) }

        return UnifiedSearchResult(
            articles: articles,
            totalCount: result.totalCount,
            offset: options.offset,
            provider: .europePMC
        )
    }

    private static func searchBoth(
        query: String,
        options: SearchOptions,
        settings: AppSettings
    ) async throws -> UnifiedSearchResult {
        // Search both providers concurrently
        async let pubmedResult = searchPubMed(
            query: query,
            options: SearchOptions(
                provider: .pubmed,
                includePreprints: false,
                maxResults: options.maxResults,
                offset: options.offset
            ),
            settings: settings
        )

        async let europePMCResult = searchEuropePMC(
            query: query,
            options: SearchOptions(
                provider: .europePMC,
                includePreprints: options.includePreprints,
                maxResults: options.maxResults,
                offset: options.offset
            )
        )

        // Await both results
        let (pubmed, europePMC) = try await (pubmedResult, europePMCResult)

        // Merge and deduplicate
        let merged = SearchResultMerger.merge(
            pubmedResult: pubmed,
            europePMCResult: europePMC
        )

        return merged
    }
}
```

---

## 5. Search Result Merger

### File: `Sources/Utilities/SearchResultMerger.swift` (new file)

```swift
//
//  SearchResultMerger.swift
//  MedicalFactChecker
//
//  Utility for merging search results from multiple providers.
//

import Foundation

/// Merges and deduplicates search results from multiple providers.
enum SearchResultMerger {
    /// Merge results from PubMed and Europe PMC, removing duplicates.
    ///
    /// Deduplication priority: PMID > DOI > Title similarity
    ///
    /// - Parameters:
    ///   - pubmedResult: Results from PubMed.
    ///   - europePMCResult: Results from Europe PMC.
    /// - Returns: Merged, deduplicated result.
    static func merge(
        pubmedResult: UnifiedSearchResult,
        europePMCResult: UnifiedSearchResult
    ) -> UnifiedSearchResult {
        var seen = Set<String>()  // Track seen identifiers
        var merged: [ArticleMetadata] = []

        // Add PubMed results first (primary source)
        for article in pubmedResult.articles {
            let key = deduplicationKey(for: article)
            if !seen.contains(key) {
                seen.insert(key)
                merged.append(article)
            }
        }

        // Add unique Europe PMC results
        for article in europePMCResult.articles {
            let key = deduplicationKey(for: article)
            if !seen.contains(key) {
                seen.insert(key)
                merged.append(article)
            }
        }

        // Sort by relevance (original position is a proxy)
        let sorted = merged.sorted { $0.resultPosition < $1.resultPosition }

        // Estimate total (may have duplicates we removed)
        let estimatedTotal = pubmedResult.totalCount + europePMCResult.totalCount

        return UnifiedSearchResult(
            articles: sorted,
            totalCount: estimatedTotal,
            offset: pubmedResult.offset,
            provider: .both
        )
    }

    /// Generate a unique key for deduplication.
    private static func deduplicationKey(for article: ArticleMetadata) -> String {
        // Prefer PMID (most reliable)
        if !article.pmid.isEmpty {
            return "pmid:\(article.pmid)"
        }

        // Fall back to DOI
        if let doi = article.doi, !doi.isEmpty {
            return "doi:\(doi.lowercased())"
        }

        // Last resort: normalized title
        let normalizedTitle = article.title
            .lowercased()
            .components(separatedBy: .alphanumerics.inverted)
            .joined()
        return "title:\(normalizedTitle)"
    }

    /// Check if two articles are likely duplicates.
    static func areDuplicates(_ a: ArticleMetadata, _ b: ArticleMetadata) -> Bool {
        // Same PMID
        if !a.pmid.isEmpty && a.pmid == b.pmid {
            return true
        }

        // Same DOI
        if let doiA = a.doi, let doiB = b.doi,
           !doiA.isEmpty && doiA.lowercased() == doiB.lowercased() {
            return true
        }

        // Similar title (Jaccard similarity > 0.8)
        let similarity = titleSimilarity(a.title, b.title)
        return similarity > 0.8
    }

    /// Calculate Jaccard similarity between two titles.
    private static func titleSimilarity(_ a: String, _ b: String) -> Double {
        let wordsA = Set(a.lowercased().components(separatedBy: .alphanumerics.inverted).filter { !$0.isEmpty })
        let wordsB = Set(b.lowercased().components(separatedBy: .alphanumerics.inverted).filter { !$0.isEmpty })

        guard !wordsA.isEmpty && !wordsB.isEmpty else { return 0 }

        let intersection = wordsA.intersection(wordsB).count
        let union = wordsA.union(wordsB).count

        return Double(intersection) / Double(union)
    }
}
```

---

## 6. Integration with FactCheckWorkflow

### Modifications to `FactCheckWorkflow.swift`

```swift
// Replace direct PubMedService usage with SearchServiceFactory

private func searchPubMed() async throws {
    guard let session = session,
          let query = session.pubmedQuery else { return }

    let batchNumber = session.batchesFetched + 1
    updateProgress(.searchingPubMed, "Searching (batch \(batchNumber))...")

    // Build search options from settings
    var options = settings.buildSearchOptions()
    options.offset = session.currentSearchOffset
    options.maxResults = settings.batchSize

    // Use unified search factory
    let result = try await SearchServiceFactory.search(
        query: query,
        options: options,
        settings: settings
    )

    // Update session state
    session.totalPubMedResults = result.totalCount
    session.currentSearchOffset = result.nextOffset
    session.batchesFetched = batchNumber

    if result.articles.isEmpty {
        if session.documents.isEmpty {
            throw PubMedError.noResults
        }
        return
    }

    // Create Document objects from ArticleMetadata
    for article in result.articles {
        let document = Document(
            pmid: article.pmid,
            title: article.title,
            abstract: article.abstract,
            authors: article.authors,
            batchNumber: article.batchNumber,
            resultPosition: article.resultPosition
        )
        document.year = article.year
        document.journal = article.journal
        document.doi = article.doi
        document.pmcId = article.pmcId
        document.meshTerms = article.meshTerms
        document.publicationDate = article.publicationDate
        document.session = session

        modelContext.insert(document)
    }

    session.documentsFound += result.articles.count
    try? modelContext.save()
}
```

---

## 7. Testing Checklist

### Unit Tests

- [ ] `SearchProvider` enum values and properties
- [ ] `EuropePMCService.search` returns valid results
- [ ] `SearchResultMerger.merge` correctly deduplicates
- [ ] `SearchResultMerger.areDuplicates` identifies matches
- [ ] `SearchServiceFactory` routes to correct provider
- [ ] AppSettings search provider persistence

### Integration Tests

- [ ] Europe PMC search returns articles
- [ ] Europe PMC preprint filter works
- [ ] Merged search returns combined results
- [ ] Deduplication removes actual duplicates
- [ ] FactCheckWorkflow uses selected provider

### Test Queries

```swift
// Europe PMC test queries
"diabetes AND metformin"
"COVID-19 vaccine efficacy"
"(cancer) AND (immunotherapy)"

// Preprint test
"SRC:PPR AND COVID-19"  // Should return preprints
```

---

## 8. Files to Create/Modify

### New Files
- `Sources/Models/SearchProvider.swift`
- `Sources/Services/EuropePMCService.swift`
- `Sources/Services/SearchServiceProtocol.swift`
- `Sources/Utilities/SearchResultMerger.swift`

### Modified Files
- `Sources/Models/AppSettings.swift` (add search provider settings)
- `Sources/Services/FactCheckWorkflow.swift` (use SearchServiceFactory)

---

## 9. Estimated Effort

| Task | Complexity | Notes |
|------|------------|-------|
| SearchProvider enum | Low | Simple enum with metadata |
| EuropePMCService | Medium | New API integration |
| SearchServiceFactory | Medium | Routing and coordination |
| SearchResultMerger | Medium | Deduplication logic |
| AppSettings extension | Low | Simple properties |
| Workflow integration | Medium | Refactoring existing code |

**Total estimated complexity: High** (due to scope)

---

## Next Phase

After completing this phase, proceed to **Phase 4: Query Translator** (`04-query-translator.md`) to implement query syntax translation between providers.
