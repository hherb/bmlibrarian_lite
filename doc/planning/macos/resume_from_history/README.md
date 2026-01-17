# macOS: Resume Search from History

## Overview

When loading a report from history, restore the original question in the search box and enable adding new search results to the existing session.

## Current State

- **MacHistoryView**: Two-column layout with session list on left, `MacSessionDetailView` on right
- **MacContentView**: Sidebar navigation with `activeWorkflow` state, `onReportSelected` callback navigates to Report tab
- **Current behavior**: "View Report" navigates to report tab but doesn't restore claim text or enable continuing search

## Existing Infrastructure

The following already exists and will be reused:
- `FactCheckSession.claim` - Stores the original question text
- `FactCheckSession.canGetMoreEvidence` - Computed property checking if more results available
- `FactCheckWorkflow.restoreForViewing()` - Method to restore a session for viewing without running
- `FactCheckWorkflow.fetchMoreEvidence()` - Method to fetch additional documents
- Pagination state: `pubmedOffset`, `europePMCCursor`, etc. are persisted in `FactCheckSession`

## Key Learnings from iOS Implementation

The iOS implementation revealed several critical issues that must be addressed:

### 1. Server-Side Cursor Expiration

Europe PMC uses cursor-based pagination where cursors are stored server-side and **expire after a period of inactivity** (possibly minutes). When resuming a session that was created hours/days ago:

- The stored `europePMCCursor` value is invalid
- Attempting to use it returns unexpected results or errors
- **Solution**: Implement `refreshPaginationState()` that re-executes the search from offset=0 to get a fresh cursor, then continues from there

### 2. Provider Switching Mid-Session

Users may want to switch from the original search provider (e.g., Europe PMC) to a different one (e.g., PubMed) when fetching more evidence:

- The session stores `searchProvider` but the UI search options may differ
- **Solution**: Accept optional `searchOptions` parameter in `fetchMoreEvidence()` to allow provider switching
- Reset pagination state for the new provider when switching

### 3. HTML Entity Decoding in Titles

PubMed and Europe PMC return titles with HTML entities and tags:
- Encoded entities: `&lt;i&gt;Serenoa repens&lt;/i&gt;`
- Raw HTML tags: `<i>Serenoa repens</i>`
- **Solution**: Add `displayTitle` computed property to Document model that decodes entities and strips tags

### 4. Workflow Restoration vs Starting Fresh

Two distinct flows:
- **`restoreForViewing(session)`**: Restores session state without running workflow (for viewing existing results)
- **`fetchMoreEvidence()`**: Actually fetches more documents (called when user clicks "Add More Results")

### 5. Pagination Refresh Logic

When `fetchMoreEvidence()` is called on a resumed session:
1. Set `isResumedSession = true` flag in `restoreForViewing()`
2. In `fetchMoreEvidence()`, if `isResumedSession`:
   a. Call `refreshPaginationState()` to re-fetch from beginning
   b. Deduplicate against existing documents
   c. Add any new documents found
   d. Update cursor/offset to fresh values
   e. Clear `isResumedSession` flag
3. Continue with normal fetch (beyond the refreshed position)

## Implementation Phases

| Phase | Description | File(s) |
|-------|-------------|---------|
| 1 | Add continue search callback to MacHistoryView | [MacHistoryView.swift](../../../macos/MedicalFactCheckerMac/Sources/Views/History/MacHistoryView.swift) |
| 2 | Handle session restoration in MacContentView | [MacContentView.swift](../../../macos/MedicalFactCheckerMac/Sources/App/MacContentView.swift) |
| 3 | Update MacFactCheckView for resumed sessions | [MacFactCheckView.swift](../../../macos/MedicalFactCheckerMac/Sources/Views/FactCheck/MacFactCheckView.swift) |
| 4 | Add displayTitle to Document model | Already done in iOS - shared via BioMedLit package |

## Phase Documents

- [Phase 1: MacHistoryView Changes](phase1_history_view.md)
- [Phase 2: MacContentView Changes](phase2_content_view.md)
- [Phase 3: MacFactCheckView Changes](phase3_factcheck_view.md)

## Verification

1. Select a session in History sidebar
2. Click "Continue Search" button in session detail panel
3. Verify navigates to Fact Check with claim text restored
4. Verify "Resumed Session Banner" is displayed
5. Verify search options show the original session's provider
6. Change the search provider in the UI
7. Click "Add More Results" button
8. Verify logs show `[RefreshPagination]` messages (pagination refresh)
9. Verify additional documents are fetched using the **new** provider
10. Verify new report includes all documents (old + new)
11. Verify document titles display correctly (no HTML entities or tags)
