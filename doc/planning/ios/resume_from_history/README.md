# iOS: Resume Search from History

## Overview

When loading a report from history, restore the original question in the search box and enable adding new search results to the existing session.

## Current State

- **HistoryView**: Shows sessions in a list, tapping a session with a report opens `ReportView` as a sheet
- **ContentView**: Tab-based navigation with `factCheckClaimText` and `factCheckWorkflow` state bindings passed to `FactCheckView`
- **Current behavior**: Tapping a history item only shows the report - no way to restore the question or continue searching

## Existing Infrastructure

The following already exists and will be reused:
- `FactCheckSession.claim` - Stores the original question text
- `FactCheckSession.canGetMoreEvidence` - Computed property checking if more results available
- `FactCheckWorkflow.resumeSession()` - Method to resume an existing session
- Pagination state: `pubmedOffset`, `europePMCCursor`, etc. are persisted in `FactCheckSession`

## Implementation Phases

| Phase | Description | File(s) |
|-------|-------------|---------|
| 1 | Add continue search callback to HistoryView | [HistoryView.swift](../../../ios/MedicalFactChecker/Sources/Views/History/HistoryView.swift) |
| 2 | Handle session restoration in ContentView | [ContentView.swift](../../../ios/MedicalFactChecker/Sources/App/ContentView.swift) |
| 3 | Update FactCheckView for resumed sessions | [FactCheckView.swift](../../../ios/MedicalFactChecker/Sources/Views/FactCheck/FactCheckView.swift) |

## Phase Documents

- [Phase 1: HistoryView Changes](phase1_history_view.md)
- [Phase 2: ContentView Changes](phase2_content_view.md)
- [Phase 3: FactCheckView Changes](phase3_factcheck_view.md)

## Verification

1. Tap history item context menu > "Continue Search"
2. Verify navigates to Check tab with claim text restored
3. Verify "Resumed Session Banner" is displayed
4. Click "Add More Results" button
5. Verify additional documents are fetched from correct pagination offset
6. Verify new report includes all documents (old + new)
