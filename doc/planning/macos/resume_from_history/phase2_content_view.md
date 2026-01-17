# Phase 2: macOS MacContentView Changes

## Objective

Handle session restoration when user selects "Continue Search" from history. Navigate to Fact Check with claim text restored and workflow ready to add more results.

## File to Modify

[macos/MedicalFactCheckerMac/Sources/App/MacContentView.swift](../../../macos/MedicalFactCheckerMac/Sources/App/MacContentView.swift)

## Changes

### 1. Add Model Context and Settings Environment

Add access to model context and settings (if not already present):

```swift
struct MacContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppSettings.self) private var settings

    // ... existing state properties
}
```

### 2. Add Claim Text State

Add state for the claim text that will be passed to MacFactCheckView:

```swift
/// The claim text for fact checking (persisted across tab switches).
@State private var claimText: String = ""
```

### 3. Add restoreSession Method

Add a method to handle session restoration. **Important**: Use `restoreForViewing()` to load the session state without running the workflow. The workflow will run when user clicks "Add More Results".

```swift
// MARK: - Session Restoration

/// Restores a session from history for viewing.
///
/// This method is called when the user clicks "Continue Search" in history. It:
/// 1. Restores the original claim text to the input field
/// 2. Creates a workflow with the session loaded (without running it)
/// 3. Sets up callbacks for any subsequent actions (like "Add More Results")
/// 4. Sets the current report so the Report view shows it
/// 5. Navigates to the Fact Check view
///
/// The session's documents, scores, and report are displayed without
/// re-running the workflow. The user can then click "Add More Results"
/// to fetch additional documents if more are available.
///
/// - Parameter session: The fact-check session to restore for viewing.
private func restoreSession(_ session: FactCheckSession) {
    // Restore the claim text to the input field
    claimText = session.claim

    // Create a new workflow for this session
    let restoredWorkflow = FactCheckWorkflow(
        modelContext: modelContext,
        settings: AppSettings.shared
    )

    // Configure workflow callbacks for any subsequent actions

    // Called when workflow completes successfully with a report
    restoredWorkflow.onComplete = { report in
        currentReport = report
        selectedNavItem = .report
    }

    // Called when an error occurs during workflow execution
    restoredWorkflow.onError = { error in
        print("[MacContentView] Workflow error: \(error.localizedDescription)")
    }

    // Called when budget limit is exceeded
    restoredWorkflow.onBudgetExceeded = { message in
        print("[MacContentView] Budget exceeded: \(message)")
    }

    // Restore session for viewing (does NOT run the workflow)
    // This sets isResumedSession = true so fetchMoreEvidence() will
    // refresh pagination state before fetching new documents
    restoredWorkflow.restoreForViewing(session)

    // Set the workflow binding so MacFactCheckView receives it
    activeWorkflow = restoredWorkflow

    // Set the current report so Report view shows it
    if let report = session.report {
        currentReport = report
    }

    // Navigate to Fact Check
    selectedNavItem = .factCheck
}
```

### 4. Update MacHistoryView Instantiation

Pass the `onContinueSession` callback:

```swift
case .history:
    MacHistoryView(
        onReportSelected: { report in
            currentReport = report
            selectedNavItem = .report
        },
        onContinueSession: { session in  // NEW
            restoreSession(session)
        }
    )
```

### 5. Pass Claim Text to MacFactCheckView

Update MacFactCheckView instantiation to include claim text binding:

```swift
case .factCheck:
    MacFactCheckView(
        workflow: $activeWorkflow,
        claimText: $claimText,  // NEW
        onReportGenerated: { report in
            currentReport = report
            selectedNavItem = .report
        },
        onShowFullText: { document in
            selectedFullTextDocument = document
            selectedNavItem = .fullText
        }
    )
```

## Data Flow

```
MacHistoryView
    │
    │ onContinueSession(session)
    ▼
MacContentView.restoreSession(session)
    │
    ├─► claimText = session.claim
    │
    ├─► activeWorkflow = new FactCheckWorkflow()
    │       │
    │       └─► workflow.restoreForViewing(session)
    │           (loads session state, sets isResumedSession = true)
    │
    ├─► currentReport = session.report
    │
    └─► selectedNavItem = .factCheck
         │
         ▼
    MacFactCheckView (receives bindings)
         │
         ├─► Shows claim text (restored)
         ├─► Shows scored documents (from session)
         ├─► Shows "Resumed Session Banner"
         └─► "Add More Results" button calls fetchMoreEvidence()
              │
              └─► refreshPaginationState() then fetches new docs
```

## Key Differences from Initial Plan

1. **Use `restoreForViewing()` not `resumeSession()`**: The session should be loaded for viewing without running the workflow. Running happens when user clicks "Add More Results".

2. **Synchronous restoration**: `restoreForViewing()` is synchronous - no `Task { await ... }` needed.

3. **Workflow doesn't run immediately**: The existing documents and report are displayed. User decides whether to add more.

4. **Pagination refresh happens later**: When user clicks "Add More Results", the `isResumedSession` flag triggers `refreshPaginationState()` to get fresh cursors before fetching.

## Testing

1. Build and run the macOS app
2. Complete a fact-check with at least one search provider having more results
3. Go to History in sidebar
4. Select a session and click "Continue Search"
5. Verify:
   - App navigates to Fact Check
   - Claim text is restored in the input field
   - Scored documents are displayed immediately (no loading)
   - "Resumed Session Banner" appears
6. The workflow does NOT run until user clicks "Add More Results"

## Note

Phase 3 will require updating `MacFactCheckView` to accept `claimText` as a binding rather than local state. This change is deferred to Phase 3.
