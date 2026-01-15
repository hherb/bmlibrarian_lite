# Phase 5: Hybrid Search UI & Result Merging

This document details the user interface implementation for search provider selection, preprint toggling, and result display with merged results.

---

## Goals

1. Add search options to `FactCheckView` (per-search toggle)
2. Add preprint checkbox (opt-in, Europe PMC only)
3. Update `FactCheckWorkflow` to use selected provider
4. Handle "fetch more" from specific providers
5. Show provider badges on documents

---

## 1. Search Options UI

### File: `Sources/Views/FactCheck/SearchOptionsView.swift` (new file)

```swift
//
//  SearchOptionsView.swift
//  MedicalFactChecker
//
//  Search provider and options selection UI.
//

import SwiftUI

/// Collapsible search options panel for provider selection.
struct SearchOptionsView: View {
    @Binding var selectedProvider: SearchProvider
    @Binding var includePreprints: Bool

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header toggle
            Button(action: { withAnimation { isExpanded.toggle() } }) {
                HStack {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundColor(.secondary)

                    Text("Search Options")
                        .font(.subheadline)
                        .foregroundColor(.primary)

                    Spacer()

                    // Show current selection summary
                    Text(selectedProvider.displayName)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if includePreprints && selectedProvider.supportsPreprints {
                        Text("+ Preprints")
                            .font(.caption)
                            .foregroundColor(.blue)
                    }

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                expandedOptions
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(10)
    }

    // MARK: - Expanded Options

    private var expandedOptions: some View {
        VStack(alignment: .leading, spacing: 16) {
            Divider()

            // Provider selection
            VStack(alignment: .leading, spacing: 8) {
                Text("Search Provider")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)

                ForEach(SearchProvider.allCases) { provider in
                    providerRow(provider)
                }
            }

            // Preprint toggle (only if provider supports it)
            if selectedProvider.supportsPreprints {
                Divider()

                Toggle(isOn: $includePreprints) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Include Preprints")
                            .font(.subheadline)
                        Text("bioRxiv, medRxiv, and 32 other servers")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .tint(.blue)
            }

            // Info text
            infoText
        }
    }

    private func providerRow(_ provider: SearchProvider) -> some View {
        Button(action: {
            withAnimation { selectedProvider = provider }
        }) {
            HStack {
                Image(systemName: provider.iconName)
                    .foregroundColor(selectedProvider == provider ? .blue : .secondary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.displayName)
                        .font(.subheadline)
                        .foregroundColor(.primary)
                    Text(provider.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if selectedProvider == provider {
                    Image(systemName: "checkmark")
                        .foregroundColor(.blue)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selectedProvider == provider ? Color.blue.opacity(0.1) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    private var infoText: some View {
        Group {
            switch selectedProvider {
            case .pubmed:
                Label(
                    "Standard PubMed search via NCBI E-utilities",
                    systemImage: "info.circle"
                )
            case .europePMC:
                Label(
                    "Access to preprints and full-text search",
                    systemImage: "info.circle"
                )
            case .both:
                Label(
                    "Results merged with duplicate removal",
                    systemImage: "info.circle"
                )
            }
        }
        .font(.caption)
        .foregroundColor(.secondary)
    }
}

// MARK: - Preview

#Preview {
    VStack {
        SearchOptionsView(
            selectedProvider: .constant(.pubmed),
            includePreprints: .constant(false)
        )

        SearchOptionsView(
            selectedProvider: .constant(.europePMC),
            includePreprints: .constant(true)
        )

        SearchOptionsView(
            selectedProvider: .constant(.both),
            includePreprints: .constant(true)
        )
    }
    .padding()
}
```

---

## 2. FactCheckView Integration

### File: `Sources/Views/FactCheck/FactCheckView.swift` (modify)

Add search options to the main fact-check view:

```swift
// Add state variables at the top of FactCheckView
@State private var selectedSearchProvider: SearchProvider = .pubmed
@State private var includePreprints: Bool = false

// Add SearchOptionsView before the claim input field
var body: some View {
    ScrollView {
        VStack(alignment: .leading, spacing: 20) {

            // Search Options (collapsible)
            SearchOptionsView(
                selectedProvider: $selectedSearchProvider,
                includePreprints: $includePreprints
            )

            // Claim input
            claimInputSection

            // ... rest of view ...
        }
    }
    .onChange(of: selectedSearchProvider) { _, newValue in
        // Reset preprints if provider doesn't support it
        if !newValue.supportsPreprints {
            includePreprints = false
        }
    }
}

// Modify the startFactCheck action to pass options
private func startFactCheck() {
    guard !claimText.isEmpty else { return }

    // Build options for this search
    let options = SearchOptions(
        provider: selectedSearchProvider,
        includePreprints: includePreprints,
        maxResults: settings.batchSize,
        offset: 0
    )

    Task {
        await workflow.startFactCheck(
            claim: claimText,
            searchOptions: options
        )
    }
}
```

