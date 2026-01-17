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

### 6. Add Search Options State and Sync

Add state to track current search options and sync with restored session:

```swift
/// Search options for the current fact-check.
@State private var searchOptions = AppSettings.shared.buildSearchOptions()

// In body, add onChange to sync with restored session
.onChange(of: workflow?.session?.searchProvider) { _, newProvider in
    // Sync search options from restored session
    if let providerRaw = newProvider,
       let provider = SearchProvider(rawValue: providerRaw),
       let session = workflow?.session {
        searchOptions = SearchOptions(
            provider: provider,
            includePreprints: session.includePreprints
        )
    }
}
```

### 7. Update Submit Handler for Provider Switching

The handleSubmit function should pass current search options to allow provider switching:

```swift
/// Handles the submit button action.
///
/// For resumed sessions with existing documents, this fetches more evidence
/// to append to the existing results. For new fact-checks, this starts
/// a fresh workflow.
private func handleSubmit() {
    if isResumedSession, let workflow = workflow {
        // Resumed session: fetch more evidence to append to existing documents
        // Pass current search options to allow provider switching mid-session
        Task {
            await workflow.fetchMoreEvidence(searchOptions: searchOptions)
        }
    } else {
        // New fact-check: start fresh
        startFactCheck()
    }
}
```

### 8. Add "New Question" Button to Banner

Update MacResumedSessionBanner to include a "New Question" button:

```swift
struct MacResumedSessionBanner: View {
    let session: FactCheckSession
    var onNewQuestion: (() -> Void)?  // NEW

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

            // NEW: New Question button
            if let onNewQuestion {
                Button(action: onNewQuestion) {
                    Text("New Question")
                        .font(.callout)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }

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

Add the helper method:

```swift
/// Clears the current resumed session and prepares for a new question.
private func startNewQuestion() {
    claimText = ""
    workflow = nil
}
```

Update banner instantiation:

```swift
if isResumedSession, let session = workflow?.session {
    MacResumedSessionBanner(
        session: session,
        onNewQuestion: startNewQuestion
    )
    .padding(.horizontal, MacSpacing.standard)
}
```

### 9. Add MacGetMoreEvidenceSection Component

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

### 10. Display GetMoreEvidenceSection (Only for Non-Resumed Sessions)

**Important**: For resumed sessions, the top "Add More Results" button handles fetching. Hide this section to avoid redundancy:

```swift
// Get More Evidence Section (for completed sessions that weren't resumed)
// For resumed sessions, the top "Add More Results" button handles this
if let workflow = workflow,
   let session = workflow.session,
   session.report != nil,
   session.canGetMoreEvidence,
   !workflow.isRunning,
   !isResumedSession {  // Only show for non-resumed sessions
    MacGetMoreEvidenceSection(
        session: session,
        isFetching: workflow.isRunning,
        onFetchMore: {
            Task {
                await workflow.fetchMoreEvidence(searchOptions: searchOptions)
            }
        }
    )
    .padding(.horizontal, MacSpacing.standard)
}
```

### 11. Use displayTitle for Document Titles

The Document model now has a `displayTitle` computed property that decodes HTML entities and strips tags. Use it everywhere document titles are displayed:

```swift
// In any document card or list
Text(document.displayTitle)  // NOT document.title
    .font(.headline)
```

This handles titles like:
- `&lt;i&gt;Serenoa repens&lt;/i&gt;` → `Serenoa repens`
- `<i>Serenoa repens</i>` → `Serenoa repens`

### 12. Update Preview

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

### Basic Resume Flow
1. Build and run the macOS app
2. Complete a fact-check to create a session
3. Go to History and select the session
4. Click "Continue Search"
5. Verify:
   - Claim text is restored
   - "Continuing previous search" banner appears
   - Banner shows correct document counts
   - Search options dropdown shows session's original provider
   - Button text is "Add More Results" instead of "Check Evidence"
   - Document titles display correctly (no HTML entities or tags)

### Add More Results
6. If more evidence is available:
   - Click "Add More Results" button
   - Verify logs show `[RefreshPagination]` (pagination state refresh)
   - Verify additional documents are fetched
   - Verify document count increases after fetching
   - Verify new report includes all documents (old + new)

### Provider Switching
7. Resume a session that used Europe PMC
8. Change the search provider dropdown to PubMed
9. Click "Add More Results"
10. Verify logs show `[FetchMoreEvidence] Updated search options to: PubMed`
11. Verify search uses PubMed (not Europe PMC)

### New Question Button
12. Click "New Question" in the resumed session banner
13. Verify claim text is cleared
14. Verify workflow is reset (no session data)
15. Verify UI shows "Check Evidence" button (not "Add More Results")

### No Redundant Buttons
16. When viewing a resumed session, verify the bottom "Get More Evidence" section does NOT appear
17. Only the top "Add More Results" button should be visible for fetching more evidence
