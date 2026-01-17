# Phase 2: iOS ContentView Changes

## Objective

Handle session restoration when user selects "Continue Search" from history. Navigate to Check tab with claim text restored and workflow resumed.

## File to Modify

[ios/MedicalFactChecker/Sources/App/ContentView.swift](../../../ios/MedicalFactChecker/Sources/App/ContentView.swift)

## Changes

### 1. Add Model Context Environment

Add access to the model context for creating workflows:

```swift
struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppSettings.self) private var settings

    @State private var selectedTab: AppTab = .check
    // ... existing state properties
}
```

### 2. Add restoreSession Method

Add a method to handle session restoration:

```swift
/// Restores a session from history, navigating to Check tab with the claim
/// and workflow ready to add more results.
private func restoreSession(_ session: FactCheckSession) {
    // Restore the claim text
    factCheckClaimText = session.claim

    // Create a new workflow for this session
    let restoredWorkflow = FactCheckWorkflow(
        modelContext: modelContext,
        settings: settings
    )

    // Configure workflow callbacks
    restoredWorkflow.onComplete = { report in
        currentReport = report
        visitedTabs.insert(.report)
        selectedTab = .report
    }

    // Set the workflow binding
    factCheckWorkflow = restoredWorkflow

    // Navigate to Check tab
    visitedTabs.insert(.check)
    selectedTab = .check

    // Resume the session asynchronously
    Task {
        await restoredWorkflow.resumeSession(session)
    }
}
```

### 3. Update HistoryView Instantiation

Pass the `onContinueSession` callback to `HistoryView`:

```swift
LazyTabContent(tab: .history, visitedTabs: $visitedTabs) {
    HistoryView(onContinueSession: { session in
        restoreSession(session)
    })
}
```

### 4. Update Preview

Ensure preview includes the required environment:

```swift
#Preview {
    ContentView()
        .modelContainer(for: [
            FactCheckSession.self,
            Document.self,
            Citation.self,
            EvidenceReport.self,
            UsageRecord.self,
        ], inMemory: true)
        .environment(AppSettings.shared)
}
```

## Data Flow

```
HistoryView
    │
    │ onContinueSession(session)
    ▼
ContentView.restoreSession(session)
    │
    ├─► factCheckClaimText = session.claim
    │
    ├─► factCheckWorkflow = new FactCheckWorkflow()
    │
    ├─► selectedTab = .check
    │
    └─► workflow.resumeSession(session)
         │
         ▼
    FactCheckView (receives bindings)
         │
         └─► Shows claim text, resumed session UI
```

## Testing

1. Build and run the app
2. Complete a fact-check with at least one search provider having more results
3. Go to History tab
4. Long-press on the session and select "Continue Search"
5. Verify:
   - App navigates to Check tab
   - Claim text is restored in the input field
   - Workflow is set up (may take a moment)
6. The next phase will add visual feedback for resumed sessions
