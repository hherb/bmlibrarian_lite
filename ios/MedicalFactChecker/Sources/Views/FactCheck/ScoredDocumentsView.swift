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
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Constants

/// Constants for scored documents view UI.
private enum ScoredDocumentsConstants {
    /// Scale factor for inline progress indicators.
    static let inlineProgressScale: CGFloat = 0.8

    /// UserDefaults key for persisting sort preference.
    static let sortPreferenceKey = "scoredDocumentsSortOption"

    /// Vertical gap between the rows of the full-text section.
    static let sectionSpacing: CGFloat = 8
}

/// Section displaying scored documents with both LLM and embedding scores.
///
/// Shows a collapsible list of documents sorted by relevance score.
/// Each document displays both scoring methods for comparison.
/// Supports user-selectable sort order with persistence.
struct ScoredDocumentsView: View {
    let session: FactCheckSession
    let showEmbeddingScores: Bool

    @State private var isExpanded = false

    /// User-selected sort option with persistence.
    @AppStorage(ScoredDocumentsConstants.sortPreferenceKey)
    private var sortOptionRaw: String = SortOption.scoreHighToLow.rawValue

    /// Current sort option derived from persisted value.
    private var sortOption: SortOption {
        get { SortOption(rawValue: sortOptionRaw) ?? .scoreHighToLow }
    }

    /// Binding for the sort option picker.
    private var sortOptionBinding: Binding<SortOption> {
        Binding(
            get: { SortOption(rawValue: sortOptionRaw) ?? .scoreHighToLow },
            set: { sortOptionRaw = $0.rawValue }
        )
    }

    /// Scored documents from the session, computed to trigger observation.
    private var scoredDocuments: [Document] {
        (session.documents ?? []).filter { $0.isScored }
    }

