//
//  ReportView.swift
//  MedicalFactChecker
//
//  View for displaying the evidence report.
//

import SwiftUI

struct ReportView: View {
    let report: EvidenceReport
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Verdict Badge
                    HStack {
                        Spacer()
                        VerdictBadge(verdict: report.verdict)
                        Spacer()
                    }

                    // Claim and Query (if available from session)
                    if let session = report.session {
                        VStack(alignment: .leading, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Claim")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(session.claim)
                                    .font(.body)
                                    .italic()
                            }

                            if let query = session.pubmedQuery {
                                Divider()
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("PubMed Query")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(query)
                                        .font(.caption)
                                        .fontDesign(.monospaced)
                                        .foregroundColor(.accentColor)
                                }
                            }
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(10)
                    }

                    // Summary
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Summary")
                            .font(.headline)
                        Text(report.summary)
                            .font(.body)
                    }
                    .padding()
                    .background(Color.accentColor.opacity(0.1))
                    .cornerRadius(10)

                    // Full Report (Markdown)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Detailed Report")
                            .font(.headline)

                        MarkdownReportView(
                            report.fullReport,
                            documents: report.session?.documents ?? []
                        )
                    }

                    // Reviewed Documents Section
                    if let session = report.session, !session.documents.isEmpty {
                        ReviewedDocumentsSection(documents: session.documents.sorted {
                            ($0.relevanceScore ?? 0) > ($1.relevanceScore ?? 0)
                        })
                    }

                    // Statistics
                    StatisticsSection(report: report)

                    // Cost (if session available)
                    if let session = report.session {
                        CostSection(session: session)
                    }
                }
                .padding()
            }
            .navigationTitle("Evidence Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    ShareLink(
                        item: report.plainTextReport,
                        subject: Text("Medical Fact Check Report"),
                        message: Text("Evidence report for: \(report.session?.claim ?? "Unknown claim")")
                    )
                }
            }
        }
    }
}

// MARK: - Subviews

struct VerdictBadge: View {
    let verdict: Verdict

    var body: some View {
        Text(verdict.rawValue)
            .font(.headline)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(backgroundColor)
            .foregroundColor(.white)
            .cornerRadius(25)
    }

    private var backgroundColor: Color {
        switch verdict {
        case .supported: return .green
        case .partiallySupported: return .orange
        case .notSupported: return .red
        case .insufficientEvidence: return .gray
        case .conflicting: return .purple
        }
    }
}

struct StatisticsSection: View {
    let report: EvidenceReport

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Statistics")
                .font(.headline)

            HStack(spacing: 20) {
                StatItem(
                    icon: "doc.text",
                    value: "\(report.documentsReviewed)",
                    label: "Reviewed"
                )
                StatItem(
                    icon: "checkmark.circle",
                    value: "\(report.uniqueSourceCount)",
                    label: "Relevant"
                )
                StatItem(
                    icon: "quote.bubble",
                    value: "\(report.citationCount)",
                    label: "Citations"
                )
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(10)
    }
}

struct StatItem: View {
    let icon: String
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.accentColor)
            Text(value)
                .font(.headline)
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct CostSection: View {
    let session: FactCheckSession

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("API Cost")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(CostCalculator.formatCost(session.estimatedCostUSD))
                    .font(.subheadline)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text("Tokens Used")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("\(session.totalInputTokens + session.totalOutputTokens)")
                    .font(.subheadline)
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(10)
    }
}

struct ReviewedDocumentsSection: View {
    let documents: [Document]
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: { withAnimation { isExpanded.toggle() } }) {
                HStack {
                    Text("Reviewed Documents (\(documents.count))")
                        .font(.headline)
                        .foregroundColor(.primary)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(documents, id: \.pmid) { document in
                    DocumentCard(document: document)
                }
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(10)
    }
}

