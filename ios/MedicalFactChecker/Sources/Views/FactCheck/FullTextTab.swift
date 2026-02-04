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

import SwiftUI
import SwiftData

// MARK: - Constants

/// Constants for the full-text tab UI.
private enum FullTextTabConstants {
    /// Empty state icon size.
    static let emptyStateIconSize: CGFloat = 60

    /// Maximum width for empty state message.
    static let emptyStateMaxWidth: CGFloat = 280

    /// Minimum score badge width.
    static let scoreBadgeWidth: CGFloat = 40
}

// MARK: - Full Text Tab View

/// Tab view for browsing and viewing full-text documents.
///
/// Provides a list-based interface for iOS with:
/// - List of documents from the current session
/// - Filter options (With Full Text / Pending / All Scored)
/// - Navigation to full-text viewer
///
/// Documents can be selected to view their full text in a sheet.
struct FullTextTab: View {
    // MARK: - Environment

    @Environment(\.modelContext) private var modelContext

    // MARK: - Properties

    /// The active workflow containing the session with documents.
    let workflow: FactCheckWorkflow?

    /// Binding to the currently selected document for viewing.
    @Binding var selectedDocument: Document?

    // MARK: - State

    @State private var filterOption: FullTextFilterOption = .withFullText
    @State private var showingFullTextViewer = false
    @State private var fullTextResult: AppFullTextResult?
    @State private var isLoadingFullText = false

    // MARK: - Computed Properties

    /// Documents available for full-text viewing based on filter.
    private var availableDocuments: [Document] {
        guard let session = workflow?.session else { return [] }

        let filtered: [Document]
        let docs = session.documents ?? []
        switch filterOption {
        case .all:
            filtered = docs.filter { $0.isScored }
        case .withFullText:
            filtered = docs.filter { $0.hasFullText }
        case .withoutFullText:
            filtered = docs.filter { !$0.hasFullText && !$0.fullTextUnavailable }
        }

        return filtered.sorted { ($0.relevanceScore ?? 0) > ($1.relevanceScore ?? 0) }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Group {
                if workflow?.session == nil {
                    noSessionView
                } else if availableDocuments.isEmpty {
                    emptyListView
                } else {
                    documentList
                }
            }
            .navigationTitle("Full Text")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    filterPicker
                }
            }
            .sheet(isPresented: $showingFullTextViewer) {
                fullTextViewerSheet
            }
        }
    }

    // MARK: - Filter Picker

    private var filterPicker: some View {
        Menu {
            ForEach(FullTextFilterOption.allCases) { option in
                Button {
                    filterOption = option
                } label: {
                    HStack {
                        Text(option.rawValue)
                        if filterOption == option {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(filterOption.rawValue)
                    .font(.subheadline)
                Image(systemName: "chevron.down")
                    .font(.caption)
            }
        }
    }

    // MARK: - Document List

    private var documentList: some View {
        List {
            Section {
                ForEach(availableDocuments, id: \.id) { document in
                    FullTextDocumentRow(
                        document: document,
                        isLoadingFullText: isLoadingFullText && selectedDocument?.id == document.id,
                        onSelect: { selectDocument(document) },
                        onFetchFullText: { fetchFullText(for: document) }
                    )
                }
            } header: {
                Text("\(availableDocuments.count) documents")
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Empty States

    private var noSessionView: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass.circle")
                .font(.system(size: FullTextTabConstants.emptyStateIconSize))
                .foregroundColor(.secondary.opacity(0.5))

            Text("No Active Session")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Run a fact-check to retrieve documents from PubMed.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: FullTextTabConstants.emptyStateMaxWidth)
        }
        .padding()
    }

    private var emptyListView: some View {
        VStack(spacing: 16) {
            Image(systemName: emptyStateIcon)
                .font(.system(size: FullTextTabConstants.emptyStateIconSize))
                .foregroundColor(.secondary.opacity(0.5))

            Text(emptyStateTitle)
                .font(.title2)
                .fontWeight(.semibold)

            Text(emptyStateMessage)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: FullTextTabConstants.emptyStateMaxWidth)
        }
        .padding()
    }

    private var emptyStateIcon: String {
        switch filterOption {
        case .all:
            return "doc.text.magnifyingglass"
        case .withFullText:
            return "doc.text"
        case .withoutFullText:
            return "arrow.down.doc"
        }
    }

    private var emptyStateTitle: String {
        switch filterOption {
        case .all:
            return "No Scored Documents"
        case .withFullText:
            return "No Full Text Documents"
        case .withoutFullText:
            return "All Documents Processed"
        }
    }

    private var emptyStateMessage: String {
        switch filterOption {
        case .all:
            return "Run a fact-check to score documents."
        case .withFullText:
            return "Tap \"Get Full Text\" on document cards to retrieve full articles."
        case .withoutFullText:
            return "All documents have been processed for full text retrieval."
        }
    }

    // MARK: - Full Text Viewer Sheet

    @ViewBuilder
    private var fullTextViewerSheet: some View {
        if let document = selectedDocument {
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
            } else if let html = document.fullTextHTML {
                FullTextViewer(
                    document: document,
                    result: AppFullTextResult(
                        content: .html(content: html, markdown: document.fullTextContent ?? ""),
                        source: AppFullTextSource(rawValue: document.fullTextSource ?? "cached") ?? .cached
                    )
                )
            }
        }
    }

    // MARK: - Actions

    /// Select a document for viewing.
    private func selectDocument(_ document: Document) {
        selectedDocument = document
        if document.hasFullText {
            // Create result from stored content
            if let html = document.fullTextHTML {
                fullTextResult = AppFullTextResult(
                    content: .html(content: html, markdown: document.fullTextContent ?? ""),
                    source: AppFullTextSource(rawValue: document.fullTextSource ?? "cached") ?? .cached
                )
            } else if let content = document.fullTextContent {
                fullTextResult = AppFullTextResult(
                    content: .markdown(content),
                    source: AppFullTextSource(rawValue: document.fullTextSource ?? "cached") ?? .cached
                )
            }
            showingFullTextViewer = true
        }
    }

    /// Fetch full text for a document.
    private func fetchFullText(for document: Document) {
        selectedDocument = document
        isLoadingFullText = true

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
                        // Don't store - just for viewing
                        break
                    }
                    document.fullTextSource = result.source.rawValue
                    document.fullTextFetchedAt = Date()
                    try? modelContext.save()

                    fullTextResult = result
                    isLoadingFullText = false
                    showingFullTextViewer = true
                }
            } catch {
                await MainActor.run {
                    if case FullTextError.noFullTextAvailable = error {
                        document.fullTextUnavailable = true
                        try? modelContext.save()
                    }
                    isLoadingFullText = false
                }
            }
        }
    }
}

