# Phase 5: Hybrid Search UI & Result Merging (macOS)

This document details the macOS-specific user interface implementation for search provider selection, preprint toggling, and result display with merged results.

---

## Goals

1. Add search provider picker to toolbar in `MacFactCheckView`
2. Add preprint toggle (opt-in, Europe PMC only)
3. Update `FactCheckWorkflow` to use selected provider
4. Handle "fetch more" from specific providers
5. Show provider badges on document cards
6. Add search provider section to Settings

---

## 1. Toolbar Search Options

### File: `Sources/Views/FactCheck/MacSearchOptionsToolbar.swift` (new file)

```swift
//
//  MacSearchOptionsToolbar.swift
//  MedicalFactChecker
//
//  Toolbar items for search provider selection on macOS.
//

import SwiftUI

/// Toolbar content for search provider selection.
struct MacSearchOptionsToolbar: ToolbarContent {
    @Binding var selectedProvider: SearchProvider
    @Binding var includePreprints: Bool

    var body: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Picker("Provider", selection: $selectedProvider) {
                ForEach(SearchProvider.allCases) { provider in
                    Label(provider.displayName, systemImage: provider.iconName)
                        .tag(provider)
                }
            }
            .pickerStyle(.menu)
            .frame(width: MacLayout.sortPickerWidth)
            .help("Select search provider")
        }

        ToolbarItem(placement: .automatic) {
            Toggle(isOn: $includePreprints) {
                Label("Preprints", systemImage: "doc.badge.clock")
            }
            .toggleStyle(.checkbox)
            .disabled(!selectedProvider.supportsPreprints)
            .help(preprintToggleHelp)
        }
    }

    private var preprintToggleHelp: String {
        if selectedProvider.supportsPreprints {
            return "Include preprints from bioRxiv, medRxiv, and other servers"
        } else {
            return "Preprints only available with Europe PMC"
        }
    }
}

// MARK: - Provider Badge

/// Badge showing which provider a document came from.
struct MacProviderBadge: View {
    let provider: SearchProvider?

    var body: some View {
        if let provider = provider {
            HStack(spacing: MacSpacing.xxSmall) {
                Image(systemName: provider.iconName)
                    .font(.caption2)
                Text(provider.shortName)
                    .font(.caption2)
            }
            .foregroundColor(badgeColor)
            .padding(.horizontal, MacSpacing.small)
            .padding(.vertical, MacSpacing.xxSmall)
            .background(badgeColor.opacity(MacOpacity.badgeBackground))
            .cornerRadius(MacCornerRadius.small)
        }
    }

    private var badgeColor: Color {
        switch provider {
        case .pubmed: return .blue
        case .europePMC: return .green
        case .both: return .purple
        case .none: return .gray
        }
    }
}

// MARK: - SearchProvider Extension

extension SearchProvider {
    /// Short name for badge display.
    var shortName: String {
        switch self {
        case .pubmed: return "PM"
        case .europePMC: return "EPMC"
        case .both: return "Both"
        }
    }
}

#Preview {
    VStack(spacing: 16) {
        MacProviderBadge(provider: .pubmed)
        MacProviderBadge(provider: .europePMC)
        MacProviderBadge(provider: .both)
    }
    .padding()
}
```

---

## 2. MacFactCheckView Integration

### File: `Sources/Views/FactCheck/MacFactCheckView.swift` (modify)

Add search provider state and toolbar:

```swift
struct MacFactCheckView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var modelContext

    // Search options state
    @State private var selectedSearchProvider: SearchProvider = .pubmed
    @State private var includePreprints: Bool = false

    // ... existing state variables ...

    var body: some View {
        VStack(spacing: 0) {
            // ... existing content ...
        }
        .toolbar {
            // Search options in toolbar
            MacSearchOptionsToolbar(
                selectedProvider: $selectedSearchProvider,
                includePreprints: $includePreprints
            )

            // ... existing toolbar items ...
        }
        .onAppear {
            // Initialize from settings
            selectedSearchProvider = settings.selectedSearchProvider
            includePreprints = settings.includePreprints
        }
        .onChange(of: selectedSearchProvider) { _, newValue in
            // Reset preprints if provider doesn't support it
            if !newValue.supportsPreprints {
                includePreprints = false
            }
        }
    }

    // Update startFactCheck to pass options
    private func startFactCheck() {
        guard !claimText.isEmpty else { return }

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
}
```

