#if os(macOS)
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

import SwiftUI
import AppKit
import PDFKit
import BioMedLit

/// macOS report view with optimized layout for larger screens.
///
/// Features:
/// - Wide, readable content area with maximum width constraint
/// - Toolbar with export options (PDF, text, print)
/// - Keyboard shortcuts for common actions
/// - Supports fetching more evidence via the optional workflow parameter
struct MacReportView: View {
    let report: EvidenceReport?
    var workflow: FactCheckWorkflow?

    /// Callback when user requests more evidence (triggers navigation to Fact Check tab).
    var onRequestMoreEvidence: (() -> Void)?

    @State private var selectedDocument: Document?
    @State private var exportFormat: ExportFormat = .pdf

    /// Whether more evidence can be fetched for this session.
    private var canGetMoreEvidence: Bool {
        report?.session?.canGetMoreEvidence ?? false
    }

    /// Whether the workflow is currently running (fetching more evidence).
    private var isFetchingEvidence: Bool {
        workflow?.isRunning ?? false
    }

    var body: some View {
        if let report = report {
            reportContent(report)
        } else {
            emptyState
        }
    }

    private func reportContent(_ report: EvidenceReport) -> some View {
        VStack(spacing: 0) {
            // Toolbar
            reportToolbar(report)
                .padding(.horizontal, MacSpacing.xLarge)
                .padding(.vertical, MacSpacing.standard)
                .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Report content
            ScrollView {
                VStack(alignment: .leading, spacing: MacSpacing.sectionSpacing) {
                    // Verdict badge
                    HStack {
                        Spacer()
                        MacVerdictBadge(verdict: report.verdict)
                        Spacer()
                    }

                    // Claim and query
                    if let session = report.session {
                        claimSection(session)
                    }

                    // Summary
                    summarySection(report)

                    // Full report
                    detailedReportSection(report)

                    // Reviewed documents
                    if let session = report.session, !(session.documents ?? []).isEmpty {
                        reviewedDocumentsSection(session.documents ?? [])
                    }

                    // Statistics
                    statisticsSection(report)

                    // Transparency Summary
                    if let session = report.session {
                        let docs = session.documents ?? []
                        if docs.contains(where: { $0.hasTransparencyAnalysis }) {
                            MacTransparencySummarySection(documents: docs)
                        }
                    }

                    // Cost
                    if let session = report.session {
                        costSection(session)
                    }

                    // Get More Evidence
                    if workflow != nil && canGetMoreEvidence {
                        getMoreEvidenceSection(report.session)
                    }

                    // Footer
                    footerSection(report)
                }
                .frame(maxWidth: MacLayout.maxContentWidth)
                .padding(MacSpacing.section)
                .frame(maxWidth: .infinity)
            }
        }
        .sheet(item: $selectedDocument) { doc in
            MacDocumentDetailSheet(document: doc)
        }
        .onReceive(NotificationCenter.default.publisher(for: .documentReferenceClicked)) { notification in
            if let url = notification.userInfo?["url"] as? URL {
                handleReferenceTap(url, documents: report.session?.documents ?? [])
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: MacSpacing.xLarge) {
            Image(systemName: "doc.text")
                .font(.system(size: MacIconSize.emptyStateLarge))
                .foregroundColor(.secondary.opacity(MacOpacity.faded))

            Text("No Report Yet")
                .font(.title)
                .fontWeight(.semibold)

            Text("Run a fact-check to generate an evidence report")
                .font(.title3)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Toolbar

    private func reportToolbar(_ report: EvidenceReport) -> some View {
        HStack(spacing: MacSpacing.large) {
            Text("Evidence Report")
                .font(.title2)
                .fontWeight(.bold)

            Spacer()

            // Export menu
            Menu {
                Button {
                    exportFormat = .pdf
                    exportReport(report)
                } label: {
                    Label("Export as PDF", systemImage: "doc.richtext")
                }

                Button {
                    exportFormat = .text
                    exportReport(report)
                } label: {
                    Label("Export as Text", systemImage: "doc.text")
                }

                Divider()

                Button {
                    printReport(report)
                } label: {
                    Label("Print...", systemImage: "printer")
                }
            } label: {
                HStack(spacing: MacSpacing.xSmall) {
                    Image(systemName: "square.and.arrow.up")
                    Text("Export")
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            // Copy to clipboard
            Button {
                copyToClipboard(report.plainTextReport)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .help("Copy to Clipboard")
        }
    }

    // MARK: - Sections

    private func claimSection(_ session: FactCheckSession) -> some View {
        VStack(alignment: .leading, spacing: MacSpacing.large) {
            VStack(alignment: .leading, spacing: MacSpacing.small) {
                Text("Claim")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                Text(session.claim)
                    .font(.title3)
                    .italic()
            }

            if let query = session.pubmedQuery {
                VStack(alignment: .leading, spacing: MacSpacing.small) {
                    Text("PubMed Query")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)
                    Text(query)
                        .font(.body)
                        .fontDesign(.monospaced)
                        .foregroundColor(.accentColor)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(MacSpacing.xLarge)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(MacCornerRadius.xLarge)
    }

    private func summarySection(_ report: EvidenceReport) -> some View {
        VStack(alignment: .leading, spacing: MacSpacing.medium) {
            Text("Summary")
                .font(.title3)
                .fontWeight(.semibold)

            Text(report.summary)
                .font(.body)
                .lineSpacing(MacSpacing.xSmall)
        }
        .padding(MacSpacing.xLarge)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(MacOpacity.light))
        .cornerRadius(MacCornerRadius.xLarge)
    }

    private func detailedReportSection(_ report: EvidenceReport) -> some View {
        VStack(alignment: .leading, spacing: MacSpacing.standard) {
            Text("Detailed Analysis")
                .font(.title3)
                .fontWeight(.semibold)

            MacMarkdownReportView(
                report.fullReport,
                documents: report.session?.documents ?? []
            )
        }
    }

    private func reviewedDocumentsSection(_ documents: [Document]) -> some View {
        MacReviewedDocumentsSection(
            documents: documents.sorted { ($0.relevanceScore ?? 0) > ($1.relevanceScore ?? 0) },
            onDocumentSelected: { doc in
                selectedDocument = doc
            }
        )
    }

    private func statisticsSection(_ report: EvidenceReport) -> some View {
        VStack(alignment: .leading, spacing: MacSpacing.standard) {
            Text("Statistics")
                .font(.title3)
                .fontWeight(.semibold)

            HStack(spacing: MacSpacing.statItemSpacing) {
                MacStatItem(icon: "doc.text", value: "\(report.documentsReviewed)", label: "Documents Reviewed")
                MacStatItem(icon: "checkmark.circle", value: "\(report.uniqueSourceCount)", label: "Relevant Sources")
                MacStatItem(icon: "quote.bubble", value: "\(report.citationCount)", label: "Citations Extracted")
            }
        }
        .padding(MacSpacing.xLarge)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(MacCornerRadius.xLarge)
    }

    private func costSection(_ session: FactCheckSession) -> some View {
        HStack(spacing: MacSpacing.statItemSpacing) {
            VStack(alignment: .leading, spacing: MacSpacing.xSmall) {
                Text("API Cost")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(CostCalculator.formatCost(session.estimatedCostUSD))
                    .font(.title3)
                    .fontWeight(.medium)
            }

            VStack(alignment: .leading, spacing: MacSpacing.xSmall) {
                Text("Tokens Used")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("\(session.totalInputTokens + session.totalOutputTokens)")
                    .font(.title3)
                    .fontWeight(.medium)
            }

            Spacer()
        }
        .padding(MacSpacing.xLarge)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(MacCornerRadius.xLarge)
    }

    private func getMoreEvidenceSection(_ session: FactCheckSession?) -> some View {
        VStack(alignment: .leading, spacing: MacSpacing.standard) {
            HStack {
                Image(systemName: "plus.magnifyingglass")
                    .font(.title3)
                    .foregroundColor(.accentColor)
                Text("Need More Evidence?")
                    .font(.title3)
                    .fontWeight(.semibold)
            }

            Text(availableSourcesText(for: session))
                .font(.body)
                .foregroundColor(.secondary)

            Button(action: {
                // Navigate to Fact Check tab, which will trigger fetchMoreEvidence
                onRequestMoreEvidence?()
            }) {
                HStack {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("Get More Evidence")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isFetchingEvidence)
        }
        .padding(MacSpacing.xLarge)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(MacOpacity.light))
        .cornerRadius(MacCornerRadius.xLarge)
    }

    /// Description of what evidence sources are available.
    private func availableSourcesText(for session: FactCheckSession?) -> String {
        guard let session = session else { return "" }

        if session.canFetchMoreDocuments {
            let remaining = session.remainingPubMedResults
            if !session.smartSearchEnabled {
                return "\(remaining) more results available from PubMed, plus smart search with alternative queries"
            } else {
                return "\(remaining) more results available from PubMed"
            }
        } else if !session.smartSearchEnabled {
            return "Smart search available - will try alternative query strategies"
        } else {
            return "All evidence sources have been exhausted"
        }
    }

    private func footerSection(_ report: EvidenceReport) -> some View {
        VStack(alignment: .leading, spacing: MacSpacing.large) {
            Divider()

            Text(report.generationFootnote)
                .font(.caption)
                .foregroundColor(.secondary)

            // Disclaimer
            HStack(alignment: .top, spacing: MacSpacing.standard) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundColor(.orange)

                VStack(alignment: .leading, spacing: MacSpacing.xSmall) {
                    Text("Important Disclaimer")
                        .font(.headline)

                    Text("This report is generated by AI and is intended for informational purposes only. It should not be used for self-diagnosis or treatment. Always consult qualified healthcare professionals for medical advice.")
                        .font(.body)
                        .foregroundColor(.secondary)
                }
            }
            .padding(MacSpacing.large)
            .background(Color.orange.opacity(MacOpacity.subtle))
            .cornerRadius(MacCornerRadius.standard)
        }
    }

    // MARK: - Actions

    private func exportReport(_ report: EvidenceReport) {
        let panel = NSSavePanel()
        panel.title = "Export Report"
        panel.nameFieldStringValue = "Medical_Fact_Check_Report"
        panel.allowedContentTypes = exportFormat == .pdf ? [.pdf] : [.plainText]

        panel.begin { response in
            if response == .OK, let url = panel.url {
                do {
                    switch exportFormat {
                    case .pdf:
                        if let pdfData = PDFExporter.generatePDFWithPagination(for: report, paperSize: .a4) {
                            try pdfData.write(to: url)
                        }
                    case .text:
                        try report.plainTextReport.write(to: url, atomically: true, encoding: .utf8)
                    }
                } catch {
                    print("Export failed: \(error)")
                }
            }
        }
    }

    private func printReport(_ report: EvidenceReport) {
        // Generate PDF and print
        if let pdfData = PDFExporter.generatePDFWithPagination(for: report, paperSize: .a4) {
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("report.pdf")
            try? pdfData.write(to: tempURL)

            if let pdfDocument = PDFKit.PDFDocument(url: tempURL) {
                let printInfo = NSPrintInfo.shared
                let printOperation = pdfDocument.printOperation(for: printInfo, scalingMode: .pageScaleToFit, autoRotate: true)
                printOperation?.run()
            }
        }
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func handleReferenceTap(_ url: URL, documents: [Document]) {
        guard url.scheme == "docref",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            return
        }

        let type = queryItems.first { $0.name == "type" }?.value
        let value = queryItems.first { $0.name == "value" }?.value

        guard let lookupType = type, let lookupValue = value else { return }

        if lookupType == "id" {
            selectedDocument = documents.first { $0.id == lookupValue }
        } else if lookupType == "ref" {
            let refText = lookupValue.removingPercentEncoding ?? lookupValue
            selectedDocument = findDocumentByReference(refText, in: documents)
        }
    }

    private func findDocumentByReference(_ reference: String, in documents: [Document]) -> Document? {
        let parts = reference.components(separatedBy: ",")
        guard parts.count >= 2 else { return nil }

        let authorPart = parts[0].trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " et al.", with: "")
            .lowercased()
        let yearPart = parts.last?.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: .letters)

        guard let yearString = yearPart, let year = Int(yearString) else { return nil }

        return documents.first { doc in
            guard doc.year == year else { return false }
            for author in doc.authors {
                let lastName = author.components(separatedBy: " ").first?.lowercased() ?? ""
                if lastName == authorPart || author.lowercased().contains(authorPart) {
                    return true
                }
            }
            return false
        }
    }
}

enum ExportFormat {
    case pdf
    case text
}

// MARK: - Supporting Views

/// Large verdict badge for report headers.
///
/// Displays the verdict with appropriate color coding in a pill shape.
struct MacVerdictBadge: View {
    /// The verdict to display.
    let verdict: Verdict

    var body: some View {
        Text(verdict.rawValue)
            .font(.title2)
            .fontWeight(.bold)
            .padding(.horizontal, MacSpacing.xxLarge)
            .padding(.vertical, MacSpacing.standard)
            .background(MacColors.verdictColor(for: verdict))
            .foregroundColor(.white)
            .cornerRadius(MacCornerRadius.pill)
    }
}

/// Displays a statistic with icon, value, and label.
struct MacStatItem: View {
    /// SF Symbol name for the icon.
    let icon: String
    /// The statistic value to display.
    let value: String
    /// Description label for the statistic.
    let label: String

    var body: some View {
        HStack(spacing: MacSpacing.standard) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.accentColor)
                .frame(width: MacIconSize.iconFrame)

            VStack(alignment: .leading, spacing: MacSpacing.xxSmall) {
                Text(value)
                    .font(.title2)
                    .fontWeight(.bold)
                Text(label)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

/// Expandable section displaying reviewed documents in the report.
///
/// Shows a collapsible list of documents with scores, allowing users to click
/// to view full document details.
struct MacReviewedDocumentsSection: View {
    /// The documents to display.
    let documents: [Document]
    /// Callback when a document is selected.
    let onDocumentSelected: (Document) -> Void

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: MacSpacing.standard) {
            Button(action: { withAnimation { isExpanded.toggle() } }) {
                HStack {
                    Text("Reviewed Documents (\(documents.count))")
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                LazyVStack(spacing: MacSpacing.listItemSpacing) {
                    ForEach(documents, id: \.pmid) { document in
                        MacReviewedDocumentRow(document: document)
                            .onTapGesture {
                                onDocumentSelected(document)
                            }
                    }
                }
            }
        }
        .padding(MacSpacing.xLarge)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(MacCornerRadius.xLarge)
    }
}

/// A single row displaying a reviewed document's summary.
///
/// Shows the document's score badge, title, and authors in a compact format.
struct MacReviewedDocumentRow: View {
    /// The document to display.
    let document: Document

    var body: some View {
        HStack(alignment: .top, spacing: MacSpacing.standard) {
            // Show score badge and transparency risk badge
            VStack(spacing: MacSpacing.xSmall) {
                MacScoreBadge(score: document.relevanceScore)
                    .frame(width: MacIconSize.scoreBadgeSmall, height: MacIconSize.scoreBadgeSmall)
                if let riskLevel = document.transparencyRiskLevel {
                    MacTransparencyRiskBadge(riskLevel: riskLevel)
                }
            }

            VStack(alignment: .leading, spacing: MacSpacing.xSmall) {
                Text(document.title)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(2)

                Text(document.formattedAuthors)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .foregroundColor(.secondary)
        }
        .padding(MacSpacing.standard)
        .background(Color(NSColor.textBackgroundColor))
        .cornerRadius(MacCornerRadius.standard)
        .contentShape(Rectangle())
    }
}

/// Markdown renderer for macOS reports.
///
/// Parses markdown content and renders it as styled SwiftUI views,
/// including support for clickable document references.
struct MacMarkdownReportView: View {
    /// The markdown content to render.
    let content: String
    /// Documents for reference linking.
    let documents: [Document]

    init(_ content: String, documents: [Document] = []) {
        self.content = content
        self.documents = documents
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MacSpacing.medium) {
            let blocks = parseMarkdownBlocks(content)
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                renderBlock(block)
            }
        }
    }

    // MARK: - Block Parsing

    private enum MarkdownBlock {
        case heading(level: Int, text: String)
        case paragraph(text: String)
        case listItem(text: String, ordered: Bool, number: Int?)
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
                if !currentParagraph.isEmpty {
                    blocks.append(.paragraph(text: currentParagraph.joined(separator: " ")))
                    currentParagraph = []
                }
                listNumber = 0
                continue
            }

            if let headingMatch = parseHeading(trimmed) {
                if !currentParagraph.isEmpty {
                    blocks.append(.paragraph(text: currentParagraph.joined(separator: " ")))
                    currentParagraph = []
                }
                blocks.append(headingMatch)
                listNumber = 0
                continue
            }

            if let listMatch = parseListItem(trimmed, currentNumber: &listNumber) {
                if !currentParagraph.isEmpty {
                    blocks.append(.paragraph(text: currentParagraph.joined(separator: " ")))
                    currentParagraph = []
                }
                blocks.append(listMatch)
                continue
            }

            currentParagraph.append(trimmed)
        }

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
        if line.hasPrefix("- ") {
            currentNumber = 0
            return .listItem(text: String(line.dropFirst(2)), ordered: false, number: nil)
        }
        if line.hasPrefix("* ") {
            currentNumber = 0
            return .listItem(text: String(line.dropFirst(2)), ordered: false, number: nil)
        }

        let pattern = "^\\d+\\.\\s+(.+)$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let textRange = Range(match.range(at: 1), in: line) else {
            return nil
        }
        currentNumber += 1
        return .listItem(text: String(line[textRange]), ordered: true, number: currentNumber)
    }

    @ViewBuilder
    private func renderBlock(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            renderHeading(level: level, text: text)
        case .paragraph(let text):
            renderParagraph(text)
        case .listItem(let text, let ordered, let number):
            renderListItem(text: text, ordered: ordered, number: number)
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
            .padding(.top, level == 1 ? MacSpacing.large : MacSpacing.standard)
            .padding(.bottom, MacSpacing.small)
    }

    @ViewBuilder
    private func renderParagraph(_ text: String) -> some View {
        renderRichText(text)
            .padding(.vertical, MacSpacing.xSmall)
    }

    @ViewBuilder
    private func renderListItem(text: String, ordered: Bool, number: Int?) -> some View {
        HStack(alignment: .top, spacing: MacSpacing.medium) {
            if ordered, let num = number {
                Text("\(num).")
                    .font(.body)
                    .fontWeight(.semibold)
                    .frame(width: MacIconSize.listNumberWidth, alignment: .trailing)
            } else {
                Text("•")
                    .font(.body)
                    .fontWeight(.bold)
                    .frame(width: MacIconSize.listNumberWidth, alignment: .trailing)
            }
            renderRichText(text)
        }
        .padding(.vertical, MacSpacing.xxSmall)
        .padding(.leading, MacSpacing.medium)
    }

    @ViewBuilder
    private func renderRichText(_ text: String) -> some View {
        let attributed = parseInlineFormatting(text)
        Text(attributed)
            .font(.body)
            .textSelection(.enabled)
    }

    private func parseInlineFormatting(_ text: String) -> AttributedString {
        var result = AttributedString()

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

            if fullRange.lowerBound > currentIndex {
                let beforeText = String(text[currentIndex..<fullRange.lowerBound])
                result.append(parseBasicFormatting(beforeText))
            }

            let displayText = String(text[displayRange])
            let documentId: String?
            if match.range(at: 2).location != NSNotFound,
               let idRange = Range(match.range(at: 2), in: text) {
                documentId = String(text[idRange])
            } else {
                documentId = nil
            }

            var refAttr = AttributedString("[\(displayText)]")
            refAttr.foregroundColor = Color.accentColor
            refAttr.underlineStyle = Text.LineStyle.single

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

        if currentIndex < text.endIndex {
            let remainingText = String(text[currentIndex...])
            result.append(parseBasicFormatting(remainingText))
        }

        return result
    }

    private func parseBasicFormatting(_ text: String) -> AttributedString {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return attributed
        }
        return AttributedString(text)
    }

