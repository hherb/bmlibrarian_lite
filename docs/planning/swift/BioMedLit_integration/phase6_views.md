# Phase 6: UI View Updates

## Objective

Update the iOS `FactCheckView` and related UI components to support the new user decision flow with smart search options.

## Files to Modify

- `ios/MedicalFactChecker/Sources/Views/FactCheck/FactCheckView.swift`

## Overview

The macOS version has improved user decision UI that:
1. Always prompts the user after scoring (never auto-continues)
2. Shows "Try Smart Search" button when smart search is available
3. Shows "Fetch More Documents" button when more documents available
4. Always shows "Proceed with Current" as an option

The iOS version needs similar functionality adapted for mobile UI patterns.

## Current iOS State

The iOS `FactCheckView` likely has:
- Basic claim input
- Progress display
- Some form of user decision handling

## Changes Required

### 1. Update User Decision Section

Create or update the decision prompt view to support smart search:

```swift
// MARK: - User Decision View

/// View displayed when user input is needed during workflow.
struct UserDecisionView: View {
    let workflow: FactCheckWorkflow
    let prompt: String
    let showSmartSearchOption: Bool
    let onContinue: () -> Void
    let onSmartSearch: (() -> Void)?
    let onProceed: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            // Icon and message
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(.orange)

                Text(prompt)
                    .font(.body)
                    .multilineTextAlignment(.leading)

                Spacer()
            }

            // Action buttons
            VStack(spacing: 12) {
                // Primary action: Smart Search or Fetch More
                if showSmartSearchOption {
                    Button {
                        onSmartSearch?()
                    } label: {
                        HStack {
                            Image(systemName: "wand.and.stars")
                            Text("Try Smart Search")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else {
                    Button {
                        onContinue()
                    } label: {
                        HStack {
                            Image(systemName: "arrow.down.doc")
                            Text("Fetch More Documents")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }

                // Secondary action: Proceed with current
                Button {
                    onProceed()
                } label: {
                    Text("Proceed with Current Results")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .cornerRadius(12)
    }
}
```

### 2. Integrate Decision View in Main FactCheckView

Update the main `FactCheckView` body to include the decision view:

```swift
struct FactCheckView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppSettings.self) private var settings

    @Binding var workflow: FactCheckWorkflow?

    var onReportGenerated: ((EvidenceReport) -> Void)?

    @State private var claimText = ""
    @State private var showingError = false
    @State private var errorMessage = ""

    // Search options
    @State private var selectedSearchProvider: SearchProvider = .pubmed
    @State private var includePreprints: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                Text("Medical Fact Check")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                // Configuration warning (if needed)
                if !settings.isLLMConfigured {
                    ConfigurationWarningView()
                }

                // Claim input section
                ClaimInputSection(
                    claimText: $claimText,
                    isRunning: workflow?.isRunning ?? false,
                    canSubmit: canSubmit,
                    selectedSearchProvider: $selectedSearchProvider,
                    includePreprints: $includePreprints,
                    onSubmit: startFactCheck
                )

                // Progress section (when running)
                if let workflow = workflow, workflow.isRunning {
                    ProgressSection(workflow: workflow)
                }

                // User decision section (when awaiting input)
                if let workflow = workflow, workflow.awaitingUserDecision {
                    UserDecisionView(
                        workflow: workflow,
                        prompt: workflow.userDecisionPrompt,
                        showSmartSearchOption: workflow.awaitingSmartSearchDecision,
                        onContinue: {
                            Task { await workflow.continueWithMoreDocuments() }
                        },
                        onSmartSearch: {
                            Task { await workflow.continueWithSmartSearch() }
                        },
                        onProceed: {
                            Task { await workflow.proceedWithCurrentDocuments() }
                        }
                    )
                }

                // Scored documents section
                if let session = workflow?.session {
                    ScoredDocumentsSection(session: session)
                }

                Spacer()
            }
            .padding()
        }
        .alert("Error", isPresented: $showingError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage)
        }
        .onAppear {
            selectedSearchProvider = settings.selectedSearchProvider
            includePreprints = settings.includePreprints
        }
    }

    // MARK: - Computed Properties

    private var canSubmit: Bool {
        let trimmed = claimText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && settings.isLLMConfigured && !(workflow?.isRunning ?? false)
    }

    // MARK: - Actions

    private func startFactCheck() {
        let newWorkflow = FactCheckWorkflow(modelContext: modelContext, settings: settings)

        newWorkflow.onComplete = { report in
            onReportGenerated?(report)
        }

        newWorkflow.onError = { error in
            errorMessage = error.localizedDescription
            showingError = true
        }

        self.workflow = newWorkflow

        let searchOptions = SearchOptions(
            provider: selectedSearchProvider,
            includePreprints: includePreprints,
            maxResults: settings.batchSize,
            offset: 0
        )

        Task {
            await newWorkflow.startFactCheck(claim: claimText, overrideSearchOptions: searchOptions)
        }
    }
}
```

