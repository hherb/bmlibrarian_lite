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

                    // Claim (if available from session)
                    if let claim = report.session?.claim {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Claim")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(claim)
                                .font(.body)
                                .italic()
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
