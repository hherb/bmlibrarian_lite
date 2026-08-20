#if os(iOS)
// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2026 Dr Horst Herb
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

import BioMedLit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Report Content View (Tab-friendly)

/// Full-screen report view designed for use in a dedicated tab.
///
/// Unlike `ReportView` (which is for sheets), this view:
/// - Uses full screen width on iPad
/// - Has no "Done" dismiss button
/// - Integrates with tab-based navigation
/// - Supports fetching more evidence via the workflow
struct ReportContentView: View {
    let report: EvidenceReport
    var workflow: FactCheckWorkflow?

    /// Callback when user requests more evidence (navigates to Check tab and triggers fetch).
    var onRequestMoreEvidence: (() -> Void)?

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showingPDFExportSheet = false
    @State private var selectedPaperSize: PaperSize = PDFExporter.preferredPaperSize
    @State private var pdfData: Data?
    @State private var isGeneratingPDF = false

    /// Maximum content width for readability on wide screens.
    private var maxContentWidth: CGFloat {
        horizontalSizeClass == .regular ? 800 : .infinity
    }

    /// Whether more evidence can be fetched for this session.
    private var canGetMoreEvidence: Bool {
        report.session?.canGetMoreEvidence ?? false
    }

    /// Whether the workflow is currently running (fetching more evidence).
    private var isFetchingEvidence: Bool {
        workflow?.isRunning ?? false
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ScrollView {
                    reportContent
                }

                // Progress overlay when fetching more evidence
                if isFetchingEvidence {
                    fetchingProgressOverlay
                }
            }
            .navigationTitle("Evidence Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    shareMenu
                }
            }
            .sheet(isPresented: $showingPDFExportSheet) {
                PDFExportSheet(
                    report: report,
                    selectedPaperSize: $selectedPaperSize,
                    pdfData: $pdfData,
                    isGenerating: $isGeneratingPDF
                )
            }
        }
    }

    /// Overlay shown when fetching more evidence.
    private var fetchingProgressOverlay: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text(workflow?.progressMessage ?? "Fetching more evidence...")
                .font(.headline)
            if let session = report.session {
                Text("\(session.documentsFound) documents, \(session.citationsExtracted) citations")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(32)
        .background(.regularMaterial)
        .cornerRadius(16)
    }

    private var reportContent: some View {
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
            if let session = report.session, !(session.documents ?? []).isEmpty {
                ReviewedDocumentsSection(documents: (session.documents ?? []).sorted {
                    ($0.relevanceScore ?? 0) > ($1.relevanceScore ?? 0)
                })
            }

            // Statistics
            StatisticsSection(report: report)

            // Transparency Summary
            if let session = report.session {
                TransparencySummarySection(documents: session.documents ?? [])
            }

            // Cost (if session available)
            if let session = report.session {
                CostSection(session: session)
            }

            // Get More Evidence button
            if onRequestMoreEvidence != nil && canGetMoreEvidence {
                GetMoreEvidenceSection(
                    session: report.session,
                    isFetching: isFetchingEvidence,
                    onFetchMore: {
                        onRequestMoreEvidence?()
                    }
                )
            }

            // Generation footnote and disclaimer
            FootnoteSection(report: report)
        }
        .frame(maxWidth: maxContentWidth)
        .padding()
        .frame(maxWidth: .infinity)
    }

    private var shareMenu: some View {
        Menu {
            // Copy to clipboard
            Button {
                UIPasteboard.general.string = report.plainTextReport
            } label: {
                Label("Copy to Clipboard", systemImage: "doc.on.doc")
            }

            // Plain text share
            ShareLink(
                item: report.plainTextReport,
                subject: Text("Medical Fact Check Report"),
                message: Text("Evidence report for: \(report.session?.claim ?? "Unknown claim")")
            ) {
                Label("Share as Text", systemImage: "doc.text")
            }

            // PDF export
            Button {
                showingPDFExportSheet = true
            } label: {
                Label("Export as PDF", systemImage: "doc.richtext")
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
    }
}

// MARK: - Report View (Sheet)

/// Report view designed for sheet presentation.
///
/// Includes a "Done" button for dismissing the sheet.
/// For tab-based display, use `ReportContentView` instead.
/// Supports fetching more evidence via the optional workflow parameter.
struct ReportView: View {
    let report: EvidenceReport
    var workflow: FactCheckWorkflow?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showingPDFExportSheet = false
    @State private var selectedPaperSize: PaperSize = PDFExporter.preferredPaperSize
    @State private var pdfData: Data?
    @State private var isGeneratingPDF = false

    /// Maximum content width for readability on wide screens.
    private var maxContentWidth: CGFloat {
        horizontalSizeClass == .regular ? 800 : .infinity
    }

    /// Whether more evidence can be fetched for this session.
    private var canGetMoreEvidence: Bool {
        report.session?.canGetMoreEvidence ?? false
    }

    /// Whether the workflow is currently running (fetching more evidence).
    private var isFetchingEvidence: Bool {
        workflow?.isRunning ?? false
    }

    var body: some View {
        NavigationStack {
            ZStack {
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
                    if let session = report.session, !(session.documents ?? []).isEmpty {
                        ReviewedDocumentsSection(documents: (session.documents ?? []).sorted {
                            ($0.relevanceScore ?? 0) > ($1.relevanceScore ?? 0)
                        })
                    }

                    // Statistics
                    StatisticsSection(report: report)

                    // Transparency Summary
                    if let session = report.session {
                        TransparencySummarySection(documents: session.documents ?? [])
                    }

                    // Cost (if session available)
                    if let session = report.session {
                        CostSection(session: session)
                    }

                    // Get More Evidence button
                    if workflow != nil && canGetMoreEvidence {
                        GetMoreEvidenceSection(
                            session: report.session,
                            isFetching: isFetchingEvidence,
                            onFetchMore: {
                                Task {
                                    await workflow?.fetchMoreEvidence()
                                }
                            }
                        )
                    }

                    // Generation footnote and disclaimer
                    FootnoteSection(report: report)
                }
                .frame(maxWidth: maxContentWidth)
                .padding()
                .frame(maxWidth: .infinity)
                }

                // Progress overlay when fetching more evidence
                if isFetchingEvidence {
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text(workflow?.progressMessage ?? "Fetching more evidence...")
                            .font(.headline)
                        if let session = report.session {
                            Text("\(session.documentsFound) documents, \(session.citationsExtracted) citations")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(32)
                    .background(.regularMaterial)
                    .cornerRadius(16)
                }
            }
            .navigationTitle("Evidence Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        // Copy to clipboard
                        Button {
                            UIPasteboard.general.string = report.plainTextReport
                        } label: {
                            Label("Copy to Clipboard", systemImage: "doc.on.doc")
                        }

                        // Plain text share
                        ShareLink(
                            item: report.plainTextReport,
                            subject: Text("Medical Fact Check Report"),
                            message: Text("Evidence report for: \(report.session?.claim ?? "Unknown claim")")
                        ) {
                            Label("Share as Text", systemImage: "doc.text")
                        }

                        // PDF export
                        Button {
                            showingPDFExportSheet = true
                        } label: {
                            Label("Export as PDF", systemImage: "doc.richtext")
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            .sheet(isPresented: $showingPDFExportSheet) {
                PDFExportSheet(
                    report: report,
                    selectedPaperSize: $selectedPaperSize,
                    pdfData: $pdfData,
                    isGenerating: $isGeneratingPDF
                )
            }
        }
    }
}

// MARK: - PDF Export Sheet

/// Sheet for selecting paper size and exporting PDF.
struct PDFExportSheet: View {
    let report: EvidenceReport
    @Binding var selectedPaperSize: PaperSize
    @Binding var pdfData: Data?
    @Binding var isGenerating: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var pdfURL: URL?
    @State private var showingShareSheet = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // Paper Size Selection
                VStack(alignment: .leading, spacing: 8) {
                    Text("Paper Size")
                        .font(.headline)

                    Picker("Paper Size", selection: $selectedPaperSize) {
                        ForEach(PaperSize.allCases) { size in
                            Text(size.rawValue).tag(size)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .padding()

                // Preview info
                VStack(spacing: 8) {
                    Image(systemName: "doc.richtext")
                        .font(.system(size: 60))
                        .foregroundColor(.accentColor)

                    Text("Medical Fact Check Report")
                        .font(.headline)

                    Text("Generated \(report.generatedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if let claim = report.session?.claim {
                        Text(claim)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .padding(.horizontal)
                    }
                }
                .padding()

                Spacer()

                // Error message
                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding()
                }

                // Generate and Share Button
                Button {
                    generateAndSharePDF()
                } label: {
                    HStack {
                        if isGenerating {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        } else {
                            Image(systemName: "square.and.arrow.up")
                        }
                        Text(isGenerating ? "Generating..." : "Generate & Share PDF")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(isGenerating ? Color.gray : Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
                .disabled(isGenerating)
                .padding(.horizontal)
                .padding(.bottom)
            }
            .navigationTitle("Export PDF")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $showingShareSheet) {
                if let url = pdfURL {
                    ShareSheet(items: [url])
                }
            }
        }
    }

    private func generateAndSharePDF() {
        isGenerating = true
        errorMessage = nil

        // Save paper size preference
        PDFExporter.preferredPaperSize = selectedPaperSize

        Task {
            // Generate PDF with pagination
            if let data = PDFExporter.generatePDFWithPagination(for: report, paperSize: selectedPaperSize) {
                pdfData = data

                // Save to temporary file
                if let url = PDFExporter.savePDFToTemporaryFile(data, for: report) {
                    pdfURL = url
                    isGenerating = false
                    showingShareSheet = true
                } else {
                    errorMessage = "Failed to save PDF file"
                    isGenerating = false
                }
            } else {
                errorMessage = "Failed to generate PDF"
                isGenerating = false
            }
        }
    }
}

// MARK: - Share Sheet (UIKit wrapper)

/// UIKit share sheet wrapper for SwiftUI.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
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
                ReportStatItem(
                    icon: "doc.text",
                    value: "\(report.documentsReviewed)",
                    label: "Reviewed"
                )
                ReportStatItem(
                    icon: "checkmark.circle",
                    value: "\(report.uniqueSourceCount)",
                    label: "Relevant"
                )
                ReportStatItem(
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

private struct ReportStatItem: View {
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
                    Text(document.displayTitle)
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

                VStack(alignment: .trailing, spacing: 4) {
                    if let score = document.relevanceScore {
                        ScoreBadge(score: score)
                    }
                    if let riskLevel = document.transparencyRiskLevel {
                        TransparencyRiskBadge(riskLevel: riskLevel)
                    }
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
            if !(document.citations ?? []).isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Key Passages:")
                        .font(.caption)
                        .fontWeight(.medium)

                    ForEach(document.citations ?? [], id: \.id) { citation in
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
    @Bindable var document: Document
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    // Full text state
    @State private var isLoadingFullText = false
    @State private var fullTextError: String?
    @State private var showFullTextViewer = false
    @State private var fullTextResult: AppFullTextResult?

    // Transparency analysis state
    @State private var isLoadingTransparency = false
    @State private var transparencyError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Title
                    Text(document.displayTitle)
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
                                Text(verbatim: "(\(year))")
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

                    // Abstract with markdown rendering
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Abstract")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        DocumentDetailAbstractView(text: document.abstract)
                    }

                    // Citations from this document
                    if !(document.citations ?? []).isEmpty {
                        Divider()

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Key Passages")
                                .font(.subheadline)
                                .fontWeight(.medium)

                            ForEach(document.citations ?? [], id: \.id) { citation in
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

                    // Full Text Section
                    Divider()
                    fullTextSection

                    // Transparency Analysis Section
                    Divider()
                    transparencyAnalysisSection

                    // External Links
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
            .sheet(isPresented: $showFullTextViewer) {
                fullTextViewerSheet
            }
        }
    }

    // MARK: - Full Text Section

    /// Section displaying full text status and action button.
    @ViewBuilder
    private var fullTextSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Full Text")
                .font(.subheadline)
                .fontWeight(.medium)

            if document.hasFullText {
                // Already have full text - show view button
                HStack {
                    Button(action: { showFullTextViewer = true }) {
                        Label("View Full Text", systemImage: "doc.text.fill")
                    }
                    .buttonStyle(.borderedProminent)

                    if let source = document.fullTextSource,
                       let fullTextSource = AppFullTextSource(rawValue: source) {
                        FullTextSourceBadge(source: fullTextSource)
                    }
                }
            } else if document.fullTextUnavailable {
                // Already tried, not available
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                    Text("Full text not available from open access sources")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Still offer to open in browser
                if let doi = document.doi,
                   let url = PlatformHelper.doiURL(for: doi) {
                    Link(destination: url) {
                        Label("Open Publisher", systemImage: "safari")
                            .font(.caption)
                    }
                }
            } else {
                // Not yet attempted - show fetch button
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
                            .lineLimit(2)
                    }
                }
            }
        }
    }

    // MARK: - Full Text Viewer Sheet

    /// Sheet content for displaying full text.
    @ViewBuilder
    private var fullTextViewerSheet: some View {
        if let result = fullTextResult {
            FullTextViewer(document: document, result: result)
        } else if let content = document.fullTextContent {
            FullTextViewer(
                document: document,
                result: AppFullTextResult(
                    content: .markdown(content),
                    source: AppFullTextSource(rawValue: document.fullTextSource ?? "cached") ?? .cached
                )
            )
        } else if let pdfPath = document.fullTextPDFPath,
                  let url = URL(string: pdfPath) {
            FullTextViewer(
                document: document,
                result: AppFullTextResult(
                    content: .pdfURL(url),
                    source: AppFullTextSource(rawValue: document.fullTextSource ?? "cached") ?? .cached
                )
            )
        }
    }

    // MARK: - Full Text Fetching

    /// Fetch full text for the document.
    private func fetchFullText() {
        isLoadingFullText = true
        fullTextError = nil

        Task {
            do {
                let service = BMLFullTextService.create(from: .shared)
                let bmlResult = try await service.fetchFullText(
                    pmcId: document.pmcId,
                    doi: document.doi,
                    pmid: document.pmid
                )
                let result = BioMedLitAdapters.toAppFullTextResult(bmlResult)

                await MainActor.run {
                    // Update document model
                    switch result.content {
                    case .html(let htmlContent, let markdownContent):
                        document.fullTextHTML = htmlContent
                        document.fullTextContent = markdownContent
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

    // MARK: - Transparency Analysis Section

    /// Section displaying transparency analysis results or an analyze button.
    @ViewBuilder
    private var transparencyAnalysisSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Transparency Analysis")
                .font(.subheadline)
                .fontWeight(.medium)

            if let result = document.transparencyResult {
                TransparencyDetailView(result: result)

                // A stale result keeps its score on screen but has to be
                // re-runnable, or the notice above names a fix the user cannot apply.
                if document.transparencyAnalysisIsStale, document.canAnalyzeTransparency {
                    transparencyAnalyzeButton(title: "Re-analyze")
                }
            } else if !document.canAnalyzeTransparency {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundColor(.secondary)
                    Text("Requires DOI or PMID for analysis")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                transparencyAnalyzeButton(title: "Analyze Transparency")
            }
        }
    }

    /// Button that runs transparency analysis, with any error beside it.
    ///
    /// - Parameter title: Button label — "Analyze Transparency" for a first run,
    ///   "Re-analyze" when replacing a result from an earlier analyzer.
    @ViewBuilder
    private func transparencyAnalyzeButton(title: String) -> some View {
        HStack(spacing: 12) {
            Button(action: analyzeTransparency) {
                if isLoadingTransparency {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Label(title, systemImage: "shield.checkered")
                }
            }
            .buttonStyle(.bordered)
            .disabled(isLoadingTransparency)

            if let error = transparencyError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(2)
            }
        }
    }

    /// Run transparency analysis for this document.
    private func analyzeTransparency() {
        isLoadingTransparency = true
        transparencyError = nil

        Task {
            do {
                let service = TransparencyAnalysisService.create(from: .shared)
                let result = try await service.analyze(
                    doi: document.doi,
                    pmid: document.pmid.isEmpty ? nil : document.pmid,
                    fullText: document.fullTextContent
                )
                await MainActor.run {
                    // A failed write leaves the previous result in place; saying so
                    // is the difference between "this did not work" and a spinner
                    // that stops with the stale notice still on screen.
                    if !document.storeTransparencyResult(result) {
                        transparencyError = "Analysis completed but could not be saved."
                    }
                    isLoadingTransparency = false
                }
            } catch {
                await MainActor.run {
                    transparencyError = error.localizedDescription
                    isLoadingTransparency = false
                }
            }
        }
    }
}

// MARK: - Abstract View for Document Details

/// View that renders abstract text with markdown formatting support for the document detail sheet.
///
/// Handles common markdown patterns found in PubMed abstracts like
/// bold section headers (e.g., **OBJECTIVE:**) and emphasis.
private struct DocumentDetailAbstractView: View {
    /// The abstract text to render.
    let text: String

    var body: some View {
        if let attributed = parseAbstractMarkdown(text) {
            Text(attributed)
                .font(.body)
        } else {
            Text(text)
                .font(.body)
        }
    }

    /// Parses markdown in abstract text and returns an AttributedString.
    ///
    /// - Parameter text: The abstract text to parse.
    /// - Returns: An AttributedString with formatting, or nil if parsing fails.
    private func parseAbstractMarkdown(_ text: String) -> AttributedString? {
        try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
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

// MARK: - Get More Evidence Section

/// Section with button to fetch additional evidence for the report.
///
/// Shows:
/// - Remaining PubMed results count (if available)
/// - Whether smart search is available
/// - Button to trigger fetching more evidence
struct GetMoreEvidenceSection: View {
    let session: FactCheckSession?
    let isFetching: Bool
    let onFetchMore: () -> Void

    /// Description of what evidence sources are available.
    private var availableSourcesText: String {
        guard let session = session else { return "" }

        if session.canFetchMoreDocuments {
            let remaining = session.remainingPubMedResults
            if !session.smartSearchEnabled {
                return "\(remaining) more results available, plus smart search"
            } else {
                return "\(remaining) more results available"
            }
        } else if !session.smartSearchEnabled {
            return "Smart search available (alternative queries)"
        } else {
            return "All sources exhausted"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "plus.magnifyingglass")
                    .foregroundColor(.accentColor)
                Text("Need More Evidence?")
                    .font(.headline)
            }

            Text(availableSourcesText)
                .font(.caption)
                .foregroundColor(.secondary)

            Button(action: onFetchMore) {
                HStack {
                    if isFetching {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    Text(isFetching ? "Fetching..." : "Get More Evidence")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(isFetching ? Color.gray : Color.accentColor)
                .foregroundColor(.white)
                .cornerRadius(10)
            }
            .disabled(isFetching)
        }
        .padding()
        .background(Color.accentColor.opacity(0.1))
        .cornerRadius(10)
    }
}

// MARK: - Footnote Section

/// Displays generation information and disclaimer at the bottom of reports.
struct FootnoteSection: View {
    let report: EvidenceReport

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()

            // Generation footnote
            Text(report.generationFootnote)
                .font(.caption)
                .foregroundColor(.secondary)

            // Disclaimer
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("Important Disclaimer")
                        .fontWeight(.semibold)
                }
                .font(.caption)

                Text("This report is generated by AI and is intended for informational purposes only. It should not be used for self-diagnosis or treatment. Always consult qualified healthcare professionals for medical advice and discuss any findings from this report with your doctor.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color.orange.opacity(0.1))
            .cornerRadius(8)
        }
        .padding(.top, 8)
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

#endif // os(iOS)
