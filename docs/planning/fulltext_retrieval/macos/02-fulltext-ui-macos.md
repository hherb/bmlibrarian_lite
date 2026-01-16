# Phase 2: Full-Text UI Components (macOS)

This document details the macOS-specific UI implementation for full-text retrieval, including the "Get Full Text" button, the full-text viewer, and split-view integration.

---

## Goals

1. Add "Get Full Text" button to `MacDocumentCard`
2. Create `MacFullTextViewer` for displaying markdown and PDF content
3. Implement split-view layout for side-by-side document + full text reading
4. Handle loading states and errors with macOS-style UI
5. Add toolbar actions for share, export, and "Open in Preview"

---

## 1. MacDocumentCard Extension

### File: `Sources/Views/FactCheck/MacScoredDocumentsView.swift`

Extend `MacDocumentCard` to include full-text functionality:

```swift
// Add state for full-text loading
@State private var isLoadingFullText = false
@State private var fullTextError: String?

// Callback for showing full text in split view
var onShowFullText: ((Document) -> Void)?

// In expandedContent, after the links section:
private var expandedContent: some View {
    VStack(alignment: .leading, spacing: MacSpacing.large) {
        // ... existing content (explanation, citations, abstract, links) ...

        Divider()

        // Full Text Section
        fullTextSection
    }
    .padding(MacSpacing.large)
}

/// Section for full-text retrieval button and status.
@ViewBuilder
private var fullTextSection: some View {
    HStack(spacing: MacSpacing.medium) {
        if document.hasFullText {
            // Already have full text - show view button
            Button(action: { onShowFullText?(document) }) {
                Label("View Full Text", systemImage: "doc.text")
            }
            .buttonStyle(.borderedProminent)

            if let source = document.fullTextSourceDisplay {
                FullTextSourceBadge(sourceString: source)
            }

            Spacer()

            // Open in Preview (for PDFs)
            if document.fullTextPDFPath != nil {
                Button(action: openInPreview) {
                    Label("Open in Preview", systemImage: "eye")
                }
                .buttonStyle(.bordered)
            }
        } else if document.fullTextUnavailable {
            // Already tried, not available
            HStack(spacing: MacSpacing.small) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundColor(.orange)
                Text("Full text not available")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Still offer to open in browser
            if let doi = document.doi, let url = URL(string: "https://doi.org/\(doi)") {
                Link(destination: url) {
                    Label("Open Publisher", systemImage: "safari")
                        .font(.caption)
                }
            }
        } else {
            // Not yet attempted
            Button(action: fetchFullText) {
                if isLoadingFullText {
                    ProgressView()
                        .scaleEffect(MacScale.progressViewSmall)
                        .frame(width: 16, height: 16)
                } else {
                    Label("Get Full Text", systemImage: "arrow.down.doc")
                }
            }
            .buttonStyle(.bordered)
            .disabled(isLoadingFullText)

            if let error = fullTextError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(1)
            }

            Spacer()
        }
    }
}

// MARK: - Full Text Actions

private func fetchFullText() {
    isLoadingFullText = true
    fullTextError = nil

    Task {
        do {
            let service = FullTextService.create(from: .shared)
            let result = try await service.fetchFullText(
                pmcId: document.pmcId,
                doi: document.doi,
                pmid: document.pmid
            )

            await MainActor.run {
                // Update document model
                switch result.content {
                case .markdown(let content):
                    document.fullTextContent = content
                case .pdfURL(let url):
                    // Download and cache PDF
                    Task {
                        await downloadAndCachePDF(from: url)
                    }
                case .webURL(let url):
                    // Open in browser
                    NSWorkspace.shared.open(url)
                }
                document.fullTextSource = result.source.rawValue
                document.fullTextFetchedAt = Date()
                isLoadingFullText = false

                // Show in split view if not web URL
                if case .webURL = result.content {
                    // Already opened in browser
                } else {
                    onShowFullText?(document)
                }
            }
        } catch {
            await MainActor.run {
                if case FullTextError.noFullTextAvailable = error {
                    document.fullTextUnavailable = true
                }
                fullTextError = error.localizedDescription
                isLoadingFullText = false
            }
        }
    }
}

private func downloadAndCachePDF(from url: URL) async {
    do {
        let (data, _) = try await URLSession.shared.data(from: url)
        let path = try FullTextService.cachePDF(data: data, for: document.pmid)
        await MainActor.run {
            document.fullTextPDFPath = path
        }
    } catch {
        print("[FullText] Failed to cache PDF: \(error)")
    }
}

private func openInPreview() {
    guard let path = document.fullTextPDFPath else { return }
    let url = URL(fileURLWithPath: path)
    NSWorkspace.shared.open(url)
}
```