---

## 3. Workflow Updates

### File: `Sources/Services/FactCheckWorkflow.swift` (modify)

Update the workflow to accept and use search options:

```swift
// Add searchOptions property
private var searchOptions: SearchOptions?

/// Start a new fact-check with specific search options.
func startFactCheck(claim: String, searchOptions: SearchOptions) async {
    self.searchOptions = searchOptions

    // ... existing initialization ...

    // Store selected provider in session for resumability
    session?.searchProvider = searchOptions.provider.rawValue
    session?.includePreprints = searchOptions.includePreprints

    await runWorkflow()
}

/// Resume uses stored options from session.
func resumeSession(_ session: FactCheckSession) async {
    // Restore search options from session
    if let providerString = session.searchProvider,
       let provider = SearchProvider(rawValue: providerString) {
        self.searchOptions = SearchOptions(
            provider: provider,
            includePreprints: session.includePreprints,
            maxResults: settings.batchSize,
            offset: session.currentSearchOffset
        )
    } else {
        // Default fallback
        self.searchOptions = settings.buildSearchOptions()
    }

    // ... rest of resume logic ...
}

// Update searchPubMed to use SearchServiceFactory
private func searchDocuments() async throws {
    guard let session = session,
          let query = session.pubmedQuery else { return }

    let options = searchOptions ?? settings.buildSearchOptions()
    var searchOpts = options
    searchOpts.offset = session.currentSearchOffset
    searchOpts.maxResults = settings.batchSize

    let providerName = options.provider.displayName
    updateProgress(.searchingPubMed, "Searching \(providerName)...")

    let result = try await SearchServiceFactory.search(
        query: query,
        options: searchOpts,
        settings: settings
    )

    // ... rest of method unchanged ...
}
```

---

## 4. Session Model Updates

### File: `Sources/Models/FactCheckSession.swift` (modify)

Add provider tracking to session:

```swift
// Add properties for search provider tracking
var searchProvider: String?
var includePreprints: Bool = false

// For "fetch more" functionality - track which providers have more
var pubmedHasMore: Bool = true
var europePMCHasMore: Bool = true
var pubmedOffset: Int = 0
var europePMCOffset: Int = 0

/// Whether more documents can be fetched from any provider.
var canFetchMoreFromAnyProvider: Bool {
    guard let providerString = searchProvider,
          let provider = SearchProvider(rawValue: providerString) else {
        return canFetchMoreDocuments
    }

    switch provider {
    case .pubmed:
        return pubmedHasMore
    case .europePMC:
        return europePMCHasMore
    case .both:
        return pubmedHasMore || europePMCHasMore
    }
}
```

---

## 5. Document Provider Badge

### File: `Sources/Views/FactCheck/ScoredDocumentsView.swift` (modify)

Add source indicator to document cards:

```swift
// Add to DocumentScoreRow
@ViewBuilder
private var sourceIndicator: some View {
    if let source = documentSource {
        HStack(spacing: 4) {
            Image(systemName: source.iconName)
            Text(source.displayName)
        }
        .font(.caption2)
        .foregroundColor(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(4)
    }
}

private var documentSource: SearchProvider? {
    // Determine source based on document properties
    // Europe PMC articles often have pmcId; preprints have specific markers
    if document.pmid.isEmpty && document.pmcId != nil {
        return .europePMC
    }
    // Default to PubMed for articles with PMID
    return .pubmed
}

// Add sourceIndicator to metadataView
private var metadataView: some View {
    HStack(spacing: 12) {
        sourceIndicator  // Add this

        if let journal = document.journal {
            Label(journal, systemImage: "book")
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }

        Label("PMID: \(document.pmid)", systemImage: "number")
            .font(.caption2)
            .foregroundColor(.secondary)
    }
}
```

---

## 6. "Fetch More" Provider Selection

### File: `Sources/Views/FactCheck/FetchMoreView.swift` (new file)

