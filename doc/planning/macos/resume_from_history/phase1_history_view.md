# Phase 1: macOS MacHistoryView Changes

## Objective

Add a "Continue Search" action to history items that allows users to restore a session and add more search results.

## File to Modify

[macos/MedicalFactCheckerMac/Sources/Views/History/MacHistoryView.swift](../../../macos/MedicalFactCheckerMac/Sources/Views/History/MacHistoryView.swift)

## Changes

### 1. Add Callback Parameter to MacHistoryView

Add an optional callback parameter:

```swift
struct MacHistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FactCheckSession.createdAt, order: .reverse) private var sessions: [FactCheckSession]

    let onReportSelected: ((EvidenceReport) -> Void)?
    let onContinueSession: ((FactCheckSession) -> Void)?  // NEW

    // ... existing state properties
}
```

### 2. Update MacSessionDetailView

Add the continue search callback and button:

```swift
struct MacSessionDetailView: View {
    @Environment(AppSettings.self) private var settings

    let session: FactCheckSession
    let onViewReport: () -> Void
    var onShowFullText: ((Document) -> Void)?
    var onContinueSession: (() -> Void)?  // NEW

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MacSpacing.xLarge) {
                // ... existing header, claim, query, status sections

                // Actions (UPDATE THIS SECTION)
                VStack(spacing: MacSpacing.standard) {
                    if session.report != nil {
                        Button(action: onViewReport) {
                            HStack {
                                Image(systemName: "doc.text")
                                Text("View Report")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }

                    // NEW: Continue Search button
                    if session.canGetMoreEvidence {
                        Button(action: { onContinueSession?() }) {
                            HStack {
                                Image(systemName: "magnifyingglass.circle")
                                Text("Continue Search")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                }

                // ... rest of implementation
            }
        }
    }
}
```

### 3. Update Context Menu

Add "Continue Search" to the context menu:

```swift
.contextMenu {
    if session.report != nil {
        Button("View Report") {
            if let report = session.report {
                onReportSelected?(report)
            }
        }
    }

    // NEW
    if session.canGetMoreEvidence {
        Button("Continue Search") {
            onContinueSession?(session)
        }
    }

    Divider()

    Button("Delete", role: .destructive) {
        deleteSession(session)
    }
}
```

### 4. Wire Up MacSessionDetailView

Pass the callback to `MacSessionDetailView`:

```swift
@ViewBuilder
private var sessionDetail: some View {
    if let session = selectedSession {
        MacSessionDetailView(
            session: session,
            onViewReport: {
                if let report = session.report {
                    onReportSelected?(report)
                }
            },
            onShowFullText: { document in
                NotificationCenter.default.post(
                    name: .showDocumentFullText,
                    object: nil,
                    userInfo: ["document": document]
                )
            },
            onContinueSession: {  // NEW
                onContinueSession?(session)
            }
        )
    } else {
        // ... empty state
    }
}
```

### 5. Update Preview

```swift
#Preview {
    MacHistoryView(
        onReportSelected: nil,
        onContinueSession: { session in
            print("Continue session: \(session.claim)")
        }
    )
    .modelContainer(for: [
        FactCheckSession.self,
        Document.self,
        Citation.self,
        EvidenceReport.self,
        UsageRecord.self,
    ], inMemory: true)
    .frame(width: 900, height: 600)
}
```

## Visual Design

The "Continue Search" button should:
- Use `.bordered` button style (secondary prominence)
- Appear below "View Report" button
- Only appear when `session.canGetMoreEvidence == true`
- Use `magnifyingglass.circle` icon

## Testing

1. Build and run the macOS app
2. Complete a fact-check to create a history item
3. Go to History in sidebar
4. Select a session
5. Verify "Continue Search" button appears for sessions with `canGetMoreEvidence == true`
6. Right-click on session row to verify context menu includes "Continue Search"
7. Verify "View Report" button still works
