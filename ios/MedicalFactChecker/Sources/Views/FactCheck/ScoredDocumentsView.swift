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

import BioMedLit
import SwiftData
import SwiftUI

// MARK: - Constants

/// Constants for scored documents view UI.
private enum ScoredDocumentsConstants {
    /// Scale factor for inline progress indicators.
    static let inlineProgressScale: CGFloat = 0.8
}

/// Section displaying scored documents with both LLM and embedding scores.
///
/// Shows a collapsible list of documents sorted by relevance score.
/// Each document displays both scoring methods for comparison.
struct ScoredDocumentsView: View {
    let session: FactCheckSession
    let showEmbeddingScores: Bool

    @State private var isExpanded = false

    /// Scored documents from the session, computed to trigger observation.
    private var scoredDocuments: [Document] {
        (session.documents ?? []).filter { $0.isScored }
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
                // Sort by LLM relevance score, highest first
                let sortedDocs = scoredDocuments.sorted {
                    ($0.relevanceScore ?? 0) > ($1.relevanceScore ?? 0)
                }

                ForEach(sortedDocs, id: \.pmid) { document in
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

/// Expandable row displaying a single document with its LLM and embedding scores.
///
/// Shows title, reference, and score badges in collapsed state.
/// Expands to show abstract, LLM reasoning, score comparison, metadata, and full-text options.
struct DocumentScoreRow: View {
    @Bindable var document: Document
    let showEmbeddingScore: Bool

    @State private var isExpanded = false

    // Full-text retrieval state
    @State private var isLoadingFullText = false
    @State private var fullTextError: String?
    @State private var showFullTextViewer = false
    @State private var fullTextResult: AppFullTextResult?

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
                            if let provider = document.sourceProvider {
                                DocumentSourceBadge(
                                    provider: provider,
                                    isPreprint: document.isPreprint
                                )
                            }
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

    /// Expanded content showing abstract, LLM reasoning, score comparison, and metadata.
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
            // Not yet attempted
            fullTextFetchView
        }
    }

    /// View shown when full text was attempted but not available.
    private var fullTextUnavailableView: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundColor(.orange)
            Text("Full text not available")
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()

            // Still offer to open in browser
            if let doi = document.doi,
               let url = PlatformHelper.doiURL(for: doi) {
                Link(destination: url) {
                    Label("Open Publisher", systemImage: "safari")
                        .font(.caption)
                }
            }
        }
    }

    /// View for fetching full text when not yet attempted.
    private var fullTextFetchView: some View {
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
            .disabled(isLoadingFullText)
            .accessibilityHint("Downloads the full text of this article if available")

            if let error = fullTextError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(2)
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
                    // Update document model
                    switch result.content {
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