    /// Sorted documents based on the selected sort option.
    private var sortedDocuments: [Document] {
        scoredDocuments.sorted(by: sortOption)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header with toggle
            Button(action: { withAnimation { isExpanded.toggle() } }) {
                HStack {
                    Text("Reviewed Documents")
                        .font(.headline)

                    Spacer()

                    Text("\(scoredDocuments.count)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                // Sorting controls
                SortingControlsView(selectedSort: sortOptionBinding)
                    .padding(.bottom, 4)

                ForEach(sortedDocuments, id: \.pmid) { document in
                    DocumentScoreRow(
                        document: document,
                        showEmbeddingScore: showEmbeddingScores
                    )
                }
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(10)
    }
}

// MARK: - Enhanced Scored Documents View

/// Enhanced view displaying scored documents with error queue and sorting.
///
/// This view extends the basic ScoredDocumentsView with:
/// - Error queue display at the top
/// - Results summary showing success/failure counts
/// - Full sorting controls
/// - Retry functionality for failed documents
///
/// ## Usage
///
/// ```swift
/// EnhancedScoredDocumentsView(
///     session: session,
///     showEmbeddingScores: true,
///     errors: $errors,
///     onRetry: { pmids in
///         await workflow.retryDocuments(pmids: pmids)
///     }
/// )
/// ```
struct EnhancedScoredDocumentsView: View {
    let session: FactCheckSession
    let showEmbeddingScores: Bool

    /// Binding to processing errors for display.
    @Binding var errors: [TransientErrorEntry]

    /// Callback for retrying failed documents.
    var onRetry: ([String]) -> Void

    @State private var isExpanded = true

    /// User-selected sort option with persistence.
    @AppStorage(ScoredDocumentsConstants.sortPreferenceKey)
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

    /// Scored documents from the session.
    private var scoredDocuments: [Document] {
        (session.documents ?? []).filter { $0.isScored }
    }

    /// Sorted documents based on the selected sort option.
    private var sortedDocuments: [Document] {
        scoredDocuments.sorted(by: sortOption)
    }

    /// Count of successfully scored documents.
    private var successCount: Int {
        scoredDocuments.filter { $0.relevanceScore != nil }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            // Error queue at top
            ErrorQueueView(errors: $errors, onRetry: handleRetry)
                .padding()

            // Sorting controls
            SortingControlsView(selectedSort: sortOptionBinding)

            // Results summary
            resultsSummaryView

            // Document list
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(sortedDocuments, id: \.pmid) { document in
                        DocumentScoreRow(
                            document: document,
                            showEmbeddingScore: showEmbeddingScores
                        )
                    }
                }
                .padding()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Scored documents view")
    }

    // MARK: - Results Summary

    /// Summary showing success and failure counts.
    private var resultsSummaryView: some View {
        HStack {
            Label("\(successCount) scored", systemImage: "checkmark.circle")
                .foregroundColor(.green)

            if !errors.isEmpty {
                Label("\(errors.count) failed", systemImage: "xmark.circle")
                    .foregroundColor(.red)
            }

            Spacer()
        }
        .font(.caption)
        .padding(.horizontal)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(successCount) documents scored successfully, \(errors.count) failed")
    }

    // MARK: - Actions

    /// Add an error to the queue.
    ///
    /// - Parameters:
    ///   - pmid: PubMed identifier of the failed document.
    ///   - step: Processing step where the error occurred.
    ///   - message: Error message.
    func addError(pmid: String, step: String, message: String) {
        let entry = TransientErrorEntry(
            pmid: pmid,
            step: step,
            message: message
        )
        errors.append(entry)
    }

    /// Handle retry request from error queue.
    private func handleRetry(_ pmids: [String]) {
        // Remove errors for these PMIDs
        errors.removeAll { pmids.contains($0.pmid) }
        // Trigger retry callback
        onRetry(pmids)
    }
}

/// Expandable row displaying a single document with its LLM and embedding scores.
///
/// Shows title, reference, and score badges in collapsed state.
/// Expands to show abstract, LLM reasoning, score comparison, metadata, and full-text options.
struct DocumentScoreRow: View {
    @Bindable var document: Document
    let showEmbeddingScore: Bool

    @Environment(\.modelContext) private var modelContext

    @State private var isExpanded = false

    // Full-text retrieval state
    @State private var isLoadingFullText = false
    @State private var fullTextError: String?
    @State private var showFullTextViewer = false
    @State private var fullTextResult: AppFullTextResult?

    // File upload state
    @State private var showFileImporter = false
    @State private var isProcessingUpload = false

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Main row content
            Button(action: { withAnimation { isExpanded.toggle() } }) {
                HStack(alignment: .top, spacing: 12) {
                    // Scores column
                    scoresColumn

                    // Title and metadata
                    VStack(alignment: .leading, spacing: 4) {
                        Text(document.displayTitle)
                            .font(.subheadline)
                            .lineLimit(isExpanded ? nil : 2)
                            .multilineTextAlignment(.leading)

                        HStack(spacing: 8) {
                            Text(document.shortReference)
                                .font(.caption)
                                .foregroundColor(.secondary)

                            // Source provider badge
                            DocumentSourceBadge(
                                provider: document.searchSourceEnum,
                                isPreprint: document.isPreprint
                            )
                        }
                    }

                    Spacer(minLength: 0)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)

            // Expanded content
            if isExpanded {
                expandedContent
            }
        }
        .padding(12)
        .background(Color(.systemBackground))
        .cornerRadius(8)
        .sheet(isPresented: $showFullTextViewer) {
            fullTextViewerSheet
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.pdf, .html, .plainText, UTType(filenameExtension: "md") ?? .plainText],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
    }

    // MARK: - Full Text Viewer Sheet

    /// Sheet content for displaying full text.
    @ViewBuilder
    private var fullTextViewerSheet: some View {
        // The cache rebuild carries the parse warnings; reconstructing it here
        // by hand defaulted them to clean, so a truncated article reopened from
        // the cache rendered exactly like a complete one (#181).
        if let result = fullTextResult ?? document.cachedFullTextResult {
            FullTextViewer(document: document, result: result)
        }
    }

    // MARK: - Subviews

    /// Column displaying LLM and embedding score badges vertically.
    private var scoresColumn: some View {
        VStack(spacing: 4) {
            // LLM Score (shows "?" if parse failed)
            LabeledScoreBadge(
                score: document.relevanceScore,
                label: "LLM",
                color: scoreColor(for: document.relevanceScore),
                parseFailed: document.scoreParseFailed
            )

            // Embedding Score (if enabled and available)
            if showEmbeddingScore {
                LabeledScoreBadge(
                    score: document.embeddingScoreNormalized,
                    label: "Emb",
                    color: scoreColor(for: document.embeddingScoreNormalized)
                )
            }
        }
    }

    /// Expanded content showing abstract, LLM reasoning, key passages, score comparison, and metadata.
    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()

            // Score explanation - visually distinct with background and icon
            if let explanation = document.scoreExplanation {
                Text("LLM Reasoning")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "brain.head.profile")
                        .font(.caption)
                        .foregroundColor(ReasoningColors.accent)

                    Text(explanation)
                        .font(.caption)
                        .italic()
                        .foregroundColor(ReasoningColors.text)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ReasoningColors.background)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(ReasoningColors.border, lineWidth: 1)
                )
            }

            // Key Passages (Citations) - shown before abstract
            if !(document.citations ?? []).isEmpty {
                keyPassagesSection
            }

            // Abstract - rendered with markdown
            if !document.abstract.isEmpty {
                Text("Abstract")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)

                AbstractTextView(text: document.abstract)
                    .lineLimit(10)
            }

            // Score comparison (if both available)
            if showEmbeddingScore,
               let llm = document.relevanceScore,
               let emb = document.embeddingScoreNormalized {
                scoreComparisonView(llmScore: llm, embScore: emb)
            }

            // Metadata
            metadataView

            Divider()

            // Full Text
            fullTextSection
        }
    }

    // MARK: - Full Text Section

    /// Section for full-text retrieval button and status.
    @ViewBuilder
    private var fullTextSection: some View {
        if document.hasFullText {
            // Already have full text - show view button
            HStack {
                Button(action: { showFullTextViewer = true }) {
                    Label("View Full Text", systemImage: "doc.text")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
                .tint(.blue)

                if let source = document.fullTextSource,
                   let fullTextSource = AppFullTextSource(rawValue: source) {
                    FullTextSourceBadge(source: fullTextSource)
                }
            }
        } else if document.fullTextUnavailable {
            // Already tried, not available
            fullTextUnavailableView
        } else {
            // Not yet attempted, or attempted and left with only a link.
            VStack(alignment: .leading, spacing: ScoredDocumentsConstants.sectionSpacing) {
                linkOnlyNotice
                fullTextFetchView
            }
        }
    }

    /// View shown when full text was attempted but not available.
    private var fullTextUnavailableView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundColor(.orange)
                Text("Full text not available")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                // Still offer to open in browser
                if let url = document.fullTextLinkDestination {
                    Link(destination: url) {
                        Label("Open Publisher", systemImage: "safari")
                            .font(.caption)
                    }
                }
            }

            // Upload button when full text is unavailable
            uploadFullTextButton
        }
    }

    /// What a link-only record has to say, and the way to reach the substitute.
    ///
    /// Rendered here rather than in ``FullTextViewer`` because this card cannot
    /// open that viewer: ``Document/cachedFullTextResult`` rebuilds a
    /// *renderable* result and answers `nil` when nothing was cached, which is
    /// exactly what a publisher-link fallback stores. So this card was silent on
    /// the outcome the degradation channel was added for — it opened Safari
    /// instead of saying anything (#187). A record that *did* cache content is
    /// left alone: it opens in the viewer, which banners it already, and a
    /// second copy behind it is the duplication that makes a notice ignorable.
    ///
    /// The "Get Full Text" button below is the retry the unreachable sentence
    /// invites, so no second retry control is added. The link is, because
    /// suppressing the automatic jump to the browser would otherwise leave the
    /// substitute unreachable from this card — and it goes through
    /// ``Document/fullTextLinkDestination`` rather than the DOI alone, because a
    /// record with no DOI is precisely one the chain sent to PubMed.
    @ViewBuilder
    private var linkOnlyNotice: some View {
        if document.isLinkOnly {
            VStack(alignment: .leading, spacing: ScoredDocumentsConstants.sectionSpacing) {
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
    }

    /// View for fetching full text when not yet attempted.
    private var fullTextFetchView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button(action: fetchFullText) {
                    if isLoadingFullText {
                        ProgressView()
                            .scaleEffect(ScoredDocumentsConstants.inlineProgressScale)
                    } else {
                        Label("Get Full Text", systemImage: "arrow.down.doc")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isLoadingFullText || isProcessingUpload)
                .accessibilityHint("Downloads the full text of this article if available")

                if let error = fullTextError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .lineLimit(2)
                }
            }

            // Upload button when full text fetch is available
            uploadFullTextButton
        }
    }

    /// Button to upload full text manually.
    private var uploadFullTextButton: some View {
        Button(action: { showFileImporter = true }) {
            if isProcessingUpload {
                ProgressView()
                    .scaleEffect(ScoredDocumentsConstants.inlineProgressScale)
            } else {
                Label("Upload Full Text", systemImage: "square.and.arrow.up")
            }
        }
        .buttonStyle(.bordered)
        .tint(.purple)
        .disabled(isLoadingFullText || isProcessingUpload)
        .accessibilityHint("Upload a PDF, HTML, or Markdown file containing the full text")
    }

    // MARK: - File Upload Handling

    /// Handle file import result from the file picker.
    ///
    /// - Parameter result: The result from the file importer.
    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            processUploadedFile(url)
        case .failure(let error):
            fullTextError = error.localizedDescription
        }
    }

    /// Process an uploaded file and store its content.
    ///
    /// - Parameter url: The URL of the uploaded file.
    private func processUploadedFile(_ url: URL) {
        isProcessingUpload = true
        fullTextError = nil

        Task {
            do {
                // Start accessing security-scoped resource
                guard url.startAccessingSecurityScopedResource() else {
                    throw FullTextUploadError.accessDenied
                }
                defer { url.stopAccessingSecurityScopedResource() }

                let fileExtension = url.pathExtension.lowercased()

                switch fileExtension {
                case "pdf":
                    // Copy PDF to app's cache directory
                    let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
                    let pdfDir = cacheDir.appendingPathComponent("fulltext_pdfs", isDirectory: true)
                    try FileManager.default.createDirectory(at: pdfDir, withIntermediateDirectories: true)
                    let destURL = pdfDir.appendingPathComponent("\(document.pmid).pdf")

                    if FileManager.default.fileExists(atPath: destURL.path) {
                        try FileManager.default.removeItem(at: destURL)
                    }
                    try FileManager.default.copyItem(at: url, to: destURL)

                    await MainActor.run {
                        // Through the one writer, so the warnings from an earlier
                        // fetch go with the content they described. Assigning by
                        // hand here left them behind to label the reader's own
                        // upload as truncated, and left the superseded HTML in
                        // place to shadow the PDF they had just chosen.
                        let result = AppFullTextResult.uploaded(content: .pdfURL(destURL))
                        document.applyFullTextResult(result)
                        // The cached file, not the URL: `MacPDFView` opens this
                        // as a filesystem path. Same follow-up as the macOS
                        // download path.
                        document.fullTextPDFPath = destURL.path
                        fullTextResult = result
                        isProcessingUpload = false
                        showFullTextViewer = true
                    }

                case "html", "htm":
                    let htmlContent = try String(contentsOf: url, encoding: .utf8)
                    await MainActor.run {
                        let result = AppFullTextResult.uploaded(
                            content: .html(content: htmlContent, markdown: htmlContent)
                        )
                        document.applyFullTextResult(result)
                        fullTextResult = result
                        isProcessingUpload = false
                        showFullTextViewer = true
                    }

                case "md", "markdown", "txt":
                    let markdownContent = try String(contentsOf: url, encoding: .utf8)
                    await MainActor.run {
                        let result = AppFullTextResult.uploaded(content: .markdown(markdownContent))
                        document.applyFullTextResult(result)
                        fullTextResult = result
                        isProcessingUpload = false
                        showFullTextViewer = true
                    }

                default:
                    throw FullTextUploadError.unsupportedFormat
                }
            } catch {
                await MainActor.run {
                    fullTextError = error.localizedDescription
                    isProcessingUpload = false
                }
            }
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
                    // One statement writes every cached field, warnings
                    // included. Assigning them by hand is what let the
                    // cache and the live result drift apart (#181).
                    document.applyFullTextResult(result)
                    save(document, "full text")

                    fullTextResult = result
                    isLoadingFullText = false

                    // A web URL is opened rather than shown — but only when
                    // there is nothing to explain first. Handing the reader to
                    // Safari before they have read why this is a substitute is
                    // the silent fallback #183 objects to, one surface along;
                    // the note and an Open Publisher link are in the card.
                    if case .webURL(let url) = result.content {
                        if result.degradation == nil {
                            openURL(url)
                        }
                    } else {
                        showFullTextViewer = true
                    }
                }
            } catch {
                await MainActor.run {
                    if case FullTextError.noFullTextAvailable = error {
                        // The writer, not the flag: it also clears the source,
                        // the warnings and the degradation, so a note left by an
                        // earlier attempt cannot outlive the one that
                        // superseded it.
                        document.markFullTextUnavailable()
                        save(document, "full text availability")
                    }
                    fullTextError = error.localizedDescription
                    isLoadingFullText = false
                }
            }
        }
    }

    /// Persist a change to the document, reporting a failure rather than
    /// trusting autosave with it.
    ///
    /// The retrieval note is read back from the stored fields, so a save that
    /// fails silently means a link-only record reads as never-fetched on the
    /// next launch — the #187 state, restored by the one step that has no
    /// visible symptom at the time it happens.
    ///
    /// - Parameters:
    ///   - document: The document being saved, for the log line.
    ///   - what: What was being recorded, for the log line.
    private func save(_ document: Document, _ what: String) {
        do {
            try modelContext.save()
        } catch {
            AppLogger.fullText.error(
                """
                Failed to save \(what, privacy: .public) for PMID \
                \(document.pmid, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """
            )
            fullTextError = "Could not save the retrieved full text."
        }
    }

    /// View showing agreement level between LLM and embedding scores.
    ///
    /// - Parameters:
    ///   - llmScore: The LLM relevance score (1-5).
    ///   - embScore: The normalized embedding score (1-5).
    /// - Returns: A view displaying agreement label, icon, and raw embedding score.
    private func scoreComparisonView(llmScore: Int, embScore: Int) -> some View {
        let result = ScoreAgreement.compute(llmScore: llmScore, embScore: embScore)

        return HStack {
            Image(systemName: result.icon)
                .foregroundColor(result.color)
            Text(result.label)
                .font(.caption)
                .foregroundColor(result.color)

            Spacer()

            if let raw = document.embeddingScore {
                Text("Raw: \(raw, specifier: "%.3f")")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(8)
        .background(result.color.opacity(0.1))
        .cornerRadius(6)
    }

    /// Row displaying journal and PMID metadata.
    private var metadataView: some View {
        HStack(spacing: 12) {
            if let journal = document.journal {
                Label(journal, systemImage: "book")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Label("PMID: \(document.pmid)", systemImage: "number")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    /// Section displaying extracted key passages (citations) from the document.
    ///
    /// Shows the extracted quotes that are most relevant to the claim being fact-checked.
    /// Each passage is displayed with a quote icon and styled to stand out from the abstract.
    private var keyPassagesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Key Passages (\((document.citations ?? []).count))")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)

            ForEach(document.citations ?? [], id: \.id) { citation in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "quote.opening")
                        .font(.caption)
                        .foregroundColor(.accentColor)

                    Text(citation.passage)
                        .font(.caption)
                        .italic()
                        .textSelection(.enabled)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.08))
                .cornerRadius(8)
            }
        }
    }

    // MARK: - Helpers

    /// Returns the appropriate color for a relevance score.
    ///
    /// - Parameter score: The score (1-5), or nil if not scored.
    /// - Returns: Color ranging from red (1) to green (5), gray if nil.
    private func scoreColor(for score: Int?) -> Color {
        guard let score = score else { return .gray }
        switch score {
        case 5: return .green
        case 4: return .blue
        case 3: return .orange
        case 2: return .red.opacity(0.7)
        default: return .red
        }
    }
}