---

## 3. Document Card Provider Badge

### File: `Sources/Views/FactCheck/MacScoredDocumentsView.swift` (modify)

Add provider badge to `MacDocumentCard`:

```swift
struct MacDocumentCard: View {
    let document: Document
    let isExpanded: Bool
    let showEmbeddingScore: Bool
    let onToggleExpand: () -> Void
    var onShowFullText: ((Document) -> Void)?

    private var cardHeader: some View {
        HStack(alignment: .top, spacing: MacSpacing.large) {
            // Score badge
            MacScoreBadge(score: document.relevanceScore)

            // Title and metadata
            VStack(alignment: .leading, spacing: MacSpacing.xSmall) {
                Text(document.title)
                    .font(.headline)
                    .lineLimit(isExpanded ? nil : 2)

                HStack(spacing: MacSpacing.medium) {
                    Text(document.formattedAuthors)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)

                    if let journal = document.journal, let year = document.year {
                        Text("•")
                            .foregroundColor(.secondary)
                        Text(verbatim: "\(journal), \(year)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }

                    // Provider badge
                    MacProviderBadge(provider: documentProvider)
                }
            }

            Spacer()

            // ... existing embedding score and expand indicator ...
        }
        .padding(MacSpacing.large)
    }

    /// Determine the provider based on document properties.
    private var documentProvider: SearchProvider? {
        // Documents from Europe PMC often have pmcId but empty pmid
        if document.pmid.isEmpty && document.pmcId != nil {
            return .europePMC
        }
        // Check if it's a preprint (would come from Europe PMC)
        if document.journal?.lowercased().contains("biorxiv") == true ||
           document.journal?.lowercased().contains("medrxiv") == true {
            return .europePMC
        }
        // Default to PubMed for articles with PMID
        if !document.pmid.isEmpty {
            return .pubmed
        }
        return nil
    }
}
```

---

## 4. Fetch More View

### File: `Sources/Views/FactCheck/MacFetchMoreView.swift` (new file)

```swift
//
//  MacFetchMoreView.swift
//  MedicalFactChecker
//
//  View for fetching additional documents with provider selection on macOS.
//

import SwiftUI

/// View for fetching more documents with provider selection.
struct MacFetchMoreView: View {
    let session: FactCheckSession
    let onFetchMore: (SearchProvider?) -> Void

    @State private var showProviderPicker = false

    var body: some View {
        VStack(spacing: MacSpacing.medium) {
            HStack(spacing: MacSpacing.large) {
                // Status text
                VStack(alignment: .leading, spacing: MacSpacing.xxSmall) {
                    Text("Need more evidence?")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    Text(statusText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Fetch buttons
                if usedBothProviders {
                    providerPickerButtons
                } else {
                    Button(action: { onFetchMore(nil) }) {
                        Label("Fetch More", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!session.canFetchMoreFromAnyProvider)
                }
            }
        }
        .padding(MacSpacing.standard)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(MacCornerRadius.standard)
    }

    private var usedBothProviders: Bool {
        session.searchProvider == SearchProvider.both.rawValue
    }

    private var statusText: String {
        if !session.canFetchMoreFromAnyProvider {
            return "All available documents have been retrieved"
        }

        var parts: [String] = []
        if session.pubmedHasMore && (usedBothProviders || session.searchProvider == "pubmed") {
            parts.append("PubMed has more")
        }
        if session.europePMCHasMore && (usedBothProviders || session.searchProvider == "europepmc") {
            parts.append("Europe PMC has more")
        }

        return parts.isEmpty ? "No additional documents available" : parts.joined(separator: ", ")
    }

    private var providerPickerButtons: some View {
        HStack(spacing: MacSpacing.small) {
            if session.pubmedHasMore {
                Button(action: { onFetchMore(.pubmed) }) {
                    Label("PubMed", systemImage: "building.columns")
                }
                .buttonStyle(.bordered)
            }

            if session.europePMCHasMore {
                Button(action: { onFetchMore(.europePMC) }) {
                    Label("Europe PMC", systemImage: "globe.europe.africa")
                }
                .buttonStyle(.bordered)
            }

            Button(action: { onFetchMore(nil) }) {
                Label("Both", systemImage: "rectangle.on.rectangle")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!session.pubmedHasMore && !session.europePMCHasMore)
        }
    }
}

#Preview {
    let session = FactCheckSession(claim: "Test claim")
    session.searchProvider = SearchProvider.both.rawValue
    session.pubmedHasMore = true
    session.europePMCHasMore = true

    return MacFetchMoreView(session: session) { provider in
        print("Fetch from: \(provider?.displayName ?? "all")")
    }
    .frame(width: 500)
    .padding()
}
```

