# Phase 3: Search Provider Abstraction & Europe PMC Service (macOS)

This document details the implementation of the search provider abstraction layer and the Europe PMC search service for the macOS app.

> **Note:** This phase consists primarily of shared code with the iOS implementation. See `../03-search-provider-abstraction.md` for the complete implementation details. This document highlights macOS-specific considerations only.

---

## Goals

1. Create `SearchProvider` enum for provider selection (shared)
2. Create `EuropePMCService` actor for Europe PMC API (shared)
3. Define common `SearchResult` and `ArticleMetadata` protocols (shared)
4. Extend `AppSettings` with search provider preferences (shared)
5. Maintain backward compatibility with existing `PubMedService` (shared)

---

## Shared Code Files

The following files are identical to the iOS implementation and should be created in the macOS project:

### 1. Search Provider Enum

**File:** `Sources/Models/SearchProvider.swift` (new file)

See `../03-search-provider-abstraction.md` for complete implementation.

```swift
/// Available search providers for literature searches.
enum SearchProvider: String, CaseIterable, Codable, Identifiable {
    case pubmed = "pubmed"
    case europePMC = "europepmc"
    case both = "both"

    // Properties: displayName, description, iconName, supportsPreprints, etc.
}

/// Options for search configuration.
struct SearchOptions {
    var provider: SearchProvider = .pubmed
    var includePreprints: Bool = false
    var maxResults: Int = 20
    var offset: Int = 0
}
```

### 2. Europe PMC Service

**File:** `Sources/Services/EuropePMCService.swift` (new file)

See `../03-search-provider-abstraction.md` for complete implementation.

```swift
/// Service for searching Europe PMC literature database.
actor EuropePMCService {
    // Search method, response parsing, etc.
}

struct EuropePMCSearchResult { ... }
struct EuropePMCArticle { ... }
enum EuropePMCError: LocalizedError { ... }
```

### 3. Unified Search Protocol

**File:** `Sources/Services/SearchServiceProtocol.swift` (new file)

See `../03-search-provider-abstraction.md` for complete implementation.

```swift
/// Unified search result that works with any provider.
struct UnifiedSearchResult { ... }

/// Factory for creating search services based on provider.
enum SearchServiceFactory {
    static func search(...) async throws -> UnifiedSearchResult
}
```

### 4. Search Result Merger

**File:** `Sources/Utilities/SearchResultMerger.swift` (new file)

See `../03-search-provider-abstraction.md` for complete implementation.

```swift
/// Merges and deduplicates search results from multiple providers.
enum SearchResultMerger {
    static func merge(...) -> UnifiedSearchResult
}
```

---

## macOS-Specific Considerations

### AppSettings Extension

The settings extension is shared, but macOS uses the native Settings scene:

**File:** `Sources/Models/AppSettings.swift` (modify)

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

### Network Configuration

macOS apps may benefit from different network settings:

```swift
extension EuropePMCService {
    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 45  // Longer for desktop
        config.timeoutIntervalForResource = 90
        config.waitsForConnectivity = true
        config.httpMaximumConnectionsPerHost = 4  // Allow more connections
        self.session = URLSession(configuration: config)
    }
}
```

### Concurrent Search Optimization

macOS can handle more concurrent requests:

```swift
extension SearchServiceFactory {
    private static func searchBoth(
        query: String,
        options: SearchOptions,
        settings: AppSettings
    ) async throws -> UnifiedSearchResult {
        // Use TaskGroup for better concurrency control on macOS
        return try await withThrowingTaskGroup(of: UnifiedSearchResult.self) { group in
            group.addTask {
                try await searchPubMed(query: query, options: options, settings: settings)
            }
            group.addTask {
                try await searchEuropePMC(query: query, options: options)
            }

            var results: [UnifiedSearchResult] = []
            for try await result in group {
                results.append(result)
            }

            guard results.count == 2 else {
                throw SearchError.partialFailure
            }

            return SearchResultMerger.merge(
                pubmedResult: results[0],
                europePMCResult: results[1]
            )
        }
    }
}
```

---

## FactCheckWorkflow Integration

### File: `Sources/Services/FactCheckWorkflow.swift` (modify)

Update the workflow to use the search factory:

```swift
// Add searchOptions property
private var searchOptions: SearchOptions?

/// Start a new fact-check with specific search options.
func startFactCheck(claim: String, searchOptions: SearchOptions) async {
    self.searchOptions = searchOptions

    // Store selected provider in session
    session?.searchProvider = searchOptions.provider.rawValue
    session?.includePreprints = searchOptions.includePreprints

    await runWorkflow()
}

private func searchDocuments() async throws {
    guard let session = session,
          let query = session.pubmedQuery else { return }

    let options = searchOptions ?? settings.buildSearchOptions()
    var searchOpts = options
    searchOpts.offset = session.currentSearchOffset
    searchOpts.maxResults = settings.batchSize

    let providerName = options.provider.displayName
    updateProgress(.searchingPubMed, "Searching \(providerName)...")

    let result = try await SearchServiceFactory.search(
        query: query,
        options: searchOpts,
        settings: settings
    )

    // Update session state
    session.totalPubMedResults = result.totalCount
    session.currentSearchOffset = result.nextOffset

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

## Session Model Extension

### File: `Sources/Models/FactCheckSession.swift` (modify)

Add provider tracking:

```swift
// MARK: - Search Provider Tracking

/// The search provider used for this session.
var searchProvider: String?

/// Whether preprints were included in the search.
var includePreprints: Bool = false

/// Track pagination per provider (for "Both" mode).
var pubmedOffset: Int = 0
var europePMCOffset: Int = 0
var pubmedHasMore: Bool = true
var europePMCHasMore: Bool = true

/// Whether more documents can be fetched.
var canFetchMoreFromAnyProvider: Bool {
    guard let providerString = searchProvider,
          let provider = SearchProvider(rawValue: providerString) else {
        return canFetchMoreDocuments
    }

    switch provider {
    case .pubmed:
        return pubmedHasMore
    case .europePMC:
        return europePMCHasMore
    case .both:
        return pubmedHasMore || europePMCHasMore
    }
}
```

---

## Testing Checklist

### Unit Tests (Shared with iOS)

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

### macOS-Specific Tests

- [ ] Concurrent search performs well
- [ ] Network timeouts are appropriate
- [ ] Session stores/restores provider selection

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

## Files to Create/Modify

### New Files

- `Sources/Models/SearchProvider.swift`
- `Sources/Services/EuropePMCService.swift`
- `Sources/Services/SearchServiceProtocol.swift`
- `Sources/Utilities/SearchResultMerger.swift`

### Modified Files

- `Sources/Models/AppSettings.swift` (add search provider settings)
- `Sources/Models/FactCheckSession.swift` (add provider tracking)
- `Sources/Services/FactCheckWorkflow.swift` (use SearchServiceFactory)

---

## Estimated Effort

| Task | Complexity | Notes |
|------|------------|-------|
| SearchProvider enum | Low | Simple enum with metadata |
| EuropePMCService | Medium | New API integration |
| SearchServiceFactory | Medium | Routing and coordination |
| SearchResultMerger | Medium | Deduplication logic |
| AppSettings extension | Low | Simple properties |
| Session model extension | Low | Tracking properties |
| Workflow integration | Medium | Refactoring existing code |

**Total estimated complexity: High** (due to scope)

---

## Next Phase

After completing this phase, proceed to **Phase 4: Query Translator** (`04-query-translator.md`) to implement query syntax translation between providers (shared code with iOS).
