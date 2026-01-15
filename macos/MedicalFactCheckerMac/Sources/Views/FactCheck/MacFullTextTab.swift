//
//  MacFullTextTab.swift
//  MedicalFactChecker
//
//  Tab view for browsing and viewing full-text documents.
//  Displays a split view with document list and full-text viewer.
//

import SwiftUI
import SwiftData

/// Tab view for browsing and viewing full-text documents.
///
/// Provides a split-view interface with:
/// - Left panel: List of documents with full text available
/// - Right panel: Full-text viewer for the selected document
///
/// Documents can be selected from:
/// - The document list in this tab
/// - Navigation from the Fact Check tab via `onShowFullText` callback
struct MacFullTextTab: View {
    // MARK: - Environment

    @Environment(\.modelContext) private var modelContext

    // MARK: - Properties

    /// The active workflow containing the session with documents.
    let workflow: FactCheckWorkflow?

    /// Binding to the currently selected document for viewing.
    @Binding var selectedDocument: Document?

    // MARK: - State

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var filterOption: FullTextFilterOption = .withFullText

    // MARK: - Computed Properties

    /// Documents available for full-text viewing.
    private var availableDocuments: [Document] {
        guard let session = workflow?.session else { return [] }

        let filtered: [Document]
        switch filterOption {
        case .all:
            filtered = session.documents.filter { $0.isScored }
        case .withFullText:
            filtered = session.documents.filter { $0.hasFullText }
        case .withoutFullText:
            filtered = session.documents.filter { !$0.hasFullText && !$0.fullTextUnavailable }
        }

        return filtered.sorted { ($0.relevanceScore ?? 0) > ($1.relevanceScore ?? 0) }
    }

