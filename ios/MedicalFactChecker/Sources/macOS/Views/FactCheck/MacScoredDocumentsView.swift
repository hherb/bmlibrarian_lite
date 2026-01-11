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
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Documents list
            ScrollView {
                LazyVStack(spacing: 12) {
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
                .padding(16)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 16) {
            // Sort picker
            Picker("Sort by", selection: $sortOrder) {
                ForEach(DocumentSortOrder.allCases) { order in
                    Text(order.rawValue).tag(order)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 140)

            // Filter picker
            Picker("Min score", selection: $filterThreshold) {
                Text("All").tag(1)
                Text("2+").tag(2)
                Text("3+").tag(3)
                Text("4+").tag(4)
                Text("5 only").tag(5)
            }
            .pickerStyle(.menu)
            .frame(width: 100)

            Spacer()

            // Count
            Text("\(scoredDocuments.count) documents")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

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
                    .padding(.horizontal, 16)

                expandedContent
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.2))
        )
    }

    private var cardHeader: some View {
        HStack(alignment: .top, spacing: 16) {
            // Score badge
            if let score = document.relevanceScore {
                MacScoreBadge(score: score)
            }

            // Title and metadata
            VStack(alignment: .leading, spacing: 4) {
                Text(document.title)
                    .font(.headline)
                    .lineLimit(isExpanded ? nil : 2)

                HStack(spacing: 8) {
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
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Embed")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("\(document.embeddingScoreNormalized)")
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
        .padding(16)
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Score explanation
            if let explanation = document.scoreExplanation, !explanation.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
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
            VStack(alignment: .leading, spacing: 4) {
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
                VStack(alignment: .leading, spacing: 8) {
                    Text("Key Passages (\(document.citations.count))")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)

                    ForEach(document.citations, id: \.id) { citation in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "quote.opening")
                                .font(.caption)
                                .foregroundColor(.accentColor)

                            Text(citation.passage)
                                .font(.body)
                                .italic()
                                .textSelection(.enabled)
                        }
                        .padding(12)
                        .background(Color.accentColor.opacity(0.05))
                        .cornerRadius(6)
                    }
                }
            }

            // Links
            HStack(spacing: 16) {
                Link(destination: URL(string: "https://pubmed.ncbi.nlm.nih.gov/\(document.pmid)/")!) {
                    HStack(spacing: 4) {
                        Image(systemName: "link")
                        Text("PubMed")
                    }
                    .font(.caption)
                }

                if let doi = document.doi {
                    Link(destination: URL(string: "https://doi.org/\(doi)")!) {
                        HStack(spacing: 4) {
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
        .padding(16)
    }

    private var embeddingColor: Color {
        let score = document.embeddingScoreNormalized
        switch score {
        case 5: return .green
        case 4: return Color(red: 0.4, green: 0.7, blue: 0.3)
        case 3: return .orange
        case 2: return Color(red: 0.9, green: 0.5, blue: 0.2)
        default: return .red
        }
    }
}

/// Score badge optimized for macOS.
struct MacScoreBadge: View {
    let score: Int

    var body: some View {
        Text("\(score)")
            .font(.title3)
            .fontWeight(.bold)
            .foregroundColor(.white)
            .frame(width: 36, height: 36)
            .background(scoreColor)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var scoreColor: Color {
        switch score {
        case 5: return .green
        case 4: return Color(red: 0.4, green: 0.7, blue: 0.3)
        case 3: return .orange
        case 2: return Color(red: 0.9, green: 0.5, blue: 0.2)
        default: return .red
        }
    }
}

#Preview {
    let session = FactCheckSession(claim: "Test claim")
    return MacScoredDocumentsView(session: session, showEmbeddingScores: true)
        .frame(width: 600, height: 500)
}
