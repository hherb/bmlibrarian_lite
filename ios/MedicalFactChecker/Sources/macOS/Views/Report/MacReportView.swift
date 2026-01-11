//
//  MacReportView.swift
//  MedicalFactChecker
//
//  macOS-optimized view for displaying evidence reports with wide layout.
//

import SwiftUI
import AppKit
import PDFKit

/// macOS report view with optimized layout for larger screens.
///
/// Features:
/// - Wide, readable content area with maximum width constraint
/// - Toolbar with export options (PDF, text, print)
/// - Keyboard shortcuts for common actions
struct MacReportView: View {
    let report: EvidenceReport?

    @State private var selectedDocument: Document?
    @State private var exportFormat: ExportFormat = .pdf

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
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Report content
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
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
                    if let session = report.session, !session.documents.isEmpty {
                        reviewedDocumentsSection(session.documents)
                    }

                    // Statistics
                    statisticsSection(report)

                    // Cost
                    if let session = report.session {
                        costSection(session)
                    }

                    // Footer
                    footerSection(report)
                }
                .frame(maxWidth: 900)
                .padding(32)
                .frame(maxWidth: .infinity)
            }
        }
        .sheet(item: $selectedDocument) { doc in
            MacDocumentDetailSheet(document: doc)
        }
        .onReceive(NotificationCenter.default.publisher(for: .documentReferenceClicked)) { notification in
            if let url = notification.userInfo?["url"] as? URL {
                handleReferenceTap(url, documents: report?.session?.documents ?? [])
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "doc.text")
                .font(.system(size: 72))
                .foregroundColor(.secondary.opacity(0.4))

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
        HStack(spacing: 16) {
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
                HStack(spacing: 4) {
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
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Claim")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                Text(session.claim)
                    .font(.title3)
                    .italic()
            }

            if let query = session.pubmedQuery {
                VStack(alignment: .leading, spacing: 6) {
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
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
    }

    private func summarySection(_ report: EvidenceReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Summary")
                .font(.title3)
                .fontWeight(.semibold)

            Text(report.summary)
                .font(.body)
                .lineSpacing(4)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08))
        .cornerRadius(12)
    }

    private func detailedReportSection(_ report: EvidenceReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
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
        VStack(alignment: .leading, spacing: 12) {
            Text("Statistics")
                .font(.title3)
                .fontWeight(.semibold)

            HStack(spacing: 32) {
                MacStatItem(icon: "doc.text", value: "\(report.documentsReviewed)", label: "Documents Reviewed")
                MacStatItem(icon: "checkmark.circle", value: "\(report.uniqueSourceCount)", label: "Relevant Sources")
                MacStatItem(icon: "quote.bubble", value: "\(report.citationCount)", label: "Citations Extracted")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
    }

    private func costSection(_ session: FactCheckSession) -> some View {
        HStack(spacing: 32) {
            VStack(alignment: .leading, spacing: 4) {
                Text("API Cost")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(CostCalculator.formatCost(session.estimatedCostUSD))
                    .font(.title3)
                    .fontWeight(.medium)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Tokens Used")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("\(session.totalInputTokens + session.totalOutputTokens)")
                    .font(.title3)
                    .fontWeight(.medium)
            }

            Spacer()
        }
        .padding(20)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
    }

    private func footerSection(_ report: EvidenceReport) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Divider()

            Text(report.generationFootnote)
                .font(.caption)
                .foregroundColor(.secondary)

            // Disclaimer
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundColor(.orange)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Important Disclaimer")
                        .font(.headline)

                    Text("This report is generated by AI and is intended for informational purposes only. It should not be used for self-diagnosis or treatment. Always consult qualified healthcare professionals for medical advice.")
                        .font(.body)
                        .foregroundColor(.secondary)
                }
            }
            .padding(16)
            .background(Color.orange.opacity(0.1))
            .cornerRadius(8)
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

            if let pdfDocument = PDFDocument(url: tempURL) {
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
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.accentColor)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
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

struct MacReviewedDocumentsSection: View {
    let documents: [Document]
    let onDocumentSelected: (Document) -> Void

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                LazyVStack(spacing: 8) {
                    ForEach(documents, id: \.pmid) { document in
                        MacReviewedDocumentRow(document: document)
                            .onTapGesture {
                                onDocumentSelected(document)
                            }
                    }
                }
            }
        }
        .padding(20)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
    }
}

struct MacReviewedDocumentRow: View {
    let document: Document

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let score = document.relevanceScore {
                MacScoreBadge(score: score)
                    .frame(width: 32, height: 32)
            }

            VStack(alignment: .leading, spacing: 4) {
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
        .padding(12)
        .background(Color(NSColor.textBackgroundColor))
        .cornerRadius(8)
        .contentShape(Rectangle())
    }
}

/// Markdown renderer for macOS reports.
struct MacMarkdownReportView: View {
    let content: String
    let documents: [Document]

    init(_ content: String, documents: [Document] = []) {
        self.content = content
        self.documents = documents
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
struct MacDocumentDetailSheet: View {
    let document: Document
    @Environment(\.dismiss) private var dismiss

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
            .padding(20)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
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
                                Text("(\(year))")
                            }
                        }
                        .font(.body)
                        .foregroundColor(.secondary)
                    }

                    Divider()

                    // Score
                    if let score = document.relevanceScore {
                        HStack(spacing: 12) {
                            Text("Relevance Score:")
                                .fontWeight(.medium)
                            MacScoreBadge(score: score)
                        }

                        if let explanation = document.scoreExplanation {
                            Text(explanation)
                                .font(.body)
                                .italic()
                                .foregroundColor(.secondary)
                        }

                        Divider()
                    }

                    // Abstract
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Abstract")
                            .font(.headline)
                        Text(document.abstract)
                            .font(.body)
                            .textSelection(.enabled)
                    }

                    // Citations
                    if !document.citations.isEmpty {
                        Divider()

                        VStack(alignment: .leading, spacing: 12) {
                            Text("Key Passages")
                                .font(.headline)

                            ForEach(document.citations, id: \.id) { citation in
                                VStack(alignment: .leading, spacing: 4) {
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
                                .padding(12)
                                .background(Color.accentColor.opacity(0.1))
                                .cornerRadius(8)
                            }
                        }
                    }

                    Divider()

                    // Links
                    HStack(spacing: 16) {
                        Link(destination: URL(string: "https://pubmed.ncbi.nlm.nih.gov/\(document.pmid)/")!) {
                            HStack(spacing: 4) {
                                Image(systemName: "link")
                                Text("View on PubMed")
                            }
                        }

                        if let doi = document.doi {
                            Link(destination: URL(string: "https://doi.org/\(doi)")!) {
                                HStack(spacing: 4) {
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
                .padding(24)
            }
        }
        .frame(minWidth: 600, minHeight: 500)
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