/// Compact badge displaying a numeric score with a label.
///
/// Used to show LLM and embedding scores side-by-side for comparison.
/// Displays a dash when score is nil (not yet scored) or "?" if parsing failed.
struct LabeledScoreBadge: View {
    /// The score to display (1-5), or nil if not scored.
    let score: Int?

    /// Short label displayed below the score (e.g., "LLM", "Emb").
    let label: String

    /// Background color for the badge.
    let color: Color

    /// If true and score is nil, shows "?" instead of "-" to indicate parse failure.
    var parseFailed: Bool = false

    var body: some View {
        VStack(spacing: 2) {
            if let score = score {
                Text("\(score)")
                    .font(.system(.headline, design: .rounded))
                    .fontWeight(.bold)
                    .foregroundColor(.white)
            } else if parseFailed {
                Text("?")
                    .font(.system(.headline, design: .rounded))
                    .fontWeight(.bold)
                    .foregroundColor(.white)
            } else {
                Text("-")
                    .font(.headline)
                    .foregroundColor(.white)
            }

            Text(label)
                .font(.system(size: 8))
                .foregroundColor(.white.opacity(0.8))
        }
        .frame(width: 36, height: 40)
        .background(backgroundColor)
        .cornerRadius(6)
    }

    private var backgroundColor: Color {
        if score != nil {
            return color
        } else if parseFailed {
            return .orange  // Amber/orange to indicate uncertain status
        } else {
            return .gray
        }
    }
}