```swift
//
//  FetchMoreView.swift
//  MedicalFactChecker
//
//  View for fetching additional documents with provider selection.
//

import SwiftUI

/// View for fetching more documents with provider selection.
struct FetchMoreView: View {
    let session: FactCheckSession
    let onFetchMore: (SearchProvider?) -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("Need more evidence?")
                .font(.subheadline)
                .fontWeight(.medium)

            if session.searchProvider == SearchProvider.both.rawValue {
                // Show per-provider options
                HStack(spacing: 12) {
                    if session.pubmedHasMore {
                        fetchButton(for: .pubmed)
                    }
                    if session.europePMCHasMore {
                        fetchButton(for: .europePMC)
                    }
                    fetchButton(for: nil, label: "Both")
                }
            } else {
                // Single provider
                Button(action: { onFetchMore(nil) }) {
                    Label("Fetch More Documents", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
            }

            // Status text
            if !session.canFetchMoreFromAnyProvider {
                Text("All available documents have been retrieved")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(10)
    }

    private func fetchButton(for provider: SearchProvider?, label: String? = nil) -> some View {
        Button(action: { onFetchMore(provider) }) {
            VStack(spacing: 4) {
                Image(systemName: provider?.iconName ?? "arrow.down.circle")
                Text(label ?? provider?.displayName ?? "More")
                    .font(.caption)
            }
            .frame(minWidth: 80)
        }
        .buttonStyle(.bordered)
    }
}

#Preview {
    let session = FactCheckSession(claim: "Test")
    session.searchProvider = SearchProvider.both.rawValue
    session.pubmedHasMore = true
    session.europePMCHasMore = true

    return FetchMoreView(session: session) { provider in
        print("Fetch from: \(provider?.displayName ?? "all")")
    }
}
```

---

## 7. Settings Integration

### File: `Sources/Views/Settings/SettingsView.swift` (modify)

Add default search provider setting:

```swift
// Add to SettingsView
Section("Search") {
    // Default Provider
    Picker("Default Provider", selection: $settings.selectedSearchProvider) {
        ForEach(SearchProvider.allCases) { provider in
            HStack {
                Image(systemName: provider.iconName)
                Text(provider.displayName)
            }
            .tag(provider)
        }
    }

    // Default Preprint Setting
    Toggle("Include Preprints by Default", isOn: $settings.includePreprints)
        .disabled(!settings.selectedSearchProvider.supportsPreprints)

    // Info
    if settings.selectedSearchProvider == .both {
        Text("Results from both providers will be merged with duplicates removed.")
            .font(.caption)
            .foregroundColor(.secondary)
    }
}
```

---

## 8. Progress Indicators

### File: `Sources/Views/FactCheck/SearchProgressView.swift` (new file)

```swift
//
//  SearchProgressView.swift
//  MedicalFactChecker
//
//  Progress indicator for multi-provider search.
//

import SwiftUI

/// Progress view showing search status across providers.
struct SearchProgressView: View {
    let provider: SearchProvider
    let currentStep: String
    let pubmedCount: Int
    let europePMCCount: Int

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()

            Text(currentStep)
                .font(.subheadline)
                .foregroundColor(.secondary)

            if provider == .both {
                HStack(spacing: 16) {
                    providerStatus("PubMed", count: pubmedCount, icon: "building.columns")
                    providerStatus("Europe PMC", count: europePMCCount, icon: "globe.europe.africa")
                }
            }
        }
        .padding()
    }

    private func providerStatus(_ name: String, count: Int, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .foregroundColor(.secondary)
            Text("\(name): \(count)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        SearchProgressView(
            provider: .pubmed,
            currentStep: "Searching PubMed...",
            pubmedCount: 15,
            europePMCCount: 0
        )

        SearchProgressView(
            provider: .both,
            currentStep: "Merging results...",
            pubmedCount: 15,
            europePMCCount: 23
        )
    }
}
```

---

