# Phase 3: macOS MacFactCheckView Changes

## Objective

Update MacFactCheckView to:
1. Accept claim text as a binding from parent (instead of local state)
2. Display visual feedback when a session is resumed from history
3. Provide clear "Add More Results" functionality

## File to Modify

[macos/MedicalFactCheckerMac/Sources/Views/FactCheck/MacFactCheckView.swift](../../../macos/MedicalFactCheckerMac/Sources/Views/FactCheck/MacFactCheckView.swift)

## Changes

### 1. Change claimText from State to Binding

Change the claim text property from local state to a binding:

```swift
struct MacFactCheckView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppSettings.self) private var settings

    @Binding var workflow: FactCheckWorkflow?
    @Binding var claimText: String  // CHANGED from @State

    let onReportGenerated: ((EvidenceReport) -> Void)?
    let onShowFullText: ((Document) -> Void)?

    // ... rest of implementation
}
```

### 2. Add Computed Property for Resumed Session

```swift
/// Whether the current workflow is resuming an existing session with documents.
private var isResumedSession: Bool {
    guard let session = workflow?.session else { return false }
    return (session.documents?.count ?? 0) > 0 && session.report != nil
}
```

### 3. Add MacResumedSessionBanner Component

```swift
/// Banner displayed when continuing a search from history.
struct MacResumedSessionBanner: View {
    let session: FactCheckSession

    var body: some View {
        HStack(spacing: MacSpacing.standard) {
            Image(systemName: "arrow.uturn.forward.circle.fill")
                .font(.title2)
                .foregroundColor(.blue)

            VStack(alignment: .leading, spacing: MacSpacing.xSmall) {
                Text("Continuing previous search")
                    .font(.headline)

                let docCount = session.documents?.count ?? 0
                let scoredCount = session.documents?.filter { $0.isScored }.count ?? 0
                Text("\(docCount) documents found, \(scoredCount) scored")
                    .font(.body)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if session.canGetMoreEvidence {
                HStack(spacing: MacSpacing.xSmall) {
                    Image(systemName: "plus.circle")
                        .foregroundColor(.green)
                    Text("More available")
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }
        }
        .padding(MacSpacing.large)
        .background(Color.blue.opacity(MacOpacity.light))
        .cornerRadius(MacCornerRadius.large)
    }
}
```

### 4. Display Banner in Main View

Add the banner after the input section:

```swift
// In the main view body, after MacClaimInputSection
if isResumedSession, let session = workflow?.session {
    MacResumedSessionBanner(session: session)
        .padding(.horizontal, MacSpacing.standard)
}
```

### 5. Update Submit Button Text

In `MacClaimInputSection`, update the button text:

```swift
// Computed property for button text
private var buttonText: String {
    if isRunning {
        return "Checking..."
    } else if isResumedSession {
        return "Add More Results"
    } else {
        return "Check Evidence"
    }
}

// Use in button
Button(action: onSubmit) {
    HStack {
        if isRunning {
            ProgressView()
                .scaleEffect(MacScale.progressViewSmall)
        }
        Text(buttonText)
    }
    .frame(maxWidth: .infinity)
}
.buttonStyle(.borderedProminent)
.controlSize(.large)
.disabled(!canSubmit || isRunning)
```

### 6. Add MacGetMoreEvidenceSection Component

```swift
/// Section shown when more evidence can be fetched for a session.
struct MacGetMoreEvidenceSection: View {
    let session: FactCheckSession
    let isFetching: Bool
    let onFetchMore: () -> Void

    var body: some View {
        HStack(spacing: MacSpacing.large) {
            VStack(alignment: .leading, spacing: MacSpacing.xSmall) {
                Text("More Evidence Available")
                    .font(.headline)

                if session.canFetchMoreDocuments {
                    Text("~\(session.estimatedRemainingResults) more documents available")
                        .font(.body)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Button(action: onFetchMore) {
                HStack {
                    if isFetching {
                        ProgressView()
                            .scaleEffect(MacScale.progressViewSmall)
                    } else {
                        Image(systemName: "plus.magnifyingglass")
                    }
                    Text("Get More")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isFetching)
        }
        .padding(MacSpacing.large)
        .background(Color.green.opacity(MacOpacity.light))
        .cornerRadius(MacCornerRadius.large)
    }
}
```

### 7. Display GetMoreEvidenceSection

Show this section when appropriate:

```swift
// After results section
if let session = workflow?.session,
   session.report != nil && session.canGetMoreEvidence {
    MacGetMoreEvidenceSection(
        session: session,
        isFetching: workflow?.isRunning ?? false,
        onFetchMore: {
            Task {
                await workflow?.fetchMoreEvidence()
            }
        }
    )
    .padding(.horizontal, MacSpacing.standard)
}
```

### 8. Update Preview

```swift
#Preview {
    @Previewable @State var workflow: FactCheckWorkflow? = nil
    @Previewable @State var claimText: String = ""

    MacFactCheckView(
        workflow: $workflow,
        claimText: $claimText,
        onReportGenerated: nil,
        onShowFullText: nil
    )
    .modelContainer(for: [
        FactCheckSession.self,
        Document.self,
        Citation.self,
        EvidenceReport.self,
        UsageRecord.self,
    ], inMemory: true)
    .environment(AppSettings.shared)
    .frame(width: 800, height: 600)
}
```

## Visual Design

### MacResumedSessionBanner
- **Background**: Light blue (`Color.blue.opacity(MacOpacity.light)`)
- **Icon**: `arrow.uturn.forward.circle.fill` in blue
- **Corner radius**: `MacCornerRadius.large`
- **Shows**: Document count, scored count, indicator if more available

### MacGetMoreEvidenceSection
- **Background**: Light green (`Color.green.opacity(MacOpacity.light)`)
- **Icon**: `plus.magnifyingglass`
- **Shows**: Estimated remaining results, fetch button

## Testing

1. Build and run the macOS app
2. Complete a fact-check to create a session
3. Go to History and select the session
4. Click "Continue Search"
5. Verify:
   - Claim text is restored
   - "Continuing previous search" banner appears
   - Banner shows correct document counts
   - Button text is "Add More Results" instead of "Check Evidence"
6. If more evidence is available:
   - Verify "More Evidence Available" section appears
   - Click "Get More" and verify additional documents are fetched
   - Verify document count increases after fetching
