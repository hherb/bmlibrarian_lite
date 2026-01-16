# Architecture Overview: Full-Text Retrieval & Hybrid Search (macOS)

This document provides a bird's eye view of two interconnected features for the macOS MedicalFactCheckerMac app:

1. **Full-Text Retrieval** - "Get Full Text" button with fallback chain
2. **Hybrid Search** - Europe PMC as an alternative/complement to PubMed

This plan builds on the iOS implementation documented in the parent directory, with macOS-specific adaptations for the desktop environment.

---

## macOS-Specific Considerations

The macOS app has several architectural differences from iOS that influence this implementation:

### Current macOS Structure

| Component | Location | Notes |
|-----------|----------|-------|
| App Entry | `Sources/App/MedicalFactCheckerMacApp.swift` | SwiftData, window management |
| Main View | `Sources/App/MacContentView.swift` | Tab-based navigation |
| Fact Check | `Sources/Views/FactCheck/MacFactCheckView.swift` | macOS-optimized layout |
| Documents | `Sources/Views/FactCheck/MacScoredDocumentsView.swift` | Expandable card design |
| Settings | `Sources/Views/Settings/MacSettingsView.swift` | Native Settings scene |
| Constants | `Sources/MacConstants.swift` | Layout, spacing, colors |

### Platform Differences from iOS

| Aspect | iOS | macOS |
|--------|-----|-------|
| PDF Viewing | Quick Look / PDFKit UIViewRepresentable | PDFKit NSViewRepresentable (already present) |
| Full-text display | Sheet presentation | Split view or window |
| Share actions | UIActivityViewController | NSSharingServicePicker |
| Clipboard | UIPasteboard | NSPasteboard |
| Open URLs | UIApplication.shared.open() | NSWorkspace.shared.open() |
| Window sizing | Fixed/adaptive | Resizable with constraints |
| Context menus | Long-press | Right-click |

---

## Feature 1: Full-Text Retrieval

### User Story

As a macOS user reviewing scored documents, I want to retrieve the full text of an article so I can read beyond the abstract and verify the evidence, taking advantage of the larger screen for side-by-side viewing.

### Behavior

1. User clicks "Get Full Text" button on an expanded document card
2. System attempts retrieval in order:
   - **Europe PMC XML** → Convert to markdown, display in-app
   - **Unpaywall PDF** → Download PDF, display with PDFKit
   - **Open Website** → Open DOI link or PubMed page in browser
3. Full text is persisted with the document for offline access
4. macOS-specific: Option to open in side panel or new window

### Data Flow

```
┌─────────────────┐     ┌──────────────────────┐     ┌─────────────────┐
│ MacDocumentCard │────▶│   FullTextService    │────▶│    Document     │
│   (expanded)    │     │      (actor)         │     │  (SwiftData)    │
└─────────────────┘     └──────────────────────┘     └─────────────────┘
         │                        │                          │
         │                        ▼                          │
         │              ┌──────────────────┐                 │
         │              │  Fallback Chain  │                 │
         │              │  1. Europe PMC   │                 │
         │              │  2. Unpaywall    │                 │
         │              │  3. DOI/Website  │                 │
         │              └──────────────────┘                 │
         │                        │                          │
         │                        ▼                          │
         │              ┌──────────────────┐                 │
         └──────────────│ MacFullTextViewer│◀────────────────┘
                        │ (Split/Window)   │
                        └──────────────────┘
```

### New Components (macOS-Specific)

| Component | Type | Location | Purpose |
|-----------|------|----------|---------|
| `FullTextService` | Actor | `Sources/Services/` | Shared with iOS |
| `FullTextSource` | Enum | `Sources/Models/` | Shared with iOS |
| `MacFullTextViewer` | View | `Sources/Views/FactCheck/` | macOS-optimized viewer |
| `MacFullTextSplitView` | View | `Sources/Views/FactCheck/` | Side-by-side layout |
| Document extensions | Model | `Sources/Models/Document.swift` | Shared with iOS |

---

## Feature 2: Hybrid Search

### User Story

As a macOS user, I want to search multiple literature databases including preprints so I can find the most comprehensive evidence for my claim, with easy access to search configuration in the toolbar.

### Behavior

1. User configures search options in toolbar or preferences:
   - **Provider selection**: PubMed only, Europe PMC only, or Both
   - **Include preprints**: Checkbox (only available with Europe PMC)
2. System executes search according to selection
3. If "Both" selected, results are merged with deduplication
4. User can request more documents from either provider

### macOS UI Adaptations

```
┌─────────────────────────────────────────────────────────────────────────┐
│ Medical Fact Checker                                      ⚙️  │ ⊞ │ ✕ │
├─────────────────────────────────────────────────────────────────────────┤
│ 🔍 Search Provider: [PubMed ▼]  ☑️ Include Preprints  │ Sort: [Score ▼] │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  ┌────────────────────────────────┐  ┌────────────────────────────────┐ │
│  │      Scored Documents          │  │       Full Text View           │ │
│  │  (MacScoredDocumentsView)      │  │   (MacFullTextViewer)          │ │
│  │                                │  │                                │ │
│  │  [5] Article Title...  📄 ←    │  │  # Full Article Title          │ │
│  │      Get Full Text             │  │  **Authors:** Smith et al.     │ │
│  │  ─────────────────────────     │  │                                │ │
│  │  [4] Another Article...        │  │  ## Abstract                   │ │
│  │      🌍 Europe PMC             │  │  Background: This study...     │ │
│  │                                │  │                                │ │
│  └────────────────────────────────┘  └────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────┘
```

### New Components (macOS-Specific)

