# Phase 4: Query Syntax Translator (macOS)

This document details the implementation of the query syntax translator that converts between PubMed and Europe PMC query formats.

> **Note:** This phase consists entirely of shared code with the iOS implementation. See `../04-query-translator.md` for the complete implementation details. This document confirms the shared nature of this code and lists the files to create.

---

## Goals

1. Build PubMed → Europe PMC query translator (shared)
2. Build Europe PMC → PubMed translator (shared)
3. Handle all common query patterns (shared)
4. Preserve search intent during translation (shared)
5. Create comprehensive test suite (shared)

---

## Shared Code Files

The following files are identical to the iOS implementation:

### 1. Query Translator

**File:** `Sources/Utilities/QueryTranslator.swift` (new file)

See `../04-query-translator.md` for complete implementation.

Key functionality:
- `pubmedToEuropePMC(_:)` - Convert PubMed query to Europe PMC
- `europePMCToPubMed(_:)` - Convert Europe PMC query to PubMed
- MeSH term translation
- Field tag translation
- Date filter translation
- Special filter translation
- Query cleanup

### 2. Query Validator

**File:** `Sources/Utilities/QueryValidator.swift` (new file)

See `../04-query-translator.md` for complete implementation.

Key functionality:
- `validateEuropePMCQuery(_:)` - Validate Europe PMC query
- `validatePubMedQuery(_:)` - Validate PubMed query
- Detection of untranslated components
- Balanced parentheses/quotes checking

---

## Query Syntax Reference

### Field Tag Mapping

| Concept | PubMed Syntax | Europe PMC Syntax |
|---------|---------------|-------------------|
| MeSH term | `"Term"[MeSH]` | `MeSH_TERM:"Term"` |
| Title/Abstract | `term[tiab]` | `TITLE_ABS:term` |
| Title only | `term[ti]` | `TITLE:term` |
| Abstract only | `term[ab]` | `ABSTRACT:term` |
| Author | `"Name"[au]` | `AUTH:"Name"` |
| Journal | `"Journal"[ta]` | `JOURNAL:"Journal"` |
| Publication Year | `2020[dp]` | `PUB_YEAR:2020` |
| Date range | `2020:2024[dp]` | `PUB_YEAR:[2020 TO 2024]` |
| Has abstract | `hasabstract` | `HAS_ABSTRACT:Y` |
| Free full text | `free full text[sb]` | `OPEN_ACCESS:Y` |

### Example Translations

```
PubMed:
("Amlodipine"[MeSH] OR amlodipine[tiab]) AND ("Vascular Stiffness"[MeSH] OR "arterial stiffness"[tiab]) AND hasabstract

Europe PMC:
(MeSH_TERM:"Amlodipine" OR TITLE_ABS:amlodipine) AND (MeSH_TERM:"Vascular Stiffness" OR TITLE_ABS:"arterial stiffness") AND HAS_ABSTRACT:Y
```

---

## Unit Tests

### File: `Tests/QueryTranslatorTests.swift` (new file)

See `../04-query-translator.md` for complete test implementation.

Key test categories:
- MeSH term translation (both directions)
- Field tag translation
- Date range translation
- Special filter translation
- Round-trip translation
- Edge cases (empty queries, whitespace cleanup)
- Validation tests

---

## Integration with SearchServiceFactory

The translator is used automatically when searching Europe PMC:

```swift
// In SearchServiceFactory.searchEuropePMC():
private static func searchEuropePMC(
    query: String,
    options: SearchOptions
) async throws -> UnifiedSearchResult {
    let service = EuropePMCService.create()

    // Translate query from PubMed syntax if needed
    let translatedQuery = QueryTranslator.pubmedToEuropePMC(query)

    // Validate translation
    let validation = QueryValidator.validateEuropePMCQuery(translatedQuery)
    if !validation.warnings.isEmpty {
        print("[Search] Query translation warnings: \(validation.warnings)")
    }

    let result = try await service.search(
        query: translatedQuery,
        maxResults: options.maxResults,
        offset: options.offset,
        includePreprints: options.includePreprints
    )

    // ... rest of method
}
```

---

## Known Limitations

1. **MeSH Explosion**: PubMed automatically explodes MeSH terms; Europe PMC may not
2. **Subheadings**: PubMed MeSH subheadings (`/therapy`) have no Europe PMC equivalent
3. **PMID Lookup**: `12345[pmid]` syntax differs between systems
4. **Complex Filters**: Some PubMed search builder filters have no equivalent

### Mitigation

- For unsupported features: Log warning and pass through as plain text
- For MeSH explosion: Consider adding related terms manually
- For critical differences: Document in user-facing help text

---

## Files to Create

### New Files

- `Sources/Utilities/QueryTranslator.swift`
- `Sources/Utilities/QueryValidator.swift`
- `Tests/QueryTranslatorTests.swift`

---

## Estimated Effort

| Task | Complexity | Notes |
|------|------------|-------|
| QueryTranslator core | Medium | Regex-based translation |
| Field tag mapping | Low | Straightforward replacements |
| Date filter translation | Low | Simple pattern matching |
| Special filter translation | Low | String replacements |
| QueryValidator | Low | Basic checks |
| Test suite | Medium | Comprehensive coverage |

**Total estimated complexity: Medium**

---

## Next Phase

After completing this phase, proceed to **Phase 5: Hybrid Search UI (macOS)** (`05-hybrid-search-ui-macos.md`) to implement the macOS-specific user interface for search provider selection and result display.
