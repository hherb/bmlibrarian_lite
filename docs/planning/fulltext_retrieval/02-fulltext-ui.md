# Phase 2: Full-Text UI Components

This document details the UI implementation for full-text retrieval, including the "Get Full Text" button and the full-text viewer.

---

## Goals

1. Add "Get Full Text" button to `DocumentScoreRow`
2. Create `FullTextViewer` for displaying markdown content
3. Create `PDFViewer` for displaying PDFs (cross-platform)
4. Handle loading states and errors
5. Add "Open in..." functionality for external apps

---

## 1. Document Score Row Extension

### File: `Sources/Views/FactCheck/ScoredDocumentsView.swift`

Add the "Get Full Text" button in the `expandedContent` section of `DocumentScoreRow`:

```swift
// Add state for full-text loading
@State private var isLoadingFullText = false
@State private var fullTextError: String?
@State private var showFullTextViewer = false
@State private var fullTextResult: FullTextResult?

// In expandedContent, after metadataView:
private var expandedContent: some View {
    VStack(alignment: .leading, spacing: 12) {
        // ... existing content (explanation, abstract, score comparison, metadata) ...

        Divider()

        // Full Text Button
        fullTextSection
    }
}

/// Section for full-text retrieval button and status.
@ViewBuilder
private var fullTextSection: some View {
    if document.hasFullText {
        // Already have full text - show view button
        Button(action: { showFullTextViewer = true }) {
            Label("View Full Text", systemImage: "doc.text")
                .font(.subheadline)
        }
        .buttonStyle(.bordered)
        .tint(.blue)

        if let source = document.fullTextSourceDisplay {
            Text("Source: \(source)")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    } else if document.fullTextUnavailable {
        // Already tried, not available
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundColor(.orange)
            Text("Full text not available")
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()

            // Still offer to open in browser
            if let doi = document.doi, let url = URL(string: "https://doi.org/\(doi)") {
                Link(destination: url) {
                    Label("Open Publisher", systemImage: "safari")
                        .font(.caption)
                }
            }
        }
    } else {
        // Not yet attempted
        HStack(spacing: 12) {
            Button(action: fetchFullText) {
                if isLoadingFullText {
                    ProgressView()
                        .scaleEffect(0.8)
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
        }
    }
}
.sheet(isPresented: $showFullTextViewer) {
    if let result = fullTextResult {
        FullTextViewer(document: document, result: result)
    } else if let content = document.fullTextContent {
        FullTextViewer(
            document: document,
            result: FullTextResult(
                content: .markdown(content),
                source: FullTextSource(rawValue: document.fullTextSource ?? "cached") ?? .cached
            )
        )
    }
}

// MARK: - Full Text Fetching

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
                    document.fullTextPDFPath = url.absoluteString
                case .webURL:
                    // Don't store - just open
                    break
                }
                document.fullTextSource = result.source.rawValue
                document.fullTextFetchedAt = Date()

                fullTextResult = result
                isLoadingFullText = false

                // For web URLs, open directly instead of showing viewer
                if case .webURL(let url) = result.content {
                    openURL(url)
                } else {
                    showFullTextViewer = true
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

@Environment(\.openURL) private var openURL
```

---

## 2. Full-Text Viewer

### File: `Sources/Views/FactCheck/FullTextViewer.swift` (new file)