struct DocumentCard: View {
    let document: Document
    @State private var showAbstract = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header with score badge
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(document.title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(2)

                    Text(document.formattedAuthors)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if let journal = document.journal, let year = document.year {
                        Text(verbatim: "\(journal), \(year)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                if let score = document.relevanceScore {
                    ScoreBadge(score: score)
                }
            }

            // Score explanation
            if let explanation = document.scoreExplanation, !explanation.isEmpty {
                Text(explanation)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .italic()
                    .padding(.top, 2)
            }

            // Expandable abstract
            Button(action: { withAnimation { showAbstract.toggle() } }) {
                HStack {
                    Text(showAbstract ? "Hide Abstract" : "Show Abstract")
                        .font(.caption)
                    Image(systemName: showAbstract ? "chevron.up" : "chevron.down")
                        .font(.caption)
                }
                .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)

            if showAbstract {
                Text(document.abstract)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 4)
            }

            // Citations from this document
            if !document.citations.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Key Passages:")
                        .font(.caption)
                        .fontWeight(.medium)

                    ForEach(document.citations, id: \.id) { citation in
                        Text("\"\(citation.passage)\"")
                            .font(.caption)
                            .italic()
                            .foregroundColor(.secondary)
                            .padding(.leading, 8)
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding()
        .background(Color.white.opacity(0.5))
        .cornerRadius(8)
    }
}

struct ScoreBadge: View {
    let score: Int

    var body: some View {
        Text("\(score)")
            .font(.caption)
            .fontWeight(.bold)
            .foregroundColor(.white)
            .frame(width: 28, height: 28)
            .background(scoreColor)
            .clipShape(Circle())
    }

    private var scoreColor: Color {
        switch score {
        case 5: return .green
        case 4: return Color(red: 0.4, green: 0.7, blue: 0.3)
        case 3: return .orange
        case 2: return Color(red: 0.9, green: 0.5, blue: 0.2)
        default: return .red
        }
    }
}

/// A parsed reference from the markdown text.
struct ParsedReference: Identifiable {
    let id = UUID()
    let text: String  // e.g., "Smith et al., 2021"
    let range: Range<String.Index>
}

/// Markdown text renderer with clickable references.
///
/// Parses markdown and detects reference patterns like [Author, Year] or [Author et al., Year],
/// making them tappable to show document details.
struct MarkdownReportView: View {
    let content: String
    let documents: [Document]

    @State private var selectedDocument: Document?

