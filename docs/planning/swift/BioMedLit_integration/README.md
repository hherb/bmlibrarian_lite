# iOS Migration Plan: Search, Citation, and Full Text Changes

This document outlines the migration of macOS changes (since commit `1f79a8e`) to iOS. The changes span document search workflow, citation extraction, multi-provider pagination, and JATS parser improvements.

## Summary of Changes to Migrate

### 1. Search Workflow Improvements
- **Structured Query System**: macOS now uses provider-agnostic `StructuredQuery` objects that get translated to PubMed or Europe PMC syntax
- **User Decision Flow**: Always prompts user after scoring, offers smart search as explicit choice
- **Multi-Provider Pagination**: Proper cursor-based pagination for Europe PMC alongside offset-based for PubMed
- **Improved Deduplication**: Checks PMID, DOI, and PMC ID to avoid duplicates

### 2. Citation Extraction
- No major changes to citation extraction itself, but better integration with the workflow

### 3. Full Text Parsing (BioMedLit Package)
- JATS parser now handles `<back>` matter sections (acknowledgments, appendices, etc.)
- Already in the shared BioMedLit package - iOS gets this automatically when using package

## Phase Breakdown

| Phase | Document | Description | Files Changed |
|-------|----------|-------------|---------------|
| 1 | [phase1_factchecksession.md](phase1_factchecksession.md) | Update FactCheckSession model | `Models/FactCheckSession.swift` |
| 2 | [phase2_responseparser.md](phase2_responseparser.md) | Add structured query parsing | `Utilities/ResponseParser.swift` |
| 3 | [phase3_structuredquery.md](phase3_structuredquery.md) | Add StructuredQuery and QueryBuilder | `Models/StructuredQuery.swift` (new) |
| 4 | [phase4_searchservice.md](phase4_searchservice.md) | Update SearchServiceFactory | `Services/SearchServiceProtocol.swift` |
| 5 | [phase5_workflow.md](phase5_workflow.md) | Update FactCheckWorkflow | `Services/FactCheckWorkflow.swift` |
| 6 | [phase6_views.md](phase6_views.md) | Update UI views | `Views/FactCheck/FactCheckView.swift` |

## Dependencies Between Phases

```
Phase 1 (FactCheckSession)
    │
    └──► Phase 3 (StructuredQuery) ──► Phase 2 (ResponseParser)
                    │                         │
                    ▼                         │
              Phase 4 (SearchService) ◄───────┘
                    │
                    ▼
              Phase 5 (Workflow)
                    │
                    ▼
              Phase 6 (Views)
```

**Execution Order:**
1. Phase 1 (FactCheckSession) - can start immediately
2. Phase 3 (StructuredQuery) - can start immediately, no dependencies
3. Phase 2 (ResponseParser) - requires Phase 3 (uses StructuredQuery types)
4. Phase 4 (SearchService) - requires Phase 3
5. Phase 5 (Workflow) - requires Phases 1-4
6. Phase 6 (Views) - requires Phase 5

**Note:** Phase 1 and Phase 3 can run in parallel. Phase 2 and Phase 4 can run in parallel after Phase 3 completes.

## Key Differences Between macOS and iOS

### Current State

| Feature | macOS | iOS |
|---------|-------|-----|
| Structured queries | Yes | No (uses string-based) |
| Multi-provider pagination | Full cursor support | Basic offset only |
| Smart search decision | User-prompted | Auto-triggered |
| Europe PMC cursor | `europePMCCursor` | `europePMCCursorMark` |
| Preprints flag | `includePreprints` | `includedPreprints` |
| Provider hasMore flags | Yes | No |

### Target State

Both platforms should have identical:
- `FactCheckSession` model properties
- `StructuredQuery` and query builders
- `SearchServiceFactory` with cursor support
- `FactCheckWorkflow` user decision logic
- UI for smart search prompts

## Testing Strategy

After each phase:
1. Build the iOS project to ensure no compilation errors
2. Run existing unit tests
3. Add new tests for added functionality

After all phases:
1. Full integration test: run a complete fact-check workflow
2. Test Europe PMC pagination with cursor
3. Test smart search flow with user prompts
4. Test deduplication across providers

## Rollback Plan

Each phase is designed to be independently revertable. If issues arise:
1. The BioMedLit package changes are already stable (tested via macOS)
2. Model changes are additive (no data loss on rollback)
3. Workflow changes are isolated to iOS codebase

## Estimated Effort

- Phase 1: Small (~15 lines changed)
- Phase 2: Small (~50 lines added)
- Phase 3: Medium (~200 lines new file)
- Phase 4: Medium (~50 lines changed)
- Phase 5: Large (~200 lines changed)
- Phase 6: Medium (~50 lines changed)

Total: ~550 lines of changes/additions