    private func normalizeLineBreaks(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: "\\n", with: "\n")
        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Document detail sheet for macOS.
///
/// Shows full document details including title, authors, abstract, score,
/// citations, full text options, and links to external resources.
struct MacDocumentDetailSheet: View {
    /// The document to display.
    @Bindable var document: Document
    @Environment(\.dismiss) private var dismiss

    // Full text state
    @State private var isLoadingFullText = false
    @State private var fullTextError: String?

    // Transparency state
    @State private var isLoadingTransparency = false
    @State private var transparencyError: String?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Reference Details")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(MacSpacing.xLarge)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: MacSpacing.xLarge) {
                    // Title
                    Text(document.title)
                        .font(.title3)
                        .fontWeight(.bold)
                        .textSelection(.enabled)

                    // Authors
                    Text(document.formattedAuthors)
                        .font(.body)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)

                    // Journal and year
                    if let journal = document.journal {
                        HStack {
                            Text(journal)
                                .italic()
                            if let year = document.year {
                                Text(verbatim: "(\(year))")
                            }
                        }
                        .font(.body)
                        .foregroundColor(.secondary)
                    }

                    Divider()

                    // Score (shows "?" for failed scores)
                    HStack(spacing: MacSpacing.standard) {
                        Text("Relevance Score:")
                            .fontWeight(.medium)
                        MacScoreBadge(score: document.relevanceScore)
                    }

