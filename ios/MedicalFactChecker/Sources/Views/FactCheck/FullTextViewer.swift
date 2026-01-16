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

// MARK: - Constants

/// Constants for the full-text viewer UI.
private enum FullTextViewerConstants {
    /// Padding for content areas.
    static let contentPadding: CGFloat = 16

    /// Spacing between elements in stack views.
    static let stackSpacing: CGFloat = 12
}

// MARK: - Full Text Viewer

/// Full-screen viewer for document full text.
///
/// Supports:
/// - Markdown content (from Europe PMC XML)
/// - PDF viewing (from Unpaywall)
/// - Share/export functionality
struct FullTextViewer: View {
    /// The document being viewed.
    let document: Document

    /// The full-text result to display.
    let result: FullTextResult

    @Environment(\.dismiss) private var dismiss

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
            webFallbackView(url: url)
        }
    }

    /// Fallback view for web-only content.
    private func webFallbackView(url: URL) -> some View {
        VStack(spacing: FullTextViewerConstants.stackSpacing) {
            Image(systemName: "safari")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text("Full text available on publisher website")
                .font(.body)
                .foregroundColor(.secondary)
            Link("Open in Browser", destination: url)
                .buttonStyle(.borderedProminent)
        }
        .padding(FullTextViewerConstants.contentPadding)
    }

    // MARK: - Share Menu

    private var shareMenu: some View {
        Menu {
            if case .markdown(let text) = result.content {
                Button(action: { PlatformHelper.copyToClipboard(text) }) {
                    Label("Copy Text", systemImage: "doc.on.doc")
                }
            }

            if let doi = document.doi,
               let url = PlatformHelper.doiURL(for: doi) {
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

    /// Open the document in the system browser.
    private func openInBrowser() {
        if let doi = document.doi,
           let url = PlatformHelper.doiURL(for: doi) {
            PlatformHelper.openURL(url)
        } else if let url = PlatformHelper.pubmedURL(for: document.pmid) {
            PlatformHelper.openURL(url)
        }
    }
}

// MARK: - Markdown Scroll View

/// Scrollable view for markdown content with proper text rendering.
struct MarkdownScrollView: View {
    /// The markdown content to display.
    let content: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FullTextViewerConstants.stackSpacing) {
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
            .padding(FullTextViewerConstants.contentPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Parse markdown text into an AttributedString.
    ///
    /// - Parameter text: The markdown text.
    /// - Returns: An AttributedString with formatting, or nil if parsing fails.
    private func parseMarkdown(_ text: String) -> AttributedString? {
        try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
    }
}

// MARK: - PDF Content View

/// View for displaying PDF content loaded from a URL.
struct PDFContentView: View {
    /// The URL to load the PDF from.
    let url: URL

    @State private var isLoading = true
    @State private var pdfData: Data?
    @State private var error: String?

    var body: some View {
        Group {
            if isLoading {
                loadingView
            } else if let data = pdfData {
                PDFKitView(data: data)
            } else if let error = error {
                errorView(message: error)
            }
        }
        .task {
            await loadPDF()
        }
    }

    /// Loading indicator view.
    private var loadingView: some View {
        VStack(spacing: FullTextViewerConstants.stackSpacing) {
            ProgressView()
            Text("Loading PDF...")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    /// Error view with fallback browser link.
    private func errorView(message: String) -> some View {
        VStack(spacing: FullTextViewerConstants.stackSpacing) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundColor(.orange)
            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Link("Open in Browser", destination: url)
                .buttonStyle(.bordered)
        }
        .padding(FullTextViewerConstants.contentPadding)
    }

    /// Load the PDF data from the URL.
    private func loadPDF() async {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == FullTextConstants.httpStatusOK else {
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
    /// The PDF data to display.
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
/// UIKit wrapper for PDFView on iOS.
struct PDFKitRepresentable: UIViewRepresentable {
    /// The PDF data to display.
    let data: Data

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        if let document = PDFKit.PDFDocument(data: data) {
            pdfView.document = document
        }
        return pdfView
    }

    func updateUIView(_ uiView: PDFView, context: Context) {}
}
#endif

#if os(macOS)
/// AppKit wrapper for PDFView on macOS.
struct PDFKitRepresentableMac: NSViewRepresentable {
    /// The PDF data to display.
    let data: Data

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        if let document = PDFKit.PDFDocument(data: data) {
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
