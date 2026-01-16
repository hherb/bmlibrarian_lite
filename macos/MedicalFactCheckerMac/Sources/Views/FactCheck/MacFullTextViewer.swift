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
/// each with appropriate styling. Supports text selection and anchor navigation.
struct MacMarkdownView: View {
    /// The markdown content to display.
    let content: String

    /// Text to highlight in the content (empty string for no highlighting).
    let searchText: String

    /// Parsed blocks from the markdown content.
    private var blocks: [MarkdownBlock] {
        parseMarkdownBlocks(content)
    }

    /// State for tracking which anchor to scroll to.
    @State private var scrollTarget: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: MacSpacing.large) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                        renderBlock(block, scrollProxy: proxy)
                            .id(block.anchorId ?? "block-\(index)")
                    }
                }
                .padding(MacFullTextLayout.markdownPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: scrollTarget) { _, target in
                if let target = target {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(target, anchor: .top)
                    }
                    scrollTarget = nil
                }
            }
        }
    }

    /// Render a single markdown block with appropriate styling.
    @ViewBuilder
    private func renderBlock(_ block: MarkdownBlock, scrollProxy: ScrollViewProxy) -> some View {
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
            renderParagraphWithLinks(block.content, scrollProxy: scrollProxy)

        case .listItem:
            HStack(alignment: .top, spacing: MacSpacing.small) {
                Text("•")
                    .foregroundColor(.secondary)
                renderParagraphWithLinks(block.content, scrollProxy: scrollProxy)
            }

        case .numberedItem(let number):
            HStack(alignment: .top, spacing: MacSpacing.small) {
                Text("\(number).")
                    .foregroundColor(.secondary)
                    .frame(minWidth: 20, alignment: .trailing)
                renderParagraphWithLinks(block.content, scrollProxy: scrollProxy)
            }

        case .image(let url, let altText):
            AsyncFigureView(url: url, altText: altText)

        case .table(let rows, let hasHeader):
            MarkdownTableView(rows: rows, hasHeader: hasHeader)

        case .figureReference, .tableReference:
            // These are handled inline in paragraphs now
            EmptyView()

        case .anchor:
            // Anchor markers are invisible but provide scroll targets
            EmptyView()
        }
    }

    /// Render a paragraph that may contain anchor links.
    @ViewBuilder
    private func renderParagraphWithLinks(_ text: String, scrollProxy: ScrollViewProxy) -> some View {
        // Check if text contains anchor links [text](#anchor)
        let parts = parseTextWithAnchorLinks(text)

        if parts.count == 1 && parts[0].anchorTarget == nil {
            // No links, render as simple text
            Text(parseInlineMarkdown(text))
                .font(.body)
                .textSelection(.enabled)
                .lineSpacing(MacFullTextLayout.markdownLineSpacing)
        } else {
            // Has links, render with clickable parts
            // Using Text concatenation for inline links
            Text(buildAttributedTextWithLinks(parts, scrollProxy: scrollProxy))
                .font(.body)
                .textSelection(.enabled)
                .lineSpacing(MacFullTextLayout.markdownLineSpacing)
                .environment(\.openURL, OpenURLAction { url in
                    // Handle anchor links
                    if url.scheme == "anchor", let target = url.host {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            scrollProxy.scrollTo(target, anchor: .top)
                        }
                        return .handled
                    }
                    return .systemAction
                })
        }
    }

    /// Parse text into parts, separating anchor links from regular text.
    private func parseTextWithAnchorLinks(_ text: String) -> [TextPart] {
        var parts: [TextPart] = []
        var remaining = text

        // Pattern: [link text](#anchor-id)
        while let linkMatch = findAnchorLink(in: remaining) {
            // Add text before the link
            if !linkMatch.beforeText.isEmpty {
                parts.append(TextPart(text: linkMatch.beforeText, anchorTarget: nil))
            }

            // Add the link
            parts.append(TextPart(text: linkMatch.linkText, anchorTarget: linkMatch.anchorTarget))

            // Continue with remaining text
            remaining = linkMatch.afterText
        }

        // Add any remaining text
        if !remaining.isEmpty {
            parts.append(TextPart(text: remaining, anchorTarget: nil))
        }

        return parts.isEmpty ? [TextPart(text: text, anchorTarget: nil)] : parts
    }

    /// Find the next anchor link in text without using regex literals.
    private func findAnchorLink(in text: String) -> (beforeText: String, linkText: String, anchorTarget: String, afterText: String)? {
        // Look for [text](#anchor) pattern
        guard let bracketStart = text.firstIndex(of: "[") else { return nil }

        // Find matching ]
        var depth = 0
        var bracketEnd: String.Index?
        var index = bracketStart

        while index < text.endIndex {
            if text[index] == "[" {
                depth += 1
            } else if text[index] == "]" {
                depth -= 1
                if depth == 0 {
                    bracketEnd = index
                    break
                }
            }
            index = text.index(after: index)
        }

        guard let bracketEnd = bracketEnd else { return nil }

        // Check for (# after ]
        let afterBracket = text.index(after: bracketEnd)
        guard afterBracket < text.endIndex,
              text[afterBracket] == "(" else { return nil }

        let afterParen = text.index(after: afterBracket)
        guard afterParen < text.endIndex,
              text[afterParen] == "#" else { return nil }

        // Find closing )
        guard let closeParen = text[afterParen...].firstIndex(of: ")") else { return nil }

        // Extract parts
        let beforeText = String(text[..<bracketStart])
        let linkText = String(text[text.index(after: bracketStart)..<bracketEnd])
        let anchorTarget = String(text[text.index(after: afterParen)..<closeParen])
        let afterText = String(text[text.index(after: closeParen)...])

        return (beforeText, linkText, anchorTarget, afterText)
    }

    /// Build AttributedString with clickable anchor links.
    private func buildAttributedTextWithLinks(_ parts: [TextPart], scrollProxy: ScrollViewProxy) -> AttributedString {
        var result = AttributedString()

        for part in parts {
            if let anchor = part.anchorTarget {
                // Create a clickable link using a custom URL scheme
                var linkText = AttributedString(part.text)
                linkText.foregroundColor = .accentColor
                linkText.underlineStyle = .single
                // Use a custom URL scheme for anchor links
                if let url = URL(string: "anchor://\(anchor)") {
                    linkText.link = url
                }
                result.append(linkText)
            } else {
                // Regular text - parse inline markdown
                if let parsed = try? AttributedString(
                    markdown: part.text,
                    options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                ) {
                    result.append(parsed)
                } else {
                    result.append(AttributedString(part.text))
                }
            }
        }

        return result
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
        var pendingAnchorId: String?

        // Split by double newlines to get blocks
        let rawBlocks = text.components(separatedBy: "\n\n")

        for rawBlock in rawBlocks {
            var trimmed = rawBlock.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            // Check for anchor comment: <!-- anchor:id -->
            // First check if the entire block is just an anchor (preferred format)
            if let anchorId = extractAnchorId(from: trimmed) {
                pendingAnchorId = anchorId
                continue
            }

            // Also handle anchors at the start of a block with content following
            // (legacy format or single-newline separation)
            if let (extractedAnchorId, remaining) = extractAnchorWithContent(from: trimmed) {
                pendingAnchorId = extractedAnchorId
                trimmed = remaining
                guard !trimmed.isEmpty else { continue }
            }

            // Use pending anchor ID for next content block
            let anchorId = pendingAnchorId
            pendingAnchorId = nil

            // Check for markdown tables (lines starting with | )
            if isMarkdownTable(trimmed) {
                if let tableBlock = parseMarkdownTable(trimmed) {
                    // Apply anchor ID to table block
                    blocks.append(MarkdownBlock(type: tableBlock.type, content: tableBlock.content, anchorId: anchorId))
                } else {
                    // Fallback to paragraph if table parsing fails
                    blocks.append(MarkdownBlock(type: .paragraph, content: trimmed, anchorId: anchorId))
                }
            } else if trimmed.hasPrefix("######") {
                // Check for headers
                let content = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                blocks.append(MarkdownBlock(type: .heading6, content: content, anchorId: anchorId))
            } else if trimmed.hasPrefix("#####") {
                let content = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                blocks.append(MarkdownBlock(type: .heading5, content: content, anchorId: anchorId))
            } else if trimmed.hasPrefix("####") {
                let content = String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                blocks.append(MarkdownBlock(type: .heading4, content: content, anchorId: anchorId))
            } else if trimmed.hasPrefix("###") {
                let content = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                blocks.append(MarkdownBlock(type: .heading3, content: content, anchorId: anchorId))
            } else if trimmed.hasPrefix("##") {
                let content = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                blocks.append(MarkdownBlock(type: .heading2, content: content, anchorId: anchorId))
            } else if trimmed.hasPrefix("#") {
                let content = String(trimmed.dropFirst(1)).trimmingCharacters(in: .whitespaces)
                blocks.append(MarkdownBlock(type: .heading1, content: content, anchorId: anchorId))
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                // Handle list items (may be multiple lines)
                let lines = trimmed.components(separatedBy: "\n")
                var isFirst = true
                for line in lines {
                    let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                    if trimmedLine.hasPrefix("- ") {
                        blocks.append(MarkdownBlock(type: .listItem, content: String(trimmedLine.dropFirst(2)), anchorId: isFirst ? anchorId : nil))
                        isFirst = false
                    } else if trimmedLine.hasPrefix("* ") {
                        blocks.append(MarkdownBlock(type: .listItem, content: String(trimmedLine.dropFirst(2)), anchorId: isFirst ? anchorId : nil))
                        isFirst = false
                    } else if !trimmedLine.isEmpty {
                        blocks.append(MarkdownBlock(type: .paragraph, content: trimmedLine, anchorId: isFirst ? anchorId : nil))
                        isFirst = false
                    }
                }
            } else if let (number, content) = parseNumberedListItem(trimmed) {
                // Numbered list item
                blocks.append(MarkdownBlock(type: .numberedItem(number), content: content, anchorId: anchorId))
            } else if let (altText, url) = parseMarkdownImage(trimmed) {
                // Markdown image: ![alt text](url)
                blocks.append(MarkdownBlock(type: .image(url: url, altText: altText), content: "", anchorId: anchorId))
            } else {
                // Regular paragraph
                blocks.append(MarkdownBlock(type: .paragraph, content: trimmed, anchorId: anchorId))
            }
        }

        return blocks
    }

    /// Extract anchor ID from an anchor comment.
    ///
    /// Handles both standalone anchor comments and anchors at the start of a block.
    /// - Parameter text: The text to search for an anchor comment.
    /// - Returns: A tuple of (anchorId, remainingText) if found, nil otherwise.
    private func extractAnchorId(from text: String) -> String? {
        // Pattern: <!-- anchor:id -->
        // Handle case where entire text is the anchor
        if text.hasPrefix("<!-- anchor:") && text.hasSuffix("-->") {
            let start = text.index(text.startIndex, offsetBy: 12)
            let end = text.index(text.endIndex, offsetBy: -3)
            if start < end {
                return String(text[start..<end]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Extract anchor ID and remaining content from text that may contain an anchor at the start.
    ///
    /// - Parameter text: The text to search.
    /// - Returns: A tuple of (anchorId, remainingText) if an anchor was found, nil otherwise.
    private func extractAnchorWithContent(from text: String) -> (anchorId: String, remaining: String)? {
        // Pattern: <!-- anchor:id --> followed by content
        guard text.hasPrefix("<!-- anchor:") else { return nil }

        // Find the closing -->
        guard let closeRange = text.range(of: "-->") else { return nil }

        let anchorStart = text.index(text.startIndex, offsetBy: 12)
        let anchorEnd = closeRange.lowerBound

        guard anchorStart < anchorEnd else { return nil }

        let anchorId = String(text[anchorStart..<anchorEnd]).trimmingCharacters(in: .whitespaces)
        let remaining = String(text[closeRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)

        return (anchorId, remaining)
    }

    /// Parse a numbered list item without using regex literals.
    private func parseNumberedListItem(_ text: String) -> (Int, String)? {
        // Look for pattern: number. text
        var numberStr = ""
        var index = text.startIndex

        // Read leading digits
        while index < text.endIndex && text[index].isNumber {
            numberStr.append(text[index])
            index = text.index(after: index)
        }

        guard !numberStr.isEmpty,
              index < text.endIndex,
              text[index] == ".",
              let number = Int(numberStr) else {
            return nil
        }

        // Skip the dot and any whitespace
        index = text.index(after: index)
        while index < text.endIndex && text[index].isWhitespace {
            index = text.index(after: index)
        }

        guard index < text.endIndex else { return nil }

        let content = String(text[index...])
        return (number, content)
    }

    /// Parse a markdown image without using regex literals.
    private func parseMarkdownImage(_ text: String) -> (altText: String, url: String)? {
        // Pattern: ![alt text](url)
        guard text.hasPrefix("![") else { return nil }

        // Find closing bracket for alt text
        guard let altEnd = text.firstIndex(of: "]"),
              text.index(after: altEnd) < text.endIndex,
              text[text.index(after: altEnd)] == "(" else {
            return nil
        }

        let altText = String(text[text.index(text.startIndex, offsetBy: 2)..<altEnd])

        // Find URL between ( and )
        let urlStart = text.index(altEnd, offsetBy: 2)
        guard let urlEnd = text.lastIndex(of: ")"),
              urlStart < urlEnd else {
            return nil
        }

        let url = String(text[urlStart..<urlEnd])
        return (altText, url)
    }

    /// Check if a block of text is a markdown table.
    private func isMarkdownTable(_ text: String) -> Bool {
        let lines = text.components(separatedBy: "\n")
        guard lines.count >= 2 else { return false }

        // Must have at least 2 lines, all starting with |
        // Second line should be the separator (| --- | --- |)
        let allLinesStartWithPipe = lines.allSatisfy { line in
            line.trimmingCharacters(in: .whitespaces).hasPrefix("|")
        }
        guard allLinesStartWithPipe else { return false }

        // Check for separator line (contains only |, -, :, and spaces)
        if lines.count >= 2 {
            let separatorLine = lines[1].trimmingCharacters(in: .whitespaces)
            let isSeparator = separatorLine.allSatisfy { char in
                char == "|" || char == "-" || char == ":" || char == " "
            }
            return isSeparator && separatorLine.contains("-")
        }

        return false
    }

    /// Parse a markdown table block into rows.
    private func parseMarkdownTable(_ text: String) -> MarkdownBlock? {
        let lines = text.components(separatedBy: "\n")
        guard lines.count >= 2 else { return nil }

        var rows: [[String]] = []
        var hasHeader = false

        for (index, line) in lines.enumerated() {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)

            // Skip separator line
            if index == 1 {
                let isSeparator = trimmedLine.allSatisfy { char in
                    char == "|" || char == "-" || char == ":" || char == " "
                }
                if isSeparator {
                    hasHeader = true
                    continue
                }
            }

            // Parse cells from the line
            let cells = parseCells(from: trimmedLine)
            if !cells.isEmpty {
                rows.append(cells)
            }
        }

        guard !rows.isEmpty else { return nil }
        return MarkdownBlock(type: .table(rows: rows, hasHeader: hasHeader), content: "")
    }

    /// Parse table cells from a markdown table row.
    private func parseCells(from line: String) -> [String] {
        var cells: [String] = []
        var trimmedLine = line

        // Remove leading and trailing pipes
        if trimmedLine.hasPrefix("|") {
            trimmedLine = String(trimmedLine.dropFirst())
        }
        if trimmedLine.hasSuffix("|") {
            trimmedLine = String(trimmedLine.dropLast())
        }

        // Split by | and trim each cell
        let parts = trimmedLine.components(separatedBy: "|")
        for part in parts {
            cells.append(part.trimmingCharacters(in: .whitespaces))
        }

        return cells
    }
}

/// A parsed markdown block.
private struct MarkdownBlock {
    let type: BlockType
    let content: String
    /// Optional anchor ID for this block (for scroll targeting).
    let anchorId: String?

    init(type: BlockType, content: String, anchorId: String? = nil) {
        self.type = type
        self.content = content
        self.anchorId = anchorId
    }

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
        case table(rows: [[String]], hasHeader: Bool)
        case figureReference(id: String, label: String)
        case tableReference(id: String, label: String)
        case anchor(id: String)
    }
}

/// A part of text that may or may not be an anchor link.
private struct TextPart {
    let text: String
    let anchorTarget: String?
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

// MARK: - Markdown Table View

/// SwiftUI view for rendering markdown tables with proper formatting.
///
/// Displays tables with:
/// - Bold header row (if present)
/// - Alternating row backgrounds for readability
/// - Horizontal scrolling for wide tables
/// - Text selection support
struct MarkdownTableView: View {
    /// The table rows (first row is header if hasHeader is true).
    let rows: [[String]]

    /// Whether the first row should be treated as a header.
    let hasHeader: Bool

    /// Background color for header row.
    private let headerBackground = Color.blue.opacity(0.1)

    /// Background color for alternating rows.
    private let alternateBackground = Color.gray.opacity(0.05)

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    HStack(spacing: 0) {
                        ForEach(Array(row.enumerated()), id: \.offset) { cellIndex, cell in
                            Text(cell)
                                .font(isHeaderRow(index) ? .body.bold() : .body)
                                .textSelection(.enabled)
                                .padding(.horizontal, MacSpacing.small)
                                .padding(.vertical, MacSpacing.xSmall)
                                .frame(minWidth: 80, alignment: .leading)

                            if cellIndex < row.count - 1 {
                                Divider()
                                    .frame(height: 20)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(rowBackground(for: index))

                    if index < rows.count - 1 {
                        Divider()
                    }
                }
            }
            .background(Color(NSColor.textBackgroundColor))
            .cornerRadius(MacCornerRadius.small)
            .overlay(
                RoundedRectangle(cornerRadius: MacCornerRadius.small)
                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
            )
        }
        .padding(.vertical, MacSpacing.small)
    }

    /// Check if a row index corresponds to the header row.
    private func isHeaderRow(_ index: Int) -> Bool {
        hasHeader && index == 0
    }

    /// Get the background color for a row.
    private func rowBackground(for index: Int) -> Color {
        if isHeaderRow(index) {
            return headerBackground
        }
        // Adjust index for alternating colors (skip header)
        let adjustedIndex = hasHeader ? index - 1 : index
        return adjustedIndex.isMultiple(of: 2) ? Color.clear : alternateBackground
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
