//
//  MacFullTextViewer.swift
//  MedicalFactChecker
//
//  macOS view for displaying full-text content with markdown and PDF support.
//  Provides toolbar actions for sharing, exporting, and opening in external apps.
//

import SwiftUI
import PDFKit

/// Full-text viewer optimized for macOS.
///
/// Supports:
/// - Markdown content (converted from Europe PMC XML)
/// - PDF viewing with PDFKit
/// - Toolbar actions for share/export
/// - Text search within markdown content
/// - Keyboard shortcuts (Cmd+F for search, Cmd+C for copy)
struct MacFullTextViewer: View {
    // MARK: - Properties

    /// The document to display full text for.
    let document: Document

    /// Callback when user wants to close the viewer.
    var onClose: (() -> Void)?

    // MARK: - State

    @State private var searchText = ""
    @State private var isSearchFieldVisible = false
    @State private var pdfDocument: PDFKit.PDFDocument?
    @State private var isLoadingPDF = false
    @State private var loadError: String?

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(
            minWidth: MacFullTextLayout.viewerMinWidth,
            idealWidth: MacFullTextLayout.viewerIdealWidth,
            maxWidth: .infinity,
            minHeight: MacFullTextLayout.viewerMinHeight
        )
        .background(MacFullTextColors.markdownBackground)
        .focusable()
        .onKeyPress(keys: [.init("f")], phases: .down) { _ in
            if NSEvent.modifierFlags.contains(.command) {
                isSearchFieldVisible = true
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.escape) {
            if isSearchFieldVisible {
                isSearchFieldVisible = false
                searchText = ""
                return .handled
            }
            onClose?()
            return .handled
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: MacSpacing.medium) {
            // Title and metadata
            VStack(alignment: .leading, spacing: MacSpacing.xxSmall) {
                Text(document.title)
                    .font(.headline)
                    .lineLimit(2)

                HStack(spacing: MacSpacing.small) {
                    Text(document.formattedAuthors)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if let journal = document.journal, let year = document.year {
                        Text("•")
                            .foregroundColor(.secondary)
                        Text(verbatim: "\(journal), \(year)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    } else if let journal = document.journal {
                        Text("•")
                            .foregroundColor(.secondary)
                        Text(journal)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }

                    if let sourceString = document.fullTextSource {
                        FullTextSourceBadge(sourceString: sourceString)
                    }
                }
            }

            Spacer()

            // Actions
            HStack(spacing: MacSpacing.small) {
                // Search field (for markdown)
                if document.fullTextContent != nil {
                    if isSearchFieldVisible {
                        HStack(spacing: MacSpacing.xSmall) {
                            TextField("Search", text: $searchText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: MacLayout.searchFieldWidth)

                            Button {
                                isSearchFieldVisible = false
                                searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
                        Button {
                            isSearchFieldVisible = true
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .buttonStyle(.bordered)
                        .help("Search (⌘F)")
                    }
                }

                // Share menu
                shareMenu

                // Open in browser
                if let doi = document.doi, let url = URL(string: "https://doi.org/\(doi)") {
                    Link(destination: url) {
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
                .scaleEffect(MacScale.progressViewMedium)
            Text("Loading full text...")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("Loading full text")
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

            if let doi = document.doi, let url = URL(string: "https://doi.org/\(doi)") {
                Link("Open Publisher Website", destination: url)
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Error: \(error)")
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
        .accessibilityLabel("No full text available")
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

            // PubMed link
            if let pubmedURL = URL(string: "https://pubmed.ncbi.nlm.nih.gov/\(document.pmid)/") {
                ShareLink(item: pubmedURL) {
                    Label("Share PubMed Link", systemImage: "link")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .help("Share options")
    }

    // MARK: - Actions

    /// Copy text to the system clipboard.
    ///
    /// - Parameter text: The text to copy.
    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Open a file in Preview.app.
    ///
    /// - Parameter path: The file path to open.
    private func openInPreview(_ path: String) {
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.open(url)
    }

    /// Reveal a file in Finder.
    ///
    /// - Parameter path: The file path to reveal.
    private func revealInFinder(_ path: String) {
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }
}

// MARK: - Markdown View

/// Scrollable markdown view with proper block element rendering.
///
/// Splits markdown content into blocks (paragraphs, headers) and renders
/// each with appropriate styling. Supports text selection.
struct MacMarkdownView: View {
    /// The markdown content to display.
    let content: String

    /// Text to highlight in the content (empty string for no highlighting).
    let searchText: String

    /// Parsed blocks from the markdown content.
    private var blocks: [MarkdownBlock] {
        parseMarkdownBlocks(content)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MacSpacing.large) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    renderBlock(block)
                }
            }
            .padding(MacFullTextLayout.markdownPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Render a single markdown block with appropriate styling.
    @ViewBuilder
    private func renderBlock(_ block: MarkdownBlock) -> some View {
        switch block.type {
        case .heading1:
            Text(parseInlineMarkdown(block.content))
                .font(.title)
                .fontWeight(.bold)
                .textSelection(.enabled)
                .padding(.top, MacSpacing.large)

        case .heading2:
            Text(parseInlineMarkdown(block.content))
                .font(.title2)
                .fontWeight(.semibold)
                .textSelection(.enabled)
                .padding(.top, MacSpacing.medium)

        case .heading3:
            Text(parseInlineMarkdown(block.content))
                .font(.title3)
                .fontWeight(.medium)
                .textSelection(.enabled)
                .padding(.top, MacSpacing.small)

        case .heading4, .heading5, .heading6:
            Text(parseInlineMarkdown(block.content))
                .font(.headline)
                .textSelection(.enabled)
                .padding(.top, MacSpacing.small)

        case .paragraph:
            Text(parseInlineMarkdown(block.content))
                .font(.body)
                .textSelection(.enabled)
                .lineSpacing(MacFullTextLayout.markdownLineSpacing)

        case .listItem:
            HStack(alignment: .top, spacing: MacSpacing.small) {
                Text("•")
                    .foregroundColor(.secondary)
                Text(parseInlineMarkdown(block.content))
                    .font(.body)
                    .textSelection(.enabled)
            }

        case .numberedItem(let number):
            HStack(alignment: .top, spacing: MacSpacing.small) {
                Text("\(number).")
                    .foregroundColor(.secondary)
                    .frame(minWidth: 20, alignment: .trailing)
                Text(parseInlineMarkdown(block.content))
                    .font(.body)
                    .textSelection(.enabled)
            }

        case .image(let url, let altText):
            AsyncFigureView(url: url, altText: altText)
        }
    }

    /// Parse inline markdown (bold, italic) to AttributedString.
    private func parseInlineMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }

    /// Parse markdown content into blocks.
    private func parseMarkdownBlocks(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []

        // Split by double newlines to get blocks
        let rawBlocks = text.components(separatedBy: "\n\n")

        for rawBlock in rawBlocks {
            let trimmed = rawBlock.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            // Check for headers
            if trimmed.hasPrefix("######") {
                let content = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                blocks.append(MarkdownBlock(type: .heading6, content: content))
            } else if trimmed.hasPrefix("#####") {
                let content = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                blocks.append(MarkdownBlock(type: .heading5, content: content))
            } else if trimmed.hasPrefix("####") {
                let content = String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                blocks.append(MarkdownBlock(type: .heading4, content: content))
            } else if trimmed.hasPrefix("###") {
                let content = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                blocks.append(MarkdownBlock(type: .heading3, content: content))
            } else if trimmed.hasPrefix("##") {
                let content = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                blocks.append(MarkdownBlock(type: .heading2, content: content))
            } else if trimmed.hasPrefix("#") {
                let content = String(trimmed.dropFirst(1)).trimmingCharacters(in: .whitespaces)
                blocks.append(MarkdownBlock(type: .heading1, content: content))
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                // Handle list items (may be multiple lines)
                let lines = trimmed.components(separatedBy: "\n")
                for line in lines {
                    let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                    if trimmedLine.hasPrefix("- ") {
                        blocks.append(MarkdownBlock(type: .listItem, content: String(trimmedLine.dropFirst(2))))
                    } else if trimmedLine.hasPrefix("* ") {
                        blocks.append(MarkdownBlock(type: .listItem, content: String(trimmedLine.dropFirst(2))))
                    } else if !trimmedLine.isEmpty {
                        blocks.append(MarkdownBlock(type: .paragraph, content: trimmedLine))
                    }
                }
            } else if let match = trimmed.firstMatch(of: /^(\d+)\.\s+(.+)/) {
                // Numbered list item
                if let number = Int(match.1) {
                    blocks.append(MarkdownBlock(type: .numberedItem(number), content: String(match.2)))
                } else {
                    blocks.append(MarkdownBlock(type: .paragraph, content: trimmed))
                }
            } else if let imageMatch = trimmed.firstMatch(of: /^!\[([^\]]*)\]\(([^)]+)\)/) {
                // Markdown image: ![alt text](url)
                let altText = String(imageMatch.1)
                let url = String(imageMatch.2)
                blocks.append(MarkdownBlock(type: .image(url: url, altText: altText), content: ""))
            } else {
                // Regular paragraph
                blocks.append(MarkdownBlock(type: .paragraph, content: trimmed))
            }
        }

        return blocks
    }
}

/// A parsed markdown block.
private struct MarkdownBlock {
    let type: BlockType
    let content: String

    enum BlockType {
        case heading1
        case heading2
        case heading3
        case heading4
        case heading5
        case heading6
        case paragraph
        case listItem
        case numberedItem(Int)
        case image(url: String, altText: String)
    }
}

// MARK: - Async Figure View

/// View for loading and displaying figure images asynchronously.
///
/// Handles loading state, errors, and displays images with appropriate sizing.
struct AsyncFigureView: View {
    let url: String
    let altText: String

    @State private var image: NSImage?
    @State private var isLoading = true
    @State private var loadError: String?

    /// Maximum width for displayed figures.
    private let maxFigureWidth: CGFloat = 600

    /// Maximum height for displayed figures.
    private let maxFigureHeight: CGFloat = 500

    var body: some View {
        VStack(alignment: .center, spacing: MacSpacing.small) {
            if let image = image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: maxFigureWidth, maxHeight: maxFigureHeight)
                    .cornerRadius(MacCornerRadius.standard)
                    .shadow(radius: 2)
            } else if isLoading {
                HStack(spacing: MacSpacing.small) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Loading figure...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(height: 100)
            } else if let error = loadError {
                VStack(spacing: MacSpacing.xSmall) {
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("Could not load image")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if !altText.isEmpty {
                        Text(altText)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .italic()
                    }
                }
                .frame(height: 100)
                .frame(maxWidth: .infinity)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(MacCornerRadius.standard)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, MacSpacing.small)
        .task {
            await loadImage()
        }
    }

    /// Alternative extensions to try if the original URL fails.
    ///
    /// Europe PMC figures often don't include extensions in the XML,
    /// so we try common image formats.
    private let alternativeExtensions = [".gif", ".jpg", ".png"]

    /// Load image from URL asynchronously, trying alternative extensions if needed.
    private func loadImage() async {
        // Build list of URLs to try
        var urlsToTry: [URL] = []

        if let baseURL = URL(string: url) {
            urlsToTry.append(baseURL)
        }

        // If the URL ends with an extension, also try stripping it and adding alternatives
        let urlString = url
        let hasExtension = [".gif", ".jpg", ".jpeg", ".png", ".svg"]
            .contains { urlString.lowercased().hasSuffix($0) }

        if hasExtension {
            // Try the original first, then alternatives by replacing the extension
            let baseWithoutExt = String(urlString.dropLast(4)) // Remove .xxx
            for ext in alternativeExtensions {
                if !urlString.lowercased().hasSuffix(ext),
                   let altURL = URL(string: baseWithoutExt + ext) {
                    urlsToTry.append(altURL)
                }
            }
        } else {
            // URL doesn't have extension, try adding them
            for ext in alternativeExtensions {
                if let altURL = URL(string: urlString + ext) {
                    urlsToTry.append(altURL)
                }
            }
        }

        // Try each URL in order
        for imageURL in urlsToTry {
            do {
                let (data, response) = try await URLSession.shared.data(from: imageURL)

                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    continue // Try next URL
                }

                if let nsImage = NSImage(data: data) {
                    await MainActor.run {
                        self.image = nsImage
                        self.isLoading = false
                    }
                    return // Success!
                }
            } catch {
                // Try next URL
                continue
            }
        }

        // All URLs failed
        await MainActor.run {
            self.loadError = "Failed to load image"
            self.isLoading = false
        }
        AppLogger.fullText.warning("Failed to load figure from \(url) (tried \(urlsToTry.count) URLs)")
    }
}

// MARK: - PDF View

/// macOS PDF viewer using PDFKit.
///
/// Loads a PDF from a file path and displays it with zoom and scroll support.
struct MacPDFView: View {
    /// The file path to the PDF.
    let filePath: String

    @State private var pdfDocument: PDFKit.PDFDocument?
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView("Loading PDF...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            loadPDF()
        }
    }

    /// Load the PDF document from the file path.
    private func loadPDF() {
        let url = URL(fileURLWithPath: filePath)

        guard FileManager.default.fileExists(atPath: filePath) else {
            loadError = "PDF file not found"
            AppLogger.fullText.error("PDF file not found at path: \(filePath)")
            return
        }

        if let document = PDFKit.PDFDocument(url: url) {
            self.pdfDocument = document
            AppLogger.fullText.debug("Successfully loaded PDF from: \(filePath)")
        } else {
            loadError = "Failed to load PDF"
            AppLogger.fullText.error("Failed to load PDF from: \(filePath)")
        }
    }
}

// MARK: - PDFKit NSViewRepresentable

/// NSViewRepresentable wrapper for PDFView on macOS.
///
/// Provides native PDF viewing with zoom, scroll, and text selection support.
struct PDFKitRepresentableMac: NSViewRepresentable {
    /// The PDF document to display.
    let document: PDFKit.PDFDocument

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
        if nsView.document != document {
            nsView.document = document
        }
    }
}

// MARK: - Preview

#Preview("Markdown Content") {
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

#Preview("Empty State") {
    let doc = Document(
        pmid: "12345678",
        title: "Article Without Full Text",
        abstract: "This article has no full text available."
    )

    return MacFullTextViewer(document: doc)
        .frame(width: 700, height: 600)
}