// MARK: - Score Agreement Helper

/// Pure function container for computing score agreement between LLM and embedding scores.
enum ScoreAgreement {
    /// Result of a score agreement computation.
    struct Result {
        let label: String
        let color: Color
        let icon: String
        let difference: Int
    }

    /// Compute the agreement level between LLM and embedding scores.
    ///
    /// - Parameters:
    ///   - llmScore: LLM relevance score (1-5).
    ///   - embScore: Normalized embedding score (1-5).
    /// - Returns: Agreement result with label, color, icon, and raw difference.
    static func compute(llmScore: Int, embScore: Int) -> Result {
        let difference = abs(llmScore - embScore)

        switch difference {
        case 0:
            return Result(label: "Perfect agreement", color: .green, icon: "checkmark.circle", difference: difference)
        case 1:
            return Result(label: "Close agreement", color: .blue, icon: "checkmark.circle", difference: difference)
        case 2:
            return Result(label: "Moderate disagreement", color: .orange, icon: "exclamationmark.triangle", difference: difference)
        default:
            return Result(label: "Strong disagreement", color: .red, icon: "exclamationmark.triangle", difference: difference)
        }
    }
}

// MARK: - Reasoning Colors

/// Colors for LLM reasoning/explanation display.
///
/// Provides a visually distinct style for AI-generated explanations
/// to help users distinguish them from source text like abstracts.
enum ReasoningColors {
    /// Background color for reasoning blocks (warm off-white).
    static let background = Color(red: 0.98, green: 0.97, blue: 0.93)

