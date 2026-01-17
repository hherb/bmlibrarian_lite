# Phase 3: iOS FactCheckView Changes

## Objective

Update FactCheckView to display visual feedback when a session is resumed from history, and provide clear "Add More Results" functionality.

## File to Modify

[ios/MedicalFactChecker/Sources/Views/FactCheck/FactCheckView.swift](../../../ios/MedicalFactChecker/Sources/Views/FactCheck/FactCheckView.swift)

## Changes

### 1. Add Computed Property for Resumed Session Detection

Add a computed property to detect if we're working with a resumed session:

```swift
/// Whether the current workflow is resuming an existing session with documents.
private var isResumedSession: Bool {
    guard let session = workflow?.session else { return false }
    return (session.documents?.count ?? 0) > 0 && session.report != nil
}
```

### 2. Add ResumedSessionBanner Component

Create a banner component to display when a session is resumed:

```swift
/// Banner displayed when continuing a search from history.
struct ResumedSessionBanner: View {
    let session: FactCheckSession

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.uturn.forward.circle.fill")
                .font(.title2)
                .foregroundColor(.blue)

            VStack(alignment: .leading, spacing: 2) {
                Text("Continuing previous search")
                    .font(.subheadline)
                    .fontWeight(.medium)

                let docCount = session.documents?.count ?? 0
                let scoredCount = session.documents?.filter { $0.isScored }.count ?? 0
                Text("\(docCount) documents found, \(scoredCount) scored")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if session.canGetMoreEvidence {
                Image(systemName: "plus.circle")
                    .foregroundColor(.green)
            }
        }
        .padding()
        .background(Color.blue.opacity(0.1))
        .cornerRadius(12)
    }
}
```

### 3. Display Banner in Main View

Add the banner to the view hierarchy, after the claim input section:

```swift
var body: some View {
    ScrollView {
        VStack(spacing: 20) {
            // Claim Input Section
            ClaimInputSection(
                claimText: $claimText,
                isRunning: workflow?.isRunning ?? false,
                canSubmit: canSubmit,
                onSubmit: { startFactCheck() }
            )

            // Resumed Session Banner (NEW)
            if isResumedSession, let session = workflow?.session {
                ResumedSessionBanner(session: session)
            }

            // ... rest of the view content
        }
    }
}
```

### 4. Update Submit Button Text

Modify the button text based on session state:

```swift
// In ClaimInputSection or wherever the submit button is
Button(action: onSubmit) {
    Text(buttonText)
        .fontWeight(.semibold)
        .foregroundColor(.white)
        .frame(maxWidth: .infinity)
        .padding()
        .background(canSubmit ? Color.accentColor : Color.gray)
        .cornerRadius(12)
}
.disabled(!canSubmit)

// Add computed property for button text
private var buttonText: String {
    if isRunning {
        return "Checking..."
    } else if isResumedSession {
        return "Add More Results"
    } else {
        return "Check Evidence"
    }
}
```

### 5. Add GetMoreEvidenceSection Component

Create a dedicated section for fetching more evidence:

```swift
/// Section shown when more evidence can be fetched for a session.
struct GetMoreEvidenceSection: View {
    let session: FactCheckSession
    let isFetching: Bool
    let onFetchMore: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("More Evidence Available")
                        .font(.headline)

                    if session.canFetchMoreDocuments {
                        Text("~\(session.estimatedRemainingResults) more documents available")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                Button(action: onFetchMore) {
                    if isFetching {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Label("Get More", systemImage: "plus.magnifyingglass")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isFetching)
            }
        }
        .padding()
        .background(Color.green.opacity(0.1))
        .cornerRadius(12)
    }
}
```

### 6. Display GetMoreEvidenceSection

Show this section when appropriate:

```swift
// After results section
if let session = workflow?.session,
   session.report != nil && session.canGetMoreEvidence {
    GetMoreEvidenceSection(
        session: session,
        isFetching: workflow?.isRunning ?? false,
        onFetchMore: {
            Task {
                await workflow?.fetchMoreEvidence()
            }
        }
    )
}
```

## Visual Design

### ResumedSessionBanner
- **Background**: Light blue (`Color.blue.opacity(0.1)`)
- **Icon**: `arrow.uturn.forward.circle.fill` in blue
- **Corner radius**: 12pt
- **Shows**: Document count, scored count, indicator if more available

### GetMoreEvidenceSection
- **Background**: Light green (`Color.green.opacity(0.1)`)
- **Icon**: `plus.magnifyingglass`
- **Shows**: Estimated remaining results, fetch button

## Testing

1. Build and run the app
2. Complete a fact-check to create a session
3. Go to History tab
4. Long-press and select "Continue Search"
5. Verify:
   - Claim text is restored
   - "Continuing previous search" banner appears
   - Banner shows correct document counts
   - Button text is "Add More Results" instead of "Check Evidence"
6. If more evidence is available:
   - Verify "More Evidence Available" section appears
   - Click "Get More" and verify additional documents are fetched
   - Verify document count increases after fetching