// MARK: - Filter Options

/// Filter options for the full-text document list.
enum FullTextFilterOption: String, CaseIterable, Identifiable {
    case withFullText = "With Full Text"
    case withoutFullText = "Pending"
    case all = "All Scored"

    var id: String { rawValue }
}

// MARK: - Document Row

/// Row view for a document in the full-text list.
///
/// Shows document title, metadata, full-text status, and source badge.
struct FullTextDocumentRow: View {
    let document: Document
    let isLoadingFullText: Bool
    let onSelect: () -> Void
    let onFetchFullText: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        Button(action: handleTap) {
            HStack(spacing: 12) {
                // Score badge
                scoreBadge

                // Document info
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(document.title)
                            .font(.body)
                            .lineLimit(2)
                            .foregroundColor(.primary)

                        if document.hasFullText {
                            Image(systemName: "doc.text.fill")
                                .font(.caption)
                                .foregroundColor(.accentColor)
                        }
                    }

                    HStack(spacing: 6) {
                        Text(document.formattedAuthors)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)

                        if let sourceString = document.fullTextSource,
                           let source = AppFullTextSource(rawValue: sourceString) {
                            FullTextSourceBadge(source: source)
                        } else if document.fullTextUnavailable {
                            unavailableBadge
                        }
                    }
                }

                Spacer()

                // Loading indicator or chevron
                if isLoadingFullText {
                    ProgressView()
                        .scaleEffect(0.8)
                } else if document.hasFullText {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if !document.fullTextUnavailable {
                    Button(action: onFetchFullText) {
                        Image(systemName: "arrow.down.circle")
                            .font(.title3)
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            if document.hasFullText {
                Button(action: onSelect) {
                    Label("View Full Text", systemImage: "doc.text")
                }
            } else if !document.fullTextUnavailable {
                Button(action: onFetchFullText) {
                    Label("Get Full Text", systemImage: "arrow.down.doc")
                }
            }

            if let doi = document.doi,
               let url = PlatformHelper.doiURL(for: doi) {
                Button {
                    openURL(url)
                } label: {
                    Label("Open Publisher", systemImage: "safari")
                }
            }

            if let url = PlatformHelper.pubmedURL(for: document.pmid) {
                Button {
                    openURL(url)
                } label: {
                    Label("Open PubMed", systemImage: "link")
                }
            }
        }
    }

    /// Handle tap on the row.
    private func handleTap() {
        if document.hasFullText {
            onSelect()
        } else if !document.fullTextUnavailable && !isLoadingFullText {
            onFetchFullText()
        }
    }

    /// Score badge showing relevance score.
    private var scoreBadge: some View {
        Group {
            if let score = document.relevanceScore {
                Text("\(score)")
                    .font(.system(.headline, design: .rounded))
                    .fontWeight(.bold)
                    .foregroundColor(.white)
            } else {
                Text("-")
                    .font(.headline)
                    .foregroundColor(.white)
            }
        }
        .frame(width: FullTextTabConstants.scoreBadgeWidth, height: FullTextTabConstants.scoreBadgeWidth)
        .background(scoreColor)
        .cornerRadius(8)
    }

    /// Badge shown when full text is unavailable.
    private var unavailableBadge: some View {
        Text("Unavailable")
            .font(.caption2)
            .foregroundColor(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(0.15))
            .cornerRadius(4)
    }

    /// Color for the score badge.
    private var scoreColor: Color {
        guard let score = document.relevanceScore else { return .gray }
        switch score {
        case 5: return .green
        case 4: return .blue
        case 3: return .orange
        case 2: return .red.opacity(0.7)
        default: return .red
        }
    }
}

// MARK: - Preview

#Preview {
    struct PreviewWrapper: View {
        @State private var selectedDocument: Document?

        var body: some View {
            FullTextTab(
                workflow: nil,
                selectedDocument: $selectedDocument
            )
        }
    }

    return PreviewWrapper()
}

#endif // os(iOS)