---

## 5. Search Progress View

### File: `Sources/Views/FactCheck/MacSearchProgressView.swift` (new file)

```swift
//
//  MacSearchProgressView.swift
//  MedicalFactChecker
//
//  Progress indicator for multi-provider search on macOS.
//

import SwiftUI

/// Progress view showing search status across providers.
struct MacSearchProgressView: View {
    let provider: SearchProvider
    let currentStep: String
    let pubmedCount: Int
    let europePMCCount: Int

    var body: some View {
        VStack(spacing: MacSpacing.large) {
            ProgressView()
                .scaleEffect(MacScale.progressViewMedium)

            Text(currentStep)
                .font(.headline)

            if provider == .both {
                HStack(spacing: MacSpacing.xLarge) {
                    providerStatus("PubMed", count: pubmedCount, icon: "building.columns", color: .blue)
                    providerStatus("Europe PMC", count: europePMCCount, icon: "globe.europe.africa", color: .green)
                }
            }
        }
        .padding(MacSpacing.xxLarge)
        .frame(maxWidth: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(MacCornerRadius.large)
    }

    private func providerStatus(_ name: String, count: Int, icon: String, color: Color) -> some View {
        HStack(spacing: MacSpacing.small) {
            Image(systemName: icon)
                .foregroundColor(color)

            VStack(alignment: .leading, spacing: 0) {
                Text(name)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("\(count) found")
                    .font(.caption)
                    .fontWeight(.medium)
            }
        }
        .padding(.horizontal, MacSpacing.standard)
        .padding(.vertical, MacSpacing.small)
        .background(color.opacity(MacOpacity.veryLight))
        .cornerRadius(MacCornerRadius.medium)
    }
}

#Preview {
    VStack(spacing: 20) {
        MacSearchProgressView(
            provider: .pubmed,
            currentStep: "Searching PubMed...",
            pubmedCount: 15,
            europePMCCount: 0
        )

        MacSearchProgressView(
            provider: .both,
            currentStep: "Merging results...",
            pubmedCount: 15,
            europePMCCount: 23
        )
    }
    .padding()
    .frame(width: 500)
}
```

---

## 6. Settings Integration

### File: `Sources/Views/Settings/MacSettingsView.swift` (modify)

Add search provider section:

```swift
struct MacSettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        TabView {
            // ... existing tabs ...

            // Search tab (new or integrate into existing)
            searchSettingsTab
                .tabItem {
                    Label("Search", systemImage: "magnifyingglass")
                }
        }
        // ... existing modifiers ...
    }

    private var searchSettingsTab: some View {
        Form {
            Section("Search Provider") {
                Picker("Default Provider", selection: Bindable(settings).selectedSearchProvider) {
                    ForEach(SearchProvider.allCases) { provider in
                        HStack {
                            Image(systemName: provider.iconName)
                            VStack(alignment: .leading) {
                                Text(provider.displayName)
                                Text(provider.description)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .tag(provider)
                    }
                }
                .pickerStyle(.radioGroup)

                Toggle("Include Preprints by Default", isOn: Bindable(settings).includePreprints)
                    .disabled(!settings.selectedSearchProvider.supportsPreprints)

                if !settings.selectedSearchProvider.supportsPreprints {
                    Text("Preprints are only available when using Europe PMC.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section("Provider Information") {
                providerInfoView
            }
        }
        .formStyle(.grouped)
        .frame(width: MacLayout.settingsWindowWidth)
    }

    private var providerInfoView: some View {
        VStack(alignment: .leading, spacing: MacSpacing.medium) {
            HStack(alignment: .top, spacing: MacSpacing.medium) {
                Image(systemName: "building.columns")
                    .foregroundColor(.blue)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: MacSpacing.xxSmall) {
                    Text("PubMed")
                        .fontWeight(.medium)
                    Text("NCBI's primary biomedical literature database. Uses MeSH indexing and provides the most reliable PMID identifiers.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            HStack(alignment: .top, spacing: MacSpacing.medium) {
                Image(systemName: "globe.europe.africa")
                    .foregroundColor(.green)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: MacSpacing.xxSmall) {
                    Text("Europe PMC")
                        .fontWeight(.medium)
                    Text("European mirror with access to preprints from 34 servers including bioRxiv and medRxiv. Also provides full-text XML for many articles.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            HStack(alignment: .top, spacing: MacSpacing.medium) {
                Image(systemName: "rectangle.on.rectangle")
                    .foregroundColor(.purple)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: MacSpacing.xxSmall) {
                    Text("Both (Merged)")
                        .fontWeight(.medium)
                    Text("Search both providers simultaneously. Results are merged with duplicates removed based on PMID, DOI, and title similarity.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, MacSpacing.small)
    }
}
```

---

## 7. User Flow Diagram

```
┌─────────────────────────────────────────────────────────────────────────┐
│ Medical Fact Checker                        [Provider: Europe PMC ▼]    │
│                                             ☑️ Include Preprints       │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  ┌────────────────────────────────────────────────────────────────────┐ │
│  │ Enter your medical claim...                                        │ │
│  └────────────────────────────────────────────────────────────────────┘ │
│                                                                          │
│  ┌─────────────────────────────┐                                        │
│  │  🔍 Check This Claim        │                                        │
│  └─────────────────────────────┘                                        │
│                                                                          │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│                        Searching Europe PMC...                           │
│                               ◐                                          │
│                                                                          │
│        ┌─────────────────┐          ┌─────────────────┐                 │
│        │ 🏛️ PubMed: 15   │          │ 🌍 EPMC: 23     │                 │
│        └─────────────────┘          └─────────────────┘                 │
│                                                                          │
├─────────────────────────────────────────────────────────────────────────┤
│ Documents                    │ Full Text                                 │
│ ────────────────────────── │ ──────────────────────────────────────── │
│                              │                                           │
│ [5] Preprint Study...   EPMC │  # Preprint Study Title                  │
│     bioRxiv 2024             │                                           │
│     ─────────────────────    │  **Authors:** Smith et al.               │
│     📄 View Full Text        │                                           │
│                              │  ## Abstract                              │
│ [4] Meta-analysis...    PM   │                                           │
│     J Med Virol 2024         │  Background: This study investigates...  │
│                              │                                           │
│ [4] COVID Study...      EPMC │  ## Methods                               │
│     medRxiv 2024             │                                           │
│                              │  We conducted a systematic review...     │
│ ────────────────────────── │                                           │
│                              │                                           │
│ ┌─────────────────────────┐  │                                           │
│ │ Need more evidence?     │  │                                           │
│ │ [PubMed] [EPMC] [Both]  │  │                                           │
│ └─────────────────────────┘  │                                           │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 8. Accessibility

```swift
// Toolbar picker
Picker("Provider", selection: $selectedProvider) { ... }
    .accessibilityLabel("Search provider")
    .accessibilityHint("Choose which database to search")

// Preprint toggle
Toggle(isOn: $includePreprints) { ... }
    .accessibilityLabel("Include preprints")
    .accessibilityHint("When enabled, search includes non-peer-reviewed preprints from bioRxiv, medRxiv, and other servers")

// Provider badge
MacProviderBadge(provider: .europePMC)
    .accessibilityLabel("Document from Europe PMC")