---

## 2. Full-Text Source Badge

### File: `Sources/Views/Components/FullTextSourceBadge.swift` (new file)

```swift
//
//  FullTextSourceBadge.swift
//  MedicalFactChecker
//
//  Badge displaying the source of full text.
//

import SwiftUI

/// Small badge showing where full text came from.
struct FullTextSourceBadge: View {
    let sourceString: String

    private var source: FullTextSource? {
        FullTextSource(rawValue: sourceString)
    }

    var body: some View {
        HStack(spacing: MacSpacing.xSmall) {
            Image(systemName: source?.iconName ?? "doc")
                .font(.caption2)
            Text(source?.displayName ?? sourceString.capitalized)
                .font(.caption2)
        }
        .foregroundColor(badgeColor)
        .padding(.horizontal, MacSpacing.small)
        .padding(.vertical, MacSpacing.xxSmall)
        .background(badgeColor.opacity(MacOpacity.badgeBackground))
        .cornerRadius(MacCornerRadius.small)
    }

    private var badgeColor: Color {
        switch source {
        case .europePMC: return MacFullTextColors.europePMCTint
        case .unpaywall: return MacFullTextColors.unpaywallTint
        case .doi: return MacFullTextColors.doiTint
        case .cached, .none: return .gray
        }
    }
}

#Preview {
    VStack(spacing: MacSpacing.medium) {
        FullTextSourceBadge(sourceString: "europepmc")
        FullTextSourceBadge(sourceString: "unpaywall")
        FullTextSourceBadge(sourceString: "doi")
        FullTextSourceBadge(sourceString: "cached")
    }
    .padding()
}
```

---

## 3. MacFullTextViewer

### File: `Sources/Views/FactCheck/MacFullTextViewer.swift` (new file)

