# Phase 1: FactCheckSession Model Updates

## Objective

Align the iOS `FactCheckSession` model with the macOS version to support multi-provider pagination with cursor-based Europe PMC support and improved state tracking.

## Files to Modify

- `ios/MedicalFactChecker/Sources/Models/FactCheckSession.swift`

## Current iOS State

The iOS `FactCheckSession` has:
- `searchProviderRaw: String?` - provider stored as raw string
- `totalEuropePMCResults: Int` - total results count
- `europePMCCursorMark: String?` - cursor for pagination
- `includedPreprints: Bool` - typo in naming

## Target State (Match macOS)

Add/rename these properties to match macOS:

### Properties to Add

```swift
// MARK: - Search Provider State

/// The search provider used for this session (stored as raw value).
/// Options: "pubmed", "europepmc", "both".
var searchProvider: String?  // NOTE: rename from searchProviderRaw

/// Whether preprints were included in the search.
var includePreprints: Bool = false  // NOTE: rename from includedPreprints

/// Pagination offset for PubMed when using "both" provider.
var pubmedOffset: Int = 0

/// Pagination offset for Europe PMC when using "both" provider.
var europePMCOffset: Int = 0

/// Cursor for Europe PMC pagination (cursor-based API).
var europePMCCursor: String?  // NOTE: rename from europePMCCursorMark

/// Whether more results are available from PubMed.
var pubmedHasMore: Bool = true

/// Whether more results are available from Europe PMC.
var europePMCHasMore: Bool = true
```

### Computed Properties to Update

Replace the existing computed properties with these macOS versions:

```swift
/// Check if more documents can be fetched from the current provider.
var canFetchMoreDocuments: Bool {
    canFetchMoreFromAnyProvider
}

/// Check if more documents can be fetched from any active provider.
var canFetchMoreFromAnyProvider: Bool {
    guard let providerString = searchProvider,
          let provider = SearchProvider(rawValue: providerString) else {
        // Fall back to legacy PubMed-only check
        return currentSearchOffset < totalPubMedResults
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

/// Estimated remaining results for the current provider.
var estimatedRemainingResults: Int {
    guard let providerString = searchProvider,
          let provider = SearchProvider(rawValue: providerString) else {
        // Legacy fallback for sessions without provider set
        return remainingPubMedResults
    }

    switch provider {
    case .pubmed:
        return pubmedHasMore ? remainingPubMedResults : 0
    case .europePMC:
        // Cursor-based pagination - estimate based on hasMore flag
        return europePMCHasMore ? 100 : 0
    case .both:
        return (pubmedHasMore ? remainingPubMedResults : 0) +
               (europePMCHasMore ? 100 : 0)
    }
}
```

### Properties to Remove

Remove the computed `searchProvider` getter/setter that wraps `searchProviderRaw`. Instead, store `searchProvider` directly as a String.

## Migration Considerations

### Property Renaming

Since SwiftData uses property names for persistence:
- `europePMCCursorMark` -> `europePMCCursor`: May need migration or alias
- `includedPreprints` -> `includePreprints`: May need migration or alias

**Recommendation**: Keep the old property names and add the new ones, then gradually deprecate. Or create a one-time migration.

### Backwards Compatibility

Existing sessions in the database should continue to work. The new hasMore flags default to `true`, which is safe because the workflow will naturally discover there are no more results.

## Validation Steps

1. Build iOS project - no compilation errors
2. Create new FactCheckSession - verify all properties accessible
3. Resume existing session - verify data loads correctly
4. Check `canFetchMoreDocuments` returns correct values for each provider type

## Reference Files

- macOS version: `macos/MedicalFactCheckerMac/Sources/Models/FactCheckSession.swift` (lines 73-220)
