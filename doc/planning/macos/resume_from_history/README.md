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
- `FactCheckWorkflow.resumeSession()` - Method to resume an existing session
- Pagination state: `pubmedOffset`, `europePMCCursor`, etc. are persisted in `FactCheckSession`

## Implementation Phases

| Phase | Description | File(s) |
|-------|-------------|---------|
| 1 | Add continue search callback to MacHistoryView | [MacHistoryView.swift](../../../macos/MedicalFactCheckerMac/Sources/Views/History/MacHistoryView.swift) |
| 2 | Handle session restoration in MacContentView | [MacContentView.swift](../../../macos/MedicalFactCheckerMac/Sources/App/MacContentView.swift) |
| 3 | Update MacFactCheckView for resumed sessions | [MacFactCheckView.swift](../../../macos/MedicalFactCheckerMac/Sources/Views/FactCheck/MacFactCheckView.swift) |

## Phase Documents

- [Phase 1: MacHistoryView Changes](phase1_history_view.md)
- [Phase 2: MacContentView Changes](phase2_content_view.md)
- [Phase 3: MacFactCheckView Changes](phase3_factcheck_view.md)

## Verification

1. Select a session in History sidebar
2. Click "Continue Search" button in session detail panel
3. Verify navigates to Fact Check with claim text restored
4. Verify "Resumed Session Banner" is displayed
5. Click "Add More Results" button
6. Verify additional documents are fetched from correct pagination offset
7. Verify new report includes all documents (old + new)