    /// Border color for reasoning blocks.
    static let border = Color(red: 0.85, green: 0.82, blue: 0.72)

    /// Text color for reasoning content.
    static let text = Color(red: 0.35, green: 0.35, blue: 0.35)

    /// Accent color for reasoning icon.
    static let accent = Color(red: 0.6, green: 0.55, blue: 0.4)
}

// MARK: - Abstract Text View

/// View that renders abstract text with markdown formatting support.
///
/// Handles common markdown patterns found in PubMed abstracts like
/// bold section headers (e.g., **OBJECTIVE:**) and emphasis.
struct AbstractTextView: View {
    /// The abstract text to render.
    let text: String

    var body: some View {
        if let attributed = parseAbstractMarkdown(text) {
            Text(attributed)
                .font(.caption)
        } else {
            Text(text)
                .font(.caption)
        }
    }

    /// Parses markdown in abstract text and returns an AttributedString.
    ///
    /// - Parameter text: The abstract text to parse.
    /// - Returns: An AttributedString with formatting, or nil if parsing fails.
    private func parseAbstractMarkdown(_ text: String) -> AttributedString? {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return attributed
        }
        return nil
    }
}

// MARK: - Preview

// MARK: - Full Text Upload Error

/// Errors that can occur during full-text file upload.
enum FullTextUploadError: LocalizedError {
    /// Access to the file was denied.
    case accessDenied
    /// The file format is not supported.
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Unable to access the selected file"
        case .unsupportedFormat:
            return "Unsupported file format. Please use PDF, HTML, or Markdown"
        }
    }
}

#Preview {
    let doc = Document(
        pmid: "12345678",
        title: "Effect of Vitamin D Supplementation on COVID-19 Outcomes: A Meta-Analysis",
        abstract: "**Background:** Vitamin D has been proposed to have immunomodulatory effects..."
    )
    doc.relevanceScore = 4
    doc.scoreExplanation = "This meta-analysis directly addresses vitamin D supplementation and COVID-19 outcomes."
    doc.embeddingScore = 0.65
    doc.year = 2024
    doc.journal = "J Med Virol"

    return ScrollView {
        DocumentScoreRow(document: doc, showEmbeddingScore: true)
            .padding()
    }
}

#endif // os(iOS)
