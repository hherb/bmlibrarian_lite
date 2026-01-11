//
//  ScoredDocumentsView.swift
//  MedicalFactChecker
//
//  View for displaying scored documents with LLM and embedding scores.
//

import SwiftData
import SwiftUI

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
        session.documents.filter { $0.isScored }
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
/// Expands to show abstract, LLM reasoning, score comparison, and metadata.
struct DocumentScoreRow: View {
    @Bindable var document: Document
    let showEmbeddingScore: Bool

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Main row content
            Button(action: { withAnimation { isExpanded.toggle() } }) {
                HStack(alignment: .top, spacing: 12) {
                    // Scores column
                    scoresColumn

                    // Title and metadata
                    VStack(alignment: .leading, spacing: 4) {
                        Text(document.title)
                            .font(.subheadline)
                            .lineLimit(isExpanded ? nil : 2)
                            .multilineTextAlignment(.leading)

                        Text(document.shortReference)
                            .font(.caption)
                            .foregroundColor(.secondary)
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
    }

    // MARK: - Subviews

    /// Column displaying LLM and embedding score badges vertically.
    private var scoresColumn: some View {
        VStack(spacing: 4) {
            // LLM Score
            LabeledScoreBadge(
                score: document.relevanceScore,
                label: "LLM",
                color: scoreColor(for: document.relevanceScore)
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

            // Abstract
            if !document.abstract.isEmpty {
                Text("Abstract")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)

                Text(document.abstract)
                    .font(.caption)
                    .lineLimit(10)
            }

            // Score explanation
            if let explanation = document.scoreExplanation {
                Text("LLM Reasoning")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)

                Text(explanation)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .italic()
            }

            // Score comparison (if both available)
            if showEmbeddingScore,
               let llm = document.relevanceScore,
               let emb = document.embeddingScoreNormalized {
                scoreComparisonView(llmScore: llm, embScore: emb)
            }

            // Metadata
            metadataView
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
/// Displays a dash when score is nil, indicating not yet scored.
struct LabeledScoreBadge: View {
    /// The score to display (1-5), or nil if not scored.
    let score: Int?

    /// Short label displayed below the score (e.g., "LLM", "Emb").
    let label: String

    /// Background color for the badge.
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            if let score = score {
                Text("\(score)")
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
        .background(score != nil ? color : Color.gray)
        .cornerRadius(6)
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

// MARK: - Preview

#Preview {
    let doc = Document(
        pmid: "12345678",
        title: "Effect of Vitamin D Supplementation on COVID-19 Outcomes: A Meta-Analysis",
        abstract: "Background: Vitamin D has been proposed to have immunomodulatory effects..."
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