```swift
//
//  FullTextViewer.swift
//  MedicalFactChecker
//
//  View for displaying full-text content with navigation options.
//

import SwiftUI
#if canImport(PDFKit)
import PDFKit
#endif

/// Full-screen viewer for document full text.
///
/// Supports:
/// - Markdown content (from Europe PMC XML)
/// - PDF viewing (from Unpaywall)
/// - Share/export functionality
struct FullTextViewer: View {
    let document: Document
    let result: FullTextResult

    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = false
    @State private var pdfData: Data?
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(document.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        shareMenu
                    }
                }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch result.content {
        case .markdown(let text):
            MarkdownScrollView(content: text)

        case .pdfURL(let url):
            PDFContentView(url: url)

        case .webURL(let url):
            // Should not reach here normally, but handle gracefully
            VStack(spacing: 16) {
                Image(systemName: "safari")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                Text("Full text available on publisher website")
                Link("Open in Browser", destination: url)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Share Menu

    private var shareMenu: some View {
        Menu {
            if case .markdown(let text) = result.content {
                Button(action: { copyToClipboard(text) }) {
                    Label("Copy Text", systemImage: "doc.on.doc")
                }
            }

            if let doi = document.doi, let url = URL(string: "https://doi.org/\(doi)") {
                ShareLink(item: url) {
                    Label("Share Link", systemImage: "square.and.arrow.up")
                }
            }

            Button(action: openInBrowser) {
                Label("Open in Browser", systemImage: "safari")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    // MARK: - Actions

    private func copyToClipboard(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    private func openInBrowser() {
        let urlString: String
        if let doi = document.doi {
            urlString = "https://doi.org/\(doi)"
        } else {
            urlString = "https://pubmed.ncbi.nlm.nih.gov/\(document.pmid)/"
        }

        if let url = URL(string: urlString) {
            #if os(iOS)
            UIApplication.shared.open(url)
            #elseif os(macOS)
            NSWorkspace.shared.open(url)
            #endif
        }
    }
}

// MARK: - Markdown Scroll View

/// Scrollable view for markdown content with proper text rendering.
struct MarkdownScrollView: View {
    let content: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
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
            .padding()
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

// MARK: - PDF Content View

/// View for displaying PDF content.
struct PDFContentView: View {
    let url: URL

    @State private var isLoading = true
    @State private var pdfData: Data?
    @State private var error: String?

    var body: some View {
        Group {
            if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading PDF...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else if let data = pdfData {
                PDFKitView(data: data)
            } else if let error = error {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Link("Open in Browser", destination: url)
                        .buttonStyle(.bordered)
                }
            }
        }
        .task {
            await loadPDF()
        }
    }

    private func loadPDF() async {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            await MainActor.run {
                self.pdfData = data
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.error = "Failed to load PDF: \(error.localizedDescription)"
                self.isLoading = false
            }
        }
    }
}

// MARK: - PDFKit Wrapper

#if canImport(PDFKit)
/// Cross-platform PDFKit view wrapper.
struct PDFKitView: View {
    let data: Data

    var body: some View {
        #if os(iOS)
        PDFKitRepresentable(data: data)
        #elseif os(macOS)
        PDFKitRepresentableMac(data: data)
        #endif
    }
}

#if os(iOS)
struct PDFKitRepresentable: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        if let document = PDFDocument(data: data) {
            pdfView.document = document
        }
        return pdfView
    }

    func updateUIView(_ uiView: PDFView, context: Context) {}
}
#endif

#if os(macOS)
struct PDFKitRepresentableMac: NSViewRepresentable {
    let data: Data

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        if let document = PDFDocument(data: data) {
            pdfView.document = document
        }
        return pdfView
    }

    func updateNSView(_ nsView: PDFView, context: Context) {}
}
#endif
#endif

// MARK: - Preview

#Preview {
    let doc = Document(
        pmid: "12345678",
        title: "Effect of Vitamin D Supplementation on COVID-19 Outcomes",
        abstract: "Background: Vitamin D has been proposed..."
    )

    let sampleMarkdown = """
    # Effect of Vitamin D Supplementation on COVID-19 Outcomes

    **Authors:** Smith J, Jones A, Brown B

    *Journal of Medical Virology* (2024)

    ## Abstract

    Vitamin D has been proposed to have immunomodulatory effects that may be beneficial in COVID-19.

    ## Methods

    We conducted a systematic review and meta-analysis of randomized controlled trials.

    ## Results

    Ten studies with 5,234 participants were included. Vitamin D supplementation was associated with...
    """

    return FullTextViewer(
        document: doc,
        result: FullTextResult(content: .markdown(sampleMarkdown), source: .europePMC)
    )
}
```

---

## 3. Source Badge Component

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
    let source: FullTextSource

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: source.iconName)
                .font(.caption2)
            Text(source.displayName)
                .font(.caption2)
        }
        .foregroundColor(badgeColor)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(badgeColor.opacity(0.15))
        .cornerRadius(4)
    }

    private var badgeColor: Color {
        switch source {
        case .europePMC: return .blue
        case .unpaywall: return .green
        case .doi: return .orange
        case .cached: return .gray
        }
    }
}

#Preview {
    VStack(spacing: 8) {
        FullTextSourceBadge(source: .europePMC)
        FullTextSourceBadge(source: .unpaywall)
        FullTextSourceBadge(source: .doi)
        FullTextSourceBadge(source: .cached)
    }
    .padding()
}
```

---

## 4. Loading State Component

### File: `Sources/Views/Components/FullTextLoadingView.swift` (new file)

```swift
//
//  FullTextLoadingView.swift
//  MedicalFactChecker
//
//  Loading indicator for full-text retrieval.
//

import SwiftUI

/// Animated loading view for full-text fetching.
struct FullTextLoadingView: View {
    @State private var currentStep = 0
    private let steps = [
        "Checking Europe PMC...",
        "Checking Unpaywall...",
        "Resolving DOI..."
    ]

    let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()

            Text(steps[currentStep])
                .font(.caption)
                .foregroundColor(.secondary)
                .animation(.easeInOut, value: currentStep)
        }
        .onReceive(timer) { _ in
            withAnimation {
                currentStep = (currentStep + 1) % steps.count
            }
        }
    }
}

#Preview {
    FullTextLoadingView()
        .padding()
}
```

---

## 5. Platform-Specific Considerations

### iOS

- Use `UIActivityViewController` for sharing
- PDF viewing via PDFKit's `PDFView`
- Open external URLs via `UIApplication.shared.open()`

### macOS

- Use `NSSharingServicePicker` for sharing
- PDF viewing via PDFKit's `PDFView` (same API)
- Open external URLs via `NSWorkspace.shared.open()`
- Consider larger default viewer size

### Shared Code

```swift
// Add to a utility file for cross-platform helpers
enum PlatformHelper {
    static func openURL(_ url: URL) {
        #if os(iOS)
        UIApplication.shared.open(url)
        #elseif os(macOS)
        NSWorkspace.shared.open(url)
        #endif
    }