## 9. User Flow Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                      Fact Check View                             │
├─────────────────────────────────────────────────────────────────┤
│  ┌───────────────────────────────────────────────────────────┐  │
│  │ ⚙️ Search Options                    PubMed       ▼      │  │
│  │ ─────────────────────────────────────────────────────────│  │
│  │ Search Provider                                           │  │
│  │   ○ PubMed - NCBI's biomedical database                  │  │
│  │   ● Europe PMC - With preprints from 34 servers     ✓    │  │
│  │   ○ Both (merged) - Results merged with dedup            │  │
│  │ ─────────────────────────────────────────────────────────│  │
│  │ ☑️ Include Preprints                                      │  │
│  │    bioRxiv, medRxiv, and 32 other servers                │  │
│  └───────────────────────────────────────────────────────────┘  │
│                                                                 │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │ Enter your medical claim or question...                   │  │
│  └───────────────────────────────────────────────────────────┘  │
│                                                                 │
│  ┌──────────────────────────────────────────┐                   │
│  │           🔍 Check This Claim            │                   │
│  └──────────────────────────────────────────┘                   │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Search Progress                               │
├─────────────────────────────────────────────────────────────────┤
│                          ◐                                      │
│                                                                 │
│               Searching Europe PMC...                           │
│                                                                 │
│        🏛️ PubMed: 0    🌍 Europe PMC: 23                        │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                   Scored Documents                               │
├─────────────────────────────────────────────────────────────────┤
│  [5] Preprint: SARS-CoV-2 Variants of Concern        🌍 EPMC   │
│      bioRxiv 2024 | Not yet peer-reviewed                       │
│  ─────────────────────────────────────────────────────────────  │
│  [4] Meta-analysis of Vitamin D...                   🏛️ PubMed │
│      J Med Virol 2024 | PMID: 12345678                          │
│  ─────────────────────────────────────────────────────────────  │
│  [4] COVID-19 Vaccine Efficacy Study                 🌍 EPMC   │
│      medRxiv 2024 | Preprint                                    │
└─────────────────────────────────────────────────────────────────┘
```

---

## 10. Accessibility

```swift
// Search options accessibility
SearchOptionsView(...)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Search Options")
    .accessibilityHint("Expand to choose search provider and options")

// Provider selection
providerRow(.europePMC)
    .accessibilityLabel("Europe PMC")
    .accessibilityValue(selectedProvider == .europePMC ? "Selected" : "Not selected")
    .accessibilityHint("Search Europe PMC database with preprint support")

// Preprint toggle
Toggle(isOn: $includePreprints) { ... }
    .accessibilityLabel("Include preprints")
    .accessibilityHint("When enabled, search includes non-peer-reviewed preprints from bioRxiv and medRxiv")
```

---

## 11. Testing Checklist

### UI Tests

- [ ] Search options expand/collapse
- [ ] Provider selection works
- [ ] Preprint toggle only shows for supporting providers
- [ ] Settings update when provider changes
- [ ] Progress shows correct provider info
- [ ] Document cards show source badges
- [ ] "Fetch more" shows provider options for merged search

### Integration Tests

- [ ] PubMed-only search works
- [ ] Europe PMC-only search works
- [ ] Merged search returns deduplicated results
- [ ] Preprint filter works
- [ ] "Fetch more" retrieves additional documents
- [ ] Session stores and restores search options

### Accessibility Tests

- [ ] VoiceOver navigates search options
- [ ] Provider selection announced correctly
- [ ] Preprint toggle state announced
- [ ] Progress updates announced

---

## 12. Files to Create/Modify

### New Files
- `Sources/Views/FactCheck/SearchOptionsView.swift`
- `Sources/Views/FactCheck/FetchMoreView.swift`
- `Sources/Views/FactCheck/SearchProgressView.swift`

### Modified Files
- `Sources/Views/FactCheck/FactCheckView.swift` (add search options)
- `Sources/Views/FactCheck/ScoredDocumentsView.swift` (add source badges)
- `Sources/Views/Settings/SettingsView.swift` (add default provider)
- `Sources/Models/FactCheckSession.swift` (add provider tracking)
- `Sources/Services/FactCheckWorkflow.swift` (use SearchServiceFactory)

---

## 13. Estimated Effort

| Task | Complexity | Notes |
|------|------------|-------|
| SearchOptionsView | Medium | New collapsible panel |
| FactCheckView integration | Low | Wire up options |
| Workflow updates | Medium | Use SearchServiceFactory |
| Session model updates | Low | Add tracking fields |
| Source badges | Low | Simple indicator |
| FetchMoreView | Medium | Provider-specific fetch |
| SearchProgressView | Low | Progress indicator |
| Settings integration | Low | Add picker |
| Accessibility | Low | Labels and hints |

**Total estimated complexity: High** (due to scope)

---

## Summary

This completes the planning documentation for both features:

1. **Full-Text Retrieval** (Phases 1-2)
   - Europe PMC XML → markdown conversion
   - Unpaywall PDF fallback
   - In-app viewer with share options

2. **Hybrid Search** (Phases 3-5)
   - Europe PMC service with preprint support
   - Query syntax translation
   - Per-search provider selection
   - Result merging with deduplication

All documentation is located in `docs/planning/`:
- `00-architecture-overview.md`
- `01-fulltext-service-model.md`
- `02-fulltext-ui.md`
- `03-search-provider-abstraction.md`
- `04-query-translator.md`
- `05-hybrid-search-ui.md`
