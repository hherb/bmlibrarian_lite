# Phase 2: macOS MacContentView Changes

## Objective

Handle session restoration when user selects "Continue Search" from history. Navigate to Fact Check with claim text restored and workflow resumed.

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

Add a method to handle session restoration:

```swift
/// Restores a session from history, navigating to Fact Check with the claim
/// and workflow ready to add more results.
private func restoreSession(_ session: FactCheckSession) {
    // Restore the claim text
    claimText = session.claim

    // Create a new workflow for this session
    let restoredWorkflow = FactCheckWorkflow(
        modelContext: modelContext,
        settings: settings
    )

    // Configure workflow callbacks
    restoredWorkflow.onComplete = { report in
        currentReport = report
        selectedNavItem = .report
    }

    // Set the workflow
    activeWorkflow = restoredWorkflow

    // Navigate to Fact Check
    selectedNavItem = .factCheck

    // Resume the session asynchronously
    Task {
        await restoredWorkflow.resumeSession(session)
    }
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
    │
    ├─► selectedNavItem = .factCheck
    │
    └─► workflow.resumeSession(session)
         │
         ▼
    MacFactCheckView (receives bindings)
         │
         └─► Shows claim text, resumed session UI
```

## Testing

1. Build and run the macOS app
2. Complete a fact-check with at least one search provider having more results
3. Go to History in sidebar
4. Select a session and click "Continue Search"
5. Verify:
   - App navigates to Fact Check
   - Claim text is restored in the input field
   - Workflow is set up (may take a moment)
6. The next phase will add visual feedback for resumed sessions

## Note

Phase 3 will require updating `MacFactCheckView` to accept `claimText` as a binding rather than local state. This change is deferred to Phase 3.