| Component | Type | Location | Purpose |
|-----------|------|----------|---------|
| `SearchProvider` | Enum | `Sources/Models/` | Shared with iOS |
| `EuropePMCService` | Actor | `Sources/Services/` | Shared with iOS |
| `QueryTranslator` | Struct | `Sources/Utilities/` | Shared with iOS |
| `SearchResultMerger` | Struct | `Sources/Utilities/` | Shared with iOS |
| `MacSearchOptionsToolbar` | View | `Sources/Views/FactCheck/` | Toolbar integration |
| Settings extensions | | `Sources/Models/AppSettings.swift` | Shared preferences |

---

## Implementation Phases

### Phase 1: Full-Text Service & Model (Shared Code)

Files shared with iOS - no macOS-specific changes needed:
- Extend `Document` model with full-text fields
- Create `FullTextService` actor
- Implement Europe PMC XML retrieval
- Implement Unpaywall PDF lookup
- Implement `JATSXMLParser`

### Phase 2: Full-Text UI (macOS-Specific)

- Add "Get Full Text" button to `MacDocumentCard`
- Create `MacFullTextViewer` view with:
  - Markdown rendering using `Text(AttributedString)`
  - PDF viewing using `PDFKitRepresentableMac` (already exists)
  - Split view option for side-by-side reading
  - Export to Preview.app option
- Handle loading states with macOS-style progress
- Add toolbar actions for share/export

### Phase 3: Search Provider Abstraction (Shared Code)

Files shared with iOS - no macOS-specific changes needed:
- Create `SearchProvider` enum
- Create `EuropePMCService` actor
- Define `SearchServiceFactory`
- Extend `AppSettings` with provider preference

### Phase 4: Query Translator (Shared Code)

Files shared with iOS:
- Build `QueryTranslator` enum
- Build `QueryValidator` for validation
- Unit tests for translation accuracy

### Phase 5: Hybrid Search UI (macOS-Specific)

- Add `MacSearchOptionsToolbar` for provider selection
- Update `MacFactCheckView` toolbar integration
- Implement `MacFetchMoreView` with provider options
- Show provider badges on `MacDocumentCard`
- Add search provider picker to Settings

---

## Shared Code Strategy

### Code Shared with iOS (No Changes)

Located in `Sources/` directories:

- **Models/**
  - `FullTextSource.swift` (new)
  - `SearchProvider.swift` (new)
  - `Document.swift` (extensions)
  - `AppSettings.swift` (extensions)

- **Services/**
  - `FullTextService.swift` (new)
  - `EuropePMCService.swift` (new)
  - `SearchServiceProtocol.swift` (new)

- **Utilities/**
  - `JATSXMLParser.swift` (new)
  - `QueryTranslator.swift` (new)
  - `QueryValidator.swift` (new)
  - `SearchResultMerger.swift` (new)

### macOS-Specific Code

Located in `Sources/Views/` with `Mac` prefix:

- **Views/FactCheck/**
  - `MacFullTextViewer.swift` (new)
  - `MacFullTextSplitView.swift` (new)
  - `MacSearchOptionsToolbar.swift` (new)
  - `MacFetchMoreView.swift` (new)
  - `MacScoredDocumentsView.swift` (modify)
  - `MacFactCheckView.swift` (modify)

- **Views/Settings/**
  - `MacSettingsView.swift` (modify)

- **Constants**
  - `MacConstants.swift` (extensions)

---

## macOS Design Patterns

### Toolbar Integration

Use native macOS toolbar for search options:

```swift
.toolbar {
    ToolbarItem(placement: .automatic) {
        Picker("Provider", selection: $searchProvider) {
            ForEach(SearchProvider.allCases) { provider in
                Label(provider.displayName, systemImage: provider.iconName)
                    .tag(provider)
            }
        }
        .pickerStyle(.menu)
    }

    ToolbarItem(placement: .automatic) {
        Toggle("Preprints", isOn: $includePreprints)
            .toggleStyle(.checkbox)
            .disabled(!searchProvider.supportsPreprints)
    }
}
```

### Split View for Full Text

Use `NavigationSplitView` for document + full text side-by-side:

```swift
NavigationSplitView {
    MacScoredDocumentsView(session: session)
} detail: {
    if let selectedDocument = selectedDocument,
       selectedDocument.hasFullText {
        MacFullTextViewer(document: selectedDocument)
    } else {
        EmptyStateView("Select a document with full text")
    }
}
```

### Context Menu Integration

Add full-text option to existing right-click menu:

```swift
.contextMenu {
    Button("Get Full Text") {
        fetchFullText()
    }
    .disabled(document.fullTextAttempted)

    if document.hasFullText {
        Button("Open in Preview") {
            openInPreview()
        }
    }

    Divider()

    // Existing menu items...
}
```

---

## Risk Assessment

| Risk | Mitigation |
|------|------------|
| PDF memory usage on large files | Stream PDF, use PDFKit's built-in pagination |
| Window management complexity | Use standard macOS patterns, avoid custom windows |
| Split view state persistence | Store selection in session, restore on relaunch |
| Keyboard navigation in viewer | Implement standard macOS shortcuts (Cmd+F, etc.) |

---

## Dependencies

- No new Swift packages required
- Uses existing patterns: Actor model, SwiftData, URLSession
- Reuses `PDFKitRepresentableMac` from existing codebase
- APIs used: Europe PMC REST, Unpaywall REST, DOI.org

---

## Next Steps

See individual phase documents for detailed implementation plans:

- `01-fulltext-service-model.md` - Shared code (reference iOS version)
- `02-fulltext-ui-macos.md` - macOS-specific UI implementation
- `03-search-provider-abstraction.md` - Shared code (reference iOS version)
- `04-query-translator.md` - Shared code (reference iOS version)
- `05-hybrid-search-ui-macos.md` - macOS-specific UI implementation