                    if let explanation = document.scoreExplanation {
                        Text(explanation)
                            .font(.body)
                            .italic()
                            .foregroundColor(.secondary)
                    }

                    Divider()

                    // Abstract with markdown rendering
                    VStack(alignment: .leading, spacing: MacSpacing.medium) {
                        Text("Abstract")
                            .font(.headline)
                        MacDocumentDetailAbstractView(text: document.abstract)
                            .textSelection(.enabled)
                    }

                    // Citations
                    if !(document.citations ?? []).isEmpty {
                        Divider()

                        VStack(alignment: .leading, spacing: MacSpacing.standard) {
                            Text("Key Passages")
                                .font(.headline)

                            ForEach(document.citations ?? [], id: \.id) { citation in
                                VStack(alignment: .leading, spacing: MacSpacing.xSmall) {
                                    Text("\"\(citation.passage)\"")
                                        .font(.body)
                                        .italic()
                                        .textSelection(.enabled)

                                    if let context = citation.context {
                                        Text(context)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .padding(MacSpacing.standard)
                                .background(Color.accentColor.opacity(MacOpacity.subtle))
                                .cornerRadius(MacCornerRadius.standard)
                            }
                        }
                    }

                    // Full Text Section
                    Divider()
                    fullTextSection

                    // Transparency Analysis
                    Divider()
                    transparencyAnalysisSection

                    // External Links
                    Divider()

                    HStack(spacing: MacSpacing.large) {
                        Link(destination: URL(string: "https://pubmed.ncbi.nlm.nih.gov/\(document.pmid)/")!) {
                            HStack(spacing: MacSpacing.xSmall) {
                                Image(systemName: "link")
                                Text("View on PubMed")
                            }
                        }

                        if let doi = document.doi {
                            Link(destination: URL(string: "https://doi.org/\(doi)")!) {
                                HStack(spacing: MacSpacing.xSmall) {
                                    Image(systemName: "doc.text")
                                    Text("View via DOI")
                                }
                            }
                        }

                        Spacer()

                        Text("PMID: \(document.pmid)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(MacSpacing.xxLarge)
            }
        }
        .frame(minWidth: MacLayout.documentSheetMinWidth, minHeight: MacLayout.documentSheetMinHeight)
    }

    // MARK: - Full Text Section

    /// Section displaying full text status and action button.
    @ViewBuilder
    private var fullTextSection: some View {
        VStack(alignment: .leading, spacing: MacSpacing.medium) {
            Text("Full Text")
                .font(.headline)

            if document.hasFullText {
                // Already have full text - show view button
                HStack(spacing: MacSpacing.standard) {
                    Button(action: showFullTextInTab) {
                        Label("View Full Text", systemImage: "doc.text.fill")
                    }
                    .buttonStyle(.borderedProminent)

                    if let source = document.fullTextSource,
                       let fullTextSource = AppFullTextSource(rawValue: source) {
                        MacFullTextSourceBadge(source: fullTextSource)
                    }
                }
            } else if document.fullTextUnavailable {
                // Already tried, not available
                HStack(spacing: MacSpacing.standard) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                    Text("Full text not available from open access sources")
                        .font(.body)
                        .foregroundColor(.secondary)
                }

                // Still offer to open in browser
                if let doi = document.doi {
                    Link(destination: URL(string: "https://doi.org/\(doi)")!) {
                        Label("Open Publisher", systemImage: "safari")
                    }
                }
            } else {
                // Not yet attempted - show fetch button
                HStack(spacing: MacSpacing.standard) {
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

    // MARK: - Transparency Analysis Section

    @ViewBuilder
    private var transparencyAnalysisSection: some View {
        VStack(alignment: .leading, spacing: MacSpacing.medium) {
            Text("Transparency Analysis")
                .font(.headline)

            if let result = document.transparencyResult {
                MacTransparencyDetailView(result: result)

                // A stale result keeps its score on screen but has to be
                // re-runnable, or the notice above names a fix the user cannot apply.
                if document.transparencyAnalysisIsStale, document.canAnalyzeTransparency {
                    transparencyAnalyzeButton(title: "Re-analyze")
                }
            } else if !document.canAnalyzeTransparency {
                HStack(spacing: MacSpacing.standard) {
                    Image(systemName: "info.circle")
                        .foregroundColor(.secondary)
                    Text("Transparency analysis requires a PMID or DOI")
                        .font(.body)
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
        HStack(spacing: MacSpacing.standard) {
            Button(action: analyzeTransparency) {
                if isLoadingTransparency {
                    ProgressView()
                        .scaleEffect(MacScale.progressViewSmall)
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

    private func analyzeTransparency() {
        isLoadingTransparency = true
        transparencyError = nil

        Task {
            do {
                let service = TransparencyAnalysisService.create(from: AppSettings.shared)
                let pmid = document.pmid.isEmpty ? nil : document.pmid
                let result = try await service.analyze(
                    doi: document.doi,
                    pmid: pmid,
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

    // MARK: - Actions

    /// Show the full text in the Full Text tab and dismiss this sheet.
    private func showFullTextInTab() {
        // Post notification to navigate to Full Text tab
        NotificationCenter.default.post(
            name: .showDocumentFullText,
            object: nil,
            userInfo: ["document": document]
        )
        dismiss()
    }

    /// Fetch full text for the document.
    private func fetchFullText() {
        isLoadingFullText = true
        fullTextError = nil

        Task {
            do {
                let service = BioMedLit.FullTextService.create(from: AppSettings.shared)
                let bmlResult = try await service.fetchFullText(
                    pmcId: document.pmcId,
                    doi: document.doi,
                    pmid: document.pmid
                )
                let result = BioMedLitAdapters.toAppFullTextResult(bmlResult)

                await MainActor.run {
                    // Update document model
                    document.applyFullTextResult(result)

                    isLoadingFullText = false

                    // Handle result based on content type
                    switch result.content {
                    case .markdown, .html, .pdfURL:
                        // Show in Full Text tab
                        showFullTextInTab()

                    case .webURL(let url):
                        // Opened rather than shown — but only when there is
                        // nothing to explain first. Handing the reader to the
                        // browser before they have read why this is a substitute
                        // is the silent fallback #183 objects to. The Full Text
                        // tab banners the record from its stored fields, so a
                        // degraded link is sent there to be explained.
                        if result.degradation == nil {
                            NSWorkspace.shared.open(url)
                        } else {
                            showFullTextInTab()
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    if case FullTextError.noFullTextAvailable = error {
                        document.markFullTextUnavailable()
                    }
                    fullTextError = error.localizedDescription
                    isLoadingFullText = false
                }
            }
        }
    }
}

// MARK: - Abstract View for Document Details

/// View that renders abstract text with markdown formatting support.
///
/// Handles common markdown patterns found in PubMed abstracts like
/// bold section headers (e.g., **OBJECTIVE:**) and emphasis.
private struct MacDocumentDetailAbstractView: View {
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

#Preview {
    let report = EvidenceReport(
        verdict: .partiallySupported,
        summary: "The evidence suggests that vitamin D may have some protective effects, but results are mixed.",
        fullReport: "## Analysis\n\nMultiple studies examined this relationship...",
        citationCount: 5,
        uniqueSourceCount: 3,
        documentsReviewed: 15
    )
    return MacReportView(report: report)
        .frame(width: 900, height: 700)
}

#endif // os(macOS)
