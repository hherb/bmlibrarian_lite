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
import SwiftData
import BioMedLit

/// macOS view for displaying scored documents as expandable cards.
///
/// Takes advantage of the larger screen with more information visible at once
/// and support for keyboard navigation. Includes full-text retrieval capabilities.
struct MacScoredDocumentsView: View {
    @Bindable var session: FactCheckSession
    let showEmbeddingScores: Bool

    /// Callback when user wants to view full text in the dedicated tab.
    var onShowFullText: ((Document) -> Void)?

    @State private var expandedDocumentId: String?

    /// User-selected sort option with persistence.
    @AppStorage("macScoredDocumentsSortOption")
    private var sortOptionRaw: String = SortOption.scoreHighToLow.rawValue

    /// Current sort option derived from persisted value.
    private var sortOption: SortOption {
        SortOption(rawValue: sortOptionRaw) ?? .scoreHighToLow
    }

    /// Binding for the sort option picker.
    private var sortOptionBinding: Binding<SortOption> {
        Binding(
            get: { SortOption(rawValue: sortOptionRaw) ?? .scoreHighToLow },
            set: { sortOptionRaw = $0.rawValue }
        )
    }

    @State private var filterThreshold: Int = 1

    private var scoredDocuments: [Document] {
        (session.documents ?? [])
            .filter { $0.isScored && ($0.relevanceScore ?? 0) >= filterThreshold }
            .sorted(by: sortOption)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            toolbar
                .padding(.horizontal, MacSpacing.large)
                .padding(.vertical, MacSpacing.medium)
                .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Documents list
            ScrollView {
                LazyVStack(spacing: MacSpacing.cardSpacing) {
                    ForEach(scoredDocuments, id: \.id) { document in
                        MacDocumentCard(
                            document: document,
                            isExpanded: expandedDocumentId == document.id,
                            showEmbeddingScore: showEmbeddingScores,
                            onToggleExpand: {
                                withAnimation(.easeInOut(duration: MacAnimation.expandDuration)) {
                                    if expandedDocumentId == document.id {
                                        expandedDocumentId = nil
                                    } else {
                                        expandedDocumentId = document.id
                                    }
                                }
                            },
                            onShowFullText: onShowFullText
                        )
                    }
                }
                .padding(MacSpacing.large)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: MacSpacing.large) {
            // Sort picker using new SortOption
            MacSortingControlsView(selectedSort: sortOptionBinding)

            // Filter picker
            Picker("Min score", selection: $filterThreshold) {
                Text("All").tag(1)
                Text("2+").tag(2)
                Text("3+").tag(3)
                Text("4+").tag(4)
                Text("5 only").tag(5)
            }
            .pickerStyle(.menu)
            .frame(width: MacLayout.filterPickerWidth)

            Spacer()

            // Count
            Text("\(scoredDocuments.count) documents")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Enhanced Mac Scored Documents View

/// Enhanced macOS view with error queue and sorting.
///
/// Extends MacScoredDocumentsView with error queue display
/// and retry functionality for failed documents.
struct EnhancedMacScoredDocumentsView: View {
    @Bindable var session: FactCheckSession
    let showEmbeddingScores: Bool

    /// Binding to processing errors for display.
    @Binding var errors: [TransientErrorEntry]

    /// Callback for retrying failed documents.
    var onRetry: ([String]) -> Void

    /// Callback when user wants to view full text.
    var onShowFullText: ((Document) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            // Error queue at top
            if !errors.isEmpty {
                MacErrorQueueView(errors: $errors, onRetry: onRetry)
                    .padding()
            }

            // Main documents view
            MacScoredDocumentsView(
                session: session,
                showEmbeddingScores: showEmbeddingScores,
                onShowFullText: onShowFullText
            )
        }
    }
}

/// Sort order options for document list (legacy - kept for backwards compatibility).
enum DocumentSortOrder: String, CaseIterable, Identifiable {
    case score = "Score"
    case year = "Year"
    case title = "Title"

    var id: String { rawValue }
}

/// Expandable document card for macOS with full-text retrieval support.
///
/// Displays document metadata, relevance score, and provides full-text
/// retrieval functionality with fallback chain (Europe PMC → Unpaywall → DOI).
struct MacDocumentCard: View {
    // MARK: - Properties

    let document: Document
    let isExpanded: Bool
    let showEmbeddingScore: Bool
    let onToggleExpand: () -> Void

    /// Callback when user wants to view full text in the dedicated tab.
    var onShowFullText: ((Document) -> Void)?

    // MARK: - State

    @State private var isLoadingFullText = false
    @State private var fullTextError: String?

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header (always visible)
            cardHeader
                .contentShape(Rectangle())
                .onTapGesture(perform: onToggleExpand)
                .contextMenu { documentContextMenu }

            // Expanded content
            if isExpanded {
                Divider()
                    .padding(.horizontal, MacSpacing.large)

                expandedContent
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(MacCornerRadius.standard)
        .overlay(
            RoundedRectangle(cornerRadius: MacCornerRadius.standard)
                .stroke(Color.secondary.opacity(MacOpacity.border))
        )
    }

    // MARK: - Card Header

    private var cardHeader: some View {
        HStack(alignment: .top, spacing: MacSpacing.large) {
            // Score badge (shows "?" for failed scores)
            MacScoreBadge(score: document.relevanceScore)

            // Title and metadata
            VStack(alignment: .leading, spacing: MacSpacing.xSmall) {
                HStack(spacing: MacSpacing.small) {
                    Text(document.title)
                        .font(.headline)
                        .lineLimit(isExpanded ? nil : 2)

                    // Full text indicator
                    if document.hasFullText {
                        Image(systemName: "doc.text.fill")
                            .font(.caption)
                            .foregroundColor(.accentColor)
                            .help("Full text available")
                    }
                }

                HStack(spacing: MacSpacing.medium) {
                    Text(document.formattedAuthors)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)

                    if let journal = document.journal, let year = document.year {
                        Text("•")
                            .foregroundColor(.secondary)
                        Text(verbatim: "\(journal), \(year)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }

                    // Search provider badge
                    MacProviderBadge(provider: documentProvider)

                    // PMC full text availability indicator (only if not already fetched)
                    if document.hasFullTextInPMC && !document.hasFullText && !document.fullTextUnavailable {
                        PMCAvailableBadge()
                    }

                    // Full text source badge (compact)
                    if let sourceString = document.fullTextSource {
                        MacFullTextSourceBadge(sourceString: sourceString)
                    }

                    // Batch indicator for documents fetched in later batches
                    if document.batchNumber > 1 {
                        MacBatchBadge(batchNumber: document.batchNumber)
                    }
                }
            }

            Spacer()

            // Embedding score (if enabled)
            if showEmbeddingScore {
                VStack(alignment: .trailing, spacing: MacSpacing.xxSmall) {
                    Text("Embed")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("\(document.embeddingScoreNormalized ?? 0)")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(embeddingColor)
                }
            }

            // Expand indicator
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .foregroundColor(.secondary)
                .font(.caption)
        }
        .padding(MacSpacing.large)
    }

    // MARK: - Expanded Content

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: MacSpacing.large) {
            // Score explanation - visually distinct with background and quote styling
            if let explanation = document.scoreExplanation, !explanation.isEmpty {
                VStack(alignment: .leading, spacing: MacSpacing.xSmall) {
                    Text("Relevance Explanation")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)

                    HStack(alignment: .top, spacing: MacSpacing.medium) {
                        Image(systemName: "brain.head.profile")
                            .font(.body)
                            .foregroundColor(MacColors.reasoningAccent)

                        Text(explanation)
                            .font(.body)
                            .italic()
                            .foregroundColor(MacColors.reasoningText)
                    }
                    .padding(MacSpacing.standard)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(MacColors.reasoningBackground)
                    .cornerRadius(MacCornerRadius.standard)
                    .overlay(
                        RoundedRectangle(cornerRadius: MacCornerRadius.standard)
                            .stroke(MacColors.reasoningBorder, lineWidth: 1)
                    )
                }
            }

            // Citations (Key Passages) - shown before abstract
            if !(document.citations ?? []).isEmpty {
                VStack(alignment: .leading, spacing: MacSpacing.medium) {
                    Text("Key Passages (\((document.citations ?? []).count))")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)

                    ForEach(document.citations ?? [], id: \.id) { citation in
                        HStack(alignment: .top, spacing: MacSpacing.medium) {
                            Image(systemName: "quote.opening")
                                .font(.caption)
                                .foregroundColor(.accentColor)

                            Text(citation.passage)
                                .font(.body)
                                .italic()
                                .textSelection(.enabled)
                        }
                        .padding(MacSpacing.standard)
                        .background(Color.accentColor.opacity(MacOpacity.veryLight))
                        .cornerRadius(MacCornerRadius.medium)
                    }
                }
            }

            // Abstract - rendered as markdown
            VStack(alignment: .leading, spacing: MacSpacing.xSmall) {
                Text("Abstract")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                MacAbstractView(text: document.abstract)
                    .textSelection(.enabled)
            }

            Divider()

            // Full Text Section
            fullTextSection

            // Links
            HStack(spacing: MacSpacing.large) {
                Link(destination: URL(string: "https://pubmed.ncbi.nlm.nih.gov/\(document.pmid)/")!) {
                    HStack(spacing: MacSpacing.xSmall) {
                        Image(systemName: "link")
                        Text("PubMed")
                    }
                    .font(.caption)
                }

                if let doi = document.doi {
                    Link(destination: URL(string: "https://doi.org/\(doi)")!) {
                        HStack(spacing: MacSpacing.xSmall) {
                            Image(systemName: "doc.text")
                            Text("DOI")
                        }
                        .font(.caption)
                    }
                }

                Spacer()

                Text("PMID: \(document.pmid)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(MacSpacing.large)
    }

    // MARK: - Full Text Section

    /// What a link-only record has to say, and the way to reach the substitute.
    ///
    /// The macOS twin of ``DocumentScoreRow/linkOnlyNotice``, and it needed the
    /// same fix for the same reason: a fetch that ends in a publisher link caches
    /// no content, so this card read as never-fetched and the browser took over
    /// before the reader saw why the article was a substitute (#183, #187).
    /// `MacFullTextTab` and `MacFullTextViewer` already spoke; this card did not.
    @ViewBuilder
    private var linkOnlyNotice: some View {
        if document.isLinkOnly {
            ParseWarningBanner(
                warnings: document.cachedRetrievalNotice.warnings,
                degradation: document.cachedRetrievalNotice.degradation
            )

            if let url = document.fullTextLinkDestination {
                Link(destination: url) {
                    Label("Open Publisher", systemImage: "safari")
                        .font(.caption)
                }
            }
        }
    }

    /// Section for full-text retrieval button and status.
    ///
    /// A column rather than a row, so the retrieval note can sit above the
    /// controls at full width: it is a sentence, and a sentence squeezed into a
    /// button row is one the reader skips.
    @ViewBuilder
    private var fullTextSection: some View {
        VStack(alignment: .leading, spacing: MacSpacing.small) {
            linkOnlyNotice

            fullTextControls
        }
    }

    /// The retrieval controls themselves, one row.
    @ViewBuilder
    private var fullTextControls: some View {
        HStack(spacing: MacSpacing.medium) {
            if document.hasFullText {
                // Already have full text - show view button
                Button(action: { onShowFullText?(document) }) {
                    Label("View Full Text", systemImage: "doc.text")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("View full text")
                .accessibilityHint("Opens the full text in a new tab")

                if let sourceString = document.fullTextSource {
                    MacFullTextSourceBadge(sourceString: sourceString)
                }

                Spacer()

                // Open in Preview (for PDFs)
                if document.fullTextPDFPath != nil {
                    Button(action: openInPreview) {
                        Label("Open in Preview", systemImage: "eye")
                    }
                    .buttonStyle(.bordered)
                    .help("Open PDF in Preview.app")
                }
            } else if document.fullTextUnavailable {
                // Already tried, not available
                HStack(spacing: MacSpacing.small) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                    Text("Full text not available")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Full text not available")

                Spacer()

                // Still offer to open in browser
                if let url = document.fullTextLinkDestination {
                    Link(destination: url) {
                        Label("Open Publisher", systemImage: "safari")
                            .font(.caption)
                    }
                }
            } else {
                // Not yet attempted, or attempted and left with only a link;
                // what the latter has to say is above this row, in
                // `linkOnlyNotice`.
                Button(action: fetchFullText) {
                    if isLoadingFullText {
                        ProgressView()
                            .scaleEffect(MacScale.progressViewSmall)
                            .frame(width: MacFullTextLayout.loadingIndicatorSize,
                                   height: MacFullTextLayout.loadingIndicatorSize)
                    } else {
                        Label("Get Full Text", systemImage: "arrow.down.doc")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isLoadingFullText)
                .accessibilityLabel(isLoadingFullText ? "Loading full text" : "Get full text")
                .accessibilityHint("Downloads the full text of this article if available")

                if let error = fullTextError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .lineLimit(1)
                }

                Spacer()
            }
        }
    }

    // MARK: - Context Menu

    /// Context menu for document card with full-text options.
    @ViewBuilder
    private var documentContextMenu: some View {
        if document.hasFullText {
            Button(action: { onShowFullText?(document) }) {
                Label("View Full Text", systemImage: "doc.text")
            }

            if document.fullTextPDFPath != nil {
                Button(action: openInPreview) {
                    Label("Open in Preview", systemImage: "eye")
                }

                Button(action: revealInFinder) {
                    Label("Reveal in Finder", systemImage: "folder")
                }
            }

            Divider()
        } else if !document.fullTextUnavailable {
            Button(action: fetchFullText) {
                Label("Get Full Text", systemImage: "arrow.down.doc")
            }
            .disabled(isLoadingFullText)

            Divider()
        }

        // Standard links
        Link(destination: URL(string: "https://pubmed.ncbi.nlm.nih.gov/\(document.pmid)/")!) {
            Label("Open in PubMed", systemImage: "link")
        }

        if let doi = document.doi, let url = URL(string: "https://doi.org/\(doi)") {
            Link(destination: url) {
                Label("Open DOI", systemImage: "link")
            }
        }

        Divider()

        Button(action: copyPMID) {
            Label("Copy PMID", systemImage: "doc.on.doc")
        }

        Button(action: copyCitation) {
            Label("Copy Citation", systemImage: "quote.opening")
        }
    }

    // MARK: - Computed Properties

    private var embeddingColor: Color {
        MacColors.scoreColor(for: document.embeddingScoreNormalized ?? 0)
    }

    /// Determine the search provider based on document properties.
    ///
    /// Returns the search provider that returned this document.
    ///
    /// Uses the stored `searchSource` property if available, otherwise
    /// falls back to heuristics for backwards compatibility with older data.
    private var documentProvider: SearchProvider? {
        // Use stored search source if available
        if let source = document.searchSource {
            return SearchProvider(rawValue: source)
        }

        // Fallback heuristics for older documents without searchSource
        // Documents from Europe PMC often have pmcId but empty pmid
        if document.pmid.isEmpty && document.pmcId != nil {
            return .europePMC
        }
        // Check if it's a preprint (would come from Europe PMC)
        if let journal = document.journal?.lowercased() {
            if journal.contains("biorxiv") || journal.contains("medrxiv") ||
               journal.contains("preprint") || journal.contains("arxiv") {
                return .europePMC
            }
        }
        // Default to PubMed for articles with PMID
        if !document.pmid.isEmpty {
            return .pubmed
        }
        return nil
    }

    // MARK: - Full Text Actions

    /// Fetch full text for this document using the BioMedLit FullTextService.
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
                    // Update document model based on result type
                    document.applyFullTextResult(result)

                    switch result.content {
                    case .markdown, .html:
                        // Content already stored, show in tab
                        onShowFullText?(document)

                    case .pdfURL(let url):
                        // Download and cache PDF
                        Task {
                            await downloadAndCachePDF(from: url)
                        }

                    case .webURL(let url):
                        // Opened rather than shown — but only when there is
                        // nothing to explain first. Handing the reader to the
                        // browser before they have read why this is a substitute
                        // is the silent fallback #183 objects to; the note and a
                        // link are in the card, via `linkOnlyNotice`.
                        if result.degradation == nil {
                            NSWorkspace.shared.open(url)
                        }
                    }

                    isLoadingFullText = false
                }
            } catch {
                await MainActor.run {
                    if case FullTextError.noFullTextAvailable = error {
                        document.markFullTextUnavailable()
                    }
                    fullTextError = error.localizedDescription
                    isLoadingFullText = false
                    AppLogger.fullText.error("Failed to fetch full text: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Download and cache a PDF file.
    ///
    /// - Parameter url: The URL to download the PDF from.
    private func downloadAndCachePDF(from url: URL) async {
        do {
            let service = BioMedLit.FullTextService.create(from: AppSettings.shared)
            let path = try await service.downloadAndCachePDF(from: url, for: document.pmid)

            await MainActor.run {
                document.fullTextPDFPath = path
                isLoadingFullText = false
                // Show in full text tab
                onShowFullText?(document)
            }
        } catch {
            await MainActor.run {
                fullTextError = "Failed to download PDF"
                isLoadingFullText = false
                AppLogger.fullText.error("Failed to cache PDF: \(error.localizedDescription)")
            }
        }
    }

    /// Open the cached PDF in Preview.app.
    private func openInPreview() {
        guard let path = document.fullTextPDFPath else { return }
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.open(url)
    }

    /// Reveal the cached PDF in Finder.
    private func revealInFinder() {
        guard let path = document.fullTextPDFPath else { return }
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }

    /// Copy the PMID to the clipboard.
    private func copyPMID() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(document.pmid, forType: .string)
    }

    /// Copy the full citation to the clipboard.
    private func copyCitation() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(document.fullCitation, forType: .string)
    }
}

// MARK: - Score Badge

/// Score badge displaying a relevance score (1-5) with color coding.
///
/// Colors range from red (1) through orange (2-3) to green (4-5).
/// Displays "?" for nil scores (parsing failures).
struct MacScoreBadge: View {
    /// The relevance score to display (nil for failed scores).
    let score: Int?

    var body: some View {
        Group {
            if let score = score {
                Text("\(score)")
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .frame(width: MacIconSize.scoreBadgeSize, height: MacIconSize.scoreBadgeSize)
                    .background(MacColors.scoreColor(for: score))
                    .clipShape(RoundedRectangle(cornerRadius: MacCornerRadius.standard))
            } else {
                Text("?")
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .frame(width: MacIconSize.scoreBadgeSize, height: MacIconSize.scoreBadgeSize)
                    .background(Color.gray)
                    .clipShape(RoundedRectangle(cornerRadius: MacCornerRadius.standard))
            }
        }
    }
}

// MARK: - Abstract View with Markdown Support

/// View that renders abstract text with markdown formatting support.
///
/// Handles common markdown patterns found in PubMed abstracts like
/// bold section headers (e.g., **OBJECTIVE:**) and emphasis.
struct MacAbstractView: View {
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
    /// Handles common patterns in PubMed abstracts:
    /// - **SECTION:** headers (bold)
    /// - *emphasis* text (italic)
    ///
    /// - Parameter text: The abstract text to parse.
    /// - Returns: An AttributedString with formatting, or nil if parsing fails.
    private func parseAbstractMarkdown(_ text: String) -> AttributedString? {
        // Try native markdown parsing first
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return attributed
        }
        return nil
    }
}

// MARK: - Batch Badge

/// Compact badge showing which batch a document was fetched in.
///
/// Displayed for documents fetched in later batches (batch 2+) to help users
/// identify which documents came from each search iteration. Uses distinct
/// colors for different batch numbers.
struct MacBatchBadge: View {
    /// The batch number (1-indexed).
    let batchNumber: Int

    var body: some View {
        Text("Batch \(batchNumber)")
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(MacColors.batchColor(for: batchNumber).opacity(0.15))
            .foregroundColor(MacColors.batchColor(for: batchNumber))
            .cornerRadius(4)
            .help("Fetched in batch \(batchNumber)")
    }
}

// MARK: - PMC Availability Badge

/// Compact badge indicating full text is available in PubMed Central.
///
/// Shows "PMC" in a green-tinted badge to indicate the article has
/// free full text available that can be fetched.
struct PMCAvailableBadge: View {
    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "doc.text.fill")
                .font(.system(size: 9))
            Text("PMC")
                .font(.system(size: 10, weight: .medium))
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Color.green.opacity(0.15))
        .foregroundColor(.green)
        .cornerRadius(4)
        .help("Full text available in PubMed Central")
    }
}

// MARK: - Preview

#Preview {
    let session = FactCheckSession(claim: "Test claim")
    return MacScoredDocumentsView(
        session: session,
        showEmbeddingScores: true,
        onShowFullText: { doc in
            print("Show full text for: \(doc.title)")
        }
    )
    .frame(width: 600, height: 500)
}

#endif // os(macOS)