// Fetch more view
MacFetchMoreView(...)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Fetch more documents")
```

---

## 9. Keyboard Shortcuts

Add keyboard shortcuts for common actions:

```swift
// In MacFactCheckView
.keyboardShortcut("1", modifiers: [.command, .shift]) // PubMed
.keyboardShortcut("2", modifiers: [.command, .shift]) // Europe PMC
.keyboardShortcut("3", modifiers: [.command, .shift]) // Both

// Add menu bar commands
CommandGroup(after: .toolbar) {
    Menu("Search Provider") {
        Button("PubMed") {
            selectedSearchProvider = .pubmed
        }
        .keyboardShortcut("1", modifiers: [.command, .shift])

        Button("Europe PMC") {
            selectedSearchProvider = .europePMC
        }
        .keyboardShortcut("2", modifiers: [.command, .shift])

        Button("Both") {
            selectedSearchProvider = .both
        }
        .keyboardShortcut("3", modifiers: [.command, .shift])

        Divider()

        Toggle("Include Preprints", isOn: $includePreprints)
            .keyboardShortcut("P", modifiers: [.command, .shift])
    }
}
```

---

## 10. Testing Checklist

### UI Tests

- [ ] Toolbar picker shows all providers
- [ ] Preprint toggle is disabled for PubMed-only
- [ ] Provider badges appear on document cards
- [ ] Progress shows correct provider counts
- [ ] "Fetch more" shows provider options when using Both
- [ ] Settings persist search provider selection

### Integration Tests

- [ ] PubMed-only search works
- [ ] Europe PMC-only search works
- [ ] Merged search returns deduplicated results
- [ ] Preprint filter works
- [ ] "Fetch more" retrieves additional documents
- [ ] Session stores and restores search options

### Accessibility Tests

- [ ] VoiceOver navigates toolbar controls
- [ ] Provider selection announced correctly
- [ ] Preprint toggle state announced
- [ ] Keyboard shortcuts work

---

## 11. Files to Create/Modify

### New Files

- `Sources/Views/FactCheck/MacSearchOptionsToolbar.swift`
- `Sources/Views/FactCheck/MacFetchMoreView.swift`
- `Sources/Views/FactCheck/MacSearchProgressView.swift`

### Modified Files

- `Sources/Views/FactCheck/MacFactCheckView.swift` (add toolbar, search options)
- `Sources/Views/FactCheck/MacScoredDocumentsView.swift` (add provider badges)
- `Sources/Views/Settings/MacSettingsView.swift` (add search provider section)
- `Sources/App/MedicalFactCheckerMacApp.swift` (add menu commands)

---

## 12. Estimated Effort

| Task | Complexity | Notes |
|------|------------|-------|
| MacSearchOptionsToolbar | Low | Standard toolbar items |
| MacProviderBadge | Low | Simple badge component |
| MacFactCheckView integration | Medium | Wire up options |
| MacFetchMoreView | Medium | Provider-specific fetch |
| MacSearchProgressView | Low | Progress indicator |
| Settings integration | Medium | New settings section |
| Menu bar commands | Low | Keyboard shortcuts |
| Accessibility | Low | Labels and hints |

**Total estimated complexity: Medium-High**

---

## Summary

This completes the planning documentation for both features on macOS:

### Full-Text Retrieval (Phases 1-2)

- Europe PMC XML → markdown conversion (shared)
- Unpaywall PDF fallback (shared)
- macOS split view for side-by-side reading
- PDF viewing with PDFKit
- "Open in Preview" functionality

### Hybrid Search (Phases 3-5)

- Europe PMC service with preprint support (shared)
- Query syntax translation (shared)
- Toolbar-based provider selection
- Result merging with deduplication (shared)
- Provider badges on document cards

### All Documentation

Located in `docs/planning/fulltext_retrieval/macos/`:

- `00-architecture-overview.md` - This overview
- `01-fulltext-service-model.md` - Shared code reference
- `02-fulltext-ui-macos.md` - macOS-specific UI
- `03-search-provider-abstraction.md` - Shared code reference
- `04-query-translator.md` - Shared code reference
- `05-hybrid-search-ui-macos.md` - macOS-specific UI

Reference iOS documentation in parent directory for shared code details.
