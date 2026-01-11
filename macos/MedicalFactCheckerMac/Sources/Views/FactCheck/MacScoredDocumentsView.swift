//
//  MacScoredDocumentsView.swift
//  MedicalFactChecker
//
//  macOS-optimized view for displaying scored documents in a table format.
//

import SwiftUI
import SwiftData

/// macOS view for displaying scored documents as expandable cards.
///
/// Takes advantage of the larger screen with more information visible at once
/// and support for keyboard navigation.
struct MacScoredDocumentsView: View {
    @Bindable var session: FactCheckSession
    let showEmbeddingScores: Bool

    @State private var expandedDocumentId: String?
    @State private var sortOrder: DocumentSortOrder = .score
    @State private var filterThreshold: Int = 1

    private var scoredDocuments: [Document] {
        session.documents
            .filter { $0.isScored && ($0.relevanceScore ?? 0) >= filterThreshold }
            .sorted { doc1, doc2 in
                switch sortOrder {
                case .score:
                    return (doc1.relevanceScore ?? 0) > (doc2.relevanceScore ?? 0)
                case .year:
                    return (doc1.year ?? 0) > (doc2.year ?? 0)
                case .title:
                    return doc1.title < doc2.title
                }
            }
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
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    if expandedDocumentId == document.id {
                                        expandedDocumentId = nil
                                    } else {
                                        expandedDocumentId = document.id
                                    }
                                }
                            }
                        )
                    }
                }
                .padding(MacSpacing.large)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: MacSpacing.large) {
            // Sort picker
            Picker("Sort by", selection: $sortOrder) {
                ForEach(DocumentSortOrder.allCases) { order in
                    Text(order.rawValue).tag(order)
                }
            }
            .pickerStyle(.menu)
            .frame(width: MacLayout.sortPickerWidth)

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

/// Sort order options for document list.
enum DocumentSortOrder: String, CaseIterable, Identifiable {
    case score = "Score"
    case year = "Year"
    case title = "Title"

    var id: String { rawValue }
}

/// Expandable document card for macOS.
struct MacDocumentCard: View {
    let document: Document
    let isExpanded: Bool
    let showEmbeddingScore: Bool
    let onToggleExpand: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header (always visible)
            cardHeader
                .contentShape(Rectangle())
                .onTapGesture(perform: onToggleExpand)

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

    private var cardHeader: some View {
        HStack(alignment: .top, spacing: MacSpacing.large) {
            // Score badge
            if let score = document.relevanceScore {
                MacScoreBadge(score: score)
            }

            // Title and metadata
            VStack(alignment: .leading, spacing: MacSpacing.xSmall) {
                Text(document.title)
                    .font(.headline)
                    .lineLimit(isExpanded ? nil : 2)

                HStack(spacing: MacSpacing.medium) {
                    Text(document.formattedAuthors)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)

                    if let journal = document.journal, let year = document.year {
                        Text("•")
                            .foregroundColor(.secondary)
                        Text("\(journal), \(year)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
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

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: MacSpacing.large) {
            // Score explanation
            if let explanation = document.scoreExplanation, !explanation.isEmpty {
                VStack(alignment: .leading, spacing: MacSpacing.xSmall) {
                    Text("Relevance Explanation")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                    Text(explanation)
                        .font(.body)
                        .italic()
                }
            }

            // Abstract
            VStack(alignment: .leading, spacing: MacSpacing.xSmall) {
                Text("Abstract")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                Text(document.abstract)
                    .font(.body)
                    .textSelection(.enabled)
            }

            // Citations
            if !document.citations.isEmpty {
                VStack(alignment: .leading, spacing: MacSpacing.medium) {
                    Text("Key Passages (\(document.citations.count))")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)

                    ForEach(document.citations, id: \.id) { citation in
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

    private var embeddingColor: Color {
        MacColors.scoreColor(for: document.embeddingScoreNormalized ?? 0)
    }
}

/// Score badge displaying a relevance score (1-5) with color coding.
///
/// Colors range from red (1) through orange (2-3) to green (4-5).
struct MacScoreBadge: View {
    /// The relevance score to display.
    let score: Int

    var body: some View {
        Text("\(score)")
            .font(.title3)
            .fontWeight(.bold)
            .foregroundColor(.white)
            .frame(width: MacIconSize.scoreBadgeSize, height: MacIconSize.scoreBadgeSize)
            .background(MacColors.scoreColor(for: score))
            .clipShape(RoundedRectangle(cornerRadius: MacCornerRadius.standard))
    }
}

#Preview {
    let session = FactCheckSession(claim: "Test claim")
    return MacScoredDocumentsView(session: session, showEmbeddingScores: true)
        .frame(width: 600, height: 500)
}
