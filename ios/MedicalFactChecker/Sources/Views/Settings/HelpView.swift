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

// MARK: - Help Window Constants

/// Layout constants for help views.
private enum HelpViewLayout {
    static let contentPadding: CGFloat = 16
    static let sectionSpacing: CGFloat = 12
}

// MARK: - Markdown Content View

/// A view that renders markdown content with proper styling for iOS.
///
/// Parses markdown line-by-line and renders headers, lists, tables,
/// code blocks, and inline formatting as native SwiftUI views.
struct MarkdownContentView: View {
    let markdownString: String

    var body: some View {
        VStack(alignment: .leading, spacing: HelpViewLayout.sectionSpacing) {
            ForEach(Array(parseMarkdown().enumerated()), id: \.offset) { _, element in
                element
            }
        }
    }

    /// Parses markdown string into SwiftUI views.
    private func parseMarkdown() -> [AnyView] {
        let lines = markdownString.components(separatedBy: "\n")
        var views: [AnyView] = []
        var inCodeBlock = false
        var codeBlockContent: [String] = []
        var inTable = false
        var tableRows: [[String]] = []

        for line in lines {
            // Handle code blocks
            if line.hasPrefix("```") {
                if inCodeBlock {
                    // End code block
                    views.append(AnyView(codeBlockView(codeBlockContent.joined(separator: "\n"))))
                    codeBlockContent = []
                    inCodeBlock = false
                } else {
                    inCodeBlock = true
                }
                continue
            }

            if inCodeBlock {
                codeBlockContent.append(line)
                continue
            }

            // Handle tables
            if line.contains("|") && !line.trimmingCharacters(in: .whitespaces).isEmpty {
                let cells = line.split(separator: "|").map { String($0).trimmingCharacters(in: .whitespaces) }
                if !cells.isEmpty && !cells.allSatisfy({ $0.allSatisfy { $0 == "-" || $0 == ":" } }) {
                    if !inTable {
                        inTable = true
                    }
                    tableRows.append(cells)
                }
                continue
            } else if inTable {
                // End table
                views.append(AnyView(tableView(tableRows)))
                tableRows = []
                inTable = false
            }

            // Skip empty lines but add spacing
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                views.append(AnyView(Spacer().frame(height: 8)))
                continue
            }

            // Handle headers
            if line.hasPrefix("#### ") {
                views.append(AnyView(headerView(line.dropFirst(5), level: 4)))
            } else if line.hasPrefix("### ") {
                views.append(AnyView(headerView(line.dropFirst(4), level: 3)))
            } else if line.hasPrefix("## ") {
                views.append(AnyView(headerView(line.dropFirst(3), level: 2)))
            } else if line.hasPrefix("# ") {
                views.append(AnyView(headerView(line.dropFirst(2), level: 1)))
            }
            // Handle horizontal rules
            else if line.trimmingCharacters(in: .whitespaces).hasPrefix("---") {
                views.append(AnyView(Divider().padding(.vertical, 8)))
            }
            // Handle bullet points
            else if line.trimmingCharacters(in: .whitespaces).hasPrefix("- ") ||
                        line.trimmingCharacters(in: .whitespaces).hasPrefix("* ") {
                let content = String(line.trimmingCharacters(in: .whitespaces).dropFirst(2))
                views.append(AnyView(bulletPointView(content)))
            }
            // Handle numbered lists
            else if let match = line.range(of: #"^\s*\d+\.\s+"#, options: .regularExpression) {
                let content = String(line[match.upperBound...])
                let number = line[line.startIndex..<match.upperBound]
                    .trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: ".", with: "")
                views.append(AnyView(numberedListView(number: number, content: content)))
            }
            // Regular paragraph
            else {
                views.append(AnyView(paragraphView(line)))
            }
        }

        // Handle any remaining table
        if inTable && !tableRows.isEmpty {
            views.append(AnyView(tableView(tableRows)))
        }

        return views
    }

    // MARK: - View Builders

    private func headerView(_ text: some StringProtocol, level: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(processInlineMarkdown(String(text)))
                .font(headerFont(level: level))
                .fontWeight(level == 1 ? .bold : .semibold)
                .foregroundColor(.primary)

            if level <= 2 {
                Rectangle()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(height: 1)
            }
        }
        .padding(.top, level == 1 ? 8 : 12)
        .padding(.bottom, 4)
    }

    private func headerFont(level: Int) -> Font {
        switch level {
        case 1: return .title
        case 2: return .title2
        case 3: return .title3
        default: return .headline
        }
    }

    private func paragraphView(_ text: String) -> some View {
        Text(processInlineMarkdown(text))
            .font(.body)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func bulletPointView(_ content: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\u{2022}")
                .font(.body)
                .foregroundColor(.secondary)
            Text(processInlineMarkdown(content))
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 16)
    }

    private func numberedListView(number: String, content: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number).")
                .font(.body)
                .foregroundColor(.secondary)
                .frame(width: 24, alignment: .trailing)
            Text(processInlineMarkdown(content))
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 12)
    }

    private func codeBlockView(_ code: String) -> some View {
        Text(code)
            .font(.system(.footnote, design: .monospaced))
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(UIColor.systemGray6))
            .cornerRadius(8)
    }

    private func tableView(_ rows: [[String]]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.offset) { colIndex, cell in
                        Text(processInlineMarkdown(cell))
                            .font(index == 0 ? .subheadline.weight(.semibold) : .subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 8)
                            .background(index == 0 ? Color.secondary.opacity(0.1) : Color.clear)

                        if colIndex < row.count - 1 {
                            Divider()
                        }
                    }
                }

                if index < rows.count - 1 {
                    Divider()
                }
            }
        }
        .background(Color(UIColor.systemGray6).opacity(0.5))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
        .padding(.vertical, 4)
    }

    /// Process inline markdown elements like bold, italic, code, and links.
    private func processInlineMarkdown(_ text: String) -> AttributedString {
        var result = text

        // Convert markdown links [text](url) to just text for display
        // (links to external URLs don't work reliably in AttributedString)
        let linkPattern = #"\[([^\]]+)\]\([^\)]+\)"#
        if let regex = try? NSRegularExpression(pattern: linkPattern) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "$1")
        }

        do {
            var options = AttributedString.MarkdownParsingOptions()
            options.interpretedSyntax = .inlineOnlyPreservingWhitespace
            return try AttributedString(markdown: result, options: options)
        } catch {
            return AttributedString(result)
        }
    }
}

