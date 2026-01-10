//
//  ScoredDocumentsView.swift
//  MedicalFactChecker
//
//  View for displaying scored documents with LLM and embedding scores.
//

import SwiftUI
import SwiftData

/// Section displaying scored documents with both LLM and embedding scores.
///
/// Shows a collapsible list of documents sorted by relevance score.
/// Each document displays both scoring methods for comparison.
struct ScoredDocumentsView: View {
    let documents: [Document]
    let showEmbeddingScores: Bool

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header with toggle
            Button(action: { withAnimation { isExpanded.toggle() } }) {
                HStack {
                    Text("Reviewed Documents")
                        .font(.headline)

                    Spacer()

                    Text("\(documents.count)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                // Sort by LLM relevance score, highest first
                let sortedDocs = documents.sorted {
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

/// Row displaying a single document with its scores.
struct DocumentScoreRow: View {
    let document: Document
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

    private var scoresColumn: some View {
        VStack(spacing: 4) {
            // LLM Score
            ScoreBadge(
                score: document.relevanceScore,
                label: "LLM",
                color: scoreColor(for: document.relevanceScore)
            )

            // Embedding Score (if enabled and available)
            if showEmbeddingScore {
                ScoreBadge(
                    score: document.embeddingScoreNormalized,
                    label: "Emb",
                    color: scoreColor(for: document.embeddingScoreNormalized)
                )
            }
        }
    }

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

    private func scoreComparisonView(llmScore: Int, embScore: Int) -> some View {
        let difference = abs(llmScore - embScore)
        let agreement: String
        let color: Color

        switch difference {
        case 0:
            agreement = "Perfect agreement"
            color = .green
        case 1:
            agreement = "Close agreement"
            color = .blue
        case 2:
            agreement = "Moderate disagreement"
            color = .orange
        default:
            agreement = "Strong disagreement"
            color = .red
        }

        return HStack {
            Image(systemName: difference <= 1 ? "checkmark.circle" : "exclamationmark.triangle")
                .foregroundColor(color)
            Text(agreement)
                .font(.caption)
                .foregroundColor(color)

            Spacer()

            if let raw = document.embeddingScore {
                Text("Raw: \(raw, specifier: "%.3f")")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(8)
        .background(color.opacity(0.1))
        .cornerRadius(6)
    }

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

/// Badge displaying a score value.
struct ScoreBadge: View {
    let score: Int?
    let label: String
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
