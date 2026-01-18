// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2025 Dr Horst Herb
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

import SwiftUI
import WebKit
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
    let result: AppFullTextResult

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(document.displayTitle)
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
        case .html(let htmlContent):
            HTMLContentView(htmlContent: htmlContent)

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
            // Copy text option for HTML or markdown content
            switch result.content {
            case .html(let html):
                Button(action: { PlatformHelper.copyToClipboard(html) }) {
                    Label("Copy HTML", systemImage: "doc.on.doc")
                }
            case .markdown(let text):
                Button(action: { PlatformHelper.copyToClipboard(text) }) {
                    Label("Copy Text", systemImage: "doc.on.doc")
                }
            default:
                EmptyView()
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

// MARK: - HTML Content View

/// SwiftUI view that renders HTML content using WKWebView.
///
/// Provides proper table rendering, semantic HTML structure, and
/// clickable anchor links for navigation within the document.
struct HTMLContentView: UIViewRepresentable {
    /// The HTML body content to render (without HTML/head wrapper).
    let htmlContent: String

    /// Coordinator to handle WKWebView navigation and callbacks.
    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: HTMLContentView

        init(_ parent: HTMLContentView) {
            self.parent = parent
        }

        /// Handle navigation actions (e.g., anchor clicks, external links).
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            // Handle anchor links within the document
            if url.scheme == nil || url.absoluteString.hasPrefix("#") {
                decisionHandler(.allow)
                return
            }

            // Handle internal fragment navigation
            if url.fragment != nil && url.host == nil {
                decisionHandler(.allow)
                return
            }

            // Open external links in Safari
            if url.scheme == "http" || url.scheme == "https" {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()

        // Enable JavaScript for anchor navigation
        let preferences = WKPreferences()
        configuration.preferences = preferences

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator

        // Set appearance to match system
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear

        // Load the HTML content
        let fullHTML = wrapHTMLContent(htmlContent)
        webView.loadHTMLString(fullHTML, baseURL: nil)

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Re-load content if it changed
        let fullHTML = wrapHTMLContent(htmlContent)
        webView.loadHTMLString(fullHTML, baseURL: nil)
    }

    /// Wrap HTML content in a full HTML document with CSS styling.
    private func wrapHTMLContent(_ content: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
            <style>
                \(htmlCSS)
            </style>
            <script>
                \(htmlJavaScript)
            </script>
        </head>
        <body>
            \(content)
        </body>
        </html>
        """
    }

    /// CSS styles for the HTML content.
    private var htmlCSS: String {
        """
        :root {
            color-scheme: light dark;
        }

        body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
            font-size: 16px;
            line-height: 1.6;
            padding: 16px;
            max-width: 100%;
            margin: 0 auto;
            color: var(--text-color);
            background-color: var(--bg-color);
            -webkit-text-size-adjust: 100%;
        }

        @media (prefers-color-scheme: dark) {
            :root {
                --text-color: #e0e0e0;
                --bg-color: #1c1c1e;
                --heading-color: #ffffff;
                --link-color: #0a84ff;
                --border-color: #444;
                --table-header-bg: #2c2c2e;
                --table-alt-bg: #252527;
                --highlight-bg: #665500;
            }
        }

        @media (prefers-color-scheme: light) {
            :root {
                --text-color: #333;
                --bg-color: #ffffff;
                --heading-color: #1a1a1a;
                --link-color: #007aff;
                --border-color: #ddd;
                --table-header-bg: #f0f4f8;
                --table-alt-bg: #fafafa;
                --highlight-bg: #ffff00;
            }
        }

        h1 {
            font-size: 1.6em;
            color: var(--heading-color);
            border-bottom: 2px solid var(--border-color);
            padding-bottom: 8px;
            margin-top: 0;
        }

        h2 {
            font-size: 1.3em;
            color: var(--heading-color);
            margin-top: 1.5em;
            border-bottom: 1px solid var(--border-color);
            padding-bottom: 4px;
        }

        h3 {
            font-size: 1.15em;
            color: var(--heading-color);
            margin-top: 1.2em;
        }

        h4, h5, h6 {
            font-size: 1.05em;
            color: var(--heading-color);
            margin-top: 1em;
        }

        p {
            margin: 0.8em 0;
        }

        a {
            color: var(--link-color);
            text-decoration: none;
        }

        a:hover, a:active {
            text-decoration: underline;
        }

        /* Metadata styling */
        .authors, .journal-info, .identifiers {
            font-size: 0.95em;
            margin: 0.5em 0;
        }

        /* Table styling */
        table {
            border-collapse: collapse;
            width: 100%;
            margin: 1em 0;
            font-size: 0.9em;
            display: block;
            overflow-x: auto;
            -webkit-overflow-scrolling: touch;
        }

        th, td {
            border: 1px solid var(--border-color);
            padding: 8px 12px;
            text-align: left;
            vertical-align: top;
            min-width: 80px;
        }

        th {
            background-color: var(--table-header-bg);
            font-weight: 600;
        }

        tr:nth-child(even) {
            background-color: var(--table-alt-bg);
        }

        .table-container {
            overflow-x: auto;
            margin: 1.5em 0;
            -webkit-overflow-scrolling: touch;
        }

        .table-caption {
            font-style: italic;
            margin-bottom: 0.5em;
            color: var(--text-color);
            opacity: 0.8;
        }

        /* Figure styling */
        figure {
            margin: 1.5em 0;
            padding: 1em;
            background-color: var(--table-alt-bg);
            border-radius: 8px;
        }

        figure img {
            max-width: 100%;
            height: auto;
            display: block;
            margin: 0 auto;
        }

        figcaption {
            margin-top: 0.5em;
            font-size: 0.9em;
            text-align: center;
        }

        figcaption strong {
            display: block;
            margin-bottom: 0.3em;
        }

        /* References styling */
        .references {
            font-size: 0.9em;
        }

        .references li {
            margin-bottom: 0.8em;
            padding-left: 0.5em;
        }

        /* iOS-specific adjustments */
        * {
            -webkit-touch-callout: default;
            -webkit-user-select: text;
        }
        """
    }

    /// JavaScript for figure fallback and anchor navigation.
    private var htmlJavaScript: String {
        """
        // Try alternative image extensions when loading fails
        function tryAlternativeExtensions(img) {
            var src = img.src;
            var extensions = ['.gif', '.jpg', '.jpeg', '.png', '.svg'];
            var currentExt = src.match(/\\.[^.]+$/);

            if (!currentExt) return;

            var base = src.slice(0, -currentExt[0].length);
            var currentIndex = extensions.indexOf(currentExt[0].toLowerCase());

            for (var i = 0; i < extensions.length; i++) {
                if (i !== currentIndex) {
                    img.src = base + extensions[i];
                    return;
                }
            }
        }

        // Smooth scroll to anchor
        document.addEventListener('click', function(e) {
            var target = e.target.closest('a[href^="#"]');
            if (target) {
                e.preventDefault();
                var id = target.getAttribute('href').substring(1);
                var element = document.getElementById(id);
                if (element) {
                    element.scrollIntoView({ behavior: 'smooth', block: 'start' });
                }
            }
        });
        """
    }
}

// MARK: - Markdown Scroll View

/// Scrollable view for markdown content with proper text rendering.
/// Note: This is a fallback for when HTML content is not available.
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

    let sampleHTML = """
    <h1>Effect of Vitamin D Supplementation on COVID-19 Outcomes</h1>

    <p class="authors"><strong>Authors:</strong> Smith J, Jones A, Brown B et al.</p>

    <p class="journal-info"><em>Journal of Medical Virology</em> (2024)</p>

    <h2>Abstract</h2>

    <p>Vitamin D has been proposed to have immunomodulatory effects that may be beneficial in COVID-19.</p>

    <h2>Methods</h2>

    <p>We conducted a systematic review and meta-analysis of randomized controlled trials.</p>

    <h2>Results</h2>

    <table>
        <thead>
            <tr><th>Study</th><th>N</th><th>Effect Size</th><th>p-value</th></tr>
        </thead>
        <tbody>
            <tr><td>Smith 2021</td><td>423</td><td>0.72</td><td>0.03</td></tr>
            <tr><td>Jones 2022</td><td>856</td><td>0.68</td><td>0.01</td></tr>
            <tr><td>Brown 2023</td><td>1,024</td><td>0.81</td><td>0.04</td></tr>
        </tbody>
    </table>

    <p>Ten studies with 5,234 participants were included. Vitamin D supplementation was associated with
    reduced ICU admission rates.</p>
    """

    return FullTextViewer(
        document: doc,
        result: AppFullTextResult(content: .html(sampleHTML), source: .europePMC)
    )
}