```swift
//
//  MacFullTextViewer.swift
//  MedicalFactChecker
//
//  macOS view for displaying full-text content with markdown and PDF support.
//

import SwiftUI
import PDFKit

/// Full-text viewer optimized for macOS.
///
/// Supports:
/// - Markdown content (from Europe PMC XML)
/// - PDF viewing with PDFKit
/// - Toolbar actions for share and export
struct MacFullTextViewer: View {
    let document: Document

    @State private var searchText = ""
    @State private var isSearching = false
    @State private var pdfData: Data?
    @State private var isLoadingPDF = false
    @State private var loadError: String?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header

            Divider()

            // Content
            content
        }
        .frame(
            minWidth: MacFullTextLayout.viewerMinWidth,
            idealWidth: MacFullTextLayout.viewerIdealWidth,
            maxWidth: MacFullTextLayout.viewerMaxWidth,
            minHeight: MacFullTextLayout.viewerMinHeight
        )
        .background(MacFullTextColors.markdownBackground)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: MacSpacing.medium) {
            VStack(alignment: .leading, spacing: MacSpacing.xxSmall) {
                Text(document.title)
                    .font(.headline)
                    .lineLimit(2)

                HStack(spacing: MacSpacing.small) {
                    Text(document.formattedAuthors)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if let source = document.fullTextSourceDisplay {
                        FullTextSourceBadge(sourceString: document.fullTextSource ?? "")
                    }
                }
            }

            Spacer()

            // Actions
            HStack(spacing: MacSpacing.small) {
                // Search (for markdown)
                if document.fullTextContent != nil {
                    TextField("Search", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: MacLayout.searchFieldWidth)
                }

                // Share menu
                shareMenu

                // Open in browser
                if let doi = document.doi {
                    Link(destination: URL(string: "https://doi.org/\(doi)")!) {
                        Image(systemName: "safari")
                    }
                    .buttonStyle(.bordered)
                    .help("Open in browser")
                }
            }
        }
        .padding(MacSpacing.standard)
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let markdownContent = document.fullTextContent {
            MacMarkdownView(content: markdownContent, searchText: searchText)
        } else if let pdfPath = document.fullTextPDFPath {
            MacPDFView(filePath: pdfPath)
        } else if isLoadingPDF {
            loadingView
        } else if let error = loadError {
            errorView(error)
        } else {
            emptyView
        }
    }

    private var loadingView: some View {
        VStack(spacing: MacSpacing.large) {
            ProgressView()
            Text("Loading full text...")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ error: String) -> some View {
        VStack(spacing: MacSpacing.large) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: MacIconSize.emptyStateMedium))
                .foregroundColor(.orange)
            Text(error)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            if let doi = document.doi {
                Link("Open Publisher Website", destination: URL(string: "https://doi.org/\(doi)")!)
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var emptyView: some View {
        VStack(spacing: MacSpacing.large) {
            Image(systemName: "doc.text")
                .font(.system(size: MacIconSize.emptyStateMedium))
                .foregroundColor(.secondary)
            Text("No full text available")
                .font(.body)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Share Menu

    private var shareMenu: some View {
        Menu {
            if let content = document.fullTextContent {
                Button(action: { copyToClipboard(content) }) {
                    Label("Copy Text", systemImage: "doc.on.doc")
                }
            }

            if let pdfPath = document.fullTextPDFPath {
                Button(action: { openInPreview(pdfPath) }) {
                    Label("Open in Preview", systemImage: "eye")
                }

                Button(action: { revealInFinder(pdfPath) }) {
                    Label("Reveal in Finder", systemImage: "folder")
                }
            }

            Divider()

            if let doi = document.doi, let url = URL(string: "https://doi.org/\(doi)") {
                ShareLink(item: url) {
                    Label("Share Link", systemImage: "square.and.arrow.up")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .help("Share options")
    }

    // MARK: - Actions

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func openInPreview(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func revealInFinder(_ path: String) {
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }
}

// MARK: - Markdown View

/// Scrollable markdown view with search highlighting.
struct MacMarkdownView: View {
    let content: String
    let searchText: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MacSpacing.standard) {
                if let attributed = parseMarkdown(content) {
                    Text(attributed)
                        .font(.body)
                        .textSelection(.enabled)
                } else {
                    Text(content)
                        .font(.body)
                        .textSelection(.enabled)
                }
            }
            .padding(MacSpacing.large)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func parseMarkdown(_ text: String) -> AttributedString? {
        try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
    }
}

// MARK: - PDF View

/// macOS PDF viewer using PDFKit.
struct MacPDFView: View {
    let filePath: String

    @State private var pdfDocument: PDFDocument?
    @State private var loadError: String?

    var body: some View {
        Group {
            if let document = pdfDocument {
                PDFKitRepresentableMac(document: document)
            } else if let error = loadError {
                VStack(spacing: MacSpacing.large) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text(error)
                        .foregroundColor(.secondary)
                }
            } else {
                ProgressView("Loading PDF...")
            }
        }
        .onAppear {
            loadPDF()
        }
    }

    private func loadPDF() {
        let url = URL(fileURLWithPath: filePath)
        if let document = PDFDocument(url: url) {
            self.pdfDocument = document
        } else {
            self.loadError = "Failed to load PDF"
        }
    }
}

/// NSViewRepresentable wrapper for PDFView on macOS.
struct PDFKitRepresentableMac: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.document = document
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = NSColor.textBackgroundColor
        return pdfView
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        nsView.document = document
    }
}

// MARK: - Preview

#Preview {
    let doc = Document(
        pmid: "12345678",
        title: "Effect of Vitamin D Supplementation on COVID-19 Outcomes: A Systematic Review",
        abstract: "Background: Vitamin D has been proposed..."
    )
    doc.fullTextContent = """
    # Effect of Vitamin D Supplementation on COVID-19 Outcomes

    **Authors:** Smith J, Jones A, Brown B et al.

    *Journal of Medical Virology* (2024)

    ## Abstract

    Vitamin D has been proposed to have immunomodulatory effects that may be beneficial in COVID-19.
    This systematic review examines the evidence from randomized controlled trials.

    ## Methods

    We conducted a systematic review and meta-analysis of randomized controlled trials examining
    vitamin D supplementation in COVID-19 patients.

    ## Results

    Ten studies with 5,234 participants were included. Vitamin D supplementation was associated
    with reduced ICU admission rates (OR 0.72, 95% CI 0.54-0.96) but not mortality.

    ## Conclusions

    Current evidence suggests a modest benefit of vitamin D supplementation in COVID-19,
    particularly for reducing ICU admissions.
    """
    doc.fullTextSource = "europepmc"

    return MacFullTextViewer(document: doc)
        .frame(width: 700, height: 600)
}
```

