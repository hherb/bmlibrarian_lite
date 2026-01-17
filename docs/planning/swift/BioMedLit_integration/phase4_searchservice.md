# Phase 4: SearchServiceFactory Updates

## Objective

Update the iOS `SearchServiceFactory` to support cursor-based pagination for Europe PMC and improve the unified search result handling.

## Files to Modify

- `ios/MedicalFactChecker/Sources/Services/SearchServiceProtocol.swift`

## Current iOS State

The iOS `SearchServiceFactory` has:
- Basic `search()` function that routes to providers
- `UnifiedSearchResult` with `nextCursorMark` support
- `SearchOptions` with `cursorMark` property

**iOS already has these utilities (no need to create):**
- `QueryTranslator.swift` - Query syntax translation
- `QueryValidator.swift` - Query validation
- `SearchResultMerger.swift` - Result merging for "both" provider
- `BioMedLitAdapters.swift` - Type conversion utilities

Check if `QueryTranslator` already has `isEuropePMCSyntax()` and `isPubMedSyntax()` methods before adding them.

## Changes Required

### 1. Update SearchServiceFactory.search() Signature

Add an optional `cursor` parameter for Europe PMC pagination:

```swift
/// Execute a search using the specified options.
///
/// - Parameters:
///   - query: The search query string (in PubMed or plain text syntax).
///   - options: Search configuration options.
///   - settings: App settings for service configuration.
///   - cursor: Optional cursor for Europe PMC pagination. Pass nil for initial search.
/// - Returns: Unified search result with articles and pagination.
/// - Throws: Provider-specific errors if search fails.
static func search(
    query: String,
    options: SearchOptions,
    settings: AppSettings,
    cursor: String? = nil
) async throws -> UnifiedSearchResult
```

### 2. Update searchEuropePMC to Use Cursor Parameter

The macOS version handles cursor more explicitly:

```swift
/// Search Europe PMC with the given query and options.
private static func searchEuropePMC(
    query: String,
    options: SearchOptions,
    cursor: String? = nil
) async throws -> UnifiedSearchResult {
    let service = BMLEuropePMCService.create()

    // Check if query is already in Europe PMC syntax
    let translatedQuery: String
    if QueryTranslator.isEuropePMCSyntax(query) {
        // Already in Europe PMC format (from EuropePMCQueryBuilder)
        translatedQuery = query
    } else if QueryTranslator.isPubMedSyntax(query) {
        // Legacy: translate from PubMed syntax (for resumed sessions)
        translatedQuery = QueryTranslator.pubmedToEuropePMC(query)

        // Log translation warnings
        let validation = QueryValidator.validateEuropePMCQuery(translatedQuery)
        if !validation.warnings.isEmpty {
            print("[Search] Query translation warnings: \(validation.warnings)")
        }
    } else {
        // Plain text query - use as-is
        translatedQuery = query
    }

    // Use provided cursor or "*" for initial request
    let searchCursor = cursor ?? "*"
    print("[Search] Europe PMC search with cursor: \(searchCursor == "*" ? "initial" : String(searchCursor.prefix(20)))")

    let result = try await service.search(
        query: translatedQuery,
        pageSize: options.maxResults,
        cursor: searchCursor,
        includePreprints: options.includePreprints
    )

    // Convert BioMedLit articles to unified format
    let batchNumber = calculateBatchNumber(offset: options.offset, batchSize: options.maxResults)
    let articles = BioMedLitAdapters.toArticleMetadataArray(
        result,
        batchNumber: batchNumber,
        basePosition: options.offset
    )

    // Only include nextCursorMark if there are actually more results
    let hasMore = result.nextCursor != nil && !result.articles.isEmpty
    return UnifiedSearchResult(
        articles: articles,
        totalCount: result.totalCount,
        offset: 0,  // Offset not used for cursor-based pagination
        provider: .europePMC,
        nextCursorMark: hasMore ? result.nextCursor : nil
    )
}
```

### 3. Update searchBoth to Pass Cursor

