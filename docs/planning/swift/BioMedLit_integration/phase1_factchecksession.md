# Phase 1: FactCheckSession Model Updates

## Objective

Align the iOS `FactCheckSession` model with the macOS version to support multi-provider pagination with cursor-based Europe PMC support and improved state tracking.

## Files to Modify

- `ios/MedicalFactChecker/Sources/Models/FactCheckSession.swift`

## Current iOS State

The iOS `FactCheckSession` has:
- `searchProviderRaw: String?` - provider stored as raw string
- `searchProvider: SearchProvider?` - computed getter/setter wrapping `searchProviderRaw`
- `totalEuropePMCResults: Int` - total results count
- `europePMCCursorMark: String?` - cursor for pagination
- `includedPreprints: Bool` - typo in naming (should be `includePreprints`)

## Target State (Match macOS)

The macOS version uses a simpler pattern: store `searchProvider` directly as a `String?` instead of using a raw/computed property pair.

### Properties to Add

```swift
// MARK: - Search Provider State

/// Pagination offset for PubMed when using "both" provider.
var pubmedOffset: Int = 0

/// Pagination offset for Europe PMC when using "both" provider.
var europePMCOffset: Int = 0

/// Whether more results are available from PubMed.
var pubmedHasMore: Bool = true

/// Whether more results are available from Europe PMC.
var europePMCHasMore: Bool = true
```

### Properties to Rename (with Compatibility)

Due to SwiftData persistence, property renames require careful handling:

**Option A: Keep both (recommended for backwards compatibility)**
```swift
// Keep existing properties, add new ones
var searchProviderRaw: String?      // Keep for existing data
var europePMCCursorMark: String?    // Keep for existing data
var includedPreprints: Bool = false // Keep for existing data

// Add computed aliases that use the old storage
var searchProviderString: String? { searchProviderRaw }
var europePMCCursor: String? { europePMCCursorMark }
var includePreprints: Bool { includedPreprints }
```

**Option B: Rename with migration (cleaner but requires migration)**
```swift
// Rename stored properties (requires SwiftData schema migration)
var searchProvider: String?      // was searchProviderRaw
var europePMCCursor: String?     // was europePMCCursorMark
var includePreprints: Bool = false  // was includedPreprints
```

### Computed Properties to Update

Update `canFetchMoreFromAnyProvider` to use the hasMore flags:

```swift
/// Check if more documents can be fetched from the current provider.
var canFetchMoreDocuments: Bool {
    canFetchMoreFromAnyProvider
}

/// Check if more documents can be fetched from any active provider.
var canFetchMoreFromAnyProvider: Bool {
    // Use searchProviderRaw (or searchProvider if renamed)
    guard let providerString = searchProviderRaw,
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
    guard let providerString = searchProviderRaw,
          let provider = SearchProvider(rawValue: providerString) else {
        return remainingPubMedResults
    }

    switch provider {
    case .pubmed:
        return pubmedHasMore ? remainingPubMedResults : 0
    case .europePMC:
        return europePMCHasMore ? 100 : 0
    case .both:
        return (pubmedHasMore ? remainingPubMedResults : 0) +
               (europePMCHasMore ? 100 : 0)
    }
}
```

### Keep Existing Computed Property

Keep the existing `searchProvider: SearchProvider?` computed property that wraps `searchProviderRaw` - this provides type-safe access while maintaining SwiftData compatibility.

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