### 3. Add Search Provider Picker (Optional Enhancement)

For mobile, you might want a compact picker for search provider:

```swift
/// Compact search options for iOS.
struct SearchOptionsSection: View {
    @Binding var selectedProvider: SearchProvider
    @Binding var includePreprints: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Provider picker
            HStack {
                Text("Search Provider")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Spacer()

                Picker("Provider", selection: $selectedProvider) {
                    Text("PubMed").tag(SearchProvider.pubmed)
                    Text("Europe PMC").tag(SearchProvider.europePMC)
                    Text("Both").tag(SearchProvider.both)
                }
                .pickerStyle(.menu)
            }

            // Preprints toggle (only for Europe PMC or Both)
            if selectedProvider.supportsPreprints {
                Toggle("Include Preprints", isOn: $includePreprints)
                    .font(.subheadline)
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(8)
    }
}
```

### 4. Update Progress Section

Ensure progress section shows the generated query:

```swift
/// Progress display during workflow execution.
struct ProgressSection: View {
    let workflow: FactCheckWorkflow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Progress indicator
            HStack {
                ProgressView()

                Text(workflow.progressMessage)
                    .font(.body)
                    .foregroundColor(.secondary)

                Spacer()
            }

            // Progress bar
            if let session = workflow.session {
                ProgressView(value: session.progressPercent, total: 100)
                    .progressViewStyle(.linear)

                // Show generated query once available
                if let query = session.pubmedQuery, !query.isEmpty {
                    DisclosureGroup("Generated Query") {
                        Text(query)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(6)
                    }
                    .font(.caption)
                }
            }
        }
        .padding()
        .background(Color.accentColor.opacity(0.05))
        .cornerRadius(12)
    }
}
```

### 5. Handle Smart Search Callback (Optional)

If you want a custom alert/sheet for smart search decision instead of inline buttons:

```swift
// In FactCheckView
@State private var showSmartSearchAlert = false

// Add to onAppear or workflow initialization:
newWorkflow.onAskSmartSearch = { message, completion in
    // Option A: Use the inline UserDecisionView (already implemented)

    // Option B: Show a sheet/alert
    // showSmartSearchAlert = true
    // ... handle completion in alert actions
}
```

## iOS-Specific Adaptations

### Mobile Layout Considerations

1. **Vertical Layout**: Use `VStack` instead of `HSplitView`
2. **Smaller Touch Targets**: Use `.controlSize(.large)` for buttons
3. **Compact Information**: Use disclosure groups for query details
4. **Pull to Refresh**: Consider adding for resuming search

### Accessibility

Ensure all buttons have appropriate:
- `accessibilityLabel`
- `accessibilityHint`
- Sufficient touch target size (44x44 pt minimum)

```swift
Button {
    onSmartSearch?()
} label: {
    // ... button content
}
.accessibilityLabel("Try Smart Search")
.accessibilityHint("Generates alternative search queries to find more relevant documents")
```

## Validation Steps

1. Build iOS project - no compilation errors
2. Launch app and test:
   - Enter a claim and start fact-check
   - Verify decision prompt appears after scoring
   - Test "Fetch More Documents" flow
   - Test "Try Smart Search" flow (when available)
   - Test "Proceed with Current" flow
3. Test edge cases:
   - No results found -> smart search prompt
   - Some results but below threshold -> shows both options
   - Sufficient results -> shows proceed option
4. Verify accessibility:
   - VoiceOver reads buttons correctly
   - All interactive elements accessible

## Reference Files

- macOS version: `macos/MedicalFactCheckerMac/Sources/Views/FactCheck/MacFactCheckView.swift`
- macOS decision section: Lines 559-607