```swift
private static func searchBoth(
    query: String,
    options: SearchOptions,
    settings: AppSettings,
    cursor: String? = nil
) async throws -> UnifiedSearchResult {
    // Search both providers concurrently
    async let pubmedResult = searchPubMed(
        query: query,
        options: SearchOptions(
            provider: .pubmed,
            includePreprints: false,
            maxResults: options.maxResults,
            offset: options.offset,
            cursorMark: nil
        ),
        settings: settings
    )

    async let europePMCResult = searchEuropePMC(
        query: query,
        options: SearchOptions(
            provider: .europePMC,
            includePreprints: options.includePreprints,
            maxResults: options.maxResults,
            offset: 0,
            cursorMark: nil
        ),
        cursor: cursor  // Pass cursor for Europe PMC
    )

    // ... rest of merging logic
}
```

### 4. Add Helper Function for Batch Calculation

```swift
/// Calculate batch number from offset and batch size.
private static func calculateBatchNumber(offset: Int, batchSize: Int) -> Int {
    guard batchSize > 0 else { return 1 }
    return (offset / batchSize) + 1
}
```

### 5. Update UnifiedSearchResult (if needed)

The macOS version has additional pagination tracking. Ensure these properties exist:

```swift
struct UnifiedSearchResult: Sendable {
    let articles: [ArticleMetadata]
    let totalCount: Int
    let offset: Int
    let provider: SearchProvider

    /// Cursor mark for next page (Europe PMC only).
    let nextCursorMark: String?

    /// Pagination state for complex pagination scenarios.
    /// Used when resuming multi-provider searches.
    var pagination: Any?  // Optional, for CursorPaginationState

    /// Check if more results are available.
    var hasMore: Bool {
        if provider == .europePMC {
            return nextCursorMark != nil && !articles.isEmpty
        }
        return offset + articles.count < totalCount
    }

    /// Next offset for PubMed pagination.
    var nextOffset: Int {
        offset + articles.count
    }
}
```

### 6. Add Query Syntax Detection to QueryTranslator

If not already present, add these helper methods to `QueryTranslator`:

```swift
/// Check if a query appears to be in Europe PMC syntax.
static func isEuropePMCSyntax(_ query: String) -> Bool {
    // Europe PMC uses field:value syntax like TITLE_ABS:, HAS_ABSTRACT:y, SRC:
    let europePMCPatterns = ["TITLE_ABS:", "HAS_ABSTRACT:", "SRC:", "AUTH:", "JOURNAL:"]
    return europePMCPatterns.contains { query.contains($0) }
}

/// Check if a query appears to be in PubMed syntax.
static func isPubMedSyntax(_ query: String) -> Bool {
    // PubMed uses [field] syntax like [MeSH], [tiab], [pt]
    let pubmedPatterns = ["[MeSH]", "[tiab]", "[pt]", "[Title]", "[Abstract]", "hasabstract"]
    return pubmedPatterns.contains { query.contains($0) }
}
```

## Routing Updates

Update the main `search()` switch to pass cursor:

```swift
static func search(
    query: String,
    options: SearchOptions,
    settings: AppSettings,
    cursor: String? = nil
) async throws -> UnifiedSearchResult {
    switch options.provider {
    case .pubmed:
        return try await searchPubMed(query: query, options: options, settings: settings)

    case .europePMC:
        return try await searchEuropePMC(query: query, options: options, cursor: cursor)

    case .both:
        return try await searchBoth(query: query, options: options, settings: settings, cursor: cursor)
    }
}
```

## Validation Steps

1. Build iOS project - no compilation errors
2. Test PubMed search (offset pagination should work unchanged)
3. Test Europe PMC search:
   - Initial search with cursor = nil -> returns results + nextCursorMark
   - Second search with returned cursor -> returns next page
   - Final search returns nil cursor when exhausted
4. Test "both" provider mode with cursor support

## Reference Files

- macOS version: `macos/MedicalFactCheckerMac/Sources/Services/SearchServiceFactory.swift` (full file)
- macOS QueryTranslator: `macos/MedicalFactCheckerMac/Sources/Utilities/QueryTranslator.swift`
