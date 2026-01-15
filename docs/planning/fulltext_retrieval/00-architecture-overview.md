# Architecture Overview: Full-Text Retrieval & Hybrid Search

This document provides a bird's eye view of two interconnected features for the iOS/macOS MedicalFactChecker app:

1. **Full-Text Retrieval** - "Get Full Text" button with fallback chain
2. **Hybrid Search** - Europe PMC as an alternative/complement to PubMed

Both features share code between iOS and macOS platforms.

---

## Feature 1: Full-Text Retrieval

### User Story

As a user reviewing scored documents, I want to retrieve the full text of an article so I can read beyond the abstract and verify the evidence.

### Behavior

1. User taps "Get Full Text" button on a document card
2. System attempts retrieval in order:
   - **Europe PMC XML** → Convert to markdown, display in-app
   - **Unpaywall PDF** → Download PDF, display in-app + option to open externally
   - **Open Website** → Open DOI link or PubMed page in browser
3. Full text is persisted with the document for offline access
4. User can view in-app or open in external app (Safari/Preview)

### Data Flow

```
┌─────────────────┐     ┌──────────────────────┐     ┌─────────────────┐
│  DocumentScore  │────▶│   FullTextService    │────▶│    Document     │
│      Row        │     │      (actor)         │     │  (SwiftData)    │
└─────────────────┘     └──────────────────────┘     └─────────────────┘
         │                        │                          │
         │                        ▼                          │
         │              ┌──────────────────┐                 │
         │              │  Fallback Chain  │                 │
         │              │  1. Europe PMC   │                 │
         │              │  2. Unpaywall    │                 │
         │              │  3. DOI/Website  │                 │
         │              └──────────────────┘                 │
         │                        │                          │
         │                        ▼                          │
         │              ┌──────────────────┐                 │
         └──────────────│ FullTextViewer   │◀────────────────┘
                        │     (View)       │
                        └──────────────────┘
```

### New Components

| Component | Type | Location | Purpose |
|-----------|------|----------|---------|
| `FullTextService` | Actor | `Services/` | API calls with fallback logic |
| `FullTextSource` | Enum | `Models/` | Track where full text came from |
| `FullTextViewer` | View | `Views/FactCheck/` | Display full text with navigation |
| Document extensions | Model | `Models/Document.swift` | Store full text content |

---

## Feature 2: Hybrid Search

### User Story

As a user, I want to search multiple literature databases including preprints so I can find the most comprehensive evidence for my claim.

### Behavior

1. User configures search options before starting fact-check:
   - **Provider selection**: PubMed only, Europe PMC only, or Both
   - **Include preprints**: Checkbox (only available with Europe PMC)
2. System executes search according to selection
3. If "Both" selected, results are merged with deduplication
4. User can request more documents from either provider

### Search Provider Comparison

| Aspect | PubMed | Europe PMC |
|--------|--------|------------|
| Query syntax | `"Term"[MeSH]`, `term[tiab]` | `MeSH_TERM:"term"`, `TITLE_ABS:term` |
| Preprints | Limited | Full (34 servers) |
| Auth required | Email recommended | None |
| Rate limits | 3-10/sec | Lenient |

### Query Translation

A Swift-native translator converts between query syntaxes:

```
PubMed:     ("Amlodipine"[MeSH] OR amlodipine[tiab]) AND hasabstract
                                    ↓
Europe PMC: (MeSH_TERM:"Amlodipine" OR TITLE_ABS:amlodipine) AND HAS_ABSTRACT:Y
```

### Data Flow

```
┌─────────────────┐     ┌──────────────────────┐     ┌─────────────────┐
│  FactCheckView  │────▶│  FactCheckWorkflow   │────▶│ SearchProvider  │
│ (search options)│     │    (orchestrator)    │     │   Selection     │
└─────────────────┘     └──────────────────────┘     └─────────────────┘
                                   │
                    ┌──────────────┼──────────────┐
                    ▼              ▼              ▼
            ┌─────────────┐ ┌─────────────┐ ┌─────────────┐
            │  PubMed     │ │ Europe PMC  │ │   Result    │
            │  Service    │ │  Service    │ │   Merger    │
            └─────────────┘ └─────────────┘ └─────────────┘
                    │              │              │
                    └──────────────┼──────────────┘
                                   ▼
                          ┌─────────────────┐
                          │   Documents     │
                          │  (deduplicated) │
                          └─────────────────┘
```

### New Components

| Component | Type | Location | Purpose |
|-----------|------|----------|---------|
| `SearchProvider` | Enum | `Models/` | Provider selection (pubmed, europePMC, both) |
| `EuropePMCService` | Actor | `Services/` | Europe PMC API client |
| `QueryTranslator` | Struct | `Utilities/` | Convert between query syntaxes |
| `SearchResultMerger` | Struct | `Utilities/` | Deduplicate and merge results |
| Settings extensions | | `Models/AppSettings.swift` | Search preferences |
| UI extensions | | `Views/FactCheck/` | Search options in UI |

---

## Implementation Phases

### Phase 1: Full-Text Service & Model (Est. complexity: Medium)
- Extend `Document` model with full-text fields
- Create `FullTextService` actor
- Implement Europe PMC XML retrieval
- Implement Unpaywall PDF lookup
- Implement fallback chain logic

### Phase 2: Full-Text UI (Est. complexity: Medium)
- Add "Get Full Text" button to `DocumentScoreRow`
- Create `FullTextViewer` view
- Handle loading states and errors
- Add "Open in..." functionality

### Phase 3: Search Provider Abstraction (Est. complexity: High)
- Create `SearchProvider` enum
- Create `EuropePMCService` actor
- Abstract common search result types
- Extend `AppSettings` with provider preference

### Phase 4: Query Translator (Est. complexity: Medium)
- Build PubMed → Europe PMC translator
- Build Europe PMC → PubMed translator (for merged searches)
- Handle edge cases (quoted strings, boolean operators)
- Unit tests for translation accuracy

### Phase 5: Hybrid Search UI & Merging (Est. complexity: High)
- Add search options to `FactCheckView`
- Implement result merging with deduplication
- Update `FactCheckWorkflow` to support multiple providers
- Handle "fetch more" from specific providers

---

## Shared Code Strategy

Both iOS and macOS will share:
- All `Models/` code
- All `Services/` code
- All `Utilities/` code
- Most `Views/` code (SwiftUI is cross-platform)

Platform-specific:
- PDF viewing (PDFKit on macOS, Quick Look on iOS)
- "Open in..." actions (share sheet vs menu)
- Layout adjustments for screen size

---

## Risk Assessment

| Risk | Mitigation |
|------|------------|
| Europe PMC API rate limits | Implement retry with backoff (already exists in LLMService) |
| Query translation edge cases | Comprehensive test suite, fallback to plain text |
| Large PDF downloads on mobile | Show progress, allow cancellation, cache aggressively |
| Merge deduplication accuracy | Match on PMID first, then DOI, then title similarity |

---

## Dependencies

- No new Swift packages required
- Uses existing patterns: Actor model, SwiftData, URLSession
- APIs used: Europe PMC REST, Unpaywall REST, DOI.org

---

## Next Steps

See individual phase documents for detailed implementation plans:
- `01-fulltext-service-model.md`
- `02-fulltext-ui.md`
- `03-search-provider-abstraction.md`
- `04-query-translator.md`
- `05-hybrid-search-ui.md`
