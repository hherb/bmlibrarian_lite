# Phase 1: iOS HistoryView Changes

## Objective

Add a "Continue Search" action to history items that allows users to restore a session and add more search results.

## File to Modify

[ios/MedicalFactChecker/Sources/Views/History/HistoryView.swift](../../../ios/MedicalFactChecker/Sources/Views/History/HistoryView.swift)

## Changes

### 1. Add Callback Parameter

Add an optional callback parameter to `HistoryView`:

```swift
struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FactCheckSession.createdAt, order: .reverse) private var sessions: [FactCheckSession]

    /// Callback when user wants to continue a search from a session.
    var onContinueSession: ((FactCheckSession) -> Void)?

    @State private var selectedReport: EvidenceReport?
    // ... rest of implementation
}
```

### 2. Add Context Menu to SessionRow

Replace the simple `onTapGesture` with a more comprehensive interaction:

```swift
ForEach(sessions) { session in
    SessionRow(session: session)
        .contentShape(Rectangle())
        .onTapGesture {
            if let report = session.report {
                selectedReport = report
            }
        }
        .contextMenu {
            if session.report != nil {
                Button {
                    selectedReport = session.report
                } label: {
                    Label("View Report", systemImage: "doc.text")
                }
            }

            if session.canGetMoreEvidence {
                Button {
                    onContinueSession?(session)
                } label: {
                    Label("Continue Search", systemImage: "magnifyingglass.circle")
                }
            }

            Divider()

            Button(role: .destructive) {
                deleteSession(session)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
}
```

### 3. Add Delete Session Helper

Extract delete logic to a reusable method:

```swift
private func deleteSession(_ session: FactCheckSession) {
    modelContext.delete(session)
    try? modelContext.save()
}
```

### 4. Update Preview

Update the preview to include the new callback:

```swift
#Preview {
    HistoryView(onContinueSession: { session in
        print("Continue session: \(session.claim)")
    })
    .modelContainer(for: [
        FactCheckSession.self,
        Document.self,
        Citation.self,
        EvidenceReport.self,
        UsageRecord.self,
    ], inMemory: true)
}
```

## Optional Enhancement: Add Visual Indicator

Consider adding a subtle indicator on `SessionRow` for sessions that have more evidence available:

```swift
// In SessionRow, after the existing HStack for status/date
if session.canGetMoreEvidence {
    HStack(spacing: 4) {
        Image(systemName: "plus.magnifyingglass")
        Text("More results available")
    }
    .font(.caption2)
    .foregroundColor(.accentColor)
}
```

## Testing

1. Build and run the app
2. Complete a fact-check to create a history item
3. Go to History tab
4. Long-press on a session to show context menu
5. Verify "Continue Search" appears for sessions with `canGetMoreEvidence == true`
6. Verify "View Report" appears for sessions with reports
7. Verify "Delete" option works
