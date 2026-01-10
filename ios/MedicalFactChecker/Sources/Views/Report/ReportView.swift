//
//  ReportView.swift
//  MedicalFactChecker
//
//  View for displaying the evidence report.
//

import SwiftUI

struct ReportView: View {
    let report: EvidenceReport
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Verdict Badge
                    HStack {
                        Spacer()
                        VerdictBadge(verdict: report.verdict)
                        Spacer()
                    }

                    // Claim and Query (if available from session)
                    if let session = report.session {
                        VStack(alignment: .leading, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Claim")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(session.claim)
                                    .font(.body)
                                    .italic()
                            }

                            if let query = session.pubmedQuery {
                                Divider()
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("PubMed Query")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(query)
                                        .font(.caption)
                                        .fontDesign(.monospaced)
                                        .foregroundColor(.accentColor)
                                }
                            }
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(10)
                    }

                    // Summary
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Summary")
                            .font(.headline)
                        Text(report.summary)
                            .font(.body)
                    }
                    .padding()
                    .background(Color.accentColor.opacity(0.1))
                    .cornerRadius(10)

                    // Full Report (Markdown)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Detailed Report")
                            .font(.headline)

                        MarkdownText(report.fullReport)
                    }

                    // Reviewed Documents Section
                    if let session = report.session, !session.documents.isEmpty {
                        ReviewedDocumentsSection(documents: session.documents.sorted {
                            ($0.relevanceScore ?? 0) > ($1.relevanceScore ?? 0)
                        })
                    }

                    // Statistics
                    StatisticsSection(report: report)

                    // Cost (if session available)
                    if let session = report.session {
                        CostSection(session: session)
                    }
                }
                .padding()
            }
            .navigationTitle("Evidence Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    ShareLink(
                        item: report.plainTextReport,
                        subject: Text("Medical Fact Check Report"),
                        message: Text("Evidence report for: \(report.session?.claim ?? "Unknown claim")")
                    )
                }
            }
        }
    }
}

// MARK: - Subviews

struct VerdictBadge: View {
    let verdict: Verdict

    var body: some View {
        Text(verdict.rawValue)
            .font(.headline)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(backgroundColor)
            .foregroundColor(.white)
            .cornerRadius(25)
    }

    private var backgroundColor: Color {
        switch verdict {
        case .supported: return .green
        case .partiallySupported: return .orange
        case .notSupported: return .red
        case .insufficientEvidence: return .gray
        case .conflicting: return .purple
        }
    }
}

struct StatisticsSection: View {
    let report: EvidenceReport

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Statistics")
                .font(.headline)

            HStack(spacing: 20) {
                StatItem(
                    icon: "doc.text",
                    value: "\(report.documentsReviewed)",
                    label: "Reviewed"
                )
                StatItem(
                    icon: "checkmark.circle",
                    value: "\(report.uniqueSourceCount)",
                    label: "Relevant"
                )
                StatItem(
                    icon: "quote.bubble",
                    value: "\(report.citationCount)",
                    label: "Citations"
                )
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(10)
    }
}

struct StatItem: View {
    let icon: String
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.accentColor)
            Text(value)
                .font(.headline)
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct CostSection: View {
    let session: FactCheckSession

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("API Cost")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(CostCalculator.formatCost(session.estimatedCostUSD))
                    .font(.subheadline)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text("Tokens Used")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("\(session.totalInputTokens + session.totalOutputTokens)")
                    .font(.subheadline)
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(10)
    }
}

struct ReviewedDocumentsSection: View {
    let documents: [Document]
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: { withAnimation { isExpanded.toggle() } }) {
                HStack {
                    Text("Reviewed Documents (\(documents.count))")
                        .font(.headline)
                        .foregroundColor(.primary)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(documents, id: \.pmid) { document in
                    DocumentCard(document: document)
                }
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(10)
    }
}

struct DocumentCard: View {
    let document: Document
    @State private var showAbstract = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header with score badge
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(document.title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(2)

                    Text(document.formattedAuthors)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if let journal = document.journal, let year = document.year {
                        Text("\(journal), \(year)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                if let score = document.relevanceScore {
                    ScoreBadge(score: score)
                }
            }

            // Score explanation
            if let explanation = document.scoreExplanation, !explanation.isEmpty {
                Text(explanation)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .italic()
                    .padding(.top, 2)
            }

            // Expandable abstract
            Button(action: { withAnimation { showAbstract.toggle() } }) {
                HStack {
                    Text(showAbstract ? "Hide Abstract" : "Show Abstract")
                        .font(.caption)
                    Image(systemName: showAbstract ? "chevron.up" : "chevron.down")
                        .font(.caption)
                }
                .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)

            if showAbstract {
                Text(document.abstract)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 4)
            }

            // Citations from this document
            if !document.citations.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Key Passages:")
                        .font(.caption)
                        .fontWeight(.medium)

                    ForEach(document.citations, id: \.id) { citation in
                        Text("\"\(citation.passage)\"")
                            .font(.caption)
                            .italic()
                            .foregroundColor(.secondary)
                            .padding(.leading, 8)
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding()
        .background(Color.white.opacity(0.5))
        .cornerRadius(8)
    }
}

struct ScoreBadge: View {
    let score: Int

    var body: some View {
        Text("\(score)")
            .font(.caption)
            .fontWeight(.bold)
            .foregroundColor(.white)
            .frame(width: 28, height: 28)
            .background(scoreColor)
            .clipShape(Circle())
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

/// Simple markdown text renderer.
struct MarkdownText: View {
    let content: String

    init(_ content: String) {
        self.content = content
    }

    var body: some View {
        if let attributed = try? AttributedString(markdown: content) {
            Text(attributed)
                .font(.body)
        } else {
            Text(content)
                .font(.body)
        }
    }
}

#Preview {
    let report = EvidenceReport(
        verdict: .partiallySupported,
        summary: "The evidence suggests that vitamin D may have some protective effects, but results are mixed across studies.",
        fullReport: """
        ## Evidence Analysis

        Multiple studies have examined the relationship between vitamin D and COVID-19 outcomes.

        **Supporting Evidence:**
        - A meta-analysis found reduced ICU admission rates [Smith, 2021]
        - Observational studies show correlation with better outcomes [Jones, 2022]

        **Limitations:**
        - Most studies are observational
        - Dosage varies significantly across trials

        ## Conclusion

        While there is suggestive evidence, more randomized controlled trials are needed.
        """,
        citationCount: 5,
        uniqueSourceCount: 3,
        documentsReviewed: 15
    )

    return ReportView(report: report)
}