---

## 4. Split View Integration

### File: `Sources/Views/FactCheck/MacFullTextSplitView.swift` (new file)

```swift
//
//  MacFullTextSplitView.swift
//  MedicalFactChecker
//
//  Split view combining scored documents with full-text viewer.
//

import SwiftUI
import SwiftData

/// Split view for side-by-side document list and full-text viewing.
struct MacFullTextSplitView: View {
    @Bindable var session: FactCheckSession
    let showEmbeddingScores: Bool

    @State private var selectedDocument: Document?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // Document list
            MacScoredDocumentsView(
                session: session,
                showEmbeddingScores: showEmbeddingScores,
                onShowFullText: { document in
                    selectedDocument = document
                }
            )
            .navigationSplitViewColumnWidth(
                min: MacLayout.leftColumnMinWidth,
                ideal: MacLayout.leftColumnIdealWidth,
                max: MacLayout.leftColumnMaxWidth
            )
        } detail: {
            // Full text viewer
            if let document = selectedDocument, document.hasFullText {
                MacFullTextViewer(document: document)
            } else if let document = selectedDocument {
                // Document selected but no full text
                noFullTextView(for: document)
            } else {
                // No selection
                emptySelectionView
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    private func noFullTextView(for document: Document) -> some View {
        VStack(spacing: MacSpacing.large) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: MacIconSize.emptyStateLarge))
                .foregroundColor(.secondary)

            Text("Full text not yet retrieved")
                .font(.headline)

            Text("Click \"Get Full Text\" on the document card to fetch it.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: MacLayout.emptyStateMaxWidth)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptySelectionView: some View {
        VStack(spacing: MacSpacing.large) {
            Image(systemName: "sidebar.left")
                .font(.system(size: MacIconSize.emptyStateLarge))
                .foregroundColor(.secondary)

            Text("Select a document")
                .font(.headline)

            Text("Click on a document with full text to view it here.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: MacLayout.emptyStateMaxWidth)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    let session = FactCheckSession(claim: "Test claim")
    return MacFullTextSplitView(session: session, showEmbeddingScores: true)
        .frame(width: 1200, height: 700)
}
```

---

## 5. Context Menu Integration

Add to `MacDocumentCard` in `MacScoredDocumentsView.swift`:

```swift
// Add context menu to card header
private var cardHeader: some View {
    HStack(alignment: .top, spacing: MacSpacing.large) {
        // ... existing header content ...
    }
    .padding(MacSpacing.large)
    .contextMenu {
        documentContextMenu
    }
}

@ViewBuilder
private var documentContextMenu: some View {
    if document.hasFullText {
        Button(action: { onShowFullText?(document) }) {
            Label("View Full Text", systemImage: "doc.text")
        }

        if document.fullTextPDFPath != nil {
            Button(action: openInPreview) {
                Label("Open in Preview", systemImage: "eye")
            }
        }

        Divider()
    } else if !document.fullTextUnavailable {
        Button(action: fetchFullText) {
            Label("Get Full Text", systemImage: "arrow.down.doc")
        }
        .disabled(isLoadingFullText)

        Divider()
    }

    // Existing context menu items
    Link(destination: URL(string: "https://pubmed.ncbi.nlm.nih.gov/\(document.pmid)/")!) {
        Label("Open in PubMed", systemImage: "link")
    }

    if let doi = document.doi {
        Link(destination: URL(string: "https://doi.org/\(doi)")!) {
            Label("Open DOI", systemImage: "link")
        }
    }

    Divider()

    Button(action: copyPMID) {
        Label("Copy PMID", systemImage: "doc.on.doc")
    }

    Button(action: copyCitation) {
        Label("Copy Citation", systemImage: "quote.opening")
    }
}

private func copyPMID() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(document.pmid, forType: .string)
}

private func copyCitation() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(document.fullCitation, forType: .string)
}
```

---

## 6. Keyboard Shortcuts

Add keyboard shortcuts to `MacFullTextViewer`:

```swift
struct MacFullTextViewer: View {
    // ... existing code ...

    var body: some View {
        VStack(spacing: 0) {
            // ... existing content ...
        }
        .focusable()
        .onKeyPress(.escape) {
            // Close viewer or deselect
            return .handled
        }
        .onKeyPress("f", modifiers: .command) {
            isSearching = true
            return .handled
        }
        .onKeyPress("c", modifiers: .command) {
            if let content = document.fullTextContent {
                copyToClipboard(content)
            }
            return .handled
        }
    }
}
```