    init(_ content: String, documents: [Document] = []) {
        self.content = content
        self.documents = documents
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            let blocks = parseMarkdownBlocks(content)
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                renderBlock(block)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .documentReferenceClicked)) { notification in
            if let url = notification.userInfo?["url"] as? URL {
                handleReferenceTap(url)
            }
        }
        .sheet(item: $selectedDocument) { doc in
            DocumentDetailSheet(document: doc)
        }
    }

    // MARK: - Block Parsing

    private enum MarkdownBlock {
        case heading(level: Int, text: String)
        case paragraph(text: String)
        case listItem(text: String, ordered: Bool, number: Int?)
        case empty
    }

    private func parseMarkdownBlocks(_ text: String) -> [MarkdownBlock] {
        let normalized = normalizeLineBreaks(text)
        let lines = normalized.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var currentParagraph: [String] = []
        var listNumber = 0

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                // Flush current paragraph
                if !currentParagraph.isEmpty {
                    blocks.append(.paragraph(text: currentParagraph.joined(separator: " ")))
                    currentParagraph = []
                }
                listNumber = 0
                continue
            }

            // Check for headers
            if let headingMatch = parseHeading(trimmed) {
                if !currentParagraph.isEmpty {
                    blocks.append(.paragraph(text: currentParagraph.joined(separator: " ")))
                    currentParagraph = []
                }
                blocks.append(headingMatch)
                listNumber = 0
                continue
            }

            // Check for list items
            if let listMatch = parseListItem(trimmed, currentNumber: &listNumber) {
                if !currentParagraph.isEmpty {
                    blocks.append(.paragraph(text: currentParagraph.joined(separator: " ")))
                    currentParagraph = []
                }
                blocks.append(listMatch)
                continue
            }

            // Regular text - accumulate into paragraph
            currentParagraph.append(trimmed)
        }

        // Flush remaining paragraph
        if !currentParagraph.isEmpty {
            blocks.append(.paragraph(text: currentParagraph.joined(separator: " ")))
        }

        return blocks
    }

    private func parseHeading(_ line: String) -> MarkdownBlock? {
        if line.hasPrefix("### ") {
            return .heading(level: 3, text: String(line.dropFirst(4)))
        } else if line.hasPrefix("## ") {
            return .heading(level: 2, text: String(line.dropFirst(3)))
        } else if line.hasPrefix("# ") {
            return .heading(level: 1, text: String(line.dropFirst(2)))
        }
        return nil
    }

    private func parseListItem(_ line: String, currentNumber: inout Int) -> MarkdownBlock? {
        // Unordered list: - item or * item
        if line.hasPrefix("- ") {
            currentNumber = 0
            return .listItem(text: String(line.dropFirst(2)), ordered: false, number: nil)
        }
        if line.hasPrefix("* ") {
            currentNumber = 0
            return .listItem(text: String(line.dropFirst(2)), ordered: false, number: nil)
        }

        // Ordered list: 1. item
        if let match = parseOrderedListItem(line) {
            currentNumber += 1
            return .listItem(text: match, ordered: true, number: currentNumber)
        }

        return nil
    }

    /// Parse ordered list item like "1. text"
    private func parseOrderedListItem(_ line: String) -> String? {
        let pattern = "^\\d+\\.\\s+(.+)$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: line,
                  range: NSRange(line.startIndex..., in: line)
              ),
              let textRange = Range(match.range(at: 1), in: line) else {
            return nil
        }
        return String(line[textRange])
    }

    // MARK: - Block Rendering

    @ViewBuilder
    private func renderBlock(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            renderHeading(level: level, text: text)
        case .paragraph(let text):
            renderParagraph(text)
        case .listItem(let text, let ordered, let number):
            renderListItem(text: text, ordered: ordered, number: number)
        case .empty:
            EmptyView()
        }
    }

    @ViewBuilder
    private func renderHeading(level: Int, text: String) -> some View {
        let font: Font = switch level {
        case 1: .title.bold()
        case 2: .title2.bold()
        default: .title3.bold()
        }

        Text(text)
            .font(font)
            .padding(.top, level == 1 ? 16 : 12)
            .padding(.bottom, 6)
    }

    @ViewBuilder
    private func renderParagraph(_ text: String) -> some View {
        renderRichText(text)
            .padding(.vertical, 4)
    }

    @ViewBuilder
    private func renderListItem(text: String, ordered: Bool, number: Int?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if ordered, let num = number {
                Text("\(num).")
                    .font(.body)
                    .fontWeight(.semibold)
                    .frame(width: 24, alignment: .trailing)
            } else {
                Text("•")
                    .font(.body)
                    .fontWeight(.bold)
                    .frame(width: 24, alignment: .trailing)
            }
            renderRichText(text)
        }
        .padding(.vertical, 2)
        .padding(.leading, 8)
    }

    // MARK: - Rich Text with References

    @ViewBuilder
    private func renderRichText(_ text: String) -> some View {
        let attributed = parseInlineFormatting(text)
        Text(attributed)
            .font(.body)
    }

    /// Parse inline formatting (bold, italic) and references into AttributedString.
    ///
    /// Supports two reference formats:
    /// 1. New format with embedded ID: [Author, Year](doc:pmid-12345678)
    /// 2. Legacy format without ID: [Author, Year]
    private func parseInlineFormatting(_ text: String) -> AttributedString {
        var result = AttributedString()

        // Pattern for references with embedded document ID: [Author, Year](doc:pmid-12345678)
        // Also matches legacy format: [Author, Year] (without the doc: link)
        // Group 1: display text (e.g., "Smith et al., 2021")
        // Group 2: optional document ID (e.g., "pmid-12345678")
        let referencePattern = "\\[([^\\]]+?,\\s*\\d{4}[a-z]?)\\](?:\\(doc:([^)]+)\\))?"
        guard let regex = try? NSRegularExpression(pattern: referencePattern) else {
            return parseBasicFormatting(text)
        }

        var currentIndex = text.startIndex
        let nsRange = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: nsRange)

        for match in matches {
            guard let fullRange = Range(match.range, in: text),
                  let displayRange = Range(match.range(at: 1), in: text) else {
                continue
            }

            // Add text before the reference
            if fullRange.lowerBound > currentIndex {
                let beforeText = String(text[currentIndex..<fullRange.lowerBound])
                result.append(parseBasicFormatting(beforeText))
            }

            // Extract display text and optional document ID
            let displayText = String(text[displayRange])
            let documentId: String?
            if match.range(at: 2).location != NSNotFound,
               let idRange = Range(match.range(at: 2), in: text) {
                documentId = String(text[idRange])
            } else {
                documentId = nil
            }

            // Add the reference as a tappable link
            var refAttr = AttributedString("[\(displayText)]")
            refAttr.foregroundColor = Color.accentColor
            refAttr.underlineStyle = Text.LineStyle.single

            // Use document ID if available, otherwise fall back to display text for lookup
            // URL format: docref://lookup?type=id&value=pmid-12345 or docref://lookup?type=ref&value=encoded-ref
            if let docId = documentId {
                let encoded = docId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? docId
                if let url = URL(string: "docref://lookup?type=id&value=\(encoded)") {
                    refAttr.link = url
                }
            } else {
                let encoded = displayText.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? displayText
                if let url = URL(string: "docref://lookup?type=ref&value=\(encoded)") {
                    refAttr.link = url
                }
            }
            result.append(refAttr)

            currentIndex = fullRange.upperBound
        }

        // Add remaining text
        if currentIndex < text.endIndex {
            let remainingText = String(text[currentIndex...])
            result.append(parseBasicFormatting(remainingText))
        }

        return result
    }

    /// Parse basic inline formatting (bold, italic) without references.
    private func parseBasicFormatting(_ text: String) -> AttributedString {
        // Try to parse as markdown for bold/italic
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return attributed
        }
        return AttributedString(text)
    }

    /// Handle taps on document references in the report.
    ///
    /// Parses the custom `docref://` URL scheme and looks up the referenced document
    /// to display in a detail sheet.
    ///
    /// - Parameter url: The tapped URL (expected scheme: `docref://`).
    private func handleReferenceTap(_ url: URL) {
        guard url.scheme == "docref" else {
            return
        }

        // Parse query parameters: docref://lookup?type=id&value=pmid-12345
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            return
        }

        let type = queryItems.first { $0.name == "type" }?.value
        let value = queryItems.first { $0.name == "value" }?.value

        guard let lookupType = type, let lookupValue = value else {
            return
        }

        if lookupType == "id" {
            // Direct ID lookup
            selectedDocument = findDocumentById(lookupValue)
        } else if lookupType == "ref" {
            // Legacy reference text lookup
            let refText = lookupValue.removingPercentEncoding ?? lookupValue
            selectedDocument = findDocumentByReference(refText)
        }
    }

    /// Find a document by its unique ID.
    ///
    /// - Parameter documentId: The document's unique identifier (e.g., "pmid-12345678").
    /// - Returns: The matching document, or nil if not found.
    private func findDocumentById(_ documentId: String) -> Document? {
        return documents.first { $0.id == documentId }
    }

    /// Find a document by reference text (legacy fallback).
    ///
    /// Used when document ID is not embedded in the reference.
    /// Parses author name and year from formats like "Smith et al., 2021" or "Smith, 2021".
    ///
    /// - Parameter reference: The reference text to parse.
    /// - Returns: The matching document, or nil if not found.
    private func findDocumentByReference(_ reference: String) -> Document? {
        // Parse reference: "Smith et al., 2021" or "Smith, 2021"
        let parts = reference.components(separatedBy: ",")
        guard parts.count >= 2 else { return nil }

        let authorPart = parts[0].trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " et al.", with: "")
            .lowercased()
        let yearPart = parts.last?.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: .letters) // Remove any suffix like "a", "b"

        guard let yearString = yearPart, let year = Int(yearString) else {
            return nil
        }

        // Find document with matching author and year
        return documents.first { doc in
            guard doc.year == year else { return false }

            // Check if any author's last name matches
            for author in doc.authors {
                let lastName = author.components(separatedBy: " ").first?.lowercased() ?? ""
                if lastName == authorPart || author.lowercased().contains(authorPart) {
                    return true
                }
            }
            return false
        }
    }

    /// Normalize various line break formats for proper markdown rendering.
    ///
    /// Converts escaped newlines (`\\n`) to actual newlines and collapses
    /// multiple consecutive newlines into double newlines.
    ///
    /// - Parameter text: The raw text to normalize.
    /// - Returns: Normalized text with consistent line breaks.
    private func normalizeLineBreaks(_ text: String) -> String {
        var result = text
        // Convert escaped newlines from JSON to actual newlines
        result = result.replacingOccurrences(of: "\\n", with: "\n")
        // Clean up multiple newlines
        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Sheet showing document details when a reference is tapped.
struct DocumentDetailSheet: View {
    let document: Document
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Title
                    Text(document.title)
                        .font(.headline)

                    // Authors
                    Text(document.formattedAuthors)
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    // Journal and Year
                    if let journal = document.journal {
                        HStack {
                            Text(journal)
                                .italic()
                            if let year = document.year {
                                Text("(\(year))")
                            }
                        }
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    }

                    Divider()

                    // Relevance Score
                    if let score = document.relevanceScore {
                        HStack {
                            Text("Relevance Score:")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            ScoreBadge(score: score)
                        }

                        if let explanation = document.scoreExplanation {
                            Text(explanation)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .italic()
                        }

                        Divider()
                    }

                    // Abstract
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Abstract")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        Text(document.abstract)
                            .font(.body)
                    }

                    // Citations from this document
                    if !document.citations.isEmpty {
                        Divider()

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Key Passages")
                                .font(.subheadline)
                                .fontWeight(.medium)

                            ForEach(document.citations, id: \.id) { citation in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\"\(citation.passage)\"")
                                        .font(.body)
                                        .italic()

                                    if let context = citation.context {
                                        Text(context)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .padding()
                                .background(Color.accentColor.opacity(0.1))
                                .cornerRadius(8)
                            }
                        }
                    }

                    // PubMed Link
                    Divider()

                    Link(destination: URL(string: "https://pubmed.ncbi.nlm.nih.gov/\(document.pmid)/")!) {
                        HStack {
                            Image(systemName: "link")
                            Text("View on PubMed")
                        }
                        .font(.subheadline)
                    }

                    if let doi = document.doi {
                        Link(destination: URL(string: "https://doi.org/\(doi)")!) {
                            HStack {
                                Image(systemName: "doc.text")
                                Text("View via DOI")
                            }
                            .font(.subheadline)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Reference Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// Legacy markdown text renderer for backwards compatibility.
struct MarkdownText: View {
    let content: String

    init(_ content: String) {
        self.content = content
    }

    var body: some View {
        MarkdownReportView(content, documents: [])
    }
}

#Preview {
    let report = EvidenceReport(
        verdict: .partiallySupported,
        summary: "The evidence suggests that vitamin D may have some protective effects, but results are mixed across studies.",
        fullReport: """
        ## Evidence Analysis

        Multiple studies have examined the relationship between vitamin D and COVID-19 outcomes.

        **Supporting Evidence:**
        - A meta-analysis found reduced ICU admission rates [Smith, 2021]
        - Observational studies show correlation with better outcomes [Jones, 2022]

        **Limitations:**
        - Most studies are observational
        - Dosage varies significantly across trials

        ## Conclusion

        While there is suggestive evidence, more randomized controlled trials are needed.
        """,
        citationCount: 5,
        uniqueSourceCount: 3,
        documentsReviewed: 15
    )

    return ReportView(report: report)
}

#Preview("Markdown with clickable refs") {
    MarkdownReportView(
        """
        ## Clinical Evidence

        Evidence suggests that perindopril provides cardiovascular protection [Taddei, 2016](doc:pmid-27354252).

        ### Dose-Dependent Effects

        The effectiveness of ACE inhibitors is dose dependent [Charpiot et al., 1993](doc:pmid-8280156), with recommendations that full-dose therapy leads to improved outcomes.

        ### Experimental Evidence

        1. Both perindopril and aerobic training reduced arterial stiffness [Miotto et al., 2023](doc:pmid-36889392)
        2. Animal models support these findings

        **Key findings:**
        - Improved vascular compliance
        - Reduced target organ damage
        """,
        documents: []
    )
    .padding()
}