// MARK: - Help View

/// View that displays the help documentation with native markdown rendering.
///
/// Loads and renders the HELP.md file bundled with the app, providing
/// users with comprehensive guidance on using the app.
struct HelpView: View {
    @State private var markdownContent: String = "Loading..."
    @State private var loadError: String?

    var body: some View {
        ScrollView {
            if let error = loadError {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text("Could not load help content")
                        .font(.headline)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
            } else {
                MarkdownContentView(markdownString: markdownContent)
                    .textSelection(.enabled)
                    .padding(HelpViewLayout.contentPadding)
            }
        }
        .navigationTitle("Help")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .task {
            loadHelpContent()
        }
    }

    // MARK: - Content Loading

    /// Loads the HELP.md content from the app bundle.
    private func loadHelpContent() {
        if let url = Bundle.main.url(forResource: "HELP", withExtension: "md"),
           let content = try? String(contentsOf: url, encoding: .utf8) {
            markdownContent = content
        } else {
            markdownContent = fallbackHelpContent
        }
    }

    /// Fallback help content if the bundle file is not available.
    private var fallbackHelpContent: String {
        """
        # Medical Fact Checker Help

        Welcome to Medical Fact Checker, an AI-powered tool for evaluating medical claims using peer-reviewed scientific literature.

        ## Quick Start

        1. Enter a medical claim or question
        2. Tap "Check Evidence"
        3. Review the evidence report

        ## Important Notes

        - This app analyzes publication abstracts, not full-text articles
        - The default fetches 20 documents per search - you can fetch more for thorough research
        - Results depend on the AI model used - Claude models are recommended

        ## Need More Help?

        Visit our GitHub repository for detailed documentation:
        github.com/hherb/bmlibrarian_lite

        ---

        This app is a research tool, not a substitute for professional medical advice.
        """
    }
}

// MARK: - Privacy View

/// View that displays the privacy policy with native markdown rendering.
struct PrivacyView: View {
    @State private var markdownContent: String = "Loading..."
    @State private var loadError: String?

    var body: some View {
        ScrollView {
            if let error = loadError {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text("Could not load privacy policy")
                        .font(.headline)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
            } else {
                MarkdownContentView(markdownString: markdownContent)
                    .textSelection(.enabled)
                    .padding(HelpViewLayout.contentPadding)
            }
        }
        .navigationTitle("Privacy Policy")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .task {
            loadPrivacyContent()
        }
    }

    // MARK: - Content Loading

    /// Loads the PRIVACY.md content from the app bundle.
    private func loadPrivacyContent() {
        if let url = Bundle.main.url(forResource: "PRIVACY", withExtension: "md"),
           let content = try? String(contentsOf: url, encoding: .utf8) {
            markdownContent = content
        } else {
            markdownContent = fallbackPrivacyContent
        }
    }

    /// Fallback privacy content if the bundle file is not available.
    private var fallbackPrivacyContent: String {
        """
        # Privacy Policy

        Medical Fact Checker is designed with privacy in mind.

        ## What We Do NOT Collect

        - We do not collect personal information
        - We do not collect usage analytics
        - We do not track your location
        - We do not use advertising trackers

        ## What Stays On Your Device

        - Medical claims and queries
        - Fact-check history
        - App settings
        - API keys (stored in iOS Keychain)

        ## Third-Party Services

        When you run a fact-check, data is sent to:
        - PubMed (NCBI) for literature searches
        - Your chosen LLM provider for AI analysis

        Use Ollama for completely local processing with no external API calls.

        ---

        For the complete privacy policy, visit:
        github.com/hherb/bmlibrarian_lite
        """
    }
}

#Preview("Help") {
    NavigationStack {
        HelpView()
    }
}

#Preview("Privacy") {
    NavigationStack {
        PrivacyView()
    }
}