    static func copyToClipboard(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
```

---

## 6. User Flow Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                      Document Card (Expanded)                    │
├─────────────────────────────────────────────────────────────────┤
│  [LLM] [Emb]  Title of the Article                              │
│   4     4     Author et al., 2024                               │
│               ─────────────────────────────                     │
│               LLM Reasoning: This article directly...           │
│               ─────────────────────────────────────             │
│               Abstract: Background: This study...               │
│               ─────────────────────────────────────             │
│               Journal: J Med | PMID: 12345678                   │
│               ─────────────────────────────────────             │
│                                                                 │
│   ┌────────────────────┐                                        │
│   │ 📄 Get Full Text   │  ← User taps                          │
│   └────────────────────┘                                        │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                     Loading State                                │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│                         ◐                                       │
│                                                                 │
│               Checking Europe PMC...                            │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
                              │
              ┌───────────────┼───────────────┐
              ▼               ▼               ▼
┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐
│  XML Found      │ │  PDF Found      │ │  Web Only       │
│  (Europe PMC)   │ │  (Unpaywall)    │ │  (DOI)          │
└─────────────────┘ └─────────────────┘ └─────────────────┘
         │                   │                   │
         ▼                   ▼                   ▼
┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐
│ Markdown Viewer │ │   PDF Viewer    │ │ Opens Browser   │
│ (in-app)        │ │   (in-app)      │ │                 │
└─────────────────┘ └─────────────────┘ └─────────────────┘
```

---

## 7. Error States

### No Identifiers

```swift
// Document has no DOI or PMC ID
HStack {
    Image(systemName: "info.circle")
        .foregroundColor(.blue)
    Text("No DOI or PMC ID available for this document")
        .font(.caption)
        .foregroundColor(.secondary)
}
```

### Network Error

```swift
// Network request failed
HStack {
    Image(systemName: "wifi.exclamationmark")
        .foregroundColor(.red)
    Text("Network error. Tap to retry.")
        .font(.caption)
        .foregroundColor(.secondary)
}
.onTapGesture { fetchFullText() }
```

### Not Available

```swift
// Full text not available from any source
HStack {
    Image(systemName: "exclamationmark.triangle")
        .foregroundColor(.orange)
    VStack(alignment: .leading) {
        Text("Full text not available")
            .font(.caption)
        if let doi = document.doi {
            Link("Try publisher website", destination: URL(string: "https://doi.org/\(doi)")!)
                .font(.caption2)
        }
    }
}
```

---

## 8. Accessibility

```swift
// Button accessibility
Button(action: fetchFullText) {
    Label("Get Full Text", systemImage: "arrow.down.doc")
}
.accessibilityHint("Downloads the full text of this article if available")

// Loading state
ProgressView()
    .accessibilityLabel("Loading full text")
    .accessibilityValue(steps[currentStep])

// Source badge
FullTextSourceBadge(source: .europePMC)
    .accessibilityLabel("Full text from Europe PMC")
```

---

## 9. Files to Create/Modify

### New Files
- `Sources/Views/FactCheck/FullTextViewer.swift`
- `Sources/Views/Components/FullTextSourceBadge.swift`
- `Sources/Views/Components/FullTextLoadingView.swift`

### Modified Files
- `Sources/Views/FactCheck/ScoredDocumentsView.swift`
  - Add full-text button in `DocumentScoreRow`
  - Add state variables for loading/error
  - Add sheet presentation for viewer

---

## 10. Testing Checklist

### Manual Testing

- [ ] Button appears on expanded document card
- [ ] Loading indicator shows during fetch
- [ ] Markdown content displays correctly
- [ ] PDF content displays correctly (iOS and macOS)
- [ ] "Open in Browser" works for web URLs
- [ ] Share menu works (copy, share link)
- [ ] Error states display correctly
- [ ] Full text persists after fetch

### Accessibility Testing

- [ ] VoiceOver reads button correctly
- [ ] Loading state announced
- [ ] Error states are accessible
- [ ] PDF is accessible to VoiceOver

### Platform Testing

- [ ] iOS: Sheet presentation works
- [ ] iOS: PDF zoom/scroll works
- [ ] macOS: Window sizing appropriate
- [ ] macOS: PDF zoom/scroll works

---

## 11. Estimated Effort

| Task | Complexity | Notes |
|------|------------|-------|
| DocumentScoreRow extension | Low | Add button and state |
| FullTextViewer | Medium | Multiple content types |
| PDF viewing | Medium | Platform differences |
| Source badge | Low | Simple component |
| Error states | Low | UI polish |
| Accessibility | Low | Labels and hints |

**Total estimated complexity: Medium**

---

## Next Phase

After completing this phase, proceed to **Phase 3: Search Provider Abstraction** (`03-search-provider-abstraction.md`) to implement the Europe PMC search service.