    // MARK: - Body

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            documentList
                .navigationSplitViewColumnWidth(
                    min: MacLayout.leftColumnMinWidth,
                    ideal: MacLayout.leftColumnIdealWidth,
                    max: MacLayout.leftColumnMaxWidth
                )
        } detail: {
            detailView
        }
        .navigationSplitViewStyle(.balanced)
    }

    // MARK: - Document List

    private var documentList: some View {
        VStack(spacing: 0) {
            // Toolbar
            listToolbar
                .padding(.horizontal, MacSpacing.large)
                .padding(.vertical, MacSpacing.medium)
                .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Document list
            if availableDocuments.isEmpty {
                emptyListView
            } else {
                ScrollView {
                    LazyVStack(spacing: MacSpacing.medium) {
                        ForEach(availableDocuments, id: \.id) { document in
                            FullTextDocumentRow(
                                document: document,
                                isSelected: selectedDocument?.id == document.id,
                                onSelect: { selectedDocument = document }
                            )
                        }
                    }
                    .padding(MacSpacing.large)
                }
            }
        }
    }

    private var listToolbar: some View {
        HStack(spacing: MacSpacing.large) {
            // Filter picker
            Picker("Show", selection: $filterOption) {
                ForEach(FullTextFilterOption.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.menu)
            .frame(width: MacLayout.filterPickerWideWidth)

            Spacer()

            // Count
            Text("\(availableDocuments.count) documents")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var emptyListView: some View {
        VStack(spacing: MacSpacing.large) {
            Image(systemName: emptyStateIcon)
                .font(.system(size: MacIconSize.emptyStateMedium))
                .foregroundColor(.secondary.opacity(MacOpacity.half))

            Text(emptyStateTitle)
                .font(.title3)
                .fontWeight(.medium)

            Text(emptyStateMessage)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: MacLayout.emptyStateMaxWidth)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            return "No Documents Yet"
        case .withFullText:
            return "No Full Text Documents"
        case .withoutFullText:
            return "All Documents Processed"
        }
    }

    private var emptyStateMessage: String {
        switch filterOption {
        case .all:
            return "Run a fact-check to retrieve documents from PubMed."
        case .withFullText:
            return "Click \"Get Full Text\" on document cards to retrieve full articles."
        case .withoutFullText:
            return "All documents have been processed for full text retrieval."
        }
    }

    // MARK: - Detail View

    @ViewBuilder
    private var detailView: some View {
        if let document = selectedDocument, document.hasFullText {
            MacFullTextViewer(
                document: document,
                onClose: { selectedDocument = nil }
            )
        } else if let document = selectedDocument {
            noFullTextView(for: document)
        } else {
            emptySelectionView
        }
    }

    private func noFullTextView(for document: Document) -> some View {
        VStack(spacing: MacSpacing.large) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: MacIconSize.emptyStateLarge))
                .foregroundColor(.secondary)

            Text("Full Text Not Retrieved")
                .font(.headline)

            Text("Click \"Get Full Text\" on the document card in the Fact Check tab to retrieve the full article.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: MacLayout.emptyStateMaxWidth)

            // Quick actions
            HStack(spacing: MacSpacing.large) {
                if let doi = document.doi, let url = URL(string: "https://doi.org/\(doi)") {
                    Link(destination: url) {
                        Label("Open Publisher", systemImage: "safari")
                    }
                    .buttonStyle(.bordered)
                }

                Link(destination: URL(string: "https://pubmed.ncbi.nlm.nih.gov/\(document.pmid)/")!) {
                    Label("Open PubMed", systemImage: "link")
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptySelectionView: some View {
        VStack(spacing: MacSpacing.large) {
            Image(systemName: "sidebar.left")
                .font(.system(size: MacIconSize.emptyStateLarge))
                .foregroundColor(.secondary)

            Text("Select a Document")
                .font(.headline)

            Text("Choose a document from the list to view its full text.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: MacLayout.emptyStateMaxWidth)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: MacSpacing.medium) {
            // Score badge
            MacScoreBadge(score: document.relevanceScore)

            // Document info
            VStack(alignment: .leading, spacing: MacSpacing.xxSmall) {
                HStack(spacing: MacSpacing.small) {
                    Text(document.title)
                        .font(.body)
                        .fontWeight(isSelected ? .semibold : .regular)
                        .lineLimit(2)

                    if document.hasFullText {
                        Image(systemName: "doc.text.fill")
                            .font(.caption)
                            .foregroundColor(.accentColor)
                    }
                }

                HStack(spacing: MacSpacing.small) {
                    Text(document.formattedAuthors)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)

                    if let sourceString = document.fullTextSource {
                        FullTextSourceBadge(sourceString: sourceString)
                    } else if document.fullTextUnavailable {
                        Text("Unavailable")
                            .font(.caption2)
                            .foregroundColor(.orange)
                            .padding(.horizontal, MacSpacing.small)
                            .padding(.vertical, MacSpacing.xxSmall)
                            .background(Color.orange.opacity(MacOpacity.badgeBackground))
                            .cornerRadius(MacCornerRadius.small)
                    }
                }
            }

            Spacer()

            // Selection indicator
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.accentColor)
            }
        }
        .padding(MacSpacing.standard)
        .background(isSelected ? Color.accentColor.opacity(MacOpacity.subtle) : Color.clear)
        .cornerRadius(MacCornerRadius.standard)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}

// MARK: - Preview

#Preview("With Documents") {
    struct PreviewWrapper: View {
        @State private var selectedDocument: Document?

        var body: some View {
            MacFullTextTab(
                workflow: nil,
                selectedDocument: $selectedDocument
            )
            .frame(width: 1000, height: 700)
        }
    }

    return PreviewWrapper()
}

#Preview("Empty State") {
    struct PreviewWrapper: View {
        @State private var selectedDocument: Document?

        var body: some View {
            MacFullTextTab(
                workflow: nil,
                selectedDocument: $selectedDocument
            )
            .frame(width: 1000, height: 700)
        }
    }

    return PreviewWrapper()
}