---

## 7. User Flow Diagram

```
┌─────────────────────────────────────────────────────────────────────────┐
│ Medical Fact Checker                                                     │
├─────────────────────────────────────────────────────────────────────────┤
│ Document List                    │ Full Text Viewer                     │
│ ─────────────────────────────── │ ────────────────────────────────────│
│                                  │                                      │
│ [5] Article Title...        [📄] │ # Article Title                      │
│     Smith et al., 2024           │ **Authors:** Smith J, Jones A        │
│     ────────────────────────     │                                      │
│     ┌─────────────────────┐      │ 🔵 Europe PMC                        │
│     │ 📄 Get Full Text    │ ←Click │                                    │
│     └─────────────────────┘      │ ## Abstract                          │
│                                  │                                      │
│     LLM Reasoning: This study... │ Vitamin D has been proposed to have  │
│                                  │ immunomodulatory effects...          │
│ ─────────────────────────────── │                                      │
│                                  │ ## Methods                           │
│ [4] Another Article...           │                                      │
│     🌍 Europe PMC                │ We conducted a systematic review...  │
│                                  │                                      │
│ [3] Third Article...             │ ## Results                           │
│     No full text                 │                                      │
│                                  │ Ten studies with 5,234 participants..│
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 8. Accessibility

```swift
// Button accessibility
Button(action: fetchFullText) {
    Label("Get Full Text", systemImage: "arrow.down.doc")
}
.accessibilityLabel("Get full text")
.accessibilityHint("Downloads the full text of this article if available")

// Loading state
ProgressView()
    .accessibilityLabel("Loading full text")

// Source badge
FullTextSourceBadge(sourceString: "europepmc")
    .accessibilityLabel("Full text from Europe PMC")

// Split view
MacFullTextSplitView(...)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Document viewer with full text panel")
```

---

## 9. Files to Create/Modify

### New Files

- `Sources/Views/Components/FullTextSourceBadge.swift`
- `Sources/Views/FactCheck/MacFullTextViewer.swift`
- `Sources/Views/FactCheck/MacFullTextSplitView.swift`

### Modified Files

- `Sources/Views/FactCheck/MacScoredDocumentsView.swift`
  - Add full-text button in `MacDocumentCard`
  - Add state variables for loading/error
  - Add context menu items
  - Add `onShowFullText` callback
- `Sources/MacConstants.swift`
  - Add `MacFullTextLayout` enum
  - Add `MacFullTextColors` enum

---

## 10. Testing Checklist

### Manual Testing

- [ ] "Get Full Text" button appears on expanded document card
- [ ] Loading indicator shows during fetch
- [ ] Markdown content displays correctly with proper formatting
- [ ] PDF content displays correctly with zoom/scroll
- [ ] Split view shows document list and full text side-by-side
- [ ] "Open in Preview" opens PDF in Preview.app
- [ ] "Reveal in Finder" shows PDF location
- [ ] Share menu works (copy, share link)
- [ ] Error states display correctly
- [ ] Full text persists after fetch
- [ ] Context menu includes full-text options

### Keyboard Testing

- [ ] Cmd+F activates search in markdown view
- [ ] Cmd+C copies full text
- [ ] Escape clears selection

### Accessibility Testing

- [ ] VoiceOver reads button correctly
- [ ] Loading state announced
- [ ] Error states are accessible
- [ ] PDF is accessible to VoiceOver
- [ ] Split view navigation works with keyboard

---

## 11. Estimated Effort

| Task | Complexity | Notes |
|------|------------|-------|
| MacDocumentCard extension | Medium | Full-text button and state |
| FullTextSourceBadge | Low | Simple badge component |
| MacFullTextViewer | Medium | Markdown + PDF support |
| MacFullTextSplitView | Medium | Split view integration |
| Context menu | Low | Additional menu items |
| Keyboard shortcuts | Low | Standard macOS shortcuts |
| Accessibility | Low | Labels and hints |

**Total estimated complexity: Medium**

---

## Next Phase

After completing this phase, proceed to **Phase 3: Search Provider Abstraction** (`03-search-provider-abstraction.md`) to implement the Europe PMC search service (shared code with iOS).
